// Native Yönetici Haftalık Maaş Ödemeleri: Windows numbers shown as-is,
// payments confirmed by Windows, retries keep their request id.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_personel/owner_payroll.dart';
import 'package:nohut_personel/pos_api.dart';
import 'package:nohut_personel/style.dart';

Json payrollReply({int paid = 0}) => {
  'ok': true, 'weekStart': '2026-11-16', 'today': '2026-11-24',
  'rows': [
    {'employeeId': 7, 'name': 'Test Personel A', 'rate': {'payType': 'Saatlik', 'rateCents': 12000},
     'minutes': 960, 'earnedCents': 176000, 'paidCents': paid, 'remainingCents': 176000 - paid,
     'financialStatus': paid == 0 ? 'Ödenmedi' : paid < 176000 ? 'Kısmen Ödendi' : 'Ödendi',
     'overdue': true, 'legacy': false},
    {'employeeId': 8, 'name': 'Test Personel B', 'rate': null, 'minutes': 0, 'earnedCents': null,
     'paidCents': 0, 'remainingCents': null, 'financialStatus': 'Çalışma kaydı yok', 'legacy': false},
  ],
  'payments': [
    if (paid > 0) {'id': 'pp_1', 'employeeId': 7, 'paidOn': '2026-11-24', 'kind': 'Ödeme', 'method': 'Nakit', 'amountCents': paid},
  ],
};

