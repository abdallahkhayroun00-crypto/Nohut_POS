// Platform Yönetimi: one read model and one enable rule for the standalone
// page and the Ana Sayfa quick widget; honest states; confirm before the
// single command; renders when NOHUT_RENDER_DIR is set. No provider calls.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_core/platform_status.dart';
import 'package:nohut_falafel_desktop/brand.dart';
import 'package:nohut_falafel_desktop/platform_management.dart';
import 'package:nohut_falafel_desktop/platform_management_ui.dart';

final now = DateTime.utc(2026, 11, 28, 9);

class FakeControl implements PlatformControl {
  FakeControl(this.cards);
  List<PlatformCard> cards;
  final commands = <(String, PlatformWorking, PlatformWorking)>[];
  @override
  Future<List<PlatformCard>> load() async => cards;
  @override
  Future<void> refresh(String provider) async {}
  @override
  Future<void> setStoreStatus(String provider, PlatformWorking target, {required PlatformWorking expected}) async {
    commands.add((provider, target, expected));
    cards = [for (final c in cards) c.provider == provider
        ? PlatformCard(provider: provider, connection: c.connection, working: c.working,
            lastVerifiedAt: c.lastVerifiedAt, canToggleStore: true,
            pending: PlatformPending('r1', target, 'pending'))
        : c];
  }
}

PlatformCard tgoOpen({DateTime? verified, bool caps = true}) => PlatformCard.fromJson({
  'provider': 'trendyol_go', 'connectionState': 'connected', 'workingStatus': 'OPEN',
  'verifiedStoreId': '456', 'verifiedStoreName': 'Nohut Falafel (sentetik)',
  'lastVerifiedAt': (verified ?? now.subtract(const Duration(minutes: 2))).toIso8601String(),
  'workingHours': [{'dayOfWeek': 'MONDAY', 'openingTime': '11:00', 'closingTime': '23:00'}],
  'capabilities': {'toggleStore': caps},
  'auditHistory': [{'at': '27.11 21:05', 'actor': 'Yönetici', 'action': 'store_status',
    'oldStatus': 'CLOSED', 'newStatus': 'OPEN', 'outcome': 'confirmed'}],
});

final boundary = GlobalKey();

Future<void> mount(WidgetTester t, Widget child, {Size size = const Size(1200, 900)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  if (Platform.environment['NOHUT_RENDER_DIR'] != null) {
    await t.runAsync(() async {
      final body = FontLoader(NohutBrand.bodyFont)
        ..addFont(rootBundle.load('assets/brand/fonts/Barlow-Regular.ttf'))
        ..addFont(rootBundle.load('assets/brand/fonts/Barlow-Bold.ttf'));
      final heading = FontLoader(NohutBrand.headingFont)
        ..addFont(rootBundle.load('assets/brand/fonts/BreeSerif-Regular.ttf'));
      final icons = FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await Future.wait([body.load(), heading.load(), icons.load()]);
    });
  }
  await t.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: NohutBrand.theme(),
    home: RepaintBoundary(key: boundary, child: Scaffold(body: SingleChildScrollView(
      padding: const EdgeInsets.all(24), child: child)))));
  await t.pumpAndSettle();
}

