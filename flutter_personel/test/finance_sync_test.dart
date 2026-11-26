import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nohut_core/finance_wire.dart';
import 'package:nohut_personel/expense_drafts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('lost acknowledgement survives restart and retries the identical operation', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const restaurant = 'test-restaurant';
    final secret = FinanceWire.createKey();
    final seen = <Map<String, dynamic>>[];
    Map<String, dynamic>? saved;
    var loseAck = true;
    final client = MockClient((request) async {
      final envelope = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
      final message = await FinanceWire.open(secret, restaurant, 'request', envelope);
      Map<String, dynamic> reply;
      if (message['operation'] == 'pull') {
        reply = {'ok': true, 'records': [if (saved != null) saved], 'hasMore': false};
      } else {
        seen.add(message);
        saved ??= {'id': 1, ...Map<String, dynamic>.from(message['entry'] as Map),
          'totalCents': 41000, 'updatedAt': 'version1', 'voided': false};
        if (loseAck) {
          loseAck = false;
          return http.Response('connection interrupted', 503);
        }
        reply = {'ok': true, 'record': saved};
      }
      final response = await FinanceWire.seal(secret, restaurant,
        'response:' + envelope['nonce'].toString(), reply);
      return http.Response(jsonEncode(response), 200);
    });
    final first = ExpenseDraftStore(restaurant, client: client);
    await first.configure(secret);
    await first.write([{
      'id': 'local-entry', 'date': '2026-10-15', 'storeBrand': 'BİM',
      'market': 'BİM', 'paymentMethod': 'Nakit', 'note': '',
      'amountsCents': [5000, 6000, 30000], 'totalCents': 41000,
      'status': 'local_draft',
    }]);
    first.host = 'http://192.168.1.15:8787';
    await first.sync(force: true);
    expect((await first.read()).single['status'], 'pending');
    final next = ExpenseDraftStore(restaurant, client: client)
      ..host = first.host;
    await next.sync(force: true);
    expect(seen.length, 2);
    expect(seen[1], seen[0]);
    final records = await next.read();
    expect(records.length, 1);
    expect(records.single['status'], 'synced');
    expect(records.single['recordId'], 1);
    expect(records.single['totalCents'], 41000);
    client.close();
    first.dispose();
    next.dispose();
  });
}
