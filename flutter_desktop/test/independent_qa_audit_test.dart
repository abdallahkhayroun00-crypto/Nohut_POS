import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:nohut_falafel_desktop/card_terminal.dart';
import 'package:nohut_falafel_desktop/lan_auth_gate.dart';
import 'package:nohut_falafel_desktop/local_accounts.dart';
import 'package:nohut_falafel_desktop/operations.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/staff_commands.dart';

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

    test('Equal split distributes remainder kuruş exactly (100.01 TL across 3 guests)', () {
      final order = <String, dynamic>{
        'id': 10,
        'source': 'Masa',
        'table': 2,
        'batches': [
          {
            'id': 1,
            'lines': [
              {'id': 'l1', 'name': 'Test Menü', 'qty': 1, 'price': 100.01},
            ],
          },
        ],
        'payments': <dynamic>[],
        'events': <dynamic>[],
      };
      splitEqually(order, 3);
      final balances = [
        for (final g in asMaps(order['guestChecks']))
          guestBalance(order, g['id'] as int),
      ];
      expect(balances, [3334, 3334, 3333]);
      expect(balances.fold<int>(0, (a, b) => a + b), 10001);
    });

    test('Refund cap and cancellation guard prevent over-refunding or cancelling paid orders', () {
      final state = <String, dynamic>{
        'employees': [
          {'id': 1, 'name': 'QA Owner', 'role': 'Yönetici', 'active': true},
        ],
        'orders': [
          {
            'id': 11,
            'source': 'Masa',
            'table': 3,
            'batches': [
              {
                'id': 1,
                'staff': 'QA Owner',
                'lines': [
                  {'id': 'l1', 'name': 'Test Dürüm', 'qty': 1, 'price': 150.00},
                ],
              },
            ],
            'payments': <dynamic>[],
            'events': <dynamic>[],
          },
        ],
        'printJobs': <dynamic>[],
        'nextId': 1200,
      };
      final order = mutableOrder(state, 11)!;
      recordPayment(order, 10000, 'Nakit', receivedCents: 10000);
      expect(orderPaidCents(order), 10000);

      // Cannot cancel while order holds net payments
      expect(() => cancelLocalOrder(state, 11, 'Müşteri vazgeçti'), throwsFormatException);

      // Cannot refund more than collected
      expect(() => refundPayment(order, 0, 10001, 'Fazla iade'), throwsFormatException);

      // Exact refund succeeds, then cancellation succeeds
      refundPayment(order, 0, 10000, 'Tam iade');
      expect(orderPaidCents(order), 0);
      cancelLocalOrder(state, 11, 'Tam iade sonrası iptal');
      expect(order['cancelled'], isTrue);
      expect(order['closed'], isTrue);
    });
  });

  group('P1 Concurrency, Idempotency & Duplicate Transaction Prevention', () {
    test('PosStore.command deduplicates retries and rejects reused requestId with mutated payload', () {
      final dir = Directory.systemTemp.createTempSync('nohut_qa_conc_');
      try {
        final store = PosStore(databaseFile: '${dir.path}/conc.sqlite3');
        final s0 = store.read();
        final data0 = s0.data;
        data0['localMenu'] = [
          {'id': 1, 'name': 'Test Falafel', 'price': 120.00, 'active': true, 'category': 'Test'},
        ];
        store.replace(data0, s0.revision);

        final rev = store.read().revision;
        final payload = {
          'requestId': 'qa_idem_order_0001',
          'expectedRevision': rev,
          'staffId': 2,
          'source': 'Masa',
          'table': 1,
          'lines': [{'productId': 1, 'qty': 2}],
        };
        final r1 = submitStaffOrder(store, payload);
        final r2 = submitStaffOrder(store, payload);
        expect(r2['orderId'], r1['orderId']);
        expect(asMaps(store.read().data['orders']).length, 1);

        // Reusing the same requestId with a different payload must throw
        expect(
          () => submitStaffOrder(store, {...payload, 'table': 2}),
          throwsFormatException,
        );

        // Stale revision on a new requestId must throw StaffConflict
        expect(
          () => submitStaffOrder(store, {
            ...payload,
            'requestId': 'qa_idem_order_0002',
            'table': 2,
          }),
          throwsA(isA<StaffConflict>()),
        );
        store.dispose();
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('InposPayments never double-charges on retry and preserves order when outcome is unknown', () async {
      final dir = Directory.systemTemp.createTempSync('nohut_qa_term_');
      try {
        final store = PosStore(databaseFile: '${dir.path}/term.sqlite3');
        final s0 = store.read();
        final data0 = s0.data;
        data0['localMenu'] = [
          {'id': 1, 'name': 'Test Falafel', 'price': 100.00, 'active': true, 'category': 'Test'},
        ];
        store.replace(data0, s0.revision);
        final created = submitStaffOrder(store, {
          'requestId': 'qa_term_order_0001',
          'expectedRevision': store.read().revision,
          'staffId': 2,
          'source': 'Masa',
          'table': 4,
          'lines': [{'productId': 1, 'qty': 1}],
        });
        final orderId = created['orderId'] as int;
        final gw = _FakeTerminalGateway();
        final terminal = InposPayments(store, gw);

        // First call times out / unknown -> no payment recorded, deletion blocked
        gw.payReply = const TerminalReply(TerminalStatus.unknown);
        final first = await terminal.pay(orderId, 10000, 'qa_ref_0001');
        expect(first.status, TerminalStatus.unknown);
        expect(gw.payCalls, 1);
        expect(orderPaidCents(mutableOrder(store.read().data, orderId)!), 0);
        expect(
          () => store.deleteOrder(orderId, store.read().revision, 'qa_del_term_0001'),
          throwsFormatException,
        );

        // Retry with same reference must inquire, NEVER call pay() a second time
        gw.inquireReply = const TerminalReply(
          TerminalStatus.approved,
          transactionId: 'TX-QA-001',
          amountCents: 10000,
        );
        final retry = await terminal.pay(orderId, 10000, 'qa_ref_0001');
        expect(retry.status, TerminalStatus.approved);
        expect(gw.payCalls, 1);
        expect(gw.inquireCalls, 1);
        expect(orderPaidCents(mutableOrder(store.read().data, orderId)!), 10000);
        store.dispose();
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}

class _FakeTerminalGateway implements InposGateway {
  @override
  bool get ready => true;
  int payCalls = 0;
  int inquireCalls = 0;
  TerminalReply payReply = const TerminalReply(TerminalStatus.unknown);
  TerminalReply inquireReply = const TerminalReply(TerminalStatus.unknown);

  @override
  Future<TerminalReply> pay(String reference, int amountCents) async {
    payCalls++;
    return payReply;
  }

  @override
  Future<TerminalReply> inquire(String reference) async {
    inquireCalls++;
    return inquireReply;
  }
}
