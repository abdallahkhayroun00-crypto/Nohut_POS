import 'dart:io';
import 'package:flutter/services.dart';

Future<void> playOrderAlert() async {
  try {
    if (Platform.isWindows) {
      final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      await Process.run(
        '$root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          '[System.Media.SystemSounds]::Exclamation.Play(); Start-Sleep -Milliseconds 500',
        ],
      );
    } else {
      await SystemSound.play(SystemSoundType.alert);
    }
  } catch (_) {
    /* The visible notification remains if audio is unavailable. */
  }
}
