import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/lan_server.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';

void main() {
  late Directory dir;
  late PosStore store;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('nohut-platform');
    store = PosStore(databaseFile: '${dir.path}/db');
    final state = emptyPosState();
    state['trendyolGoOrders'] = [
      {
        'source': 'Trendyol Go',
        'orderNumber': 'TG-1',
        'packageId': 'pkg-1',
        'supplierId': '1',
        'status': 'Created',
        'preparationMinutes': 15,
        'apiSecret': 'never-exposed',
        'lines': [
          {'name': 'Falafel', 'qty': 1, 'removed': ['Domates'],
            'extras': ['Acı'], 'options': []},
        ],
      },
    ];
    store.replace(state, store.read().revision);
  });
  tearDown(() {
    store.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<(int, Map)> call(PosLanServer server, String method, String path,
      [Object? body]) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(
        method, Uri.parse('http://127.0.0.1:${server.port}$path'));
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      return (res.statusCode, jsonDecode(text) as Map);
    } finally {
      client.close(force: true);
    }
  }

  test('phone Kabul Et / Hazır goes through the laptop handler', () async {
    final received = <Map<String, dynamic>>[];
    var writable = true;
    final server = PosLanServer(
      store,
      port: 0,
      staffHtml: '<h1>Personel</h1>',
      platformWritable: () => writable,
      platformAction: (request) async {
        received.add(request);
        if (request['action'] == 'ready') {
          throw const FormatException('Sipariş durumu değişmiş.');
        }
        return {'ok': true, 'verified': true};
      },
    );
    await server.start();
    expect(server.running, true, reason: server.error);
    try {
      final (bootStatus, boot) = await call(server, 'GET', '/api/bootstrap');
      expect(bootStatus, 200);
      final state = boot['state'] as Map;
      expect(state['tgoCanWrite'], true);
      final order = (state['trendyolGoOrders'] as List).single as Map;
      expect(order['packageId'], 'pkg-1');
      expect(order['preparationMinutes'], 15);
      expect(order.containsKey('apiSecret'), false);
      final line = (order['lines'] as List).single as Map;
      expect(line['removed'], ['Domates']);
      expect(line['extras'], ['Acı']);

      final (ok, accepted) = await call(server, 'POST', '/api/staff/platform',
          {'staffId': 1, 'packageId': 'pkg-1', 'action': 'accept',
            'preparationMinutes': 12});
      expect(ok, 200);
      expect(accepted['verified'], true);
      expect(received.single['preparationMinutes'], 12);

      final (rejected, body) = await call(server, 'POST',
          '/api/staff/platform', {'staffId': 1, 'packageId': 'pkg-1',
            'action': 'ready'});
      expect(rejected, 422);
      expect(body['message'], 'Sipariş durumu değişmiş.');

      writable = false;
      final (_, again) = await call(server, 'GET', '/api/bootstrap');
      expect((again['state'] as Map)['tgoCanWrite'], false);
    } finally {
      await server.stop();
      server.dispose();
    }
  });

  test('without a handler the endpoint is unavailable', () async {
    final server = PosLanServer(store, port: 0, staffHtml: '<h1>P</h1>');
    await server.start();
    try {
      final (status, body) = await call(server, 'POST', '/api/staff/platform',
          {'staffId': 1, 'packageId': 'pkg-1', 'action': 'accept'});
      expect(status, 503);
      expect(body['error'], 'unavailable');
    } finally {
      await server.stop();
      server.dispose();
    }
  });
}
