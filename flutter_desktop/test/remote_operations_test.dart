// Phase 5D: remote reprint (ambiguous prints only), product sale toggle and
// delivery-platform actions with reconciliation (spec §11.2). Synthetic data.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/remote_commands.dart';

final t0 = DateTime.utc(2026, 11, 27, 12);

Map<String, dynamic> env(String type, Map<String, dynamic> payload, {String id = 'cmd_op_0001', List<String> grants = const [], bool owner = false}) => {
  'request_id': id,
  'action_type': type,
  'client': 'personel',
  'actor': {'employee_id': 2, 'is_owner': owner, 'grants': grants},
  'issued_at': t0.toIso8601String(),
  'expires_at': t0.add(const Duration(minutes: 4)).toIso8601String(),
  'payload': payload,
  'payload_sha256': payloadSha256(payload),
};

void main() {
  late Directory dir;
  late PosStore store;
  final now = t0.add(const Duration(seconds: 3));

  Json base() => {
    ...emptyPosState(),
    'localMenu': [
      {'id': 0, 'name': 'Falafel', 'category': 'wrap', 'price': 140, 'active': true},
    ],
    'printJobs': [
      {'orderId': 7, 'batchId': 1, 'state': 'Kontrol gerekli', 'error': 'kapandı'},
      {'orderId': 8, 'batchId': 1, 'state': 'Yazdırıldı'},
    ],
    'trendyolGoOrders': [
      {'source': 'Trendyol Go', 'supplierId': 's1', 'storeId': 'st', 'packageId': 'P100', 'orderNumber': 'T1', 'status': 'Created', 'lines': []},
    ],
  };

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nohut-remote-ops');
    store = PosStore(databaseFile: '${dir.path}/db');
    expect(store.replace(base(), store.read().revision).ok, true);
  });
  tearDown(() {
    store.dispose();
    dir.deleteSync(recursive: true);
  });

  group('retry_print', () {
    test('only an ambiguous print is re-queued, after the printer was checked', () {
      final unchecked = executeRemoteCommand(store, env('retry_print', {'target': 'kitchen', 'orderId': 7, 'batchId': 1}, grants: ['receipts.print']), now: now);
      expect(unchecked.outcome, CommandOutcome.rejected);
      final ok = executeRemoteCommand(store, env('retry_print', {'target': 'kitchen', 'orderId': 7, 'batchId': 1, 'checked': true}, id: 'cmd_print_0002', grants: ['receipts.print']), now: now);
      expect(ok.outcome, CommandOutcome.confirmed, reason: ok.result.toString());
      expect(asMaps(store.read().data['printJobs']).first['state'], 'Bekliyor');
    });

    test('a ticket that printed fine is never printed again remotely', () {
      final r = executeRemoteCommand(store, env('retry_print', {'target': 'kitchen', 'orderId': 8, 'batchId': 1, 'checked': true}, grants: ['receipts.print']), now: now);
      expect(r.outcome, CommandOutcome.rejected);
      expect(asMaps(store.read().data['printJobs'])[1]['state'], 'Yazdırıldı');
    });

    test('needs receipts.print', () {
      expect(executeRemoteCommand(store, env('retry_print', {'target': 'kitchen', 'orderId': 7, 'batchId': 1, 'checked': true}), now: now).code, 'forbidden');
    });
  });

  group('set_product_sale', () {
    test('removes a product from sale with an audit notice; needs menu.stock.toggle', () {
      expect(executeRemoteCommand(store, env('set_product_sale', {'productId': 0, 'active': false}), now: now).code, 'forbidden');
      final r = executeRemoteCommand(store, env('set_product_sale', {'productId': 0, 'active': false}, id: 'cmd_sale_0002', grants: ['menu.stock.toggle']), now: now);
      expect(r.outcome, CommandOutcome.confirmed, reason: r.result.toString());
      final s = store.read().data;
      expect(asMaps(s['localMenu']).single['active'], false);
      expect(asMaps(s['staffNotices']).last['action'], contains('satıştan kaldırıldı'));
    });
  });

  group('platform_action', () {
    Map<String, dynamic> accept({String id = 'cmd_tgo_0001'}) =>
        env('platform_action', {'action': 'accept', 'packageId': 'P100'}, id: id, grants: ['online.act']);

    test('confirmed when the platform confirms; a retry does not call again', () async {
      var calls = 0;
      Future<bool> platform(Json o, String a, {int? preparationMinutes}) async {
        calls++;
        return true;
      }

      final r = await executeRemoteCommandAsync(store, accept(), platform: platform, now: now);
      expect(r.outcome, CommandOutcome.confirmed);
      final again = await executeRemoteCommandAsync(store, accept(), platform: platform, now: now);
      expect(again.outcome, CommandOutcome.confirmed);
      expect(calls, 1);
    });

    test('unknown outcome → reconciliation required, never retried automatically', () async {
      var calls = 0;
      Future<bool> flaky(Json o, String a, {int? preparationMinutes}) async {
        calls++;
        throw const SocketException('timeout');
      }

      final r = await executeRemoteCommandAsync(store, accept(), platform: flaky, now: now);
      expect(r.outcome, CommandOutcome.reconciliationRequired);
      expect(r.toJson()['state'], 'reconciliation_required');
      final again = await executeRemoteCommandAsync(store, accept(), platform: flaky, now: now);
      expect(again.outcome, CommandOutcome.reconciliationRequired);
      expect(calls, 1);
    });

    test('unverified provider response is uncertain, including after expiry', () async {
      var calls = 0;
      Future<bool> unverified(Json o, String a, {int? preparationMinutes}) async {
        calls++;
        return false;
      }
      final e = accept();
      expect((await executeRemoteCommandAsync(store, e, platform: unverified, now: now)).outcome,
          CommandOutcome.reconciliationRequired);
      expect((await executeRemoteCommandAsync(store, e, platform: unverified,
          now: t0.add(const Duration(hours: 1)))).outcome, CommandOutcome.reconciliationRequired);
      expect(calls, 1);
    });

    test('confirmed platform attempt is returned after expiry without another call', () async {
      var calls = 0;
      Future<bool> platform(Json o, String a, {int? preparationMinutes}) async {
        calls++;
        return true;
      }
      final e = accept();
      expect((await executeRemoteCommandAsync(store, e, platform: platform, now: now)).outcome,
          CommandOutcome.confirmed);
      expect((await executeRemoteCommandAsync(store, e, platform: platform,
          now: t0.add(const Duration(hours: 1)))).outcome, CommandOutcome.confirmed);
      expect(calls, 1);
    });

    test('a check that fails before any network call is a plain rejection', () async {
      Future<bool> refuse(Json o, String a, {int? preparationMinutes}) async =>
          throw const PlatformPreflightException('Yazma erişimi etkin değil.');
      final r = await executeRemoteCommandAsync(store, accept(), platform: refuse, now: now);
      expect(r.outcome, CommandOutcome.rejected);
    });

    test('malformed response after external I/O stays uncertain through restart and expiry',()async{
      var calls=0;
      Future<bool> malformed(Json o,String a,{int? preparationMinutes})async{
        calls++;
        // An external action may have committed before JSON decoding failed.
        throw const FormatException('Synthetic malformed provider response');
      }
      final e=accept();
      expect((await executeRemoteCommandAsync(store,e,platform:malformed,now:now)).outcome,CommandOutcome.reconciliationRequired);
      expect(store.platformAttempt('cmd_tgo_0001')!['state'],'reconciliation_required');
      store.dispose();store=PosStore(databaseFile:'${dir.path}/db');
      expect((await executeRemoteCommandAsync(store,e,platform:malformed,now:t0.add(const Duration(hours:1)))).outcome,CommandOutcome.reconciliationRequired);
      expect(calls,1);
    });

    test('same package across suppliers is rejected before an external attempt',()async{
      final snap=store.read();
      final first=Map<String,dynamic>.from((snap.data['trendyolGoOrders'] as List).single as Map);
      (snap.data['trendyolGoOrders'] as List).add({...first,'supplierId':'another-supplier'});
      expect(store.replace(snap.data,snap.revision).ok,true);
      var calls=0;
      final result=await executeRemoteCommandAsync(store,accept(),now:now,platform:(o,a,{preparationMinutes})async{calls++;return true;});
      expect(result.code,'ambiguous_platform_identity');expect(calls,0);
      expect(store.platformAttempt('cmd_tgo_0001'),null);
    });

    test('no integration → rejected without recording an attempt', () async {
      final r = await executeRemoteCommandAsync(store, accept(), now: now);
      expect(r.code, 'platform_unavailable');
      expect(store.platformAttempt('cmd_tgo_0001'), isNull);
    });

    test('needs online.act and only accept/ready', () async {
      final noGrant = env('platform_action', {'action': 'accept', 'packageId': 'P100'});
      expect((await executeRemoteCommandAsync(store, noGrant, now: now)).code, 'forbidden');
      final cancel = env('platform_action', {'action': 'cancel', 'packageId': 'P100'}, grants: ['online.act']);
      expect((await executeRemoteCommandAsync(store, cancel, now: now)).code, 'action_mismatch');
    });

    test('the synchronous path refuses platform commands', () {
      expect(executeRemoteCommand(store, accept(), now: now).code, 'async_required');
    });
  });
}
