import 'dart:io';
import 'dart:convert';

import 'package:nohut_core/finance_wire.dart';
import 'package:nohut_core/report_period.dart';

import 'payroll.dart';
import 'personal_performance.dart';
import 'demand_view.dart';
import 'workforce.dart' as wf show addDays, isCalendarDay, istanbulDayOfInstant, sharedSchedule, weekStartOf, workMinutes;
import 'finance_logic.dart';
import 'google_business.dart';
import 'staff_commands.dart';
import 'campaign_menu.dart';
import 'operations.dart';
import 'order_reporting.dart';
import 'market_prices.dart';
import 'trendyol_go_readonly.dart';
import 'package:nohut_core/management_sections.dart';
import 'finance_pdf.dart';
import 'pos_logic.dart';
import 'pos_store.dart';
import 'qr_menu_remote.dart';
import 'windows_vault.dart';

/// Independent, physically enrolled financial capability. Never grant it to
/// an ordinary staff bearer token. The key is held in the Windows DPAPI vault.
class FinanceSyncServer {
  FinanceSyncServer(this.store, {this.staffProjection, this.googleProvider, this.ownerEmployeeIds, this.menuRemote}) :
    vault = WindowsVault(File(store.filePath + '.finance-sync.dpapi'));

  final PosStore store;
  final Json Function(Json)? staffProjection;
  final GoogleBusiness Function()? googleProvider;
  /// Employee profiles linked to owner accounts (Windows › Kullanıcılar).
  final List<int> Function()? ownerEmployeeIds;
  /// QR publish / verify / POS sync with Windows' key (owner channel).
  final QrMenuRemoteService? menuRemote;

  Json _owner(Json state) => owner(state, ownerIds: ownerEmployeeIds?.call() ?? const []);

  /// The owner profile: the active employee linked to the owner account.
  /// Installs without a linked owner account keep the legacy name match so
  /// an existing pairing keeps working after the upgrade.
  static Json owner(Json state, {List<int> ownerIds = const []}) {
    final active = asMaps(state['employees']).where((e) => e['active'] == true && e['id'] is int);
    final linked = active.where((e) => ownerIds.contains(e['id'])).toList();
    if (linked.length == 1) return linked.single;
    final legacy = active.where((e) => e['name'] == legacyManagementOwnerName).toList();
    if (ownerIds.isEmpty && legacy.length == 1) return legacy.single;
    throw const FormatException(
        'İşletme sahibi hesabını bir personel profiline bağlayın (Ayarlar › Güvenlik › Kullanıcılar).');
  }

  Future<String> rotateOwnerKey() async {
    final employee = _owner(store.read().data);
    if (_changing) throw StateError('Yönetici anahtarı değişiyor.');
    _changing = true;
    _generation++;
    try {
      final key = FinanceWire.createKey();
      await vault.save({'key': key, 'managerReports': true, 'ownerId': employee['id']});
      return key;
    } finally { _changing = false; }
  }
  final WindowsVault vault;
  int _generation = 0;
  bool _changing = false;

