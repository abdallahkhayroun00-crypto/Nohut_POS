import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/lan_auth_gate.dart';
import 'package:nohut_falafel_desktop/lan_server.dart';
import 'package:nohut_falafel_desktop/local_accounts.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/platform_management.dart';
import 'package:nohut_core/platform_status.dart';

class FakeControl implements PlatformControl {
  final commands = <String>[];
  bool refuse = false;
  @override
  Future<List<PlatformCard>> load() async => PlatformCard.completeSet([
    PlatformCard(provider: 'trendyol_go', connection: PlatformConnection.connected,
        working: PlatformWorking.open, verifiedStoreId: '1', lastVerifiedAt: DateTime.now().toUtc(),
        canToggleStore: true),
  ]);
  @override
  Future<void> refresh(String provider) async => commands.add('refresh:$provider');
  @override
  Future<void> setStoreStatus(String provider, PlatformWorking target, {required PlatformWorking expected}) async {
    if (refuse) throw const PlatformUnavailable('Bekleniyor');
    commands.add('store:$provider:${PlatformCard.workingWire(expected)}>${PlatformCard.workingWire(target)}');
  }
}

void main() {
  late Directory dir;
  late PosStore store;
  late LocalAuth auth;
  late PosLanServer server;
  late FakeControl control;
  const device = 'manager-device-0001-abc';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('nohut-yonetici');
    store = PosStore(databaseFile: '${dir.path}/db');
    auth = LocalAuth(store.authDatabase, iterations: 1000);
    await auth.createUser(username: 'sahip', password: 'owner-pass-1', role: 'Yönetici', isOwner: true);
    await auth.createUser(username: 'mudur', password: 'mudur-pass-1', role: 'Müdür');
    await auth.createUser(username: 'garson', password: 'staff-pass-1', role: 'Personel');
    server = PosLanServer(store, port: 0, staffHtml: '<h1>P</h1>',
        yoneticiHtml: File('assets/yonetici.html').readAsStringSync(), authGate: LanAuthGate(auth), platforms: control = FakeControl());
    await server.start();
  });
  tearDown(() async {
    await server.stop();
    server.dispose();
    store.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<(int, Object?, String?)> call(String method, String path, {Object? body, String? cookie}) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:${server.port}$path'));
      if (cookie != null) req.headers.set(HttpHeaders.cookieHeader, cookie);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      final decoded = res.headers.contentType?.mimeType == 'application/json' ? jsonDecode(text) : text;
      return (res.statusCode, decoded, res.headers.value(HttpHeaders.setCookieHeader));
    } finally {
      client.close(force: true);
    }
  }

  Future<String> login(String user, String pass) async {
    final (status, body, setCookie) = await call('POST', '/api/auth/login',
        body: {'username': user, 'password': pass, 'deviceId': '$device-$user', 'client': 'yonetici'});
    expect(status, 200, reason: '$body');
    return setCookie!.split(';').first;
  }

  test('Platform Yönetimi: platform.view reads, platform.store.toggle commands', () async {
    final staff = await login('garson', 'staff-pass-1');
    final (s, _, _) = await call('GET', '/api/yonetici/platforms', cookie: staff);
    expect(s, 403);

    final mudur = await login('mudur', 'mudur-pass-1');
    final (m, mb, _) = await call('GET', '/api/yonetici/platforms', cookie: mudur);
    expect(m, 200);
    final cards = [for (final c in (mb as Map)['cards'] as List) PlatformCard.fromJson(c as Map)];
    expect(cards.map((c) => c.provider), platformProviderOrder);
    expect(cards.first.statusLabel(DateTime.now().toUtc()), 'Açık');
    expect(cards[1].statusLabel(DateTime.now().toUtc()), 'Entegrasyon bekleniyor');
    expect(mb['canToggle'], false);
    final (r, _, _) = await call('POST', '/api/yonetici/platform', cookie: mudur,
        body: {'action': 'refresh', 'provider': 'trendyol_go'});
    expect(r, 200);
    final (t, _, _) = await call('POST', '/api/yonetici/platform', cookie: mudur, body: {
      'action': 'store', 'provider': 'trendyol_go', 'target': 'CLOSED', 'expected': 'OPEN', 'confirmed': true});
    expect(t, 403);
    expect(control.commands, ['refresh:trendyol_go']);

    final owner = await login('sahip', 'owner-pass-1');
    final (o, ob, _) = await call('GET', '/api/yonetici/platforms', cookie: owner);
    expect(o, 200);
    expect((ob as Map)['canToggle'], true);
    final (u, _, _) = await call('POST', '/api/yonetici/platform', cookie: owner, body: {
      'action': 'store', 'provider': 'trendyol_go', 'target': 'CLOSED', 'expected': 'OPEN'});
    expect(u, 422, reason: 'an unconfirmed command is refused');
    final (k, _, _) = await call('POST', '/api/yonetici/platform', cookie: owner, body: {
      'action': 'store', 'provider': 'trendyol_go', 'target': 'CLOSED', 'expected': 'OPEN', 'confirmed': true});
    expect(k, 200);
    expect(control.commands.last, 'store:trendyol_go:OPEN>CLOSED');
    control.refuse = true;
    final (x, xb, _) = await call('POST', '/api/yonetici/platform', cookie: owner, body: {
      'action': 'store', 'provider': 'trendyol_go', 'target': 'CLOSED', 'expected': 'OPEN', 'confirmed': true});
    expect(x, 409);
    expect((xb as Map)['message'], 'Bekleniyor');
    expect(control.commands.length, 2);
  });
  // Optional browser run of the real page (NOHUT_E2E_SCRIPT =
  // tools/e2e/yonetici_platform.js, a Playwright
  // script, NOHUT_RENDER_DIR = where screenshots go).
  final script = Platform.environment['NOHUT_E2E_SCRIPT'];
  test('Yönetici web: Daha Fazla › Platform Yönetimi and the Özet widget', () async {
    final r = await Process.run('node', [script!, 'http://127.0.0.1:${server.port}',
      Platform.environment['NOHUT_RENDER_DIR'] ?? Directory.systemTemp.path],
        environment: {'NODE_PATH': Platform.environment['NODE_PATH'] ?? ''});
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final out = jsonDecode('${r.stdout}'.trim().split('\n').last) as Map;
    expect(out['errors'], isEmpty);
    expect((out['quick'] as List).length, 3);
    expect(out['quick'][0], contains('Açık'));
    expect(out['msg'], contains('İstek gönderildi'));
    expect(out['disabled'], true);
    expect(control.commands, ['store:trendyol_go:OPEN>CLOSED']);
  }, timeout: const Timeout(Duration(minutes: 2)), skip: script == null ? 'browser run only with NOHUT_E2E_SCRIPT' : false);
}
