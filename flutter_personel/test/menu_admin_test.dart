// Menü Yönetimi (Android): grants decide the controls, edits carry the
// draft stamp, a stale draft reloads; with menu.qr.publish the phone reviews,
// confirms and asks Windows to publish (owner decision 2026-11-27).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_personel/menu_admin_page.dart';
import 'package:nohut_personel/pos_api.dart';
import 'package:nohut_personel/style.dart';

import 'visual/render_harness.dart';

Json catalog() => {
      'categories': [
        {'id': 'durum', 'name': {'tr': 'Dürümler', 'en': 'Wraps', 'ar': 'لفائف'}, 'active': true, 'order': 0},
        {'id': 'meze', 'name': {'tr': 'Mezeler', 'en': 'Meze', 'ar': 'مقبلات'}, 'active': true, 'order': 1},
      ],
      'products': [
        {'id': 1, 'category': 'durum', 'name': {'tr': 'Falafel Dürüm', 'en': 'Falafel Wrap', 'ar': 'لفافة فلافل'},
          'price': 140, 'available': true, 'active': true},
        {'id': 2, 'category': 'meze', 'name': {'tr': 'Humus', 'en': 'Hummus', 'ar': 'حمص'},
          'price': 90.5, 'available': false, 'active': true},
      ],
      'campaigns': [
        {'id': 'ogle', 'title': {'tr': 'Öğle Menüsü', 'en': 'Lunch', 'ar': 'غداء'}, 'price': 199, 'active': true},
      ],
    };

/// Stand-in for `/api/menu/*` with the server's rules (grants, stamp).
class FakeMenuApi extends NohutApi {
  FakeMenuApi(this.grants);
  final Set<String> grants;
  Json draft = jsonDecode(jsonEncode(catalog())) as Json;
  int version = 1;
  bool reachable = true, pending = false;
  String link = 'ready';
  int publishes = 0, syncs = 0;
  final writes = <Json>[];
  String get stamp => 'stamp-$version';

  @override
  Future<(int, Json)> menu(String method, String path, {Json? body}) async {
    if (!reachable) throw Exception('socket');
    if (method == 'GET') {
      return (200, <String, dynamic>{
        'available': true, 'stamp': stamp, 'revision': 'abc1234ffff', 'revisionLabel': 'abc1234',
        'offline': false, 'pendingPublish': pending, 'publish': 'here', 'link': link,
        'can': {for (final op in ['menu.product.edit', 'menu.price.edit', 'menu.category.edit',
          'menu.campaign.edit', 'menu.stock.toggle', 'menu.qr.publish']) op: grants.contains(op)},
        'changes': [if (version > 1) {'list': 'products', 'id': 1, 'label': 'Falafel Dürüm', 'detail': 'değişti'}],
        'catalog': jsonDecode(jsonEncode(draft)),
      });
    }
    writes.add({...body!, 'path': path});
    if (path == 'sync') {
      syncs++;
      return (200, <String, dynamic>{'ok': true});
    }
    if (path == 'reconcile') {
      pending = false;
      return (200, <String, dynamic>{'ok': true, 'outcome': 'confirmed', 'message': 'Önceki yayın doğrulandı.'});
    }
    if (pending) return (409, <String, dynamic>{'error': 'conflict', 'message': 'Önceki yayının sonucu henüz doğrulanmadı.'});
    if (body['expectedStamp'] != stamp) return (409, <String, dynamic>{'error': 'conflict', 'message': 'Menü başka bir cihazda değişti.'});
    if (path == 'publish') {
      if (!grants.contains('menu.qr.publish')) return (403, <String, dynamic>{'error': 'forbidden'});
      publishes++;
      version = 1; // published: draft equals the base again
      return (200, <String, dynamic>{'ok': true, 'outcome': 'published', 'revision': 'def5678ffff', 'revisionLabel': 'def5678'});
    }
    final p = (draft['products'] as List).cast<Map>().firstWhere((p) => p['id'] == (body['id'] ?? 1), orElse: () => {});
    if (path == 'image') p['image'] = 'assets/products/upload.webp';
    switch (body['action']) {
      case 'set_stock':
        if (!grants.contains('menu.stock.toggle')) return (403, <String, dynamic>{'error': 'forbidden'});
        p['available'] = body['available'];
      case 'set_price':
        if (!grants.contains('menu.price.edit')) return (403, <String, dynamic>{'error': 'forbidden'});
        p['price'] = (body['priceCents'] as int) / 100;
      case 'set_visible':
        p['active'] = body['active'];
      case 'save_product':
        if (body['id'] == null) {
          (draft['products'] as List).add({'id': 3, 'category': body['category'], 'name': body['name'],
            'price': (body['priceCents'] as int) / 100, 'available': true, 'active': true});
        }
    }
    version++;
    return (200, <String, dynamic>{'ok': true, 'stamp': stamp});
  }
}

