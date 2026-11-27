import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/cloud_finance_serializer.dart';
import 'package:nohut_falafel_desktop/finance_logic.dart';
import 'package:nohut_falafel_desktop/finance_sync_history.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/sync_field_registry.dart';
import 'package:nohut_falafel_desktop/sync_outbox.dart';
import 'package:nohut_falafel_desktop/sync_worker.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory folder;
  late Database db;
  late CloudIdentityMap ids;
  setUp(() {
    folder = Directory.systemTemp.createTempSync('nohut-typed-finance');
    db = sqlite3.open('${folder.path}/ids.sqlite3');
    ids = CloudIdentityMap(db);
  });
  tearDown(() { db.close(); folder.deleteSync(recursive:true); });

  Map<String,dynamic> fixture() {
    final state = emptyPosState();
    saveQuickMaterialPurchase(state, date:'2026-10-01',storeBrand:'BİM',amountsCents:[500,600]);
    saveQuickMaterialPurchase(state,id:1,date:'2026-10-02',storeBrand:'BİM',amountsCents:[500,700]);
    saveMaterialPurchase(state,date:'2026-10-01',title:'Synthetic purchase',unit:'kg',quantityMilli:1500,pricePerUnitCents:1000);
    saveMaterialPurchase(state,id:2,date:'2026-10-02',title:'Synthetic purchase',unit:'kg',quantityMilli:2000,pricePerUnitCents:1000);
    saveMonthlyFixed(state,category:'Kira',name:'Synthetic rent',amountCents:20000,startMonth:'2026-10');
    markMonthlyFixedPaid(state,1,'2026-10',true);
    saveEmployeePay(state,1,'Saatlik',1000);
    saveWeeklyPayroll(state,employeeId:1,weekStart:'2026-11-23',workedMinutes:600,bonusCents:1000,advanceCents:2000,paid:true);
    saveOtherExpense(state,day:'2026-10-01',category:'Diğer',name:'Synthetic expense',amountCents:100,paymentMethod:'Nakit');
    saveManualPlatformIncome(state,source:'Yemeksepeti',month:'2026-11',kind:'Brüt',amountCents:9000);
    saveManualPlatformIncome(state,source:'Yemeksepeti',month:'2026-11',kind:'Net',amountCents:10000);
    return state;
  }

  test('real finance write paths serialize exact facts and immutable source histories', () {
    final state=fixture();
    final projected=projectForCloud(state)['finance'] as Map<String,dynamic>;
    final rows=serializeFinance(projected,ids);
    expect(rows.where((r)=>r.table=='material_purchases'),hasLength(2));
    expect(rows.where((r)=>r.table=='material_purchase_history'),hasLength(2));
    expect(rows.singleWhere((r)=>r.table=='weekly_payroll').data,
      containsPair('payable_kurus',9000));
    expect(rows.singleWhere((r)=>r.table=='weekly_payroll').data['pay_type'],'hourly');
    expect(rows.singleWhere((r)=>r.table=='manual_platform_sales').data['amount_kind'],'net');
    expect(rows.singleWhere((r)=>r.table=='manual_platform_sales_history').data['amount_kind'],'gross');
    expect(rows.singleWhere((r)=>r.table=='fixed_expenses').data['start_month'],'2026-10-01');
    expect(jsonEncode(rows.map((r)=>r.toJson()).toList()),isNot(contains('payRateCents')));
  });

  test('source identities survive restart, reordering, and financial changes', () {
    final state=fixture();
    final book=state['finance'] as Map<String,dynamic>;
    final before=serializeFinance(book,ids);
    final oldId=before.first.data['purchase_id'];
    db.close();
    db=sqlite3.open('${folder.path}/ids.sqlite3');
    ids=CloudIdentityMap(db);
    final materials=book['materials'] as List;
    book['materials']=materials.reversed.toList();
    final after=serializeFinance(book,ids);
    expect(after.where((r)=>r.table=='material_purchases').last.data['purchase_id'],oldId);
    expect(ids.id('material_purchase',1),oldId);
  });

  test('duplicate source identities and incomplete money facts fail closed', () {
    final book=fixture()['finance'] as Map<String,dynamic>;
    final materials=book['materials'] as List;
    materials.add(Map<String,dynamic>.from(materials.first as Map));
    expect(()=>serializeFinance(book,ids),throwsFormatException);
    materials.removeLast();
    (materials.first as Map)['totalCents']=12.5;
    expect(()=>serializeFinance(book,ids),throwsFormatException);
  });

  test('typed event encoding is stable and does not mutate the raw outbox', () {
    final book=fixture()['finance'];
    final event=SyncEvent(seq:1,eventId:'source',entityType:'finance',entityId:'core',op:'upsert',
      payloadJson:canonicalJson(book),payloadSha256:'original',ordinal:0,createdAt:'2026-11-27T12:00:00Z');
    final tx=SyncTransaction(authorityEpoch:'10000000-0000-4000-8000-000000000001',sourceRevision:1,events:[event]);
    final encoder=TypedFinanceTransport(ids,_NeverSend());
    final first=encoder.encode(tx), again=encoder.encode(tx);
    expect(first.toJson(),again.toJson());
    expect(first.events.single.entityType,'typed_finance');
    expect(first.events.single.eventId,'10000000000040008000000000000001:1:typed_finance:core');
    expect(event.payloadSha256,'original');
    expect(first.bodySha256,isNot(tx.bodySha256));
  });

  test('undo and repay keep an explicit reversal and original paid facts', () {
    final state=fixture();
    final book=state['finance'] as Map<String,dynamic>;
    final original=Map<String,dynamic>.from((book['fixedPayments'] as List).single as Map);
    final before=jsonDecode(jsonEncode(book));
    markMonthlyFixedPaid(state,1,'2026-10',false);
    final reversed=captureFinanceReversals(db,before,book,'2026-11-27T12:00:00Z');
    final row=serializeFinance(reversed,ids).singleWhere((r)=>r.table=='fixed_expense_payments');
    expect(row.data['reversed'],true);
    expect(row.data['amount_kurus'],original['amountCents']);
    expect(row.data['paid_at'],original['paidAt']);
    markMonthlyFixedPaid(state,1,'2026-10',true);
    final repaid=captureFinanceReversals(db,book,book,'2026-11-27T13:00:00Z');
    expect(serializeFinance(repaid,ids).singleWhere((r)=>r.table=='fixed_expense_payments').data['reversed'],false);
  });

  test('the real outbox atomically captures a fixed-payment reversal', () {
    final store=PosStore(databaseFile:'${folder.path}/pos.sqlite3');
    final probe=sqlite3.open(store.filePath);
    try {
      final state=fixture();
      expect(store.replace(state,store.read().revision).ok,true);
      enableOutbox(probe);
      store.command('synthetic_reverse',{},(s) {
        markMonthlyFixedPaid(s,1,'2026-10',false);
        return {'ok':true};
      });
      final group=groupPending(probe).single;
      final encoded=TypedFinanceTransport(CloudIdentityMap(probe),_NeverSend()).encode(group);
      final payload=jsonDecode(encoded.events.single.payloadJson) as Map;
      final records=(payload['rows'] as List).cast<Map>();
      final payment=records.singleWhere((r)=>r['table']=='fixed_expense_payments')['data'] as Map;
      expect(payment['reversed'],true);
      expect(payment['amount_kurus'],20000);
      expect(store.read().data['finance']['fixedPayments'],isEmpty);
      expect(pendingOutbox(probe),hasLength(1),reason:'encoding never acknowledges');
    } finally { probe.close(); store.dispose(); }
  });
}

class _NeverSend implements SyncTransport {
  @override
  Future<IngestResult> ingest(SyncTransaction tx)=>throw StateError('No network in serializer tests');
}
