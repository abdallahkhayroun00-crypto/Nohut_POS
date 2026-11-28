// Spec §23.3 / §23.4: individual local accounts, trusted devices, PIN,
// idle lock, revocation, permissions and owner MFA (synthetic data only).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/local_accounts.dart';
import 'package:nohut_falafel_desktop/permission_roles.g.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database db;
  late LocalAuth auth;
  late DateTime now;
  const dev1 = 'device-aaaaaaaaaaaaaaaa', dev2 = 'device-bbbbbbbbbbbbbbbb';

  setUp(() {
    db = sqlite3.openInMemory();
    now = DateTime.utc(2026, 11, 27, 9);
    auth = LocalAuth(db, clock: () => now, iterations: 1000);
  });
  tearDown(() => db.close());

  Future<(String, String)> seed() async {
    final owner = await auth.createUser(
        username: 'sahip', password: 'sentetik-sifre-1', role: 'Yönetici', isOwner: true);
    final staff = await auth.createUser(
        username: 'deniz', password: 'sentetik-sifre-2', role: 'Personel', employeeId: 2);
    return (owner, staff);
  }

  test('role defaults match the shared contract', () {
    final contract = jsonDecode(File('../docs/contracts/v1/permissions.json').readAsStringSync()) as Map;
    final want = {
      for (final o in contract['operations'] as List)
        (o as Map)['id'] as String: List<String>.from(o['defaults'] as List? ?? const []),
    };
    expect(permissionRoleDefaults, want);
  });

  test('first account must be the owner; one owner only; weak passwords refused', () async {
    expect(() => auth.createUser(username: 'deniz', password: 'sentetik-sifre', role: 'Personel'),
        throwsA(isA<LocalAuthException>().having((e) => e.code, 'code', 'owner_first')));
    await auth.createUser(username: 'sahip', password: 'sentetik-sifre', role: 'Yönetici', isOwner: true);
    expect(() => auth.createUser(username: 'ikinci', password: 'sentetik-sifre', role: 'Yönetici', isOwner: true),
        throwsA(isA<LocalAuthException>()));
    expect(() => auth.createUser(username: 'kisa', password: '1234567', role: 'Personel'),
        throwsA(isA<LocalAuthException>().having((e) => e.code, 'code', 'weak_password')));
    expect(() => auth.createUser(username: 'SAHIP', password: 'sentetik-sifre', role: 'Personel'),
        throwsA(isA<LocalAuthException>().having((e) => e.code, 'code', 'username_taken')));
  });

  test('no plaintext secrets are stored; tokens stored only as hashes', () async {
    await seed();
    final login = await auth.login(username: 'deniz', password: 'sentetik-sifre-2',
        deviceId: dev1, client: 'personel', label: 'Telefon');
    await auth.setPin(login.token, 'personel', '58291');
    final dump = [
      for (final t in ['auth_users', 'auth_devices', 'auth_sessions', 'auth_audit'])
        ...db.select('SELECT * FROM $t').map((r) => r.values.join('|')),
    ].join('\n');
    expect(dump, isNot(contains('sentetik-sifre-2')));
    expect(dump, isNot(contains('58291')));
    expect(dump, isNot(contains(login.token)));
  });

  test('login, permissions per client, Windows-only refused on LAN even for owner', () async {
    await seed();
    final staff = await auth.login(username: 'deniz', password: 'sentetik-sifre-2',
        deviceId: dev1, client: 'personel');
    expect(staff.context.ok, isTrue);
    expect(auth.authorize(staff.context, 'orders.create'), 'ok');
    expect(auth.authorize(staff.context, 'payments.refund'), 'forbidden');
    expect(auth.authorize(staff.context, 'finance.view'), 'client_not_allowed');
    expect(auth.authorize(staff.context, 'sync.manual'), 'windows_only');
    expect(auth.authorize(staff.context, 'nope'), 'unknown_operation');
    final owner = await auth.login(username: 'sahip', password: 'sentetik-sifre-1',
        deviceId: dev2, client: 'yonetici');
    expect(auth.authorize(owner.context, 'backup.restore'), 'windows_only');
    expect(auth.authorize(owner.context, 'finance.view'), 'ok');
    expect(auth.authorize(owner.context, 'permissions.update'), 'mfa_required');
    // A token is bound to the client it was issued for.
    expect(auth.check(staff.token, 'yonetici').status, 'client_mismatch');
    // The JSON for the app lists only grants valid for that client.
    final grants = staff.context.toJson()['grants'] as List;
    expect(grants, contains('orders.create'));
    expect(grants, isNot(contains('sync.manual')));
  });

  test('wrong password locks the account for 15 minutes after 5 tries', () async {
    await seed();
    for (var i = 0; i < 5; i++) {
      await expectLater(auth.login(username: 'deniz', password: 'yanlis-sifre',
          deviceId: dev1, client: 'personel'), throwsA(isA<LocalAuthException>()));
    }
    await expectLater(auth.login(username: 'deniz', password: 'sentetik-sifre-2',
        deviceId: dev1, client: 'personel'),
        throwsA(isA<LocalAuthException>().having((e) => e.code, 'code', 'locked_out')));
    now = now.add(const Duration(minutes: 16));
    expect((await auth.login(username: 'deniz', password: 'sentetik-sifre-2',
        deviceId: dev1, client: 'personel')).context.ok, isTrue);
  });

  test('5-digit PIN rules and password unlock share the login lockout (independent review)', () async {
    await seed();
    final l = await auth.login(username: 'deniz', password: 'sentetik-sifre-2',
        deviceId: dev1, client: 'personel');
    for (final weak in ['11111', '12345', '54321', '123456', '1234', '5829a']) {
      expect(() => auth.setPin(l.token, 'personel', weak), throwsA(isA<LocalAuthException>()), reason: weak);
    }
    await auth.setPin(l.token, 'personel', '58291');
    now = now.add(const Duration(minutes: 31));
    expect(auth.check(l.token, 'personel').status, 'locked');
    for (var i = 0; i < 4; i++) {
      expect((await auth.unlockWithPassword(l.token, 'personel', 'wrong-pass')).status, 'invalid_credentials');
    }
    expect((await auth.unlockWithPassword(l.token, 'personel', 'wrong-pass')).status, 'locked_out');
    // Even the right password is refused for 15 minutes.
    expect((await auth.unlockWithPassword(l.token, 'personel', 'sentetik-sifre-2')).status, 'locked_out');
    now = now.add(const Duration(minutes: 16));
    expect((await auth.unlockWithPassword(l.token, 'personel', 'sentetik-sifre-2')).ok, isTrue);
    // A wrong client never unlocks.
    expect((await auth.unlockWithPassword(l.token, 'yonetici', 'sentetik-sifre-2')).status, 'revoked');
  });

  test('QA-17: a first PIN later than 5 minutes after sign-in also needs the password', () async {
    await seed();
    final l = await auth.login(username: 'deniz', password: 'sentetik-sifre-2',
        deviceId: dev1, client: 'personel');
    now = now.add(const Duration(minutes: 6)); // PIN step skipped, phone left unlocked
    await expectLater(auth.setPin(l.token, 'personel', '47302'),
        throwsA(isA<LocalAuthException>().having((e) => e.code, 'code', 'password_required')));
    await auth.setPin(l.token, 'personel', '47302', password: 'sentetik-sifre-2');
  });

  test('changing an existing PIN needs the password (an unlocked phone is not enough)', () async {
    await seed();
    final l = await auth.login(username: 'deniz', password: 'sentetik-sifre-2',
        deviceId: dev1, client: 'personel');
    await auth.setPin(l.token, 'personel', '58291'); // first PIN right after login
    await auth.setPin(l.token, 'personel', '58291'); // still the sign-in step: allowed
    // A password that is sent is checked even during the sign-in step.
    await expectLater(auth.setPin(l.token, 'personel', '47302', password: 'wrong-pass'),
        throwsA(isA<LocalAuthException>().having((e) => e.code, 'code', 'invalid_credentials')));
    now = now.add(const Duration(minutes: 6));
    await expectLater(auth.setPin(l.token, 'personel', '47302'),
        throwsA(isA<LocalAuthException>().having((e) => e.code, 'code', 'password_required')));
    await expectLater(auth.setPin(l.token, 'personel', '47302', password: 'wrong-pass'),
        throwsA(isA<LocalAuthException>().having((e) => e.code, 'code', 'invalid_credentials')));
    await auth.setPin(l.token, 'personel', '47302', password: 'sentetik-sifre-2');
    now = now.add(const Duration(minutes: 31));
    expect((await auth.unlockWithPin(l.token, 'personel', '58291')).status, 'invalid_pin');
    expect((await auth.unlockWithPin(l.token, 'personel', '47302')).ok, isTrue);
  });

  test('idle lock after 30 minutes; PIN re-entry; 5 wrong PINs need password', () async {
    await seed();
    final l = await auth.login(username: 'deniz', password: 'sentetik-sifre-2',
        deviceId: dev1, client: 'personel');
    expect(() => auth.setPin(l.token, 'personel', '12345'), throwsA(isA<LocalAuthException>()));
    await auth.setPin(l.token, 'personel', '58291');
    now = now.add(const Duration(minutes: 29));
    expect(auth.check(l.token, 'personel').ok, isTrue); // activity resets idle
    now = now.add(const Duration(minutes: 30));
    expect(auth.check(l.token, 'personel').status, 'locked');
    expect((await auth.unlockWithPin(l.token, 'personel', '58291')).ok, isTrue);
    now = now.add(const Duration(minutes: 31));
    for (var i = 0; i < 4; i++) {
      expect((await auth.unlockWithPin(l.token, 'personel', '00001')).status, 'invalid_pin');
    }
    expect((await auth.unlockWithPin(l.token, 'personel', '00001')).status, 'password_required');
    expect((await auth.unlockWithPin(l.token, 'personel', '58291')).status, 'password_required');
    expect((await auth.unlockWithPassword(l.token, 'personel', 'sentetik-sifre-2')).ok, isTrue);
    // Owner-configurable lock time.
    auth.idleLock = const Duration(minutes: 5);
    now = now.add(const Duration(minutes: 6));
    expect(auth.check(l.token, 'personel').status, 'locked');
  });

  test('sessions are bounded: expire after 30 days (offline-safe, no refresh token)', () async {
    await seed();
    final l = await auth.login(username: 'deniz', password: 'sentetik-sifre-2',
        deviceId: dev1, client: 'personel');
    for (var d = 0; d < 30; d++) {
      now = now.add(const Duration(days: 1));
      await auth.unlockWithPassword(l.token, 'personel', 'sentetik-sifre-2');
    }
    expect(auth.check(l.token, 'personel').status, 'expired');
  });

  test('deactivation, password reset, device and session revocation take effect at once', () async {
    final (_, staffId) = await seed();
    var l = await auth.login(username: 'deniz', password: 'sentetik-sifre-2',
        deviceId: dev1, client: 'personel');
    auth.setActive(staffId, false);
    expect(auth.check(l.token, 'personel').status, anyOf('revoked', 'inactive'));
    await expectLater(auth.login(username: 'deniz', password: 'sentetik-sifre-2',
        deviceId: dev1, client: 'personel'), throwsA(isA<LocalAuthException>()));
    auth.setActive(staffId, true);
    l = await auth.login(username: 'deniz', password: 'sentetik-sifre-2', deviceId: dev1, client: 'personel');
    await auth.resetPassword(staffId, 'yeni-sentetik-sifre');
    expect(auth.check(l.token, 'personel').status, 'revoked');
    l = await auth.login(username: 'deniz', password: 'yeni-sentetik-sifre', deviceId: dev1, client: 'personel');
    auth.revokeDevice(dev1);
    expect(auth.check(l.token, 'personel').status, 'revoked');
    await expectLater(auth.login(username: 'deniz', password: 'yeni-sentetik-sifre',
        deviceId: dev1, client: 'personel'),
        throwsA(isA<LocalAuthException>().having((e) => e.code, 'code', 'device_revoked')));
    // A device enrolled for one account cannot be reused by another.
    await expectLater(auth.login(username: 'sahip', password: 'sentetik-sifre-1',
        deviceId: dev1, client: 'personel'), throwsA(isA<LocalAuthException>()));
    l = await auth.login(username: 'deniz', password: 'yeni-sentetik-sifre', deviceId: dev2, client: 'personel');
    auth.logout(l.token);
    expect(auth.check(l.token, 'personel').status, 'revoked');
  });

  test('grants change per user and bump the permission version', () async {
    final (_, staffId) = await seed();
    final l = await auth.login(username: 'deniz', password: 'sentetik-sifre-2', deviceId: dev1, client: 'personel');
    final v = l.context.permissionVersion;
    auth.setGrant(staffId, 'payments.refund', true);
    final c = auth.check(l.token, 'personel');
    expect(c.permissionVersion, v + 1);
    expect(auth.authorize(c, 'payments.refund'), 'ok');
    expect(() => auth.setGrant(staffId, 'backup.restore', true), throwsA(isA<LocalAuthException>()));
    auth.setGrant(staffId, 'payments.refund', false);
    expect(auth.authorize(auth.check(l.token, 'personel'), 'payments.refund'), 'forbidden');
  });

  test('owner TOTP: enrollment, verification, no replay, admin needs MFA from LAN', () async {
    final (ownerId, _) = await seed();
    final secret = auth.beginTotp(ownerId);
    int step() => now.millisecondsSinceEpoch ~/ 30000;
    auth.confirmTotp(ownerId, LocalAuth.totpCode(secret, step()));
    expect(auth.mfaEnrolled(ownerId), isTrue);
    final l = await auth.login(username: 'sahip', password: 'sentetik-sifre-1', deviceId: dev2, client: 'yonetici');
    expect(auth.authorize(l.context, 'permissions.update'), 'mfa_required');
    // Same step cannot be replayed.
    expect(auth.verifyMfa(l.token, 'yonetici', LocalAuth.totpCode(secret, step())).status, 'invalid_code');
    now = now.add(const Duration(seconds: 30));
    final ok = auth.verifyMfa(l.token, 'yonetici', LocalAuth.totpCode(secret, step()));
    expect(ok.mfa, isTrue);
    expect(auth.authorize(ok, 'permissions.update'), 'ok');
    now = now.add(const Duration(hours: 13));
    await auth.unlockWithPassword(l.token, 'yonetici', 'sentetik-sifre-1');
    expect(auth.authorize(auth.check(l.token, 'yonetici'), 'permissions.update'), 'mfa_required');
    // RFC 6238 test vector (SHA-1, secret "12345678901234567890", T=59 s).
    expect(LocalAuth.totpCode('GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ', 1), '287082');
  });

  test('İlk Aktivasyon: one-time code sets own password and this device PIN', () async {
    final (owner, staff) = await seed();
    await expectLater(auth.issueActivation(owner), throwsA(isA<LocalAuthException>()));
    final old = await auth.login(username: 'deniz', password: 'sentetik-sifre-2', deviceId: dev1, client: 'personel');
    final issued = await auth.issueActivation(staff, actor: owner);
    expect(issued.code, matches(RegExp(r'^[A-Z0-9]{4}-[A-Z0-9]{4}$')));
    expect(issued.expiresAt, now.add(LocalAuth.activationLifetime));
    // Issuing is a reset: old password and sessions stop working.
    expect(auth.check(old.token, 'personel').ok, isFalse);
    await expectLater(auth.login(username: 'deniz', password: 'sentetik-sifre-2', deviceId: dev1, client: 'personel'),
        throwsA(isA<LocalAuthException>()));
    expect(auth.users().firstWhere((u) => u['userId'] == staff)['activation'], {'expiresAt': issued.expiresAt.toIso8601String(), 'expired': false});
    // The code is never stored in clear.
    expect(db.select('SELECT code_hash FROM auth_activations').single['code_hash'], isNot(contains(issued.code.replaceAll('-', ''))));
    // Weak PIN refused before the code is used.
    await expectLater(auth.activate(username: 'deniz', code: issued.code, password: 'kendi-sifrem-9',
        pin: '12345', deviceId: dev2, client: 'personel'), throwsA(predicate((e) => e is LocalAuthException && e.code == 'weak_pin')));
    final r = await auth.activate(username: 'Deniz ', code: issued.code.toLowerCase().replaceAll('-', ' '),
        password: 'kendi-sifrem-9', pin: '48207', deviceId: dev2, client: 'personel', label: 'Android');
    expect(r.context.ok, isTrue);
    expect(auth.devices(userId: staff).firstWhere((d) => d['deviceId'] == dev2)['hasPin'], isTrue);
    expect(auth.users().firstWhere((u) => u['userId'] == staff)['activation'], isNull);
    // One use only; the new password works.
    await expectLater(auth.activate(username: 'deniz', code: issued.code, password: 'kendi-sifrem-9',
        pin: '48207', deviceId: dev2, client: 'personel'), throwsA(predicate((e) => e is LocalAuthException && e.code == 'invalid_activation')));
    expect((await auth.login(username: 'deniz', password: 'kendi-sifrem-9', deviceId: dev2, client: 'personel')).context.ok, isTrue);
  });

  test('activation codes expire and five wrong tries void them', () async {
    final (owner, staff) = await seed();
    var issued = await auth.issueActivation(staff, actor: owner);
    now = now.add(LocalAuth.activationLifetime);
    await expectLater(auth.activate(username: 'deniz', code: issued.code, password: 'kendi-sifrem-9',
        pin: '48207', deviceId: dev2, client: 'personel'), throwsA(isA<LocalAuthException>()));
    expect(auth.activationOf(staff)!['expired'], isTrue);
    issued = await auth.issueActivation(staff, actor: owner);
    for (var i = 0; i < 5; i++) {
      await expectLater(auth.activate(username: 'deniz', code: 'AAAA-AAAA', password: 'kendi-sifrem-9',
          pin: '48207', deviceId: dev2, client: 'personel'), throwsA(isA<LocalAuthException>()));
    }
    await expectLater(auth.activate(username: 'deniz', code: issued.code, password: 'kendi-sifrem-9',
        pin: '48207', deviceId: dev2, client: 'personel'), throwsA(isA<LocalAuthException>()));
    await expectLater(auth.activate(username: 'nobody', code: issued.code, password: 'kendi-sifrem-9',
        pin: '48207', deviceId: dev2, client: 'personel'), throwsA(isA<LocalAuthException>()));
  });

  test('activation: inactive looks like any refusal; bad device keeps the code (QA-24/25)', () async {
    final (owner, staff) = await seed();
    final issued = await auth.issueActivation(staff, actor: owner);
    await expectLater(auth.activate(username: 'deniz', code: issued.code, password: 'kendi-sifrem-9',
        pin: '48207', deviceId: 'bad', client: 'personel'),
        throwsA(predicate((e) => e is LocalAuthException && e.code == 'invalid_device')));
    await expectLater(auth.activate(username: 'deniz', code: issued.code, password: 'kendi-sifrem-9',
        pin: '48207', deviceId: dev2, client: 'nope'),
        throwsA(predicate((e) => e is LocalAuthException && e.code == 'client_not_allowed')));
    expect(auth.activationOf(staff), isNotNull, reason: 'code not consumed');
    auth.setActive(staff, false, actor: owner);
    await expectLater(auth.activate(username: 'deniz', code: issued.code, password: 'kendi-sifrem-9',
        pin: '48207', deviceId: dev2, client: 'personel'),
        throwsA(predicate((e) => e is LocalAuthException && e.code == 'invalid_activation')));
    auth.setActive(staff, true, actor: owner);
    final r = await auth.activate(username: 'deniz', code: issued.code, password: 'kendi-sifrem-9',
        pin: '48207', deviceId: dev2, client: 'personel');
    expect(r.context.ok, isTrue);
  });
}
