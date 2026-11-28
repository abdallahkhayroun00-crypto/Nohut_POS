import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Writes each `takeScreenshot` from the on-device test next to the APK
/// screenshots (CI emulator evidence only).
Future<void> main() => integrationDriver(
  onScreenshot: (name, bytes, [args]) async {
    final dir = Directory(Platform.environment['NOHUT_SHOTS'] ?? 'build/emulator/screens')
      ..createSync(recursive: true);
    File('${dir.path}/flutter-$name.png').writeAsBytesSync(bytes);
    return true;
  },
);
