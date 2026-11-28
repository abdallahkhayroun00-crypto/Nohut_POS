import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as paths;

import 'qr_publisher_client.dart';

/// Version the bundled `QRPublisher/server.mjs` reports on /health. Bump both
/// together: a running publisher with another version is restarted.
const qrPublisherVersion = '2026.11.28';

/// Why the local QR publisher is (not) available, most specific first.
enum PublisherIssue {
  running,
  notWindows,
  remoteEndpoint,
  scriptMissing,
  nodeMissing,
  keyMissing,
  portBusy,
  outdated,
  stopped,
  startFailed,
}

/// The action that fixes an issue; null when the user cannot fix it here.
enum PublisherFix { start, restart, chooseKey, installNode }

class PublisherDiagnosis {
  const PublisherDiagnosis(this.issue, {
    this.endpoint = '',
    this.script,
    this.node,
    this.keyFound = false,
    this.runningVersion,
    this.lastStatus,
    this.logTail = const [],
  });
  final PublisherIssue issue;
  final String endpoint;
  final String? script, node, runningVersion;
  final bool keyFound;
  /// `status.json` written by start-windows.ps1 (state + message, no secrets).
  final Map<String, dynamic>? lastStatus;
  final List<String> logTail;

  bool get ok => issue == PublisherIssue.running;

  String get title => switch (issue) {
    PublisherIssue.running => 'Yayınlama hizmeti çalışıyor',
    PublisherIssue.notWindows => 'Yayınlama hizmeti yalnızca Windows’ta',
    PublisherIssue.remoteEndpoint => 'Uzak yayınlama adresi kullanılıyor',
    PublisherIssue.scriptMissing => 'Yayınlama hizmeti dosyaları eksik',
    PublisherIssue.nodeMissing => 'Node.js 22 veya üstü bulunamadı',
    PublisherIssue.keyMissing => 'GitHub App anahtarı (.pem) bulunamadı',
    PublisherIssue.portBusy => 'Yayınlama portu başka bir programda',
    PublisherIssue.outdated => 'Eski yayınlama hizmeti çalışıyor',
    PublisherIssue.stopped => 'Yayınlama hizmeti durmuş',
    PublisherIssue.startFailed => 'Yayınlama hizmeti başlatılamadı',
  };

  String get help => switch (issue) {
    PublisherIssue.running => 'Bu bilgisayar menüyü GitHub’a yayınlayabilir.',
    PublisherIssue.notWindows => 'Yayınlama yalnızca Windows POS üzerinden yapılır.',
    PublisherIssue.remoteEndpoint =>
      'Ayarlarda HTTPS bir adres kayıtlı; bu bilgisayar hizmeti başlatmaz.',
    PublisherIssue.scriptMissing =>
      'Bu kurulumda QRPublisher klasörü yok. Son Nohut Falafel POS kurulum '
      'paketini yeniden kurun; siparişler ve ayarlar korunur.',
    PublisherIssue.nodeMissing =>
      'Hizmet Node.js ile çalışır. Ücretsiz Node.js LTS (22 veya üstü) '
      'kurulduktan sonra Hizmeti Başlat’a basın.',
    PublisherIssue.keyMissing =>
      'GitHub App özel anahtarı bu bilgisayarda yok. Dosyayı bir kez seçin; '
      'yalnızca bu Windows kullanıcısının klasörüne kopyalanır.',
    PublisherIssue.portBusy =>
      'Bu adreste Nohut QR Publisher olmayan bir program yanıt veriyor. '
      'O programı kapatın veya Ayarlar’da başka bir yerel port seçin.',
    PublisherIssue.outdated =>
      'Çalışan hizmet bu POS sürümünden eski. Yeniden başlatın.',
    PublisherIssue.stopped =>
      'Gereken her şey yerinde ama hizmet çalışmıyor.',
    PublisherIssue.startFailed => _statusMessage ??
      'Hizmet birkaç saniye içinde yanıt vermedi. Teknik ayrıntılara bakın.',
  };

  String? get _statusMessage {
    final m = lastStatus?['message'];
    return m is String && m.trim().isNotEmpty ? m.trim() : null;
  }

