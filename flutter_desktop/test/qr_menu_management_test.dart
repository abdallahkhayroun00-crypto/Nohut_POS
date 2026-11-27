// QR Menü Yönetimi against a fake publisher: disconnected and reconnect,
// zero-change restore, stale revision (merge and conflict), refused publish,
// lost answer before and after the write, and a restart in between.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/brand.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/qr_menu_management.dart';
import 'package:nohut_falafel_desktop/qr_menu_sync.dart';
import 'package:nohut_falafel_desktop/qr_publisher_client.dart';
import 'package:nohut_falafel_desktop/qr_publisher_service.dart';
import 'qr_publisher_service_test.dart' as svc;

Json github() => {
      'schemaVersion': 1,
      'currency': 'TRY',
      'categories': [
        {'id': 'durum', 'name': {'tr': 'Dürümler', 'en': 'Wraps', 'ar': 'لفائف'}, 'order': 0, 'active': true},
        {'id': 'meze', 'name': {'tr': 'Mezeler', 'en': 'Meze', 'ar': 'مقبلات'}, 'order': 1, 'active': true},
      ],
      'products': [
        {'id': 1, 'legacyKey': 'Falafel Dürüm', 'category': 'durum', 'name': {'tr': 'Falafel Dürüm', 'en': 'Falafel Wrap', 'ar': 'لفافة فلافل'},
          'price': 140, 'available': true, 'active': true, 'order': 0},
        {'id': 2, 'legacyKey': 'Humus', 'category': 'meze', 'name': {'tr': 'Humus', 'en': 'Hummus', 'ar': 'حمص'},
          'price': 90, 'available': true, 'active': true, 'order': 1},
        {'id': 3, 'legacyKey': 'Ayran', 'category': 'meze', 'name': {'tr': 'Ayran', 'en': 'Ayran', 'ar': 'عيران'},
          'price': 1250.5, 'available': false, 'active': true, 'order': 2},
      ],
      'campaigns': [
        {'id': 'ogle', 'active': true, 'price': 199, 'title': {'tr': 'Öğle Menüsü', 'en': 'Lunch', 'ar': 'غداء'}, 'items': []},
      ],
    };

class FakePublisher extends QrPublisherClient {
  FakePublisher() : super('/nonexistent/db.sqlite3', testToken: 'x' * 40);
  bool token = true, up = true;
  String revision = 'sha-1';
  Json remote = github();
  String? failNext; // lost | lostAfterWrite
  int publishes = 0;
  @override
  Future<bool> hasToken() async => token;
  @override
  Future<bool> health(String endpoint) async => up;
  @override
  Future<Map<String, dynamic>> catalog(String endpoint) async {
    if (!up) throw const QrPublisherNoAnswer('down');
    return {'revision': revision, 'catalog': copyJson(remote)};
  }

  @override
  Future<Map<String, dynamic>> publish(String endpoint, String revision, Json menu) async {
    publishes++;
    final mode = failNext;
    failNext = null;
    if (mode == 'lost') throw const QrPublisherNoAnswer('Yayınlama isteği zaman aşımına uğradı.');
    if (revision != this.revision) {
      throw const QrPublisherRefused('Web menüsü değişti. Güncel sürümü yeniden alın.', 409);
    }
    remote = copyJson(menu);
    this.revision = 'sha-p$publishes';
    if (mode == 'lostAfterWrite') throw const QrPublisherNoAnswer('Yayınlama hizmeti bağlantıyı kesti.');
    return {'published': true, 'revision': this.revision, 'commit': 'c0ffee1234567'};
  }
}

class Host extends StatefulWidget {
  const Host({super.key, required this.initial, required this.store, required this.publisher,
    this.supervisor,this.sync});
  final Json initial;
  final PosStore store;
  final FakePublisher publisher;
  final QrPublisherSupervisor? supervisor;
  final QrMenuAutoSync? sync;
  @override
  State<Host> createState() => HostState();
}