  Future<String> rotateKey() async {
    if (_changing) throw StateError('Finans anahtarı değişiyor.');
    _changing = true;
    _generation++;
    try {
      final key = FinanceWire.createKey();
      await vault.save({'key': key, 'managerReports': true});
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
        'totalCents', 'paymentMethod', 'voided', 'updatedAt', 'note',
        'discountType', 'discountValue', 'amountsCents',
      ]),
      'weeklyPayroll': pick('weeklyPayroll', (r) => matches(r, 'weekEnd'), [
        'id', 'employeeId', 'employeeName', 'weekStart', 'weekEnd',
        'payType', 'rateCents', 'workedMinutes', 'bonusCents', 'advanceCents',
        'grossCents', 'payableCents', 'paid', 'updatedAt',
      ]),
      // Amount in force for the requested month, not today's amount.
      'monthlyFixed': [
        for (final (r, amount) in fixedDueRows(state, month))
          {
            for (final key in ['id', 'category', 'name', 'startMonth',
                'dueDay', 'updatedAt'])
              key: r[key],
            'amountCents': amount,
          },
      ],
      'fixedPayments': pick('fixedPayments', (r) => r['month'] == month, [
        'templateId', 'month', 'paidAt', 'amountCents',
      ]),
      'other': pick('other', (r) => matches(r, 'date'), [
        'id', 'date', 'category', 'name', 'amountCents', 'paymentMethod',
        'voided', 'createdAt',
      ]),
      'manualPlatformSales': pick('manualPlatformSales', (r) => r['month'] == month &&
        r['voided'] != true, ['source', 'month', 'kind', 'amountCents', 'note', 'updatedAt']),
      'employees': [
        for (final e in asMaps(state['employees']))
          if (e['active'] == true)
            {for (final key in ['id', 'name', 'payType', 'payRateCents']) key: e[key]},
      ],
    };
  }

  /// Manager operations reuse the desktop domain rules. A stale edit is
  /// rejected at the transaction boundary; append-only expenses can be
  /// safely retried using the same persisted request ID.
  static Json managerWrite(PosStore store, Json payload) {
    final id = payload['requestId'];
    final action = payload['action'];
    if (id is! String || !RegExp(r'^[A-Za-z0-9_-]{16,80}$').hasMatch(id) ||
        action is! String || payload['data'] is! Map) {
      throw const FormatException('Finans işlemi geçersiz.');
    }
    final d = Map<String, dynamic>.from(payload['data'] as Map);
    String str(String key) {
      if (d[key] is! String) throw const FormatException('Metin alanı geçersiz.');
      return d[key] as String;
    }
    int num(String key) {
      if (d[key] is! int) throw const FormatException('Sayı alanı geçersiz.');
      return d[key] as int;
    }
    bool flag(String key) {
      if (d[key] is! bool) throw const FormatException('Seçim geçersiz.');
      return d[key] as bool;
    }
    final actor = '${payload['actor'] ?? 'Android yönetici'}';
    return store.command('fin_mgr_' + id, payload, (state) {
      Json? row(String collection, bool Function(Json) match) =>
        financeRows(state, collection).where(match).firstOrNull;
      void check(Json? current, {String field = 'updatedAt'}) {
        if ((current?[field] ?? null) != d['expectedVersion']) {
          throw const FinanceVersionConflict();
        }
      }
      switch (action) {
        case 'other_create':
          saveOtherExpense(state, day: str('date'), category: str('category'),
            name: str('name'), amountCents: num('amountCents'),
            paymentMethod: str('paymentMethod'));
        case 'other_void':
          final current = row('other', (r) => r['id'] == num('id') && r['voided'] != true);
          if (current == null) throw const FinanceVersionConflict();
          check(current, field: 'createdAt');
          voidOtherExpense(state, num('id'), str('reason'));
        case 'payroll_save':
          final employee = asMaps(state['employees']).where((r) =>
            r['id'] == num('employeeId') && r['active'] == true).firstOrNull;
          if (employee == null || employee['payRateCents'] != d['expectedRate'] ||
              employee['payType'] != d['expectedPayType']) {
            throw const FinanceVersionConflict();
          }
          check(row('weeklyPayroll', (r) => r['employeeId'] == num('employeeId') &&
            r['weekStart'] == str('weekStart')));
          saveWeeklyPayroll(state, employeeId: num('employeeId'),
            weekStart: str('weekStart'), workedMinutes: num('workedMinutes'),
            bonusCents: num('bonusCents'), advanceCents: num('advanceCents'),
            paid: flag('paid'));
        case 'payroll_paid':
          final current = row('weeklyPayroll', (r) =>
            r['employeeId'] == num('employeeId') && r['weekStart'] == str('weekStart'));
          if (current == null) throw const FinanceVersionConflict();
          check(current);
          markWeeklyPayrollPaid(state, num('employeeId'), str('weekStart'));
        case 'fixed_save':
          if (d['id'] != null) {
            final current = row('monthlyFixed', (r) => r['id'] == num('id'));
            if (current == null) throw const FinanceVersionConflict();
            check(current);
          }
          saveMonthlyFixed(state, id: d['id'] == null ? null : num('id'),
            category: str('category'), name: str('name'),
            amountCents: num('amountCents'), startMonth: str('startMonth'),
            dueDay: num('dueDay'), active: flag('active'));
        case 'fixed_paid':
          final current = row('monthlyFixed', (r) => r['id'] == num('id'));
          if (current == null) throw const FinanceVersionConflict();
          check(current);
          final payment = row('fixedPayments', (r) =>
            r['templateId'] == num('id') && r['month'] == str('month'));
          if (payment?['paidAt'] != d['expectedPaidAt']) {
            throw const FinanceVersionConflict();
          }
          markMonthlyFixedPaid(state, num('id'), str('month'), flag('paid'));
        case 'manual_save':
          check(manualPlatformIncome(state, str('source'), str('month')));
          saveManualPlatformIncome(state, source: str('source'),
            month: str('month'), kind: str('kind'),
            amountCents: num('amountCents'), note: str('note'));
        case 'manual_void':
          final current = manualPlatformIncome(state, str('source'), str('month'));
          if (current == null) throw const FinanceVersionConflict();
          check(current);
          voidManualPlatformIncome(state, str('source'), str('month'));
        // V6.0 payroll (lib/payroll.dart): rates with effective dates and an
        // immutable payment ledger; nothing here initiates a transfer.
        case 'payroll_rate':
          setEmployeeRate(state, employeeId: num('employeeId'), payType: str('payType'),
            rateCents: num('rateCents'), effectiveFrom: str('effectiveFrom'), by: actor);
        case 'payroll_payment':
          final w = str('weekStart');
          if (d['expectedPaidCents'] != null &&
              payrollStatus(state, num('employeeId'), w, today: '9999-12-31')['paidCents'] != d['expectedPaidCents']) {
            throw const FinanceVersionConflict();
          }
          recordPayrollPayment(state, {...d, 'requestId': id}, by: actor);
        case 'payroll_reverse':
          reversePayrollPayment(state, d, by: actor);
        case 'payroll_unpaid':
          acknowledgeUnpaid(state, d, by: actor);
        case 'payroll_eligible':
          if (d['eligible'] is! bool) throw const FormatException('Bordro seçimi geçersiz.');
          setPayrollEligible(state, num('employeeId'), d['eligible'] as bool);
        case 'quick_save':
          // §24.8 Hızlı Gider Ekle from Yönetici (LAN + Android): same rules
          // as the Windows quick form; edits need the exact prior version.
          int? editId;
          if (d['id'] != null) {
            editId = num('id');
            final current = row('materials', (r) => r['id'] == editId);
            if (current == null || current['voided'] == true || !isQuickMaterial(current)) {
              throw const FinanceVersionConflict();
            }
            check(current);
          }
          final amounts = d['amountsCents'];
          if (amounts is! List || !amounts.every((x) => x is int)) {
            throw const FormatException('Tutarlar geçersiz.');
          }
          saveQuickMaterialPurchase(state, id: editId, date: str('date'),
            storeBrand: str('storeBrand'), amountsCents: amounts.cast<int>(),
            market: str('market'), paymentMethod: str('paymentMethod'),
            note: str('note'));
        case 'quick_void':
          final current = row('materials', (r) => r['id'] == num('id'));
          if (current == null || current['voided'] == true || !isQuickMaterial(current)) {
            throw const FinanceVersionConflict();
          }
          check(current);
          voidMaterialPurchase(state, num('id'), str('reason'));
        case 'material_save':
          Json? current;
          if (d['id'] != null) {
            current = row('materials', (r) => r['id'] == num('id'));
            if (current == null || current['voided'] == true || isQuickMaterial(current)) {
              throw const FinanceVersionConflict();
            }
            check(current);
          }
          saveMaterialPurchase(state, id: d['id'] == null ? null : num('id'),
            date: str('date'), title: str('title'), unit: str('unit'),
            quantityMilli: num('quantityMilli'), pricePerUnitCents: num('pricePerUnitCents'),
            storeBrand: str('storeBrand'), market: str('market'),
            marketKey: (current?['marketKey'] ?? '').toString(),
            marketUnit: (current?['marketUnit'] ?? '').toString(),
            referencePriceCents: current?['referencePriceCents'] as int?,
            paymentMethod: str('paymentMethod'), discountType: str('discountType'),
            discountValue: num('discountValue'), note: str('note'));
        case 'material_void':
          final current = row('materials', (r) => r['id'] == num('id'));
          if (current == null || current['voided'] == true || isQuickMaterial(current)) {
            throw const FinanceVersionConflict();
          }
          check(current);
          voidMaterialPurchase(state, num('id'), str('reason'));
        default:
          throw const FormatException('Desteklenmeyen finans işlemi.');
      }
      return {'ok': true, 'requestId': id};
    });
  }

  /// Read-only, explicit operational projections; never ship the POS state,
  /// credentials, customer contacts or unrestricted database write access.
  static Json ownerOverview(Json state, String day) {
    if (!validBusinessDate(day)) throw const FormatException('Tarih geçersiz.');
    final period = ReportPeriod(day, day);
    final facts = managementReportFacts(state, period);
    final orders = asMaps(state['orders']);
    final today = orders.where((o) => period.includesStamp(o['createdAt'])).toList();
    Json projectOrder(Json o) => {
      for (final k in ['id','dailyNumber','source','table','createdAt','closed','cancelled','status','serviceStatus']) k:o[k],
      'totalCents': orderTotalCents(o), 'paidCents': orderPaidCents(o), 'dueCents': orderDueCents(o),
      'owner': orderOwnerName(o),
    };
    final payments = ledger(state).where((p)=>period.includesStamp(p.stamp) &&
      ['Masa','Gel-Al'].contains(p.source)).toList();
    final cash = payments.where((p)=>p.method=='Nakit').fold<int>(0,(n,p)=>n+p.amount);
    final card = payments.where((p)=>p.method=='Kart').fold<int>(0,(n,p)=>n+p.amount);
    // §24.3 Yönetici Ana Sayfa: today's team. Planned shifts are names and
    // times only; actual hours are the staff's own Mesai records for the day.
    final worked = <Object?, Json>{};
    final names = {for (final e in asMaps(state['employees'])) e['id']: e['name']};
    for (final w in asMaps(state['shifts'])) {
      final start = DateTime.tryParse('${w['start']}');
      if (start == null || wf.istanbulDayOfInstant(start) != day) continue;
      final m = wf.workMinutes(w);
      if (m <= 0) continue;
      final row = worked.putIfAbsent(w['employeeId'], () => {'employeeId': w['employeeId'],
        'name': w['employeeName'] ?? names[w['employeeId']] ?? '', 'minutes': 0});
      row['minutes'] = (row['minutes'] as int) + m;
    }
    return {
      'day':day, 'cashCents':cash, 'cardCents':card,
      'activeTables':{for (final o in orders) if (o['source']=='Masa' && o['closed']!=true && o['cancelled']!=true) o['table']}.length,
      'team':{
        'planned':[for (final p in wf.sharedSchedule(state, day, day)) if (p['dayOff'] != true)
          {for (final k in ['employeeName','start','end','endsNextDay']) k:p[k]}],
        'worked':worked.values.toList(),
        'actualMinutes':worked.values.fold<int>(0, (n, r) => n + (r['minutes'] as int)),
      },
      'orderCount':today.where((o)=>o['cancelled']!=true && ['Masa','Gel-Al'].contains(o['source'])).length,
      'orders':today.reversed.take(100).map(projectOrder).toList(),
      'openAccounts':orders.where((o)=>['Masa','Gel-Al'].contains(o['source']) &&
        o['closed']!=true && o['cancelled']!=true && orderDueCents(o)>0)
        .map(projectOrder).toList(),
      'online':[
        for(final o in today.where((o)=>!['Masa','Gel-Al','Trendyol Go'].contains(o['source']) &&
          o['testPackage']!=true && o['demoRemoteStatus']==null)) projectOrder(o),
        for(final o in tgoOrders(state).where((o)=>period.includesStamp(o['createdAt']) && o['testPackage']!=true))
          {for(final k in ['orderNumber','status','createdAt','totalCents']) k:o[k], 'source':'Trendyol Go'},
      ],
      'staff':[
        for(final p in facts['staff'] as List<Json>) {
          for(final k in ['name','tableOrders','pickupOrders','ownedCents','batches','extraBatches','items']) k:p[k],
          'distinctTables':(p['tables'] as Set<String>).length,
        },
      ],
      'hourly':hourlyOrderCounts(today.where((o)=>['Masa','Gel-Al'].contains(o['source'])),from:day,to:day),
      'menu':[
        for(final p in orderingProducts(state))
          {for(final k in ['id','name','category','price','active']) k:p[k]},
      ],
      'market':[
        for(final p in trackedMarketProducts(state))
          {for(final k in ['title','market','unit','priceCents','lastCheckedAt']) k:p[k]},
      ],
      'reviews': [
        if (state['tgoReviewCache'] is Map)
          for(final r in asMaps((state['tgoReviewCache'] as Map)['reviews']).take(100))
            {for(final k in ['reviewId','rating','score','createdAt','comment']) k:r[k]},
      ],
      'employees':[
        for(final p in asMaps(state['employees']))
          {for(final k in ['id','name','role','active']) k:p[k]},
      ],
    };
  }

  /// §24.6 Haftalık Maaş Ödemeleri for the native Yönetici app: the same
  /// rows, statuses and money as `/api/yonetici/payroll` (one calculation in
  /// lib/payroll.dart). Payments go through `managerWrite` `payroll_payment`.
  static Json ownerPayroll(PosStore store, String weekStart, {required List<int> ownerIds, DateTime? now}) {
    ensureOwnerPayrollDefault(store, ownerIds);
    final state = store.read().data;
    final today = wf.istanbulDayOfInstant(now ?? DateTime.now());
    final week = wf.isCalendarDay(weekStart) ? wf.weekStartOf(weekStart) : wf.addDays(wf.weekStartOf(today), -7);
    return {'ok': true, 'weekStart': week, 'today': today,
      'rows': payrollWeek(state, week, today: today),
      'payments': [for (final p in financeRows(state, 'payrollPayments')) if (p['weekStart'] == week) p]};
  }

  static Future<Json> report(Json state, Json payload) async {
    if (payload['from'] is! String || payload['to'] is! String) {
      throw const FormatException('Rapor tarih aralığı gerekli. Uygulamayı güncelleyin.');
    }
    final period = ReportPeriod(payload['from'] as String, payload['to'] as String);
    final bytes = await generateManagementPdf(state, period);
    if (bytes.length > 12000000) {
      throw const FormatException('Rapor mobil aktarım sınırını aşıyor. Windows üzerinden tek PDF alın.');
    }
    return {'ok': true, 'name': period.fileName, 'pdf': base64Encode(bytes)};
  }

  Future<Json> handle(Json envelope, String serverId) async {
    if (_changing) throw const FormatException('Finans erişimi değişiyor.');
    final generation = _generation;
    final access = await vault.load();
    final key = access?['key'];
    if (key is! String) throw const FormatException('Finans erişimi kapalı.');
    final payload = await FinanceWire.open(key, serverId, 'request', envelope);
    if (_changing || generation != _generation) throw const FormatException('Finans erişimi değişti.');
    Json result;
    try {
      if (access?['ownerId'] != null && _owner(store.read().data)['id'] != access?['ownerId']) {
        throw const FormatException('Yönetici yetkisi kaldırıldı.');
      }
      final op = payload['operation'];
      if (op is String && op.startsWith('owner')) {
        final employee = _owner(store.read().data);
        if (access?['ownerId'] != employee['id']) throw const FormatException('İşletme sahibi eşleştirmesi gerekli.');
        if (op == 'ownerHello') {
          result = {'ok':true,'ownerId':employee['id'],'ownerName':employee['name']};
        } else if (op == 'ownerOverview') {
          result = {'ok':true,'view':ownerOverview(store.read().data, (payload['day'] ?? '').toString())};
        } else if (op == 'ownerDemand') {
          result = {'ok': true, 'demand': demandView(store.read().data,
              '${payload['range'] ?? ''}', wf.istanbulDayOfInstant(DateTime.now()))};
        } else if (op == 'ownerTeamPerformance') {
          result = {'ok': true, 'team': teamPerformance(store.read().data,
              performanceRangeOf('${payload['range'] ?? ''}'), wf.istanbulDayOfInstant(DateTime.now()))};
        } else if (op == 'ownerPayroll') {
          result = ownerPayroll(store, '${payload['weekStart'] ?? ''}',
              ownerIds: ownerEmployeeIds?.call() ?? [employee['id'] as int]);
        } else if (op == 'ownerMenu') {
          result = {'ok': true, 'menu': qrMenuView(store.read().data, can: (_) => true,
              link: await menuRemote?.linkState())};
        } else if (op == 'ownerMenuWrite') {
          if (payload['data'] is! Map) throw const FormatException('İstek geçersiz.');
          try {
            result = applyQrMenuCommand(store, Map<String, dynamic>.from(payload['data'] as Map),
                can: (_) => true, actor: '${employee['name']}', actorId: employee['id'] as int?);
          } on QrMenuConflict catch (e) {
            result = {'ok': false, 'error': 'conflict', 'message': e.message};
          }
        } else if (op == 'ownerMenuPublish' || op == 'ownerMenuReconcile' || op == 'ownerMenuSync' ||
            op == 'ownerMenuImage') {
          final r = menuRemote ?? (throw const FormatException('QR yayınlama bu bilgisayarda kapalı.'));
          final actor = '${employee['name']}';
          final id = employee['id'] as int?;
          final request = payload['data'] is Map ? Map<String, dynamic>.from(payload['data'] as Map) : <String, dynamic>{};
          try {
            result = switch (op) {
              'ownerMenuPublish' => await r.publish(expectedStamp: '${request['expectedStamp'] ?? ''}', actor: actor, actorId: id),
              'ownerMenuReconcile' => await r.reconcile(actor: actor, actorId: id),
              'ownerMenuImage' => await r.uploadImage(payload: request, can: (_) => true, actor: actor, actorId: id),
              _ => await r.sync(actor: actor),
            };
          } on QrMenuConflict catch (e) {
            result = {'ok': false, 'error': 'conflict', 'message': e.message};
          }
        } else if (op == 'ownerGoogle') {
          final google = googleProvider?.call();
          if (google == null || !google.connected) {
            result = {'ok':true,'connected':false};
          } else {
            final profile = await google.profile();
            final reviews = await google.reviews(pageToken: payload['pageToken'] as String?);
            result = {'ok':true,'connected':true,
              'profile':{for(final k in ['title','websiteUri','phoneNumbers','regularHours','openInfo']) k:profile[k]},
              'averageRating':reviews['averageRating'],'totalReviewCount':reviews['totalReviewCount'],
              'nextPageToken':reviews['nextPageToken'],
              'reviews':[for(final r in asMaps(reviews['reviews']))
                {for(final k in ['reviewId','starRating','comment','createTime','updateTime','reviewReply']) k:r[k]}],
            };
          }
        } else if (op == 'ownerGoogleReply') {
          final google = googleProvider?.call();
          if (google == null || !google.connected || payload['confirmed']!=true ||
              payload['reviewId'] is! String || payload['comment'] is! String) {
            throw const FormatException('Google bağlantısı ve yanıt onayı gerekli.');
          }
          await google.reply(payload['reviewId'] as String,payload['comment'] as String);
          result = {'ok':true};
        } else if (op == 'ownerBootstrap') {
          final snap = store.read();
          final project = staffProjection;
          if (project == null) throw const FormatException('Sipariş bağlantısı hazır değil.');
          final state = project(snap.data);
          state['employees'] = [{'id':employee['id'],'name':employee['name'],'active':true}];
          result = {'ok':true,'revision':snap.revision,'state':state,'serverId':serverId};
        } else if (op == 'ownerOrder' || op == 'ownerAction') {
          if (payload['data'] is! Map) throw const FormatException('İstek geçersiz.');
          final data = Map<String,dynamic>.from(payload['data'] as Map);
          data['staffId'] = employee['id'];
          result = op == 'ownerOrder' ? submitStaffOrder(store,data) : submitStaffAction(store,data);
        } else {
          throw const FormatException('Yönetici işlemi desteklenmiyor.');
        }
        if (_changing || generation != _generation) throw const FormatException('Finans erişimi değişti.');
        return await FinanceWire.seal(key,serverId,'response:' + envelope['nonce'].toString(),result);
      }
      if (['monthView', 'report', 'managerWrite'].contains(payload['operation']) &&
          access?['managerReports'] != true) {
        throw const FormatException('Yeni yönetici finans anahtarı gerekli.');
      }
      if (payload['operation'] == 'managerWrite') {
        result = managerWrite(store, payload);
      } else if (payload['operation'] == 'monthView') {
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
    } on StaffConflict {
      result = {'ok':false,'error':'conflict','message':'Windows kaydı değişti. Yenileyin.'};
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