Future<void> shot(WidgetTester t, String name) async {
  final dir = Platform.environment['NOHUT_RENDER_DIR'];
  if (dir == null) return;
  await t.runAsync(() async {
    final image = await (boundary.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  group('read model', () {
    test('labels and the single enable rule', () {
      final open = tgoOpen();
      expect(open.statusLabel(now), 'Açık');
      expect(open.toggleTarget, PlatformWorking.closed);
      expect(open.toggleBlockedReason(now, granted: true), isNull);
      expect(open.toggleBlockedReason(now, granted: false), contains('yetki'));

      final stale = tgoOpen(verified: now.subtract(const Duration(minutes: 30)));
      expect(stale.statusLabel(now), 'Bilinmiyor');
      expect(stale.toggleBlockedReason(now, granted: true), contains('Yenile'));

      expect(tgoOpen(caps: false).toggleBlockedReason(now, granted: true), isNotNull);

      final pending = PlatformCard.fromJson({'provider': 'trendyol_go', 'connectionState': 'connected',
        'workingStatus': 'OPEN', 'lastVerifiedAt': now.toIso8601String(), 'capabilities': {'toggleStore': true},
        'pendingMutation': {'requestId': 'x', 'targetStatus': 'CLOSED', 'outcome': 'unknown'}});
      expect(pending.statusLabel(now), 'Doğrulanıyor');
      expect(pending.toggleBlockedReason(now, granted: true), isNotNull);

      final odd = PlatformCard.fromJson({'provider': 'yemeksepeti', 'connectionState': 'weird',
        'workingStatus': 'BUSY'});
      expect(odd.statusLabel(now), 'Entegrasyon bekleniyor');
      expect(PlatformCard.completeSet([open]).map((c) => c.provider),
          ['trendyol_go', 'yemeksepeti', 'migros_yemek']);
    });

    test('Windows today: credentials alone never enable Aç/Kapat', () async {
      final cards = await PendingPlatformControl().load();
      expect(cards.map((c) => c.statusLabel(now)).toSet(), {'Entegrasyon bekleniyor'});
      expect(cards.every((c) => c.toggleBlockedReason(now, granted: true) != null), isTrue);
      await expectLater(PendingPlatformControl().setStoreStatus('trendyol_go', PlatformWorking.closed,
          expected: PlatformWorking.open), throwsA(isA<PlatformUnavailable>()));
    });
  });

  testWidgets('page: confirm then one command; page and quick widget agree', (t) async {
    final control = FakeControl([tgoOpen()]);
    await mount(t, PlatformManagementPage(control: control, now: () => now));
    expect(find.byKey(const ValueKey('platform-card-migros_yemek')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('platform-status-yemeksepeti')),
        matching: find.text('Entegrasyon bekleniyor')), findsOneWidget);
    await shot(t, 'platform-page-wide');

    await t.tap(find.byKey(const ValueKey('platform-toggle-trendyol_go')));
    await t.pumpAndSettle();
    expect(find.textContaining('iptal edilmez'), findsOneWidget);
    await t.tap(find.text('Vazgeç').last);
    await t.pumpAndSettle();
    expect(control.commands, isEmpty, reason: 'cancelled confirmation sends nothing');

    await t.tap(find.byKey(const ValueKey('platform-toggle-trendyol_go')));
    await t.pumpAndSettle();
    await t.tap(find.text('Evet, kapat'));
    await t.pumpAndSettle();
    expect(control.commands, [('trendyol_go', PlatformWorking.closed, PlatformWorking.open)]);
    expect(find.descendant(of: find.byKey(const ValueKey('platform-status-trendyol_go')),
        matching: find.text('İşleniyor')), findsOneWidget);
    final again = t.widget<FilledButton>(find.byKey(const ValueKey('platform-toggle-trendyol_go')));
    expect(again.onPressed, isNull, reason: 'no second command while pending');

    var opened = false;
    await mount(t, SizedBox(width: 420, child: PlatformQuickPanel(control: control,
        onOpenPage: () => opened = true, now: () => now)), size: const Size(470, 330));
    expect(find.text('İşleniyor'), findsOneWidget);
    expect(t.widget<TextButton>(find.byKey(const ValueKey('platform-quick-toggle-trendyol_go'))).onPressed, isNull);
    await shot(t, 'platform-quick-pending');
    await t.tap(find.byKey(const ValueKey('platform-quick-open')));
    expect(opened, isTrue);
  });

  testWidgets('narrow page and Windows-today quick widget render honestly', (t) async {
    await mount(t, PlatformManagementPage(control: PendingPlatformControl(), now: () => now),
        size: const Size(520, 1600));
    for (final p in platformProviderOrder) {
      expect(t.widget<FilledButton>(find.byKey(ValueKey('platform-toggle-$p'))).onPressed, isNull);
    }
    await shot(t, 'platform-page-narrow-today');
    await mount(t, SizedBox(width: 420, child: PlatformQuickPanel(control: PendingPlatformControl(),
        onOpenPage: () {}, now: () => now)), size: const Size(470, 330));
    await shot(t, 'platform-quick-today');
  });
}
