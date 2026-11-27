import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/lan_auth_gate.dart';
import 'package:nohut_falafel_desktop/lan_server.dart';
import 'package:nohut_falafel_desktop/local_accounts.dart';
import 'package:nohut_falafel_desktop/notification_events.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';

void main() {
  test('Dart categories mirror docs/contracts/v1/notifications.json', () {
    final doc = jsonDecode(File('../docs/contracts/v1/notifications.json').readAsStringSync()) as Map;
    final cats = {for (final c in doc['categories'] as List) (c as Map)['id']: c};
    expect(cats.keys.toSet(), notificationCategories.keys.toSet());
    for (final e in notificationCategories.entries) {
      final c = cats[e.key] as Map;
      expect(c['label'], e.value.label, reason: e.key);
      expect(c['severity'], e.value.severity, reason: e.key);
      expect(c['permission'], e.value.permission, reason: e.key);
      expect((c['clients'] as List).cast<String>(), e.value.clients, reason: e.key);
      expect(c['windowsOnly'], e.value.windowsOnly, reason: e.key);
    }
  });

  group('history and LAN feed', () {
    late Directory dir;
    late PosStore store;
    late LocalAuth auth;
    var now = DateTime.utc(2026, 11, 27, 12);
    setUp(() async {
      now = DateTime.utc(2026, 11, 27, 12);
      dir = Directory.systemTemp.createTempSync('nohut-notify');
      store = PosStore(databaseFile: '${dir.path}/db');
      final s = emptyPosState();
      s['staffNotices'] = [
        {'id': 'n1', 'orderId': 5, 'staff': 'Ayşe', 'action': 'Yeni sipariş', 'table': 3, 'at': '2026-11-27T11:59:00Z'},
        {'id': 'n0', 'orderId': 4, 'staff': 'Ayşe', 'action': 'Yeni sipariş', 'table': 2, 'at': '2026-11-26T08:00:00Z'},
        {'id': 'n2', 'orderId': 5, 'staff': 'Ayşe', 'action': 'Ödeme alındı', 'table': 3, 'at': '2026-11-27T11:59:30Z'},
      ];
      s['printJobs'] = [
        {'orderId': 5, 'batchId': 1, 'kind': 'bill', 'state': 'Kontrol gerekli', 'createdAt': '2026-11-27T11:58:00Z', 'spooledAt': '2026-11-27T11:58:05Z'},
      ];
      s['terminalAttempts'] = [
        {'reference': 'r1', 'orderId': 5, 'amountCents': 100, 'status': 'unknown'},
      ];
      store.replace(s, store.read().revision);
      auth = LocalAuth(store.authDatabase, iterations: 1000);
      await auth.createUser(username: 'sahip', password: 'owner-pass-1', role: 'Yönetici', isOwner: true);
      final g = await auth.createUser(username: 'garson', password: 'staff-pass-1', role: 'Personel', employeeId: 2);
      auth.setGrant(g, 'receipts.print', false);
    });
    tearDown(() {
      store.dispose();
      dir.deleteSync(recursive: true);
    });

    test('derived once, stale events already read, no write when nothing new', () {
      final added = recordOperationalNotifications(store, clock: () => now);
      expect(added, containsAll(['staff:n1', 'staff:n0', 'terminal:r1:unknown']));
      expect(added.any((id) => id.startsWith('print:')), true);
      expect(added, isNot(contains('staff:n2')), reason: 'payments are not order alerts');
      final rows = asMaps(store.read().data['notifications']);
      expect(rows.firstWhere((r) => r['eventId'] == 'staff:n0')['read'], true);
      expect(rows.firstWhere((r) => r['eventId'] == 'staff:n1')['read'], false);
      final revision = store.read().revision;
      expect(recordOperationalNotifications(store, clock: () => now), isEmpty);
      expect(store.read().revision, revision);
    });

    test('LAN feed filters by permission and keeps read state per user', () async {
      recordOperationalNotifications(store, clock: () => now);
      final s = store.read().data;
      (s['notifications'] as List).add({'eventId': 'backup:x', 'category': 'backup', 'severity': 'high',
        'createdAt': '2026-11-27T11:00:00Z', 'title': 'Yedek', 'permission': 'backup.view', 'read': false});
      store.replace(s, store.read().revision);
      final server = PosLanServer(store, port: 0, staffHtml: '<p>', yoneticiHtml: '<p>', authGate: LanAuthGate(auth));
      await server.start();
      Future<(int, Map, String?)> call(String m, String path, {Object? body, String? cookie}) async {
        final c = HttpClient();
        try {
          final r = await c.openUrl(m, Uri.parse('http://127.0.0.1:${server.port}$path'));
          if (cookie != null) r.headers.set(HttpHeaders.cookieHeader, cookie);
          if (body != null) { r.headers.contentType = ContentType.json; r.write(jsonEncode(body)); }
          final res = await r.close();
          return (res.statusCode, jsonDecode(await res.transform(utf8.decoder).join()) as Map,
              res.headers.value(HttpHeaders.setCookieHeader));
        } finally { c.close(force: true); }
      }
      try {
        expect((await call('GET', '/api/notifications?client=personel')).$1, 401);
        final (_, _, ck) = await call('POST', '/api/auth/login', body: {
          'username': 'garson', 'password': 'staff-pass-1', 'deviceId': 'phone-device-000000001'});
        final cookie = ck!.split(';').first;
        final (st, feed, _) = await call('GET', '/api/notifications?client=personel', cookie: cookie);
        expect(st, 200);
        final ids = [for (final n in feed['notifications'] as List) (n as Map)['eventId']];
        expect(ids, contains('staff:n1'));
        expect(ids, contains('terminal:r1:unknown'));
        expect(ids.any((id) => '$id'.startsWith('print:')), false, reason: 'receipts.print removed');
        expect(ids, isNot(contains('backup:x')), reason: 'Windows-only category');
        final unread = feed['unread'] as int;
        await call('POST', '/api/notifications/read', cookie: cookie,
            body: {'client': 'personel', 'eventIds': ['staff:n1', 'backup:x']});
        final (_, feed2, _) = await call('GET', '/api/notifications?client=personel', cookie: cookie);
        expect(feed2['unread'], unread - 1);
        // Windows history keeps its own read state.
        expect(asMaps(store.read().data['notifications']).firstWhere((r) => r['eventId'] == 'staff:n1')['read'], false);
      } finally {
        await server.stop();
        server.dispose();
      }
    });
  });
}
