import 'dart:io';
import 'dart:convert';

import 'package:nohut_core/finance_wire.dart';

import 'finance_logic.dart';
import 'finance_pdf.dart';
import 'pos_logic.dart';
import 'pos_store.dart';
import 'windows_vault.dart';

/// Independent, physically enrolled financial capability. Never grant it to
/// an ordinary staff bearer token. The key is held in the Windows DPAPI vault.
class FinanceSyncServer {
  FinanceSyncServer(this.store) :
    vault = WindowsVault(File(store.filePath + '.finance-sync.dpapi'));

  final PosStore store;
  final WindowsVault vault;
  int _generation = 0;
  bool _changing = false;

  Future<String> rotateKey() async {
    if (_changing) throw StateError('Finans anahtarı değişiyor.');
    _changing = true;
    _generation++;
    try {
      final key = FinanceWire.createKey();
      await vault.save({'key': key});
      return key;
    } finally {
      _changing = false;
    }
  }

  Future<void> revoke() async {
    if (_changing) throw StateError('Finans anahtarı değişiyor.');
    _changing = true;
    _generation++;
    try {
      await vault.clear();
    } finally {
      _changing = false;
    }
  }

  static Json project(Json p) => {
    for (final name in [
      'id', 'date', 'storeBrand', 'market', 'amountsCents', 'totalCents',
      'paymentMethod', 'note', 'updatedAt', 'voided', 'voidedAt',
    ]) name: p[name],
  };

  /// Executed under the existing SQLite transaction and idempotency receipt.
  /// An edit/void requires the exact prior record version.
  static Json apply(PosStore store, Json payload) {
    final operation = payload['operation'];
    final requestId = payload['requestId'];
    if (requestId is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{16,80}$').hasMatch(requestId) ||
        !['create', 'edit', 'void'].contains(operation)) {
      throw const FormatException('Finans işlemi geçersiz.');
    }
    return store.command('fin_' + requestId, payload, (state) {
      final entries = financeRows(state, 'materials');
      final id = payload['recordId'];
      if (operation != 'create') {
        if (id is! int) throw const FormatException('Kayıt kimliği geçersiz.');
        final current = entries.where((p) => p['id'] == id).firstOrNull;
        if (current == null || !isQuickMaterial(current) ||
            current['voided'] == true ||
            current['updatedAt'] == null ||
            current['updatedAt'] != payload['expectedUpdatedAt']) {
          // No mutation; do not acknowledge an edit that was not applied.
          throw const FinanceVersionConflict();
        }
      }
      if (operation == 'void') {
        voidMaterialPurchase(state, id as int, 'Android yönetici iptali');
      } else {
        final data = payload['entry'];
        if (data is! Map || data['amountsCents'] is! List ||
            data['date'] is! String || data['storeBrand'] is! String ||
            data['paymentMethod'] is! String || data['market'] is! String ||
            data['note'] is! String ||
            !(data['amountsCents'] as List).every((x) => x is int)) {
          throw const FormatException('Gider alanları geçersiz.');
        }
        saveQuickMaterialPurchase(state,
          id: operation == 'create' ? null : id as int,
          date: data['date'] as String,
          storeBrand: data['storeBrand'] as String,
          amountsCents: (data['amountsCents'] as List).cast<int>(),
          market: data['market'] as String,
          paymentMethod: data['paymentMethod'] as String,
          note: data['note'] as String,
        );
      }
      final updated = financeRows(state, 'materials');
      final row = operation == 'create'
        ? updated.reduce((a, b) => (a['id'] as int) > (b['id'] as int) ? a : b)
        : updated.firstWhere((p) => p['id'] == id);
      return {'ok': true, 'record': project(row)};
    });
  }

