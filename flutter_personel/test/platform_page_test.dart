import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_core/platform_status.dart';
import 'package:nohut_personel/platform_page.dart';
import 'package:nohut_personel/pos_api.dart';
import 'package:nohut_personel/style.dart';

import 'visual/render_harness.dart';

/// What Windows answers for `ownerPlatforms` / `ownerPlatform`.
PlatformRequest windows(List<Json> asked, {bool verified = true, String? refuse}) => (p) async {
  asked.add(p);
  if (p['operation'] == 'ownerPlatform') {
    return refuse == null ? {'ok': true} : {'ok': false, 'error': 'unavailable', 'message': refuse};
  }
  return {'ok': true, 'canToggle': true, 'cards': [
    PlatformCard(provider: 'trendyol_go', connection: PlatformConnection.connected,
        working: verified ? PlatformWorking.open : PlatformWorking.unknown,
        verifiedStoreId: verified ? '316490' : null, verifiedStoreName: verified ? 'Nohut Falafel' : null,
        lastVerifiedAt: verified ? DateTime.now().toUtc() : null, canToggleStore: verified,
        note: verified ? null : 'Mağaza durumu bulut üzerinden doğrulanacak. Platform bağlantısı hazırlanıyor.',
        workingHours: const [PlatformHours('MONDAY', '11:00', '23:00')]).toJson(),
    const PlatformCard(provider: 'yemeksepeti', connection: PlatformConnection.notConnected,
        note: 'Yemeksepeti için doğrulanmış resmî entegrasyon yok.').toJson(),
  ]};
};

void main() {
  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await loadNohutFonts();
  });

  Widget app(Widget body) => MaterialApp(debugShowCheckedModeBanner: false,
      theme: NohutStyle.theme, darkTheme: NohutStyle.darkTheme,
      home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: body)));

  test('card JSON round-trips through the shared model', () {
    final c = PlatformCard(provider: 'trendyol_go', connection: PlatformConnection.connected,
        working: PlatformWorking.closed, lastVerifiedAt: DateTime.utc(2026, 11, 28, 9),
        pending: const PlatformPending('r1', PlatformWorking.open, 'unknown'), canToggleStore: true,
        audit: const [PlatformAuditEntry(at: 'x', actor: 'Ömer', action: 'store', oldStatus: 'OPEN',
            newStatus: 'CLOSED', outcome: 'confirmed')]);
    final back = PlatformCard.fromJson(c.toJson());
    final now = DateTime.utc(2026, 11, 28, 9, 1);
    expect(back.statusLabel(now), c.statusLabel(now));
    expect(back.toggleBlockedReason(now, granted: true), 'Önceki istek doğrulanıyor.');
    expect(back.audit.single.newStatus, 'CLOSED');
    expect(back.toJson(), c.toJson());
  });

  for (final (label, size, mode) in [
    ('phone', const Size(412, 915), Brightness.light),
    ('phone-dark', const Size(412, 915), Brightness.dark),
    ('compact', const Size(320, 640), Brightness.light),
  ]) {
    testWidgets('Platform Yönetimi page ($label)', (t) async {
      final asked = <Json>[];
      await renderScreen(t, 'platform-$label',
          app(PlatformPage(source: OwnerPlatformSource(windows(asked)))), size: size, brightness: mode);
      expect(asked.single, {'operation': 'ownerPlatforms'});
      expect(find.byKey(const ValueKey('platform-card-migros_yemek')), findsOneWidget);
      expect(find.text('Açık'), findsOneWidget);
      expect(find.text('Entegrasyon bekleniyor'), findsNWidgets(2));
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('close asks first; cancel sends nothing; confirm sends one command', (t) async {
    final asked = <Json>[];
    await t.pumpWidget(app(PlatformPage(source: OwnerPlatformSource(windows(asked)))));
    await t.pumpAndSettle();
    expect(t.widget<FilledButton>(find.byKey(const ValueKey('platform-toggle-yemeksepeti'))).onPressed, isNull);
    await t.tap(find.byKey(const ValueKey('platform-toggle-trendyol_go')));
    await t.pumpAndSettle();
    expect(find.textContaining('iptal edilmez'), findsOneWidget);
    await t.tap(find.text('Vazgeç'));
    await t.pumpAndSettle();
    expect(asked.where((a) => a['operation'] == 'ownerPlatform'), isEmpty);
    await t.tap(find.byKey(const ValueKey('platform-toggle-trendyol_go')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('platform-confirm')));
    await t.pumpAndSettle();
    final sent = asked.where((a) => a['operation'] == 'ownerPlatform').toList();
    expect(sent.single['data'], {'action': 'store', 'provider': 'trendyol_go', 'target': 'CLOSED',
      'expected': 'OPEN', 'confirmed': true});
    expect(find.byKey(const ValueKey('platform-message')), findsOneWidget);
  });

  testWidgets('quick card: unverified or offline is disabled with the reason', (t) async {
    final asked = <Json>[];
    var opened = 0;
    await renderScreen(t, 'platform-quick',
        app(PlatformQuickCard(source: OwnerPlatformSource(windows(asked, verified: false)), onOpen: () => opened++)));
    expect(find.text('Bilinmiyor'), findsOneWidget);
    for (final p in platformProviderOrder) {
      expect(t.widget<TextButton>(find.byKey(ValueKey('platform-quick-toggle-$p'))).onPressed, isNull);
    }
    await t.tap(find.byKey(const ValueKey('platform-quick-open')));
    expect(opened, 1);
    await t.pumpWidget(app(PlatformQuickCard(source: OwnerPlatformSource(windows(asked)), offline: true, onOpen: () {})));
    await t.pumpAndSettle();
    expect(t.widget<TextButton>(find.byKey(const ValueKey('platform-quick-toggle-trendyol_go'))).onPressed, isNull);
  });
}
