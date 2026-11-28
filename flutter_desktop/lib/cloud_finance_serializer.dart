/// Typed commercial finance facts. No user identity, provider payload,
/// password, device configuration or network operation belongs here.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as hash;
import 'package:sqlite3/sqlite3.dart';

import 'sync_outbox.dart';
import 'sync_worker.dart';

class CloudIdentityMap {
  CloudIdentityMap(this.db) {
    db.execute('CREATE TABLE IF NOT EXISTS cloud_source_ids('
      'kind TEXT NOT NULL,source_key TEXT NOT NULL,cloud_id TEXT NOT NULL UNIQUE,'
      'PRIMARY KEY(kind,source_key))');
  }
  final Database db;
  String id(String kind, Object sourceKey) {
    final key = jsonEncode(sourceKey);
    final found = db.select('SELECT cloud_id FROM cloud_source_ids WHERE kind=? AND source_key=?', [kind,key]);
    if (found.isNotEmpty) return found.single['cloud_id'] as String;
    final r = Random.secure();
    final bytes = List.generate(16, (_) => r.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final h = bytes.map((v) => v.toRadixString(16).padLeft(2,'0')).join();
    final uuid = '${h.substring(0,8)}-${h.substring(8,12)}-${h.substring(12,16)}-${h.substring(16,20)}-${h.substring(20)}';
    db.execute('INSERT OR IGNORE INTO cloud_source_ids(kind,source_key,cloud_id) VALUES(?,?,?)', [kind,key,uuid]);
    return db.select('SELECT cloud_id FROM cloud_source_ids WHERE kind=? AND source_key=?', [kind,key]).single['cloud_id'] as String;
  }
}

class FinanceProjectionRow {
  const FinanceProjectionRow(this.table, this.data);
  final String table;
  final Map<String,Object?> data;
  Map<String,Object?> toJson() => {'table':table,'data':data};
}

List<Map<String,dynamic>> _rows(Object? raw) {
  if (raw == null) return [];
  if (raw is! List || raw.any((r) => r is! Map)) throw const FormatException('Invalid finance collection');
  return raw.map((r) => Map<String,dynamic>.from(r as Map)).toList();
}

int _integer(Object? value) {
  if (value is! int || value.abs()>9007199254740991) throw const FormatException('Finance integer required');
  return value;
}

String _text(Object? value) {
  if (value is! String) throw const FormatException('Finance text required');
  return value;
}

String _month(Object? value) {
  final month = _text(value);
  if (!RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(month)) throw const FormatException('Invalid finance month');
  return '$month-01';
}

String _kind(Object? value) => switch (value) {
  'Brüt' => 'gross', 'Net' => 'net', _ => throw const FormatException('Invalid platform amount kind'),
};

/// Allocations are persisted in SQLite, so retry/restart/backup preserve IDs.
/// Local IDs and history timestamps identify existing source records; list
/// positions, labels and financial values never become record identities.
List<FinanceProjectionRow> serializeFinance(Map<String,dynamic> book, CloudIdentityMap ids) {
  const allowed = {'materials','monthlyFixed','fixedPayments','weeklyPayroll','other','manualPlatformSales','_fixedPaymentReversals','payrollPayments','payrollReviews'};
  if (book.keys.any((k) => !allowed.contains(k))) throw const FormatException('Unsupported finance category');
  final out = <FinanceProjectionRow>[];
  final seen = <String>{};
  void add(String table, Object source, Map<String,Object?> data) {
    if (!seen.add('$table:${jsonEncode(source)}')) throw const FormatException('Duplicate finance identity');
    out.add(FinanceProjectionRow(table,data));
  }
  for (final p in _rows(book['materials'])) {
    final local = _integer(p['id']), id = ids.id('material_purchase', local);
    add('material_purchases',local,{
      'purchase_id':id,'local_id':local,'business_day':_text(p['date']),'title':_text(p['title']),
      'record_type':p['recordType']??'detailed','unit':p['unit'],'quantity_milli':p['quantityMilli'],
      'unit_price_kurus':p['pricePerUnitCents'],'subtotal_kurus':p['subtotalCents'],
      'discount_kurus':p['discountCents'],'total_kurus':_integer(p['totalCents']),
      'store_brand':p['storeBrand'],'market':p['market'],'market_key':p['marketKey'],
      'market_unit':p['marketUnit'],'reference_price_kurus':p['referencePriceCents'],
      'discount_type':p['discountType'],'discount_value':p['discountValue'],
      'amounts_kurus':p['amountsCents'],'note':p['note'],'payment_method':_text(p['paymentMethod']),
      'voided':p['voided']??false,'voided_at':p['voidedAt'],'void_reason':p['voidReason'],
      'created_at':_text(p['createdAt']),
    });
    for (final h in _rows(p['history'])) {
      final key = [local,_text(h['changedAt'])];
      add('material_purchase_history',key,{
        'purchase_id':id,'history_id':ids.id('material_purchase_history',key),'changed_at':h['changedAt'],
        'previous_total_kurus':_integer(h['previousTotalCents']),
        'previous_discount_kurus':h['previousDiscountCents'],'previous_unit_price_kurus':h['previousUnitPriceCents'],
        'previous_quantity_milli':h['previousQuantityMilli'],'previous_day':h['previousDate'],
        'previous_store_brand':h['previousStoreBrand'],'previous_market':h['previousMarket'],
        'previous_amounts_kurus':h['previousAmountsCents'],'previous_payment_method':h['previousPaymentMethod'],
        'previous_note':h['previousNote'],
      });
    }
  }
  for (final f in _rows(book['monthlyFixed'])) {
    final local = _integer(f['id']), id = ids.id('fixed_expense',local);
    add('fixed_expenses',local,{'fixed_expense_id':id,'local_id':local,'category':_text(f['category']),
      'label':_text(f['name']),'amount_kurus':_integer(f['amountCents']),'start_month':_month(f['startMonth']),
      'due_day':_integer(f['dueDay']),'active':f['active']??true,'created_at':_text(f['createdAt'])});
    final ranges = f['activeRanges'] ?? [{'from':f['startMonth'],'to':null}];
    for (final range in _rows(ranges)) {
      final from = _month(range['from']);
      add('fixed_expense_active_ranges',[local,from],{'fixed_expense_id':id,'from_month':from,
        'to_month':range['to']==null?null:_month(range['to'])});
    }
    final history = f['amountHistory'] ?? [{'fromMonth':f['startMonth'],'amountCents':f['amountCents']}];
    for (final h in _rows(history)) {
      final month = _month(h['fromMonth']);
      add('fixed_expense_amount_history',[local,month],{'fixed_expense_id':id,'from_month':month,'amount_kurus':_integer(h['amountCents'])});
    }
  }
  for (final p in _rows(book['fixedPayments'])) {
    final local = _integer(p['templateId']), month = _month(p['month']);
    add('fixed_expense_payments',[local,month],{'fixed_expense_id':ids.id('fixed_expense',local),
      'payment_month':month,'amount_kurus':_integer(p['amountCents']),'paid_at':_text(p['paidAt']),
      'reversed':false,'reversed_at':null});
  }
  for (final p in _rows(book['_fixedPaymentReversals'])) {
    final local = _integer(p['templateId']), month = _month(p['month']);
    add('fixed_expense_payments',[local,month],{'fixed_expense_id':ids.id('fixed_expense',local),
      'payment_month':month,'amount_kurus':_integer(p['amountCents']),'paid_at':_text(p['paidAt']),
      'reversed':true,'reversed_at':_text(p['reversedAt'])});
  }
  for (final p in _rows(book['weeklyPayroll'])) {
    final local = _integer(p['id']);
    add('weekly_payroll',local,{'payroll_id':ids.id('weekly_payroll',local),'local_id':local,
      'employee_local_id':_integer(p['employeeId']),'employee_name_at_record':_text(p['employeeName']),
      'week_start':_text(p['weekStart']),'week_end':_text(p['weekEnd']),
      'pay_type':switch(p['payType']) {'Saatlik'=>'hourly','Haftalık Sabit'=>'weekly_fixed',_=>throw const FormatException('Invalid payroll type')},
      'rate_kurus':_integer(p['rateCents']),'worked_minutes':_integer(p['workedMinutes']),
      'base_kurus':_integer(p['baseCents']),'bonus_kurus':_integer(p['bonusCents']),
      'advance_kurus':_integer(p['advanceCents']),'gross_kurus':_integer(p['grossCents']),
      'payable_kurus':_integer(p['payableCents']),'paid':p['paid'],'paid_at':p['paidAt'],
      'created_at':_text(p['createdAt'])});
  }
  for (final p in _rows(book['other'])) {
    final local = _integer(p['id']);
    add('expenses',local,{'expense_id':ids.id('expense',local),'local_id':local,
      'business_day':_text(p['date']),'category':_text(p['category']),'label':_text(p['name']),
      'amount_kurus':_integer(p['amountCents']),'payment_method':_text(p['paymentMethod']),
      'voided':p['voided']??false,'created_at':_text(p['createdAt'])});
  }
  for (final p in _rows(book['manualPlatformSales'])) {
    final local = _integer(p['id']), id = ids.id('manual_platform_sale',local);
    add('manual_platform_sales',local,{'sale_id':id,'local_id':local,
      'platform':switch(p['source']) {'Yemeksepeti'=>'yemeksepeti','Migros Yemek'=>'migros',_=>throw const FormatException('Unsupported platform sale')},
      'sales_month':_month(p['month']),'amount_kind':_kind(p['kind']),
      'amount_kurus':_integer(p['amountCents']),'voided':p['voided']??false,
      'note':p['note'],'created_at':_text(p['createdAt'])});
    for (final h in _rows(p['history'])) {
      final key = [local,_text(h['changedAt'])];
      add('manual_platform_sales_history',key,{'sale_id':id,'history_id':ids.id('manual_platform_sale_history',key),
        'changed_at':h['changedAt'],'amount_kind':_kind(h['kind']),'amount_kurus':_integer(h['amountCents'])});
    }
  }
  // Originals precede their audited reversal even in a reordered import.
  final payments = _rows(book['payrollPayments'])..sort((a,b) =>
      (a['reverses']==null?0:1).compareTo(b['reverses']==null?0:1));
  for (final p in payments) {
    final source = _text(p['id']);
    add('payroll_payments',source,{
      'payment_id':ids.id('payroll_payment',source),'source_reference':source,
      'employee_local_id':_integer(p['employeeId']),
      'employee_name_at_record':_text(p['employeeName']),
      'week_start':_text(p['weekStart']),'paid_on':_text(p['paidOn']),
      'kind':_text(p['kind']),'method':_text(p['method']),
      'cash_kurus':_integer(p['cashCents']),'bank_kurus':_integer(p['bankCents']),
      'amount_kurus':_integer(p['amountCents']),
      'reverses_id':p['reverses']==null?null:ids.id('payroll_payment',_text(p['reverses'])),
      'note':_text(p['note']),'recorded_at':_text(p['createdAt']),
      'actor_label':_text(p['createdBy']),
    });
  }
  for (final p in _rows(book['payrollReviews'])) {
    final source = [_integer(p['employeeId']),_text(p['weekStart']),_text(p['at'])];
    add('payroll_reviews',source,{
      'review_id':ids.id('payroll_review',source),
      'employee_local_id':source[0],'week_start':source[1],
      'state':_text(p['state']),'note':_text(p['note']),
      'recorded_at':source[2],'actor_label':_text(p['by']),
    });
  }
  return out;
}

/// Opt-in typed encoding for the existing worker; raw outbox events remain
/// durable and unmodified. IDs are allocated before any network request.
class TypedFinanceTransport implements SyncTransport {
  const TypedFinanceTransport(this.identities, this.delegate);
  final CloudIdentityMap identities;
  final SyncTransport delegate;

