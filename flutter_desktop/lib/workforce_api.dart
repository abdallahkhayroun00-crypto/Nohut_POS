/// `/api/work/*` for the local Personel and Yönetici browser apps
/// (spec §24.4, tasks W1/W2). Always needs an individual login, even while
/// the legacy shared Personel panel is still allowed: hours and schedules
/// belong to a person. The acting employee is the signed-in session, never
/// a value sent by the phone.
library;

import 'lan_auth_gate.dart';
import 'local_accounts.dart';
import 'pos_logic.dart';
import 'pos_store.dart';
import 'personal_performance.dart';
import 'finance_logic.dart' show financeRows, saveQuickMaterialPurchase, materialStores, financeMethods;
import 'payroll.dart' show payrollStatus, payRateOn, payrollPaymentsFor;
import 'workforce.dart';

class WorkforceApi {
  WorkforceApi(this.store, this.gate, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final PosStore store;
  final LanAuthGate gate;
  final DateTime Function() _clock;

  LocalAuth get auth => gate.auth;

  Future<GateReply> handle(String method, String path, Map<String, String> query, Json body,
      {String? token}) async {
    final client = '${body['client'] ?? query['client'] ?? 'personel'}' == 'yonetici' ? 'yonetici' : 'personel';
    GateDecision guard(String op, {bool touch = true}) =>
        gate.guard(token: token, client: client, operation: op, touch: touch, forceRequired: true);
    final now = _clock();
    final today = dayOf(istanbulNow(now));
    String week(Object? raw) {
      final w = '${raw ?? ''}';
      return isCalendarDay(w) ? weekStartOf(w) : weekStartOf(today);
    }
    try {
      switch ((method, path)) {
        case ('GET', 'week'):
          final d = guard('shifts.self', touch: query['poll'] != '1');
          if (!d.allowed) return GateReply(d.status, {'error': d.error});
          final ctx = d.context!;
          final manager = auth.authorize(ctx, 'shifts.manage') == 'ok';
          final requested = int.tryParse('${query['employeeId'] ?? ''}');
          final who = manager && requested != null ? requested : ctx.employeeId;
          if (who == null) return const GateReply(409, {'error': 'no_employee',
            'message': 'Hesabınız bir personele bağlı değil. Windows › Kullanıcılar’dan bağlayın.'});
          final view = ownWeek(store.read().data, who, week(query['weekStart']));
          // Rate is payroll data: only for the person themself or payroll.view.
          if (who != ctx.employeeId && auth.authorize(ctx, 'payroll.view') != 'ok') {
            (view['employee'] as Map)..remove('payRateCents')..remove('payType');
          }
          // Own earned / paid / remaining (staff see only their own).
          if (who == ctx.employeeId || auth.authorize(ctx, 'payroll.view') == 'ok') {
            final data = store.read().data;
            view['pay'] = payrollStatus(data, who, view['weekStart'] as String, today: today);
            view['payments'] = [
              for (final p in payrollPaymentsFor(data, who, view['weekStart'] as String))
                {for (final k in ['id', 'paidOn', 'kind', 'method', 'amountCents', 'reverses']) k: p[k]},
            ];
            final emp = asMaps(data['employees']).where((e) => e['id'] == who).firstOrNull;
            final rate = emp == null ? null : payRateOn(emp, view['weekStart'] as String);
            (view['employee'] as Map)..['payType'] = rate?.$1..['payRateCents'] = rate?.$2;
          }
          return GateReply(200, {'today': today, 'self': who == ctx.employeeId, 'week': view});
        case ('GET', 'performance'):
          // Own numbers only; a phone never chooses whose.
          final d = guard('shifts.self', touch: query['poll'] != '1');
          if (!d.allowed) return GateReply(d.status, {'error': d.error});
          final who = d.context!.employeeId;
          if (who == null) return const GateReply(409, {'error': 'no_employee',
            'message': 'Hesabınız bir personele bağlı değil. Windows › Kullanıcılar’dan bağlayın.'});
          return GateReply(200, {'today': today, 'performance': personalPerformance(
              store.read().data, who, performanceRangeOf(query['range']), today)});
        case ('GET', 'expenses'):
          // §24.8 Hızlı Gider for staff with the explicit grant: own rows only.
          final d = guard('expenses.quick_add', touch: query['poll'] != '1');
          if (!d.allowed) return GateReply(d.status, {'error': d.error});
          final who = d.context!.employeeId;
          if (who == null) return const GateReply(409, {'error': 'no_employee',
            'message': 'Hesabınız bir personele bağlı değil. Windows › Kullanıcılar’dan bağlayın.'});
          final from = addDays(today, -30);
          return GateReply(200, {'today': today, 'stores': materialStores, 'methods': financeMethods,
            'expenses': [
              for (final r in financeRows(store.read().data, 'materials').reversed)
                if (r['submittedByEmployeeId'] == who && '${r['date']}'.compareTo(from) >= 0)
                  {for (final k in ['id', 'date', 'storeBrand', 'market', 'amountsCents', 'totalCents',
                    'paymentMethod', 'note', 'voided', 'createdAt']) k: r[k]},
            ]});
        case ('POST', 'expense'):
          final d = guard('expenses.quick_add');
          if (!d.allowed) return GateReply(d.status, {'error': d.error});
          final ctx = d.context!;
          final who = ctx.employeeId;
          if (who == null) return const GateReply(409, {'error': 'no_employee',
            'message': 'Hesabınız bir personele bağlı değil. Windows › Kullanıcılar’dan bağlayın.'});
          final requestId = body['requestId'];
          final amounts = body['amountsCents'];
          if (requestId is! String || !RegExp(r'^[A-Za-z0-9_-]{16,80}$').hasMatch(requestId) ||
              amounts is! List || !amounts.every((x) => x is int)) {
            return const GateReply(422, {'error': 'invalid_request'});
          }
          final name = asMaps(store.read().data['employees'])
              .where((e) => e['id'] == who).firstOrNull?['name'];
          // Create only; edits and voids stay with finance.edit (Yönetici).
          final r = store.command('qexp_$requestId', {...body, 'employeeId': who}, (state) {
            saveQuickMaterialPurchase(state, date: '${body['date']}',
              storeBrand: '${body['storeBrand']}', amountsCents: amounts.cast<int>(),
              market: '${body['market'] ?? ''}', paymentMethod: '${body['paymentMethod'] ?? 'Nakit'}',
              note: '${body['note'] ?? ''}', submittedByEmployeeId: who,
              submittedByName: name is String ? name : ctx.username);
            final rows = financeRows(state, 'materials');
            final row = rows.reduce((a, b) => (a['id'] as int) > (b['id'] as int) ? a : b);
            return {'ok': true, 'id': row['id'], 'totalCents': row['totalCents']};
          });
          return GateReply(200, r);
        case ('GET', 'schedule'):
          final d = guard('shifts.self', touch: query['poll'] != '1');
          if (!d.allowed) return GateReply(d.status, {'error': d.error});
          final from = week(query['weekStart']);
          return GateReply(200, {'weekStart': from, 'today': today,
            'plans': sharedSchedule(store.read().data, from, addDays(from, 6), viewerId: d.context!.employeeId)});
        case ('GET', 'team'):
          final d = guard('shifts.manage', touch: query['poll'] != '1');
          if (!d.allowed) return GateReply(d.status, {'error': d.error});
          final w = week(query['weekStart']);
          return GateReply(200, {'weekStart': w, 'today': today, 'team': teamWeek(store.read().data, w)});
        case ('POST', 'write'):
          final action = '${body['action'] ?? ''}';
          final d = guard('shifts.self');
          if (!d.allowed) return GateReply(d.status, {'error': d.error});
          final ctx = d.context!;
          final manager = auth.authorize(ctx, 'shifts.manage') == 'ok';
          final name = ctx.username ?? '';
          final payload = Map<String, dynamic>.from(body)..remove('client');
          final Json result;
          if (action.startsWith('plan_')) {
            result = applyPlanCommand(store, payload, actorId: ctx.employeeId, actorName: name,
                manager: manager, now: now);
          } else if (action.startsWith('work_')) {
            // Only one's own actual hours; managers use the audited correction.
            payload.remove('employeeId');
            result = applyWorkCommand(store, payload, actorId: ctx.employeeId, actorName: name, now: now);
          } else if (action == 'week_submit') {
            result = submitWeek(store, payload, actorId: ctx.employeeId, now: now);
          } else {
            return const GateReply(422, {'error': 'invalid_request'});
          }
          return GateReply(200, result);
      }
      return const GateReply(404, {'error': 'not_found'});
    } on OverlapWarning catch (e) {
      return GateReply(409, {'error': 'overlap', 'message': e.message});
    } on WorkforceConflict catch (e) {
      return GateReply(409, {'error': 'conflict', 'message': e.message});
    } on FormatException catch (e) {
      return GateReply(422, {'error': 'invalid_request', 'message': e.message});
    }
  }
}