Widget app(NohutApi api, {ThemeMode mode = ThemeMode.light, MenuPhotoPicker? photo}) => MaterialApp(
    debugShowCheckedModeBanner: false, theme: NohutStyle.theme, darkTheme: NohutStyle.darkTheme, themeMode: mode,
    home: Scaffold(appBar: AppBar(title: const Text('Menü Yönetimi')),
      body: MenuAdminPage(api: api, imageBase: null, pickPhoto: photo ?? () async => null)));

const allMenu = {'menu.product.edit', 'menu.price.edit', 'menu.category.edit', 'menu.campaign.edit',
  'menu.stock.toggle', 'menu.qr.publish'};

void main() {
  setUpAll(loadNohutFonts);

  testWidgets('narrowed by the owner to stock only: toggles stock, no price, visibility or publish', (t) async {
    final api = FakeMenuApi({'menu.stock.toggle'});
    await t.pumpWidget(app(api));
    await t.pumpAndSettle();
    expect(find.text('Yayındakiyle aynı'), findsOneWidget);
    expect(find.text('Dürümler · 140,00 ₺'), findsOneWidget);
    expect(find.text('Mezeler · 90,50 ₺'), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-new-product')), findsNothing);
    expect(t.widget<IconButton>(find.byKey(const ValueKey('menu-visible-1'))).onPressed, isNull);
    expect(t.widget<ListTile>(find.byKey(const ValueKey('menu-product-1'))).onTap, isNull);
    await t.tap(find.byKey(const ValueKey('menu-stock-1')));
    await t.pumpAndSettle();
    expect(api.writes.single['action'], 'set_stock');
    expect(api.writes.single['expectedStamp'], 'stamp-1');
    expect(api.writes.single['requestId'], startsWith('menu-'));
    expect(find.text('1 değişiklik yayın bekliyor'), findsOneWidget);
    expect(t.widget<FilledButton>(find.byKey(const ValueKey('menu-publish'))).onPressed, isNull,
        reason: 'no menu.qr.publish grant');
  });

  for (final role in ['Personel', 'Yönetici']) {
    testWidgets('$role (default grants): review, confirm, publish; photo; POS sync; verify a lost answer', (t) async {
      final api = FakeMenuApi({...allMenu});
      await t.pumpWidget(app(api, photo: () async => ('image/jpeg', [1, 2, 3])));
      await t.pumpAndSettle();
      expect(t.widget<FilledButton>(find.byKey(const ValueKey('menu-publish'))).onPressed, isNull, reason: 'nothing to publish');
      await t.tap(find.byKey(const ValueKey('menu-stock-1')));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 6));
      await t.pumpAndSettle();
      // Photo through Windows.
      await t.tap(find.byKey(const ValueKey('menu-product-1')));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(find.byKey(const ValueKey('menu-photo')), 200,
          scrollable: find.byType(Scrollable).last);
      await t.tap(find.byKey(const ValueKey('menu-photo')));
      await t.pumpAndSettle();
      expect(api.writes.last['path'], 'image');
      expect(api.writes.last['mime'], 'image/jpeg');
      expect(api.writes.last['base64'], 'AQID');
      expect(api.writes.last['expectedStamp'], 'stamp-2');
      await t.pump(const Duration(seconds: 6));
      await t.pumpAndSettle();
      // Publish: review sheet, cancel publishes nothing; confirm publishes the reviewed stamp.
      await t.tap(find.byKey(const ValueKey('menu-publish')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('menu-publish-sheet')), findsOneWidget);
      expect(find.textContaining('yayındaki sürüm abc1234'), findsOneWidget);
      await t.tapAt(const Offset(10, 10));
      await t.pumpAndSettle();
      expect(api.publishes, 0);
      await t.tap(find.byKey(const ValueKey('menu-publish')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('menu-publish-confirm')));
      await t.pumpAndSettle();
      expect(api.publishes, 1);
      expect(api.writes.last['expectedStamp'], 'stamp-3');
      expect(find.textContaining('QR menü yayınlandı (sürüm def5678)'), findsOneWidget);
      expect(find.text('Yayındakiyle aynı'), findsOneWidget);
      await t.pump(const Duration(seconds: 6));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('menu-sync')));
      await t.pumpAndSettle();
      expect(api.syncs, 1);
      // An unanswered publish: edits and publish are frozen until verified.
      api.pending = true;
      await t.pump(const Duration(seconds: 6));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('menu-stock-2')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('menu-publish')), findsNothing);
      await t.tap(find.byKey(const ValueKey('menu-reconcile')));
      await t.pumpAndSettle();
      expect(find.textContaining('doğrulandı'), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-publish')), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('Windows publishing chain down: says why and publish stays disabled', (t) async {
    final api = FakeMenuApi({...allMenu})..version = 2..link = 'service_down';
    await t.pumpWidget(app(api));
    await t.pumpAndSettle();
    expect(find.textContaining('yayınlama hizmeti çalışmıyor'), findsOneWidget);
    expect(t.widget<FilledButton>(find.byKey(const ValueKey('menu-publish'))).onPressed, isNull);
  });

  testWidgets('owner/manager: price via the edit screen, new product, stale draft reloads', (t) async {
    final api = FakeMenuApi({...allMenu});
    await t.pumpWidget(app(api));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('menu-product-1')));
    await t.pumpAndSettle();
    expect(find.text('140,00'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('menu-price')), '150,5');
    await t.tap(find.byKey(const ValueKey('menu-save')));
    await t.pumpAndSettle();
    expect(api.writes.last['action'], 'save_product');
    expect(api.writes.last['priceCents'], 15050);
    // Another device changed the draft: the phone's next write is refused and it reloads.
    api.version += 5;
    await t.pump(const Duration(seconds: 6)); // let the snackbar leave
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('menu-stock-2')));
    await t.pumpAndSettle();
    expect(find.textContaining('Güncel hali yüklendi'), findsOneWidget);
    await t.pump(const Duration(seconds: 6));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('menu-stock-2')));
    await t.pumpAndSettle();
    expect(api.writes.last['expectedStamp'], 'stamp-${api.version - 1}');
    expect((api.draft['products'] as List)[1]['available'], true);
    // New product needs all three names.
    await t.tap(find.byKey(const ValueKey('menu-new-product')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('menu-name-tr')), 'Mercimek Çorbası');
    await t.enterText(find.byKey(const ValueKey('menu-price')), '85');
    await t.tap(find.byKey(const ValueKey('menu-save')));
    await t.pumpAndSettle();
    expect(find.text('TR / EN / AR ürün adları gerekli.'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('menu-name-en')), 'Lentil Soup');
    await t.enterText(find.byKey(const ValueKey('menu-name-ar')), 'شوربة عدس');
    await t.tap(find.byKey(const ValueKey('menu-save')));
    await t.pumpAndSettle();
    expect(api.writes.last['name'], {'tr': 'Mercimek Çorbası', 'en': 'Lentil Soup', 'ar': 'شوربة عدس'});
    expect(api.writes.last.containsKey('id'), false);
    await t.scrollUntilVisible(find.text('Mercimek Çorbası'), 200,
        scrollable: find.descendant(of: find.byKey(const ValueKey('menu-admin')), matching: find.byType(Scrollable)).first);
    await t.drag(find.byKey(const ValueKey('menu-admin')), const Offset(0, 2000));
    await t.pumpAndSettle();
    // Tabs, preview, changes.
    await t.tap(find.text('Kampanya · 1'));
    await t.pumpAndSettle();
    expect(find.text('199,00 ₺'), findsOneWidget);
    await t.tap(find.text('Kategori · 2'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('menu-categories-meze')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('menu-preview')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('menu-preview-sheet')), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('away from the restaurant: says the LAN is needed and remote access is not ready', (t) async {
    final api = FakeMenuApi({})..reachable = false;
    await t.pumpWidget(app(api));
    await t.pumpAndSettle();
    expect(find.textContaining('uzaktan (bulut) erişim henüz hazır değil'), findsOneWidget);
  });

  for (final mode in [Brightness.light, Brightness.dark]) {
    final m = mode == Brightness.light ? 'light' : 'dark';
    testWidgets('render menu admin $m', (t) async {
      final api = FakeMenuApi({...allMenu})..version = 2;
      await renderScreen(t, 'menu-admin-$m', app(api, mode: mode == Brightness.light ? ThemeMode.light : ThemeMode.dark),
          brightness: mode);
      await renderScreen(t, 'menu-admin-compact-$m', app(api, mode: mode == Brightness.light ? ThemeMode.light : ThemeMode.dark),
          brightness: mode, size: const Size(360, 740));
      expect(t.takeException(), isNull);
    });
  }
}