  /// Explicitly scoped finance view. Never send the whole POS database,
  /// customer information, credentials or platform tokens to Android.
  static Json monthView(Json state, String month) {
    if (!validFinanceMonth(month)) throw const FormatException('Ay geçersiz.');
    final summary = financeMonthSummary(state, month);
    List<Json> pick(String collection, bool Function(Json) include,
        List<String> keys) => [
      for (final row in financeRows(state, collection).where(include))
        {for (final key in keys) key: row[key]},
    ];
    bool matches(Json row, String field) =>
      (row[field] ?? '').toString().startsWith(month);
    return {
      'month': month,
      'summary': {
        'localReceiptsCents': summary.localReceiptsCents,
        'onlineKnownNetCents': summary.onlineKnownNetCents,
        'onlineUnpricedGrossCents': summary.onlineUnpricedGrossCents,
        'materialsCents': summary.materialsCents,
        'payrollCents': summary.payrollCents,
        'fixedCents': summary.fixedCents,
        'otherCents': summary.otherCents,
        'totalExpensesCents': summary.totalExpensesCents,
        'estimateCents': summary.estimateCents,
      },
      'platforms': [
        for (final p in financePlatformFigures(state, month))
          {'source': p.source, 'origin': p.origin, 'inputKind': p.inputKind,
           'grossCents': p.grossCents, 'deductionCents': p.deductionCents,
           'netCents': p.netCents, 'automaticOrders': p.automaticOrders},
      ],
      'materials': pick('materials', (r) => matches(r, 'date'), [
        'id', 'recordType', 'date', 'title', 'market', 'storeBrand',
        'quantityMilli', 'unit', 'pricePerUnitCents', 'discountCents',
        'totalCents', 'paymentMethod', 'voided',
      ]),
      'weeklyPayroll': pick('weeklyPayroll', (r) => matches(r, 'weekEnd'), [
        'id', 'employeeId', 'employeeName', 'weekStart', 'weekEnd',
        'payType', 'rateCents', 'workedMinutes', 'bonusCents', 'advanceCents',
        'grossCents', 'payableCents', 'paid', 'updatedAt',
      ]),
      'monthlyFixed': pick('monthlyFixed', (r) => r['active'] == true &&
          (r['startMonth'] ?? '').toString().compareTo(month) <= 0, [
        'id', 'category', 'name', 'amountCents', 'startMonth', 'dueDay',
        'updatedAt',
      ]),
      'fixedPayments': pick('fixedPayments', (r) => r['month'] == month, [
        'templateId', 'month', 'paidAt', 'amountCents',
      ]),
      'other': pick('other', (r) => matches(r, 'date'), [
        'id', 'date', 'category', 'name', 'amountCents', 'paymentMethod',
        'voided', 'createdAt',
      ]),
      'employees': [
        for (final e in asMaps(state['employees']))
          if (e['active'] == true)
            {for (final key in ['id', 'name', 'payType', 'payRateCents']) key: e[key]},
      ],
    };
  }

  static Future<Json> report(Json state, Json payload) async {
    final kind = payload['kind'];
    final combined = kind == 'all';
    final selected = combined ? FinancePdfKind.monthly :
      FinancePdfKind.values.where((k) => k.name == kind).firstOrNull;
    if (selected == null || payload['month'] is! String ||
        payload['day'] is! String || payload['weekStart'] is! String) {
      throw const FormatException('Rapor türü veya tarihi geçersiz.');
    }
    final request = FinancePdfRequest(kind: selected,
      month: payload['month'] as String, day: payload['day'] as String,
      weekStart: payload['weekStart'] as String);
    final bytes = await generateFinancePdf(state, request, combined: combined);
    if (bytes.length > 1200000) {
      throw const FormatException('Rapor çok büyük. Daha kısa dönem seçin.');
    }
    return {'ok': true, 'name': combined
      ? 'Nohut_Tum_Finans_' + request.month + '.pdf' : request.suggestedName,
      'pdf': base64Encode(bytes)};
  }

  Future<Json> handle(Json envelope, String serverId) async {
    if (_changing) throw const FormatException('Finans erişimi değişiyor.');
    final generation = _generation;
    final key = (await vault.load())?['key'];
    if (key is! String) throw const FormatException('Finans erişimi kapalı.');
    final payload = await FinanceWire.open(key, serverId, 'request', envelope);
    if (_changing || generation != _generation) throw const FormatException('Finans erişimi değişti.');
    Json result;
    try {
      if (payload['operation'] == 'monthView') {
        if (payload['month'] is! String) throw const FormatException('Ay geçersiz.');
        final snap = store.read();
        result = {'ok': true, 'revision': snap.revision, 'updatedAt': snap.updatedAt,
          'view': monthView(snap.data, payload['month'] as String)};
      } else if (payload['operation'] == 'report') {
        result = await report(store.read().data, payload);
      } else if (payload['operation'] == 'pull') {
        final cursor = payload['afterId'];
        if (cursor is! int || cursor < 0) {
          throw const FormatException('Sayfa kimliği geçersiz.');
        }
        final rows = financeRows(store.read().data, 'materials')
          .where((p) => isQuickMaterial(p) && p['id'] is int &&
            (p['id'] as int) > cursor).toList()
          ..sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
        result = {
          'ok': true, 'records': rows.take(100).map(project).toList(),
          'hasMore': rows.length > 100,
        };
      } else {
        result = apply(store, payload);
      }
    } on FinanceVersionConflict {
      result = {'ok': false, 'error': 'conflict',
        'message': 'Kayıt Windows üzerinde değişti. Yenileyin ve karşılaştırın.'};
    } on FormatException catch (e) {
      result = {'ok': false, 'error': 'invalid', 'message': e.message};
    }
    if (_changing || generation != _generation) throw const FormatException('Finans erişimi değişti.');
    return FinanceWire.seal(key, serverId,
      'response:' + envelope['nonce'].toString(), result);
  }
}

class FinanceVersionConflict implements Exception {
  const FinanceVersionConflict();
}
