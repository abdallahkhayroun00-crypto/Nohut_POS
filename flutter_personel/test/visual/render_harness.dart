// Renders real widgets to PNG with the bundled fonts, for visual review.
// Writes files only when NOHUT_RENDER_DIR is set; otherwise it is a smoke
// test that the screens build and lay out without overflow.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> loadNohutFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      loader.addFont(File(f).readAsBytes().then((b) => ByteData.view(b.buffer)));
    }
    await loader.load();
  }
  await family('Barlow', ['assets/Barlow-Regular.ttf', 'assets/Barlow-SemiBold.ttf', 'assets/Barlow-Bold.ttf']);
  await family('Bree', ['assets/BreeSerif-Regular.ttf']);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter';
  final icons = '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
  if (File(icons).existsSync()) await family('MaterialIcons', [icons]);
}

/// Pumps [child] at a phone size and, if requested, saves a PNG.
Future<void> renderScreen(WidgetTester t, String name, Widget child,
    {Size size = const Size(412, 915), double ratio = 2, Brightness brightness = Brightness.light}) async {
  // Real shadows while rendering; restored before the test ends, because
  // newer SDKs check painting debug flags before tear-downs run.
  final shadows = debugDisableShadows;
  debugDisableShadows = false;
  try {
    await _render(t, name, child, size: size, ratio: ratio, brightness: brightness);
  } finally {
    debugDisableShadows = shadows;
  }
}

Future<void> _render(WidgetTester t, String name, Widget child,
    {required Size size, required double ratio, required Brightness brightness}) async {
  t.view.physicalSize = size * ratio;
  t.view.devicePixelRatio = ratio;
  t.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
  final key = GlobalKey();
  await t.pumpWidget(RepaintBoundary(key: key, child: child));
  await t.pumpAndSettle();
  final dir = Platform.environment['NOHUT_RENDER_DIR'];
  if (dir == null) return;
  await t.runAsync(() async {
    // Let images (logo) decode.
    for (final e in find.byType(Image).evaluate()) {
      final img = e.widget as Image;
      await precacheImage(img.image, e);
    }
  });
  await t.pumpAndSettle();
  await t.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: ratio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}