class HostState extends State<Host> {
  late Json data = copyJson(widget.initial);
  bool edit(void Function(Json) change) {
    final next = copyJson(data);
    change(next);
    PosStore.validate(next);
    setState(() => data = next);
    return true;
  }

  @override
  Widget build(BuildContext context) => QrMenuManagement(
        state: data,
        edit: edit,
        store: widget.store,
        publisher: widget.publisher,
        readPublicMenu: () async => github()..['source'] = 'public-website',
        networkImages: false,
        supervisor: widget.supervisor,
        sync: widget.sync,
        now: () => DateTime.utc(2026, 11, 27, 19, 55),
      );
}

late PosStore store;
var fontsLoaded = false;
final boundary = GlobalKey();

Future<GlobalKey<HostState>> mount(WidgetTester t, FakePublisher f,
    {Json? state, Size size = const Size(1536, 864), Brightness brightness = Brightness.light,
    QrPublisherSupervisor? supervisor,QrMenuAutoSync? sync}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
  if (Platform.environment['NOHUT_RENDER_DIR'] != null && !fontsLoaded) {
    fontsLoaded = true;
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
  final key = GlobalKey<HostState>();
  final light = NohutBrand.theme();
  await t.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: brightness == Brightness.light
        ? light
        : ThemeData(colorSchemeSeed: NohutBrand.green, brightness: Brightness.dark, fontFamily: NohutBrand.bodyFont),
    home: RepaintBoundary(
      key: boundary,
      child: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 22),
          child: Host(key: key, initial: {...emptyPosState(), ...?state}, store: store, publisher: f,
            supervisor: supervisor,sync:sync),
        ),
      ),
    ),
  ));
  await t.pumpAndSettle();
  return key;
}

String text(WidgetTester t, String key) =>
    t.widget<Text>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)).last).data!;
String state(WidgetTester t) => t.widget<Text>(find.byKey(const ValueKey('qr-state'))).data!;
String primary(WidgetTester t) => t
    .widget<Text>(find.descendant(of: find.byKey(const ValueKey('qr-primary')), matching: find.byType(Text)))
    .data!;
bool primaryEnabled(WidgetTester t) =>
    t.widget<ButtonStyleButton>(find.byKey(const ValueKey('qr-primary'))).onPressed != null;