  PublisherFix? get fix => switch (issue) {
    PublisherIssue.nodeMissing => PublisherFix.installNode,
    PublisherIssue.keyMissing => PublisherFix.chooseKey,
    PublisherIssue.outdated => PublisherFix.restart,
    PublisherIssue.stopped || PublisherIssue.startFailed => PublisherFix.start,
    _ => null,
  };

  String? get fixLabel => switch (fix) {
    PublisherFix.start => issue == PublisherIssue.startFailed
        ? 'Tekrar Dene' : 'Hizmeti Başlat',
    PublisherFix.restart => 'Yeniden Başlat',
    PublisherFix.chooseKey => 'Anahtar Dosyasını Seç',
    PublisherFix.installNode => 'Node.js İndirme Sayfası',
    null => null,
  };

  /// Facts for the expandable "Teknik ayrıntılar" (never a secret).
  List<(String, String)> get facts => [
    ('Adres', endpoint),
    ('Hizmet dosyası', script ?? 'bulunamadı'),
    ('Node.js', node ?? 'bulunamadı'),
    ('GitHub App anahtarı', keyFound ? 'bulundu' : 'bulunamadı'),
    if (runningVersion != null) ('Çalışan sürüm', runningVersion!),
    ('Beklenen sürüm', qrPublisherVersion),
    if (lastStatus?['state'] is String)
      ('Son başlatma', '${lastStatus!['state']}'
          '${lastStatus!['at'] is String ? ' · ${lastStatus!['at']}' : ''}'),
  ];
}

