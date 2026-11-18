import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as paths;

/// Short notification reserved for orders submitted by local staff devices.
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
    // Visual staff notification remains.
  }
}

/// Original, synthesized ten-second restaurant sounds.
/// Does not play copyrighted sounds extracted from partner apps.
class OnlineOrderSoundPlayer {
  Process? _running;
  int _generation = 0;

  void stop() {
    _generation++;
    _running?.kill();
    _running = null;
  }

  Future<void> play(String platform, int urgency) async {
    stop(); // Never overlap sounds when several online orders arrive.
    final generation = _generation;
    if (!Platform.isWindows) {
      // Non-Windows preview: OS sound, while production POS runs on Windows.
      await SystemSound.play(SystemSoundType.alert);
      return;
    }
    final slug = switch (platform) {
      'Yemeksepeti' => 'yemeksepeti',
      'Migros Yemek' => 'migros',
      _ => 'trendyol',
    };
    final level = urgency.clamp(0, 2);
    final root = Platform.environment['TEMP'] ?? Directory.systemTemp.path;
    final dir = Directory(paths.join(root, 'NohutFalafel', 'alarm-tones'));
    await dir.create(recursive: true);
    final wav = File(paths.join(dir.path, '$slug-$level.wav'));
    if (!await wav.exists()) {
      await wav.writeAsBytes(_generateWav(slug, level), flush: true);
    }
    if (generation != _generation) return;
    final powershell = paths.join(
      Platform.environment['SystemRoot'] ?? r'C:\Windows',
      'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe',
    );
    final escaped = wav.path.replaceAll("'", "''");
    final script =
        "[System.Media.SoundPlayer]::new('$escaped').PlaySync()";
    final process = await Process.start(
      powershell,
      ['-NoProfile', '-NonInteractive', '-Command', script],
    );
    if (generation != _generation) {
      process.kill();
      return;
    }
    _running = process;
    await process.exitCode;
    if (_running == process) _running = null;
  }

  /// WAV PCM 16-bit mono, 10 seconds. Escalation changes pitch/cadence.
  Uint8List _generateWav(String platform, int urgency) {
    const sampleRate = 12000;
    const seconds = 10;
    final samples = sampleRate * seconds;
    final data = ByteData(44 + samples * 2);
    void ascii(int offset, String text) {
      for (var i = 0; i < text.length; i++) {
        data.setUint8(offset + i, text.codeUnitAt(i));
      }
    }
    ascii(0, 'RIFF');
    data.setUint32(4, 36 + samples * 2, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, sampleRate, Endian.little);
    data.setUint32(28, sampleRate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, samples * 2, Endian.little);
    final notes = switch (platform) {
      'yemeksepeti' => <double>[523.25, 659.25, 523.25, 784.0],
      'migros' => <double>[440.0, 554.37, 698.46],
      _ => <double>[659.25, 880.0, 659.25],
    };
    final beat = urgency == 2 ? 0.28 : urgency == 1 ? 0.42 : 0.64;
    for (var i = 0; i < samples; i++) {
      final t = i / sampleRate;
      final slot = (t / beat).floor();
      final phase = (t / beat) - slot;
      final envelope = phase < 0.72
          ? (math.min(phase * 20, 1.0) * math.min((0.72 - phase) * 18, 1.0))
          : 0.0;
      final pitch = notes[slot % notes.length] * (urgency == 2 ? 1.17 : 1.0);
      final wave = math.sin(2 * math.pi * pitch * t) +
          0.20 * math.sin(2 * math.pi * pitch * 2 * t);
      final sample = (wave * envelope * 12500).round().clamp(-32767, 32767);
      data.setInt16(44 + i * 2, sample, Endian.little);
    }
    return data.buffer.asUint8List();
  }
}
