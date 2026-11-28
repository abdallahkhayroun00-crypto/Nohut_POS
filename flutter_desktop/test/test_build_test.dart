// Runs twice in CI: normally (production rules) and with
// --dart-define=NOHUT_TEST_BUILD=true (the isolated TEST build).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/local_accounts.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/qr_publisher_client.dart';
import 'package:nohut_falafel_desktop/receipt_printer.dart';
import 'package:nohut_falafel_desktop/test_build.dart';
import 'package:nohut_falafel_desktop/test_build_seed.dart';

void main() {
  late Directory dir;
  late PosStore store;
  late LocalAuth auth;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('nohut-testbuild');
    store = PosStore(databaseFile: '${dir.path}/db');
    auth = LocalAuth(store.authDatabase, iterations: 1000);
  });
  tearDown(() {
    store.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<LoginResult> fixtureLogin() => auth.login(username: 'test', password: '00000',
      deviceId: 'test-build-device-0001', client: 'yonetici');

  if (!nohutTestBuild) {
    test('production build: no test account, test/00000 refused, 00000 is a weak PIN', () async {
      await seedTestAccount(auth);
      expect(auth.hasUsers, isFalse, reason: 'nothing is seeded outside TEST builds');
      await auth.createUser(username: 'test', password: 'real-pass-123', role: 'Yönetici', isOwner: true);
      await expectLater(fixtureLogin(), throwsA(isA<LocalAuthException>()
          .having((e) => e.code, 'code', 'invalid_credentials')));
      final r = await auth.login(username: 'test', password: 'real-pass-123',
          deviceId: 'test-build-device-0002', client: 'yonetici');
      await expectLater(auth.setPin(r.token, 'yonetici', '00000'), throwsA(isA<LocalAuthException>()
          .having((e) => e.code, 'code', 'weak_pin')));
      expect(isTestFixtureLogin('test', '00000'), isFalse);
      expect(PosStore.resolvePath(null), isNot(contains(testBuildDataFolder)));
    });
    return;
  }

  test('TEST build: test / 00000 signs in, keeps PIN 00000; others keep the rules', () async {
    await seedTestAccount(auth);
    final r = await fixtureLogin();
    expect(r.context.ok, isTrue);
    expect(r.context.isOwner, isTrue);
    await auth.setPin(r.token, 'yonetici', '00000');
    await auth.createUser(username: 'garson', password: 'staff-pass-1', role: 'Personel');
    final g = await auth.login(username: 'garson', password: 'staff-pass-1',
        deviceId: 'test-build-device-0003', client: 'personel');
    await expectLater(auth.setPin(g.token, 'personel', '00000'), throwsA(isA<LocalAuthException>()
        .having((e) => e.code, 'code', 'weak_pin')));
    await expectLater(auth.login(username: 'garson', password: '00000',
        deviceId: 'test-build-device-0004', client: 'personel'), throwsA(isA<LocalAuthException>()));
  });

  test('TEST build: own data folder, no outside network, no printing, no QR publish', () async {
    expect(PosStore.resolvePath(null), contains(testBuildDataFolder));
    installTestBuildGuards();
    final client = HttpClient();
    await expectLater(() async => (await client.getUrl(Uri.parse('https://api.github.com/'))).close(),
        throwsA(isA<TestBuildBlocked>()));
    client.close(force: true);
    await expectLater(windowsPrint('x', 'printer'), throwsA(isA<TestBuildBlocked>()));
    await expectLater(QrPublisherClient('db', testToken: 'x' * 40).call('GET', 'http://127.0.0.1:18787', 'menu'),
        throwsA(isA<FormatException>()));
    HttpOverrides.global = null;
  });
}
