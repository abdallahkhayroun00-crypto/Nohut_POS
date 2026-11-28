// Ayarlar › Bulut & Senkronizasyon: the four gated steps against the
// in-memory agent server, with an optional render (NOHUT_RENDER_DIR).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/backup_container.dart';
import 'package:nohut_falafel_desktop/backup_service.dart';
import 'package:nohut_falafel_desktop/brand.dart';
import 'package:nohut_falafel_desktop/first_sync_ui.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:sqlite3/sqlite3.dart';

import 'initial_sync_test.dart' show FakeAgentServer;
import 'support/synthetic_pos.dart';

final boundary = GlobalKey();

Future<void> shot(WidgetTester t, String name) async {
  final dir = Platform.environment['NOHUT_RENDER_DIR'];
  if (dir == null) return;
  await t.runAsync(() async {
    final image = await (boundary.currentContext!.findRenderObject() as RenderRepaintBoundary)
        .toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  late Directory dir;
  late PosStore store;
  late Database db;
  late FakeAgentServer server;
  var backups = 0;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nohut-first-sync-ui');
    store = PosStore(databaseFile: '${dir.path}/db');
    store.replace(buildSyntheticState(30), store.read().revision);
    db = sqlite3.open('${dir.path}/db');
    server = FakeAgentServer();
    backups = 0;
  });
  tearDown(() {
    db.dispose();
    store.dispose();
    dir.deleteSync(recursive: true);
  });

  FirstSyncController controller({bool connected = true}) => FirstSyncController(
    db: db, store: store,
    backup: () async {
      backups++;
      final rev = store.read().revision;
      return BackupRunResult(ok: true, message: 'ok', manifest: BackupManifest(
        backupId: 'synthetic-$backups', createdAt: '2026-11-28T09:00:00Z', revision: rev,
        appVersion: 'test', tableCounts: const {}, orderCount: 0, bytesUncompressed: 1,
        sha256Uncompressed: '0' * 64));
    },
    transport: () async => connected ? server : null,
  );

  Future<void> mount(WidgetTester t, FirstSyncController c) async {
    t.view.physicalSize = const Size(900, 1300);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    if (Platform.environment['NOHUT_RENDER_DIR'] != null) {
      await t.runAsync(() async {
        final body = FontLoader(NohutBrand.bodyFont)
          ..addFont(rootBundle.load('assets/brand/fonts/Barlow-Regular.ttf'))
          ..addFont(rootBundle.load('assets/brand/fonts/Barlow-Bold.ttf'));
        final icons = FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await Future.wait([body.load(), icons.load()]);
      });
    }
    await t.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: NohutBrand.theme(),
      home: RepaintBoundary(key: boundary, child: Scaffold(body: SingleChildScrollView(
        padding: const EdgeInsets.all(24), child: FirstSyncPanel(controller: c))))));
    await t.pumpAndSettle();
  }

  testWidgets('prepare → freeze → backup + send → active; nothing sent before Başlat', (t) async {
    final c = controller();
    await mount(t, c);
    expect(c.connected, isTrue);
    await shot(t, 'first-sync-1-connected');

    await t.tap(find.byKey(const ValueKey('first-sync-prepare')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('first-sync-cat-typed_order')), findsOneWidget);
    expect(find.byKey(const ValueKey('first-sync-rejected')), findsOneWidget,
        reason: 'synthetic TGO rows lack provider ids and are listed');
    await shot(t, 'first-sync-2-prepared');

    await t.tap(find.byKey(const ValueKey('first-sync-freeze')));
    await t.pumpAndSettle();
    expect(c.planOpen, isTrue);
    expect(server.calls.where((x) => x != 'status'), isEmpty);
    expect(backups, 0);
    await shot(t, 'first-sync-3-frozen');

    await t.tap(find.byKey(const ValueKey('first-sync-start')));
    await t.pumpAndSettle();
    expect(backups, 1);
    expect(c.active, isTrue, reason: c.message);
    expect(server.migrations.values.single['status'], 'active');
    expect(find.byKey(const ValueKey('first-sync-message')), findsOneWidget);
    expect(c.message, contains('tamamlandı'));
    await shot(t, 'first-sync-4-active');
  });

  testWidgets('not enrolled: honest message, no send button path', (t) async {
    final c = controller(connected: false);
    await mount(t, c);
    expect(find.textContaining('kayıtlı değil'), findsWidgets);
    await t.tap(find.byKey(const ValueKey('first-sync-prepare')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('first-sync-freeze')));
    await t.pumpAndSettle();
    final start = t.widget<FilledButton>(find.byKey(const ValueKey('first-sync-start')));
    expect(start.onPressed, isNull);
    expect(server.calls, isEmpty);
    await t.tap(find.byKey(const ValueKey('first-sync-cancel')));
    await t.pumpAndSettle();
    expect(c.planOpen, isTrue, reason: 'cannot cancel in the cloud while offline; kept for resume');
  });
}
