/// Local Yönetici browser app API (`/api/yonetici/*`, spec §23.4, task L3).
///
/// Always requires an individual login (client `yonetici`), whatever the
/// "Bireysel giriş zorunlu" switch says: there is no legacy manager page to
/// keep alive. Reuses the paired manager app's projections
/// ([FinanceSyncServer.ownerOverview], `monthView`, `managerWrite`, `report`)
/// so Windows stays the single source of business rules.
///
/// Financial data (sales totals, monthly finance, payroll, PDF reports) is
/// only served once the owner has allowed it on Windows (`local_finance_http`)
/// — spec §23.4.7 asks for a trusted-HTTPS check on a physical iPhone first.
library;

import 'daily_report.dart';
import 'finance_sync_server.dart';
import 'lan_auth_gate.dart';
import 'local_accounts.dart';
import 'pos_logic.dart';
import 'pos_store.dart';
import 'staff_commands.dart';

class YoneticiApi {
  YoneticiApi(this.store, this.gate);
  final PosStore store;
  final LanAuthGate gate;
  static const client = 'yonetici';

  LocalAuth get auth => gate.auth;

  /// Owner opt-in on Windows until local HTTPS is verified (§23.4.7).
  bool financeAllowed({required bool secure}) =>
      secure || auth.setting('local_finance_http') == '1';

  GateDecision _guard(String? token, String op, {bool touch = true}) => gate.guard(
      token: token, client: client, operation: op, touch: touch, forceRequired: true);

  bool _can(AuthContext ctx, String op) => auth.authorize(ctx, op) == 'ok';

  static String writeOperation(Json body) =>
      '${body['action']}'.startsWith('payroll_') ? 'payroll.manage' : 'finance.edit';

  Future<GateReply> handle(String method, String path, Json query, Json body,
      {String? token, bool secure = false}) async {
    try {
      switch ((method, path)) {
        case ('GET', 'overview'):
          final d = _guard(token, 'dashboard.view', touch: query['poll'] != '1');
          if (!d.allowed) return GateReply(d.status, {'error': d.error});
          final ctx = d.context!;
          final view = FinanceSyncServer.ownerOverview(store.read().data, '${query['day'] ?? ''}');
          final money = financeAllowed(secure: secure) && _can(ctx, 'sales.view');
          if (!money) {
            view.remove('cashCents');
            view.remove('cardCents');
          }
          if (!_can(ctx, 'staff.view')) {
            view.remove('staff');
            view.remove('employees');
          } else {
            view['employees'] = [
              for (final e in asMaps(view['employees']))
                {for (final k in ['id', 'name', 'active']) k: e[k]},
            ];
          }
          if (!financeAllowed(secure: secure) || !_can(ctx, 'finance.view')) view.remove('market');
          // The old review cache is superseded by the review repository.
          view.remove('reviews');
          return GateReply(200, {
            'view': view,
            'session': ctx.toJson(),
            'financeAllowed': financeAllowed(secure: secure),
          });
        case ('GET', 'daily'):
          // §24.7 Gün Sonu Raporu: counts for dashboard.view; amounts need
          // sales.view (+ finance.view for expenses) and the finance gate.
          final d = _guard(token, 'dashboard.view');
          if (!d.allowed) return GateReply(d.status, {'error': d.error});
          final ctx = d.context!;
          final money = financeAllowed(secure: secure) && _can(ctx, 'sales.view');
          final report = buildDailyReport(store.read().data, '${query['day'] ?? ''}');
          return GateReply(200, {'report': redactDailyReport(report,
              money: money, expenses: _can(ctx, 'finance.view'))});
        case ('GET', 'month'):
          final d = _guard(token, 'finance.view');
          if (!d.allowed) return GateReply(d.status, {'error': d.error});
          if (!financeAllowed(secure: secure)) return const GateReply(403, {'error': 'https_required'});
          final snap = store.read();
          final view = FinanceSyncServer.monthView(snap.data, '${query['month'] ?? ''}');
          if (!_can(d.context!, 'payroll.view')) {
            view.remove('weeklyPayroll');
            view['employees'] = [
              for (final e in asMaps(view['employees'])) {'id': e['id'], 'name': e['name']},
            ];
            (view['summary'] as Map).remove('payrollCents');
          }
          return GateReply(200, {'revision': snap.revision, 'view': view});
        case ('POST', 'write'):
          final d = _guard(token, writeOperation(body));
          if (!d.allowed) return GateReply(d.status, {'error': d.error});
          if (!financeAllowed(secure: secure)) return const GateReply(403, {'error': 'https_required'});
          try {
            return GateReply(200, FinanceSyncServer.managerWrite(store, body));
          } on FinanceVersionConflict {
            return const GateReply(409, {'error': 'conflict',
              'message': 'Kayıt Windows üzerinde değişti. Yenileyin ve karşılaştırın.'});
          } on StaffConflict {
            return const GateReply(409, {'error': 'conflict',
              'message': 'Kayıt Windows üzerinde değişti. Yenileyin ve karşılaştırın.'});
          }
        case ('POST', 'report'):
          final d = _guard(token, 'reports.export');
          if (!d.allowed) return GateReply(d.status, {'error': d.error});
          if (!financeAllowed(secure: secure)) return const GateReply(403, {'error': 'https_required'});
          return GateReply(200, await FinanceSyncServer.report(store.read().data, body));
      }
      return const GateReply(404, {'error': 'not_found'});
    } on FormatException catch (e) {
      return GateReply(422, {'error': 'invalid_request', 'message': e.message});
    }
  }
}
