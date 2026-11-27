import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:nohut_falafel_desktop/lan_auth_gate.dart';
import 'package:nohut_falafel_desktop/local_accounts.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';

/// Independent QA & security regression suite maintained on `gemini/independent-qa`.
/// Uses synthetic data only — never real restaurant, customer or employee records.
void main() {
  group('P0 Security & Authorization (LocalAuth + LanAuthGate)', () {
    late Database db;
    late DateTime clock;
    late LocalAuth auth;
    late LanAuthGate gate;

    setUp(() {
      db = sqlite3.openInMemory();
      clock = DateTime.utc(2026, 11, 27, 10, 0);
      auth = LocalAuth(db, clock: () => clock, iterations: 1000);
      gate = LanAuthGate(auth, clock: () => clock);
    });

    tearDown(() {
      db.dispose();
    });

    test('Windows-only sync.* and backup.* operations are refused on LAN clients even for owner', () async {
      await auth.createUser(
        username: 'qa_owner',
        password: 'OwnerPassword123',
        role: 'Yönetici',
        employeeId: 1,
        isOwner: true,
      );
      final login = await auth.login(
        username: 'qa_owner',
        password: 'OwnerPassword123',
        deviceId: 'qa_device_yonetici_001',
        client: 'yonetici',
      );
      expect(login.context.ok, isTrue);
      expect(auth.authorize(login.context, 'sync.cloud.configure'), 'windows_only');
      expect(auth.authorize(login.context, 'sync.initial.start'), 'windows_only');
      expect(auth.authorize(login.context, 'backup.manual'), 'windows_only');
      expect(auth.authorize(login.context, 'backup.restore'), 'windows_only');
      expect(auth.authorize(login.context, 'backup.delete'), 'windows_only');
    });

    test('Deactivating an employee immediately revokes active LAN sessions', () async {
      await auth.createUser(
        username: 'qa_owner',
        password: 'OwnerPassword123',
        role: 'Yönetici',
        employeeId: 1,
        isOwner: true,
      );
      final staffId = await auth.createUser(
        username: 'qa_staff',
        password: 'StaffPassword123',
        role: 'Personel',
        employeeId: 2,
      );
      final login = await auth.login(
        username: 'qa_staff',
        password: 'StaffPassword123',
        deviceId: 'qa_device_staff_001',
        client: 'personel',
      );
      expect(auth.check(login.token, 'personel').ok, isTrue);

      auth.setActive(staffId, false, actor: 'qa_owner');
      final after = auth.check(login.token, 'personel');
      expect(after.ok, isFalse);
      expect(after.status, 'revoked');

      await expectLater(
        auth.login(
          username: 'qa_staff',
          password: 'StaffPassword123',
          deviceId: 'qa_device_staff_001',
          client: 'personel',
        ),
        throwsA(isA<LocalAuthException>().having((e) => e.code, 'code', 'inactive')),
      );
    });

    test('Owner TOTP code cannot be replayed within the same 30-second step', () async {
      final ownerId = await auth.createUser(
        username: 'qa_owner',
        password: 'OwnerPassword123',
        role: 'Yönetici',
        employeeId: 1,
        isOwner: true,
      );
      final secret = auth.beginTotp(ownerId);
      final step = clock.millisecondsSinceEpoch ~/ 30000;
      auth.confirmTotp(ownerId, LocalAuth.totpCode(secret, step));

      final login = await auth.login(
        username: 'qa_owner',
        password: 'OwnerPassword123',
        deviceId: 'qa_device_yonetici_002',
        client: 'yonetici',
      );
      // Advance 30s so next step is fresh after confirmTotp.
      clock = clock.add(const Duration(seconds: 30));
      final nextStep = clock.millisecondsSinceEpoch ~/ 30000;
      final code = LocalAuth.totpCode(secret, nextStep);

      final verified = auth.verifyMfa(login.token, 'yonetici', code);
      expect(verified.ok, isTrue);
      expect(verified.mfa, isTrue);

      // Replaying the exact same TOTP code must fail.
      final replay = auth.verifyMfa(login.token, 'yonetici', code);
      expect(replay.ok, isFalse);
      expect(replay.status, 'invalid_code');
    });

    test('5 wrong PIN attempts clear the device PIN and require password', () async {
      await auth.createUser(
        username: 'qa_owner',
        password: 'OwnerPassword123',
        role: 'Yönetici',
        employeeId: 1,
        isOwner: true,
      );
      final login = await auth.login(
        username: 'qa_owner',
        password: 'OwnerPassword123',
        deviceId: 'qa_device_staff_002',
        client: 'personel',
      );
      await auth.setPin(login.token, 'personel', '482917');
      clock = clock.add(const Duration(minutes: 40)); // idle lock
      expect(auth.check(login.token, 'personel').status, 'locked');

      for (var i = 0; i < 4; i++) {
        final bad = await auth.unlockWithPin(login.token, 'personel', '192837');
        expect(bad.status, 'invalid_pin');
      }
      final fifth = await auth.unlockWithPin(login.token, 'personel', '192837');
      expect(fifth.status, 'password_required');

      // Even the previously valid PIN must no longer unlock once cleared.
      final afterClear = await auth.unlockWithPin(login.token, 'personel', '482917');
      expect(afterClear.status, 'password_required');
    });

    test('LanAuthGate.withIdentity always stamps signed-in employeeId and blocks impersonation', () async {
      await auth.createUser(
        username: 'qa_owner',
        password: 'OwnerPassword123',
        role: 'Yönetici',
        employeeId: 1,
        isOwner: true,
      );
      await auth.createUser(
        username: 'qa_staff',
        password: 'StaffPassword123',
        role: 'Personel',
        employeeId: 7,
      );
      final login = await auth.login(
        username: 'qa_staff',
        password: 'StaffPassword123',
        deviceId: 'qa_device_staff_003',
        client: 'personel',
      );
      final decision = gate.guard(
        token: login.token,
        client: 'personel',
        operation: 'orders.create',
        forceRequired: true,
      );
      expect(decision.allowed, isTrue);

      final forgedPayload = <String, dynamic>{'staffId': 1, 'table': 2};
      final bound = LanAuthGate.withIdentity(forgedPayload, decision.context);
      expect(bound['staffId'], 7);
    });
  });

  group('P0 Financial Integrity (exact kuruş arithmetic)', () {
    test('Order totals, partial payments, refunds, and due amounts stay exact in integer kuruş', () {
      final order = <String, dynamic>{
        'id': 1,
        'source': 'Masa',
        'table': 1,
        'batches': [
          {
            'id': 1,
            'lines': [
              {'id': 'l1', 'name': 'Test Dürüm', 'qty': 3, 'price': 133.33},
              {'id': 'l2', 'name': 'Test Ayran', 'qty': 1, 'price': 25.01},
            ],
          },
        ],
        'payments': [
          {
            'id': 'p1',
            'amount': 200.00,
            'method': 'Nakit',
            'refunds': [
              {'id': 'r1', 'amount': 25.00, 'reason': 'Test iade'},
            ],
          },
          {'id': 'p2', 'amount': 125.00, 'method': 'Kart'},
        ],
      };
      // 3 * 13333 + 2501 = 39999 + 2501 = 42500 kuruş (425.00 TL)
      // Net paid = (20000 - 2500) + 12500 = 30000 kuruş (300.00 TL)
      // Due = 42500 - 30000 = 12500 kuruş (125.00 TL)
      expect(orderTotalCents(order), 42500);
      expect(orderPaidCents(order), 30000);
      expect(orderDueCents(order), 12500);
    });
  });
}