Future<void> tapKey(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

Future<void> setPrice(WidgetTester t, int id, String value) async {
  await tapKey(t, 'qr-price-$id');
  await t.enterText(find.byKey(const ValueKey('qr-price-field')), value);
  await t.tap(find.text('Fiyatı Kaydet'));
  await t.pumpAndSettle();
}

Future<void> publishNow(WidgetTester t) async {
  expect(primary(t), 'Gözden Geçir ve Yayınla');
  await tapKey(t, 'qr-primary');
  expect(find.byKey(const ValueKey('qr-publish-review')), findsOneWidget);
  await tapKey(t, 'qr-confirm-publish');
}

Future<void> shot(WidgetTester t, String name) async {
  final dir = Platform.environment['NOHUT_RENDER_DIR'];
  if (dir == null) return;
  await t.runAsync(() async {
    final image = await (boundary.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('nohut-qr-');
    store = PosStore(databaseFile: '${dir.path}/pos.sqlite3');
  });
  tearDown(() {
    store.dispose();
    dir.deleteSync(recursive: true);
  });

  testWidgets('QR workspace owns POS sync settings and disabled manual sync', (t) async {
    final sync=QrMenuAutoSync(store);
    addTearDown(sync.dispose);
    final host=await mount(t,FakePublisher(),sync:sync);
    expect(text(t,'qr-fact-sync'),'İlk kontrol bekleniyor');
    expect(text(t,'qr-fact-sync-time'),'—');
    await tapKey(t,'qr-more');
    await t.tap(find.text('Eşitleme Ayarları'));
    await t.pumpAndSettle();
    expect(find.text('QR Menü otomatik eşitleme'),findsOneWidget);
    expect(find.text('Yalnızca POS · Yerel fiyatlar'),findsNothing);
    await t.tap(find.byType(SwitchListTile));
    await t.pumpAndSettle();
    expect(host.currentState!.data['settings']['qrAutoSync'],false);
    expect(find.text('Yalnızca POS · Yerel fiyatlar'),findsOneWidget);
    expect(t.widget<OutlinedButton>(find.ancestor(of:find.text('Şimdi Eşitle'),matching:find.byWidgetPredicate((w)=>w is OutlinedButton))).onPressed,isNull);
    await t.tap(find.text('Kapat'));
    await t.pumpAndSettle();
    expect(text(t,'qr-fact-sync'),'Kapalı');
    await tapKey(t,'qr-more');
    expect(t.widget<PopupMenuItem<String>>(find.widgetWithText(PopupMenuItem<String>,'Şimdi Eşitle')).enabled,false);
    await t.tapAt(const Offset(5,5));
    await t.pumpAndSettle();
    expect(t.takeException(),isNull);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('service down: public menu opens as an offline draft; reconnect follows GitHub', (t) async {
    final f = FakePublisher()..up = false;
    f.remote['products'][1]['price'] = 95; // GitHub is newer than the website
    final host = await mount(t, f);
    expect(state(t), 'Çevrimdışı taslak');
    expect(text(t, 'qr-fact-link'), 'Yayınlama hizmeti çalışmıyor');
    expect(text(t, 'qr-fact-changes'), 'Değişiklik yok');
    expect(text(t, 'qr-fact-revision'), 'Bilinmiyor');
    expect(primary(t), 'Yeniden Bağlan');
    expect(find.textContaining('127.0.0.1:18787'), findsOneWidget);
    expect(find.text('140,00 ₺'), findsOneWidget);
    expect(find.text('1.250,50 ₺'), findsOneWidget);
    expect(find.textContaining('₺140'), findsNothing);
    expect(host.currentState!.data['qrPublisherDraft'], isNull, reason: 'viewing never saves a draft');
    await shot(t, 'qr-offline-1536x864-light');
    f.up = true;
    await tapKey(t, 'qr-primary');
    expect(state(t), 'Yayındakiyle aynı');
    expect(text(t, 'qr-fact-link'), 'GitHub bağlı');
    expect(text(t, 'qr-fact-revision'), 'sha-1');
    expect(text(t, 'qr-fact-verified'), startsWith('Bugün'));
    expect(find.text('95,00 ₺'), findsOneWidget);
    expect(primary(t), 'GitHub’dan Yenile');
    expect(t.takeException(), isNull);
  });

  testWidgets('publisher stopped: compact card, one-click start, then connected', (t) async {
    final f = FakePublisher()..up = false;
    final machine = svc.ready();
    machine.onLaunch = (_) {
      f.up = true;
      machine.healthBody = {'service': 'Nohut QR Publisher', 'version': qrPublisherVersion};
    };
    final sup = QrPublisherSupervisor(endpoint: QrPublisherClient.defaultLocalEndpoint,
      client: f, host: machine, startTimeout: const Duration(milliseconds: 50));
    await mount(t, f, supervisor: sup);
    expect(state(t), 'Çevrimdışı taslak');
    expect(t.widget<Text>(find.byKey(const ValueKey('qr-repair-title'))).data, 'Yayınlama hizmeti durmuş');
    expect(find.text('Hizmeti Başlat'), findsOneWidget);
    expect(find.byKey(const ValueKey('qr-repair-log')), findsNothing, reason: 'details stay folded');
    expect(find.textContaining('start-windows.ps1'), findsNothing, reason: 'no PowerShell instructions');
    expect(t.widget<Text>(find.byKey(const ValueKey('qr-info'))).style?.color,
      isNot(Theme.of(t.element(find.byKey(const ValueKey('qr-info')))).colorScheme.error),
      reason: 'an offline draft is a state, not a red error');
    await tapKey(t, 'qr-repair-details');
    expect(find.text('GitHub App anahtarı'), findsOneWidget);
    expect(find.text('bulundu'), findsOneWidget);
    await shot(t, 'qr-publisher-stopped-1536x864');
    await tapKey(t, 'qr-repair-action');
    expect(machine.launches.single, contains('-NoPrompt'));
    expect(find.byKey(const ValueKey('qr-repair')), findsNothing);
    expect(state(t), 'Yayındakiyle aynı');
    expect(text(t, 'qr-fact-link'), 'GitHub bağlı');
  });

  testWidgets('missing key and missing Node each name their own fix', (t) async {
    final f = FakePublisher()..up = false;
    QrPublisherSupervisor sup(svc.FakeHost h) => QrPublisherSupervisor(
      endpoint: QrPublisherClient.defaultLocalEndpoint, client: f, host: h,
      startTimeout: const Duration(milliseconds: 50));
    await mount(t, f, supervisor: sup(svc.ready()..files.remove(svc.key)));
    expect(t.widget<Text>(find.byKey(const ValueKey('qr-repair-title'))).data, 'GitHub App anahtarı (.pem) bulunamadı');
    expect(find.text('Anahtar Dosyasını Seç'), findsOneWidget);
    await shot(t, 'qr-publisher-no-key-1100x720');
    await mount(t, f, supervisor: sup(svc.ready()..runs.remove(svc.node)));
    expect(t.widget<Text>(find.byKey(const ValueKey('qr-repair-title'))).data, 'Node.js 22 veya üstü bulunamadı');
    expect(find.text('Node.js İndirme Sayfası'), findsOneWidget);
    await mount(t, f, supervisor: sup(svc.ready()..portIsOpen = true));
    expect(t.widget<Text>(find.byKey(const ValueKey('qr-repair-title'))).data, 'Yayınlama portu başka bir programda');
    expect(find.byKey(const ValueKey('qr-repair-action')), findsNothing);
  });

  testWidgets('no key: says so and points to Ayarlar', (t) async {
    final f = FakePublisher()..token = false;
    await mount(t, f);
    expect(text(t, 'qr-fact-link'), 'Yayınlama anahtarı kayıtlı değil');
    expect(find.textContaining('Ayarlar > Entegrasyonlar'), findsOneWidget);
  });

  testWidgets('a restored draft equal to GitHub shows zero changes, not "unpublished"', (t) async {
    final f = FakePublisher();
    await mount(t, f, state: {
            'qrPublisherDraft': github(),
      'qrPublisherDraftRevision': 'sha-1',
      'qrPublisherDraftSourceSnapshot': github(),
    });
    expect(state(t), 'Yayındakiyle aynı');
    expect(text(t, 'qr-fact-changes'), 'Değişiklik yok');
    expect(find.textContaining('Yayımlanmamış'), findsNothing);
  });

  testWidgets('edit, review and publish: one primary action per state; draft survives restart', (t) async {
    final f = FakePublisher();
    var host = await mount(t, f);
    expect(state(t), 'Yayındakiyle aynı');
    await setPrice(t, 1, '150');
    await tapKey(t, 'qr-stock-2');
    await tapKey(t, 'qr-visible-3');
    expect(state(t), 'Yayın bekliyor');
    expect(text(t, 'qr-fact-changes'), '3 değişiklik');
    expect(find.text('150,00 ₺'), findsOneWidget);
    final saved = copyJson(host.currentState!.data);
    expect(saved['qrPublisherDraftRevision'], 'sha-1');
    await shot(t, 'qr-dirty-1536x864-light');
    // Restart: the same draft, the same truthful count.
    await t.pumpWidget(const SizedBox.shrink());
    host = await mount(t, f, state: saved);
    expect(state(t), 'Yayın bekliyor');
    expect(text(t, 'qr-fact-changes'), '3 değişiklik');
    await publishNow(t);
    expect(f.publishes, 1);
    expect(f.remote['products'][0]['price'], 150);
    expect(state(t), 'Yayındakiyle aynı');
    expect(text(t, 'qr-fact-revision'), 'sha-p1');
    expect(find.textContaining('commit c0ffee1'), findsOneWidget);
    expect(host.currentState!.data['qrPublisherDraft'], isNull);
    expect(host.currentState!.data['qrPublisherPendingPublish'], isNull);
    expect(t.takeException(), isNull);
  });

  testWidgets('stale revision: untouched fields follow GitHub; a field changed on both sides needs a choice', (t) async {
    final f = FakePublisher();
    final local = github();
    local['products'][0]['price'] = 160;
    f.revision = 'sha-2';
    f.remote['products'][1]['price'] = 99; // published elsewhere meanwhile
    await mount(t, f, state: {
            'qrPublisherDraft': local,
      'qrPublisherDraftRevision': 'sha-1',
      'qrPublisherDraftSourceSnapshot': github(),
    });
    expect(state(t), 'Yayın bekliyor');
    expect(text(t, 'qr-fact-changes'), '1 değişiklik');
    expect(find.text('99,00 ₺'), findsOneWidget, reason: 'old offline copy must not overwrite newer GitHub prices');
    expect(find.text('160,00 ₺'), findsOneWidget);
    expect(text(t, 'qr-fact-revision'), 'sha-2');

    // Conflict: GitHub also changed product 1.
    await t.pumpWidget(const SizedBox.shrink());
    f.revision = 'sha-3';
    f.remote['products'][0]['price'] = 155;
    final host = await mount(t, f, state: {
            'qrPublisherDraft': local,
      'qrPublisherDraftRevision': 'sha-1',
      'qrPublisherDraftSourceSnapshot': github(),
    });
    expect(state(t), 'Çakışma var');
    expect(primary(t), 'Çakışmaları Çöz (1)');
    expect(t.widget<TextButton>(find.byKey(const ValueKey('qr-price-1'))).onPressed, isNull,
        reason: 'no edits while a merge is open');
    await shot(t, 'qr-conflict-1536x864-light');
    await tapKey(t, 'qr-primary');
    expect(find.byKey(const ValueKey('qr-conflicts')), findsOneWidget);
    expect(find.text('Taslak: 160,00 ₺'), findsOneWidget);
    expect(find.text('GitHub: 155,00 ₺'), findsOneWidget);
    expect(t.widget<FilledButton>(find.byKey(const ValueKey('qr-apply-merge'))).onPressed, isNull);
    await t.tap(find.text('Taslak: 160,00 ₺'));
    await t.pumpAndSettle();
    await tapKey(t, 'qr-apply-merge');
    expect(state(t), 'Yayın bekliyor');
    expect(host.currentState!.data['qrPublisherDraftRevision'], 'sha-3');
    await publishNow(t);
    expect(f.remote['products'][0]['price'], 160);
    expect(f.remote['products'][1]['price'], 99);
  });

  testWidgets('refused because GitHub moved on: nothing written, rebased, then published', (t) async {
    final f = FakePublisher();
    await mount(t, f);
    await setPrice(t, 1, '150');
    f.revision = 'sha-other';
    f.remote['products'][2]['price'] = 30;
    await publishNow(t);
    expect(f.publishes, 1);
    expect(state(t), 'Yayın bekliyor');
    expect(find.text('150,00 ₺'), findsOneWidget);
    expect(find.text('30,00 ₺'), findsOneWidget);
    expect(text(t, 'qr-fact-revision'), 'sha-oth');
    await publishNow(t);
    expect(f.publishes, 2);
    expect(f.remote['products'][0]['price'], 150);
    expect(f.remote['products'][2]['price'], 30);
    expect(state(t), 'Yayındakiyle aynı');
  });

  testWidgets('lost answer, nothing written: blocked until verified, survives restart, then retry', (t) async {
    final f = FakePublisher();
    var host = await mount(t, f);
    await setPrice(t, 1, '150');
    f.failNext = 'lost';
    await publishNow(t);
    expect(state(t), 'Sonuç bilinmiyor');
    expect(primary(t), 'Sonucu Doğrula');
    expect(t.widget<TextButton>(find.byKey(const ValueKey('qr-price-1'))).onPressed, isNull);
    final saved = copyJson(host.currentState!.data);
    expect(saved['qrPublisherPendingPublish']['revision'], 'sha-1');
    await shot(t, 'qr-unknown-1536x864-light');
    // Restart while the publisher is down: still unknown, never "ready".
    await t.pumpWidget(const SizedBox.shrink());
    f.up = false;
    host = await mount(t, f, state: saved);
    expect(state(t), 'Sonuç bilinmiyor');
    expect(find.textContaining('doğrulanamıyor'), findsOneWidget);
    f.up = true;
    await tapKey(t, 'qr-primary');
    expect(state(t), 'Yayın bekliyor');
    expect(find.textContaining('ulaşmamış'), findsOneWidget);
    expect(host.currentState!.data['qrPublisherPendingPublish'], isNull);
    await publishNow(t);
    expect(f.publishes, 2);
    expect(state(t), 'Yayındakiyle aynı');
  });

  testWidgets('lost answer after GitHub wrote it: verify confirms, no second publish', (t) async {
    final f = FakePublisher();
    final host = await mount(t, f);
    await setPrice(t, 1, '150');
    f.failNext = 'lostAfterWrite';
    await publishNow(t);
    expect(state(t), 'Sonuç bilinmiyor');
    await tapKey(t, 'qr-primary');
    expect(state(t), 'Yayındakiyle aynı');
    expect(find.textContaining('doğrulandı'), findsOneWidget);
    expect(f.publishes, 1);
    expect(host.currentState!.data['qrPublisherDraft'], isNull);
  });

  testWidgets('every control: tabs, search, filter, drawer, preview, setup, discard; small window and dark', (t) async {
    final f = FakePublisher();
    final host = await mount(t, f, size: const Size(1100, 720));
    await t.enterText(find.byKey(const ValueKey('qr-search')), 'hum');
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('qr-row-1')), findsNothing);
    expect(find.byKey(const ValueKey('qr-row-2')), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('qr-search')), '');
    await t.pumpAndSettle();
    await tapKey(t, 'qr-filter');
    await t.tap(find.text('Dürümler').last);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('qr-row-2')), findsNothing);
    await tapKey(t, 'qr-filter');
    await t.tap(find.text('Tüm kategoriler').last);
    await t.pumpAndSettle();
    // Edit drawer from a row.
    await tapKey(t, 'qr-row-2');
    expect(find.byKey(const ValueKey('qr-product-drawer')), findsOneWidget);
    await t.enterText(find.widgetWithText(TextField, 'Fiyat · ₺'), '92,50');
    await tapKey(t, 'qr-product-save');
    expect(find.text('92,50 ₺'), findsOneWidget);
    // New product.
    await tapKey(t, 'qr-new-product');
    await t.enterText(find.widgetWithText(TextField, 'Ürün Adı · Türkçe'), 'Mercimek Çorbası');
    await t.enterText(find.widgetWithText(TextField, 'Fiyat · ₺'), '85');
    await t.tap(find.text('İsimler · TR/EN/AR'));
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, 'English · Product name'), 'Lentil Soup');
    await t.enterText(find.widgetWithText(TextField, 'العربية · اسم المنتج'), 'شوربة عدس');
    await tapKey(t, 'qr-product-save');
    expect(find.text('Mercimek Çorbası'), findsOneWidget);
    expect(text(t, 'qr-fact-changes'), '2 değişiklik');
    await shot(t, 'qr-dirty-1100x720-light');
    // Undo one product from its row menu.
    await tapKey(t, 'qr-row-more-2');
    await t.tap(find.text('Değişikliği Geri Al'));
    await t.pumpAndSettle();
    await t.tap(find.text('Geri Al').last);
    await t.pumpAndSettle();
    expect(find.text('90,00 ₺'), findsOneWidget);
    expect(text(t, 'qr-fact-changes'), '1 değişiklik');
    // Tabs.
    await t.tap(find.text('Kategoriler · 2'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('qr-category-meze')), findsOneWidget);
    await t.tap(find.text('Kampanyalar · 1'));
    await t.pumpAndSettle();
    expect(find.text('199,00 ₺ · Lunch'), findsOneWidget);
    await t.tap(find.text('Ürünler · 4'));
    await t.pumpAndSettle();
    // Preview is a stable header button; setup stays in the overflow menu.
    await tapKey(t, 'qr-preview-button');
    expect(find.byKey(const ValueKey('qr-preview')), findsOneWidget);
    expect(find.text('Mercimek Çorbası'), findsWidgets);
    await t.tap(find.text('Müşteri Görünümü'));
    await t.pumpAndSettle();
    await t.tap(find.text('Kapat'));
    await t.pumpAndSettle();
    await tapKey(t, 'qr-more');
    await t.tap(find.text('Yayınlama Kurulumu'));
    await t.pumpAndSettle();
    expect(find.textContaining('8787'), findsWidgets);
    await t.tap(find.text('Tamam'));
    await t.pumpAndSettle();
    // Discard returns to GitHub.
    await tapKey(t, 'qr-more');
    await t.tap(find.text('Taslağı At ve GitHub’dan Yükle'));
    await t.pumpAndSettle();
    await t.tap(find.text('Taslağı At').last);
    await t.pumpAndSettle();
    expect(state(t), 'Yayındakiyle aynı');
    expect(host.currentState!.data['qrPublisherDraft'], isNull);
    expect(f.publishes, 0);
    expect(t.takeException(), isNull);
  });

  testWidgets('dark theme and a narrow window render without overflow', (t) async {
    final f = FakePublisher();
    await mount(t, f, brightness: Brightness.dark);
    await setPrice(t, 1, '150');
    await shot(t, 'qr-dirty-1536x864-dark');
    await t.pumpWidget(const SizedBox.shrink());
    f.up = false;
    await mount(t, f, size: const Size(760, 900), brightness: Brightness.dark);
    expect(state(t), 'Çevrimdışı taslak');
    await shot(t, 'qr-offline-760x900-dark');
    expect(t.takeException(), isNull);
  });

  testWidgets('a phone edit of the shared draft shows up on Windows; the base stays saved for phones', (t) async {
    final f = FakePublisher();
    final host = await mount(t, f);
    expect(host.currentState!.data['qrPublisherDraftSourceSnapshot'], isNotNull);
    expect(host.currentState!.data['qrPublisherDraftRevision'], 'sha-1');
    final phone = github();
    phone['products'][1]['available'] = false;
    host.currentState!.edit((s) => s['qrPublisherDraft'] = phone);
    await t.pumpAndSettle();
    expect(state(t), 'Yayın bekliyor');
    expect(text(t, 'qr-fact-changes'), '1 değişiklik');
    expect(find.textContaining('Telefondan'), findsOneWidget);
    await publishNow(t);
    expect(f.remote['products'][1]['available'], false);
  });

  testWidgets('a phone publish shows up on Windows: pending first, then the new revision', (t) async {
    final f = FakePublisher();
    final host = await mount(t, f);
    final phone = github();
    phone['products'][1]['available'] = false;
    host.currentState!.edit((s) => s['qrPublisherDraft'] = phone);
    await t.pumpAndSettle();
    host.currentState!.edit((s) => s['qrPublisherPendingPublish'] = {'revision': 'sha-1', 'at': '2026-11-27T21:00:00Z', 'changes': 1});
    await t.pumpAndSettle();
    expect(find.textContaining('Bir telefondan yayın gönderildi'), findsOneWidget);
    host.currentState!.edit((s) {
      s['qrPublisherDraftSourceSnapshot'] = copyJson(phone);
      s['qrPublisherDraftRevision'] = 'sha-phone99';
      s.remove('qrPublisherDraft');
      s.remove('qrPublisherPendingPublish');
    });
    await t.pumpAndSettle();
    expect(find.textContaining('Telefondan yayınlandı: sha-pho'), findsOneWidget);
    expect(text(t, 'qr-fact-changes'), 'Değişiklik yok');
    expect(f.publishes, 0, reason: 'Windows does not publish again');
  });
}