  SyncTransaction encode(SyncTransaction tx) => SyncTransaction(
    authorityEpoch: tx.authorityEpoch, sourceRevision: tx.sourceRevision,
    events: [for (final event in tx.events) _encodeEvent(tx,event)],
  );

  SyncEvent _encodeEvent(SyncTransaction tx, SyncEvent event) {
    if (event.entityType != 'finance') return event;
    if (event.op != 'upsert' || event.entityId != 'core' || event.createdAt == null) {
      throw const SyncRejectedException('unsupported_finance_event');
    }
    final raw = jsonDecode(event.payloadJson);
    if (raw is! Map) throw const SyncRejectedException('invalid_finance_projection');
    final payload = canonicalJson({'source_updated_at':event.createdAt,
      'rows':[for (final row in serializeFinance(Map<String,dynamic>.from(raw),identities)) row.toJson()]});
    return SyncEvent(seq:event.seq, eventId:'${tx.authorityEpoch}:${tx.sourceRevision}:typed_finance:core',
      entityType:'typed_finance',entityId:'core',op:'upsert',payloadJson:payload,
      payloadSha256:hash.sha256.convert(utf8.encode(payload)).toString(),ordinal:event.ordinal,createdAt:event.createdAt);
  }

  @override
  Future<IngestResult> ingest(SyncTransaction tx) {
    try {
      return delegate.ingest(encode(tx));
    } on FormatException {
      throw const SyncRejectedException('invalid_finance_projection');
    }
  }
}