/// Everything the supervisor touches on the machine, injectable for tests.
class PublisherHost {
  const PublisherHost();
  bool get isWindows => Platform.isWindows;
  String get executableDir => paths.dirname(Platform.resolvedExecutable);
  Map<String, String> get env => Platform.environment;
  Future<bool> fileExists(String path) => File(path).exists();
  Future<List<String>> listFiles(String dir) async {
    final d = Directory(dir);
    if (!await d.exists()) return const [];
    return [
      await for (final e in d.list(followLinks: false))
        if (e is File) e.path,
    ];
  }
  Future<List<String>> listDirs(String dir) async {
    final d = Directory(dir);
    if (!await d.exists()) return const [];
    return [
      await for (final e in d.list(followLinks: false))
        if (e is Directory) e.path,
    ];
  }
  Future<String?> readText(String path) async {
    try {
      // Logs come from Windows console redirection: tolerate any encoding.
      return utf8.decode(await File(path).readAsBytes(), allowMalformed: true);
    } catch (_) {
      return null;
    }
  }
  Future<String?> run(String exe, List<String> args) async {
    try {
      final r = await Process.run(exe, args)
          .timeout(const Duration(seconds: 8));
      return r.exitCode == 0 ? '${r.stdout}' : null;
    } catch (_) {
      return null;
    }
  }
  /// The publisher's /health body, or null when nothing (or something else)
  /// answers.
  Future<Map<String, dynamic>?> health(Uri base) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.getUrl(base.resolve('health'))
          .timeout(const Duration(seconds: 4));
      req.followRedirects = false;
      final res = await req.close().timeout(const Duration(seconds: 4));
      final raw = await utf8.decoder.bind(res).join()
          .timeout(const Duration(seconds: 4));
      final body = jsonDecode(raw);
      return res.statusCode == 200 && body is Map &&
              body['service'] == 'Nohut QR Publisher'
          ? Map<String, dynamic>.from(body) : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
  Future<bool> portOpen(Uri base) async {
    try {
      final s = await Socket.connect(base.host, base.port,
          timeout: const Duration(seconds: 2));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
  Future<void> launch(String exe, List<String> args) =>
      Process.start(exe, args, mode: ProcessStartMode.detached);
  Future<void> wait(Duration d) => Future<void>.delayed(d);
}

/// Finds, starts, restarts and explains the local Nohut QR Publisher, so the
/// owner never has to open PowerShell for routine use.
class QrPublisherSupervisor {
  QrPublisherSupervisor({
    required this.endpoint,
    required this.client,
    this.host = const PublisherHost(),
    this.startTimeout = const Duration(seconds: 25),
  });
  final String endpoint;
  final QrPublisherClient client;
  final PublisherHost host;
  final Duration startTimeout;
  Future<PublisherDiagnosis>? _flight;

  String get _appData => host.env['APPDATA'] ?? '';
  String get serviceDir => paths.join(_appData, 'NohutFalafel', 'QrPublisher');
  String get statusFile => paths.join(serviceDir, 'status.json');
  String get logFile => paths.join(serviceDir, 'publisher.log');
  String get errorLogFile => paths.join(serviceDir, 'publisher-error.log');

  Uri? get _local {
    try {
      final u = QrPublisherClient.checkEndpoint(endpoint);
      return u.scheme == 'http' &&
              (u.host == '127.0.0.1' || u.host == 'localhost')
          ? u : null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> findScript() async {
    final local = host.env['LOCALAPPDATA'];
    for (final p in [
      paths.join(host.executableDir, 'QRPublisher', 'start-windows.ps1'),
      if (local != null && local.isNotEmpty)
        paths.join(local, 'Programs', 'Nohut Falafel POS', 'QRPublisher',
          'start-windows.ps1'),
    ]) {
      if (await host.fileExists(p)) return p;
    }
    return null;
  }

  /// Same search as start-windows.ps1: PATH, Program Files, fnm installs.
  Future<String?> findNode() async {
    final candidates = <String>[];
    final where = await host.run('where.exe', ['node.exe']);
    if (where != null) {
      candidates.addAll(const LineSplitter().convert(where)
          .map((l) => l.trim()).where((l) => l.isNotEmpty));
    }
    final pf = host.env['ProgramFiles'];
    if (pf != null) candidates.add(paths.join(pf, 'nodejs', 'node.exe'));
    for (final root in {
      host.env['FNM_DIR'],
      if (host.env['APPDATA'] != null) paths.join(host.env['APPDATA']!, 'fnm'),
      if (host.env['LOCALAPPDATA'] != null)
        paths.join(host.env['LOCALAPPDATA']!, 'fnm'),
      if (host.env['USERPROFILE'] != null)
        paths.join(host.env['USERPROFILE']!, '.fnm'),
    }) {
      if (root == null || root.isEmpty) continue;
      for (final v in await host.listDirs(paths.join(root, 'node-versions'))) {
        candidates.add(paths.join(v, 'installation', 'node.exe'));
      }
    }
    String? best;
    var bestMajor = 0;
    for (final c in candidates.toSet()) {
      if (!await host.fileExists(c)) continue;
      final out = await host.run(c, ['--version']);
      final m = RegExp(r'^v(\d+)\.').firstMatch(out?.trim() ?? '');
      final major = m == null ? 0 : int.parse(m.group(1)!);
      if (major >= 22 && major > bestMajor) {
        best = '${out!.trim()} · $c';
        bestMajor = major;
      }
    }
    return best;
  }

  /// The key the script would pick without asking: the protected copy, or
  /// GitHub's original file name in the protected folder or Downloads.
  Future<bool> findKey() async {
    if (await host.fileExists(
        paths.join(serviceDir, 'github-app-private-key.pem'))) {
      return true;
    }
    final profile = host.env['USERPROFILE'];
    for (final dir in [
      serviceDir,
      if (profile != null) paths.join(profile, 'Downloads'),
    ]) {
      for (final f in await host.listFiles(dir)) {
        final name = paths.basename(f).toLowerCase();
        if (name.startsWith('nohut-qr-publisher') && name.endsWith('.pem')) {
          return true;
        }
      }
    }
    return false;
  }

  Future<Map<String, dynamic>?> _status() async {
    final raw = await host.readText(statusFile);
    if (raw == null) return null;
    try {
      final v = jsonDecode(raw.replaceFirst('﻿', ''));
      return v is Map ? Map<String, dynamic>.from(v) : null;
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> _logTail() async {
    final lines = <String>[
      for (final f in [logFile, errorLogFile])
        ...const LineSplitter().convert(await host.readText(f) ?? '')
            .where((l) => l.trim().isNotEmpty),
    ];
    return lines.sublist(lines.length > 12 ? lines.length - 12 : 0);
  }

  /// Read-only check; changes nothing on the machine.
  Future<PublisherDiagnosis> diagnose() async {
    if (!host.isWindows) {
      return PublisherDiagnosis(PublisherIssue.notWindows, endpoint: endpoint);
    }
    final local = _local;
    if (local == null) {
      return PublisherDiagnosis(PublisherIssue.remoteEndpoint,
        endpoint: endpoint);
    }
    final health = await host.health(local);
    final script = await findScript();
    final status = await _status(), tail = await _logTail();
    if (health != null) {
      final v = health['version'] is String ? health['version'] as String : null;
      return PublisherDiagnosis(
        v == qrPublisherVersion ? PublisherIssue.running : PublisherIssue.outdated,
        endpoint: endpoint, script: script, keyFound: true,
        runningVersion: v ?? 'eski (sürüm bildirmiyor)',
        lastStatus: status, logTail: tail);
    }
    final node = await findNode(), key = await findKey();
    PublisherDiagnosis d(PublisherIssue i) => PublisherDiagnosis(i,
      endpoint: endpoint, script: script, node: node, keyFound: key,
      lastStatus: status, logTail: tail);
    if (script == null) return d(PublisherIssue.scriptMissing);
    if (node == null) return d(PublisherIssue.nodeMissing);
    if (!key) return d(PublisherIssue.keyMissing);
    if (await host.portOpen(local)) return d(PublisherIssue.portBusy);
    final state = status?['state'];
    return d(state is String && state != 'running' && state != 'stopped'
        ? PublisherIssue.startFailed : PublisherIssue.stopped);
  }

  /// Starts (or restarts an outdated) publisher and waits for /health.
  /// [allowPrompt] lets the script open the Windows file picker for the key;
  /// automatic starts never prompt.
  Future<PublisherDiagnosis> start({bool allowPrompt = false}) =>
      _flight ??= _start(allowPrompt).whenComplete(() => _flight = null);

  Future<PublisherDiagnosis> _start(bool allowPrompt) async {
    final before = await diagnose();
    if (before.issue == PublisherIssue.running) return before;
    // The script replaces an older publisher itself (only node.exe running
    // QRPublisher\server.mjs on this port), so outdated is startable too.
    final startable = before.issue == PublisherIssue.stopped ||
        before.issue == PublisherIssue.startFailed ||
        before.issue == PublisherIssue.outdated ||
        (allowPrompt && before.issue == PublisherIssue.keyMissing);
    if (!startable || before.script == null) return before;
    await host.launch('powershell.exe', [
      '-NoProfile', '-STA', '-WindowStyle', 'Hidden',
      '-ExecutionPolicy', 'Bypass', '-File', before.script!,
      '-Port', '${_local!.port}',
      if (!allowPrompt) '-NoPrompt',
    ]);
    final launched = DateTime.now().toUtc()
        .subtract(const Duration(seconds: 2)).toIso8601String();
    final deadline = DateTime.now().add(
        allowPrompt ? startTimeout * 6 : startTimeout);
    while (DateTime.now().isBefore(deadline)) {
      await host.wait(const Duration(milliseconds: 500));
      final h = await host.health(_local!);
      if (h != null && h['version'] == qrPublisherVersion) return diagnose();
      final report = await _status();
      // The script reports a definite failure (no Node, no key, port...).
      if (report?['state'] is String &&
          !{'starting', 'running'}.contains(report!['state']) &&
          '${report['at']}'.compareTo(launched) > 0) {
        break;
      }
    }
    final after = await diagnose();
    return after.issue == PublisherIssue.stopped
        ? PublisherDiagnosis(PublisherIssue.startFailed,
            endpoint: after.endpoint, script: after.script, node: after.node,
            keyFound: after.keyFound, lastStatus: after.lastStatus,
            logTail: after.logTail)
        : after;
  }

  /// POS launch: bring the publisher up quietly when everything it needs is
  /// present. Never prompts, never changes credentials.
  Future<PublisherDiagnosis> ensureRunning() async {
    final d = await diagnose();
    if (d.issue == PublisherIssue.stopped ||
        d.issue == PublisherIssue.outdated) {
      return start();
    }
    return d;
  }
}