void main() {
  late List<Json> sent;
  late int paid;
  late bool dropNext;
  late Set<Object?> applied;

  setUp(() { sent = []; paid = 0; dropNext = false; applied = {}; });

  Future<Json> fake(Json p) async {
    sent.add(p);
    if (p['operation'] == 'ownerPayroll') return payrollReply(paid: paid);
    if (p['operation'] == 'managerWrite') {
      final d = p['data'] as Map;
      if (dropNext) {
        dropNext = false;
        applied.add(p['requestId']);
        paid += (d['cashCents'] as int) + (d['bankCents'] as int); // applied, reply lost
        throw Exception('connection reset');
      }
      if (applied.contains(p['requestId'])) return {'ok': true}; // replay of an applied request
      if (d['expectedPaidCents'] != paid) throw const FormatException('Kayıt Windows üzerinde değişti.');
      applied.add(p['requestId']);
      paid += (d['cashCents'] as int) + (d['bankCents'] as int);
      return {'ok': true};
    }
    throw const FormatException('?');
  }

  Future<void> pump(WidgetTester t, {Size size = const Size(412, 915), double scale = 1}) async {
    t.view.physicalSize = size * 3;
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: NohutStyle.theme,
      builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: OwnerPayrollPage(request: fake)));
    await t.pumpAndSettle();
  }

  Future<void> payCash(WidgetTester t, String amount) async {
    await t.tap(find.text('Ödeme Kaydet'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('pay-cash')), amount);
    await t.tap(find.widgetWithText(FilledButton, 'Kaydet'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(FilledButton, 'Kaydet').last); // confirm dialog
    await t.pumpAndSettle();
  }

  testWidgets('acceptance: 1760 earned; pay 800 → Kısmen Ödendi, 960 left', (t) async {
    await pump(t);
    expect(find.text('Ödenmedi'), findsOneWidget);
    expect(find.text('Gecikti'), findsOneWidget);
    expect(find.text(money(176000)), findsWidgets);
    // Unknown money is never shown as 0 TL.
    expect(find.text('Çalışma kaydı yok'), findsOneWidget);
    // Totals skip people with nothing owed; they are not unknown.
    expect(find.textContaining('Ücreti tanımlı olmayan'), findsNothing);
    await payCash(t, '800');
    final w = sent.lastWhere((p) => p['operation'] == 'managerWrite');
    expect(w['action'], 'payroll_payment');
    expect(w['data'], containsPair('cashCents', 80000));
    expect(w['data'], containsPair('bankCents', 0));
    expect(w['data'], containsPair('expectedPaidCents', 0));
    expect(w['data'], containsPair('weekStart', '2026-11-16'));
    expect(find.text('Kısmen Ödendi'), findsOneWidget);
    expect(find.text(money(96000)), findsWidgets);
    expect(find.text('Ödeme Windows’a kaydedildi.'), findsOneWidget);
  });

  testWidgets('a lost reply: Windows is asked before anything is claimed', (t) async {
    await pump(t);
    dropNext = true;
    await payCash(t, '800');
    // Windows had applied it: the screen says so and shows the new status.
    expect(find.text('Ödeme Windows’a kaydedildi (bağlantı geri geldi).'), findsOneWidget);
    expect(find.text('Kısmen Ödendi'), findsOneWidget);
    expect(paid, 80000);
    final id = sent.lastWhere((p) => p['operation'] == 'managerWrite')['requestId'] as String;
    expect(RegExp(r'^[A-Za-z0-9_-]{16,80}$').hasMatch(id), true);
  });

  testWidgets('Windows unreachable after a lost reply: the identical retry reuses the request id', (t) async {
    await pump(t);
    var offline = false, writes = 0;
    final realFake = fake;
    Future<Json> flaky(Json p) async {
      if (offline && p['operation'] == 'ownerPayroll') { sent.add(p); throw Exception('offline'); }
      if (p['operation'] == 'managerWrite' && writes++ == 0) { offline = true; sent.add(p); throw Exception('reset'); }
      return realFake(p);
    }
    t.view.physicalSize = const Size(412, 915) * 3;
    await t.pumpWidget(MaterialApp(theme: NohutStyle.theme, home: OwnerPayrollPage(key: const ValueKey('flaky'), request: flaky)));
    await t.pumpAndSettle();
    await payCash(t, '800');
    expect(find.textContaining('kayıt iki kez oluşmaz'), findsOneWidget);
    expect(paid, 0);
    offline = false;
    await t.pump(const Duration(seconds: 5));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Yenile'));
    await t.pumpAndSettle();
    await payCash(t, '800');
    final ids = [for (final p in sent.where((p) => p['operation'] == 'managerWrite')) p['requestId']];
    expect(ids, hasLength(2));
    expect(ids[0], ids[1]);
    expect(paid, 80000);
  });

  testWidgets('wrong amount is refused locally; Karma needs both parts', (t) async {
    await pump(t);
    await t.tap(find.text('Ödeme Kaydet'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('pay-cash')), '12,345');
    await t.tap(find.widgetWithText(FilledButton, 'Kaydet'));
    await t.pumpAndSettle();
    expect(find.text('Tutarı girin (ör. 1.250,00).'), findsOneWidget);
    await t.tap(find.text('Karma'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('pay-cash')), '100');
    await t.enterText(find.byKey(const ValueKey('pay-bank')), '0');
    await t.tap(find.widgetWithText(FilledButton, 'Kaydet'));
    await t.pumpAndSettle();
    expect(find.text('Karma ödemede nakit ve havale tutarını girin.'), findsOneWidget);
    expect(sent.where((p) => p['operation'] == 'managerWrite'), isEmpty);
  });

  testWidgets('small phone with large text lays out without overflow', (t) async {
    await pump(t, size: const Size(320, 640), scale: 1.3);
    expect(t.takeException(), isNull);
    await t.scrollUntilVisible(find.text('Ödeme Kaydet'), 200, scrollable: find.byType(Scrollable).first);
    expect(t.takeException(), isNull);
    await t.tap(find.text('Ödeme Kaydet'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });

  test('parseTl: Turkish amounts to kuruş with integer math', () {
    expect(parseTl('800'), 80000);
    expect(parseTl('1.250,50'), 125050);
    expect(parseTl('1250,5'), 125050);
    expect(parseTl('960 ₺'), 96000);
    expect(parseTl('0,07'), 7);
    expect(parseTl('12,345'), isNull);
    expect(parseTl('1,2,3'), isNull);
    expect(parseTl('-5'), isNull);
    expect(parseTl(''), isNull);
  });
}
