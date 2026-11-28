import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/qr_publisher_client.dart';
import 'package:nohut_falafel_desktop/qr_publisher_service.dart';
import 'package:nohut_falafel_desktop/qr_image_crops.dart';
import 'package:path/path.dart' as p;

/// A scripted Windows machine. Paths use the host separator.
class FakeHost extends PublisherHost {
  FakeHost();
  bool windows = true;
  final files = <String, String>{};
  final dirs = <String, List<String>>{};
  final runs = <String, String>{};
  Map<String, dynamic>? healthBody;
  bool portIsOpen = false;
  final launches = <List<String>>[];
  final launchEnv = <Map<String, String>>[];
  final deleted = <String>[];
  final runArgs = <List<String>>[];
  bool shutdownWorks = false;
  /// What happens when node is launched.
  void Function(List<String> args)? onLaunch;

  @override bool get isWindows => windows;
  @override String get executableDir => p.join('C:', 'POS');
  @override Map<String, String> get env => {
    'APPDATA': p.join('C:', 'AppData'),
    'LOCALAPPDATA': p.join('C:', 'Local'),
    'USERPROFILE': p.join('C:', 'User'),
    'ProgramFiles': p.join('C:', 'PF'),
    'USERNAME': 'kasa',
    'USERDOMAIN': 'NOHUT-PC',
  };
  @override Future<bool> fileExists(String path) async => files.containsKey(path);
  @override Future<List<String>> listFiles(String dir) async =>
      files.keys.where((f) => p.dirname(f) == dir).toList();
  @override Future<List<String>> listDirs(String dir) async => dirs[dir] ?? const [];
  @override Future<String?> readText(String path) async => files[path];
  @override Future<String?> run(String exe, List<String> args) async {
    runArgs.add([exe, ...args]);
    return runs[exe];
  }
  @override Future<Map<String, dynamic>?> health(Uri base) async => healthBody;
  @override Future<bool> portOpen(Uri base) async => portIsOpen || healthBody != null;
  @override Future<int?> launch(String exe, List<String> args,
      {Map<String, String>? environment, String? workingDirectory}) async {
    launches.add([exe, ...args]);
    launchEnv.add(environment ?? const {});
    onLaunch?.call(args);
    return 4242;
  }
  @override Future<void> writeText(String path, String text) async => files[path] = text;
  @override Future<void> copyFile(String from, String to) async => files[to] = files[from]!;
  @override Future<void> deleteFile(String path) async {
    deleted.add(path);
    files.remove(path);
  }
  @override Future<bool> shutdown(Uri base, String token) async {
    if (shutdownWorks) healthBody = null;
    return shutdownWorks;
  }
  @override Future<void> wait(Duration d) async {}
}

final script = p.join('C:', 'POS', 'QRPublisher', 'server.mjs');
final node = p.join('C:', 'PF', 'nodejs', 'node.exe');
final key = p.join('C:', 'AppData', 'NohutFalafel', 'QrPublisher',
  'github-app-private-key.pem');
final status = p.join('C:', 'AppData', 'NohutFalafel', 'QrPublisher', 'status.json');

FakeHost ready() => FakeHost()
  ..files[script] = ''
  ..files[node] = ''
  ..runs[node] = 'v22.11.0\n'
  ..runs['icacls.exe'] = 'ok'
  ..files[key] = '-----BEGIN PRIVATE KEY-----\nnever read\n-----END PRIVATE KEY-----';

QrPublisherSupervisor sup(FakeHost h, {String endpoint = 'http://127.0.0.1:18787'}) =>
    QrPublisherSupervisor(endpoint: endpoint,
      client: QrPublisherClient('db', testToken: 'x' * 40), host: h,
      startTimeout: const Duration(milliseconds: 50));

/// The real machine with a throwaway profile (Windows CI only).
class IsolatedHost extends PublisherHost {
  IsolatedHost(this.root);
  final String root;
  @override bool get isWindows => true;
  @override String get executableDir => p.join(root, 'POS');
  @override Map<String, String> get env => {
    ...Platform.environment,
    'APPDATA': p.join(root, 'AppData'),
    'LOCALAPPDATA': p.join(root, 'Local'),
    'USERPROFILE': p.join(root, 'User'),
    'USERNAME': Platform.environment['USERNAME'] ?? 'ci',
  };
  // Off Windows (local runs only) stand in for where.exe and icacls.exe.
  @override Future<String?> run(String exe, List<String> args) async {
    if (!Platform.isWindows && exe == 'where.exe') return super.run('which', ['node']);
    if (!Platform.isWindows && exe == 'icacls.exe') return 'ok';
    return super.run(exe, args);
  }
}

void main() {
  test('each missing prerequisite gets its own honest diagnosis', () async {
    expect((await sup(FakeHost()..windows = false).diagnose()).issue,
      PublisherIssue.notWindows);
    expect((await sup(ready(), endpoint: 'https://pub.example.com').diagnose()).issue,
      PublisherIssue.remoteEndpoint);
    expect((await sup(ready()..files.remove(script)).diagnose()).issue,
      PublisherIssue.scriptMissing);
    expect((await sup(ready()..runs[node] = 'v20.1.0').diagnose()).issue,
      PublisherIssue.nodeMissing);
    final noKey = await sup(ready()..files.remove(key)).diagnose();
    expect(noKey.issue, PublisherIssue.keyMissing);
    expect(noKey.fix, PublisherFix.chooseKey);
    expect((await sup(ready()..portIsOpen = true).diagnose()).issue,
      PublisherIssue.portBusy);
    expect((await sup(ready()).diagnose()).issue, PublisherIssue.stopped);
  });

  test('GitHub original key name in Downloads counts as found', () async {
    final h = ready()..files.remove(key)
      ..files[p.join('C:', 'User', 'Downloads',
          'nohut-qr-publisher.2026-11-20.private-key.pem')] = '';
    expect((await sup(h).diagnose()).issue, PublisherIssue.stopped);
  });

  test('running and outdated are told apart by /health version', () async {
    final h = ready()..healthBody = {'service': 'Nohut QR Publisher',
      'version': qrPublisherVersion};
    expect((await sup(h).diagnose()).ok, isTrue);
    h.healthBody = {'service': 'Nohut QR Publisher'};
    final old = await sup(h).diagnose();
    expect(old.issue, PublisherIssue.outdated);
    expect(old.fix, PublisherFix.restart);
  });

  test('a failed script run is reported with its own message', () async {
    final h = ready()..files[status] =
      '{"state":"exited","at":"2026-11-28T00:07:00Z","message":"Hizmet kapandı (kod 1)."}';
    final d = await sup(h).diagnose();
    expect(d.issue, PublisherIssue.startFailed);
    expect(d.help, 'Hizmet kapandı (kod 1).');
  });

  test('start runs node directly (no PowerShell) with the key and code in its environment', () async {
    final h = ready();
    h.onLaunch = (_) => h.healthBody = {'service': 'Nohut QR Publisher',
      'version': qrPublisherVersion};
    final d = await sup(h).start();
    expect(d.ok, isTrue);
    expect(h.launches.single, [node, script]);
    final env = h.launchEnv.single;
    expect(env['GITHUB_APP_PRIVATE_KEY_FILE'], key);
    expect(env['QR_PUBLISH_ADMIN_TOKEN'], 'x' * 40);
    expect(env['QR_PUBLISH_PORT'], '18787');
    expect(env['QR_PUBLISH_STATUS_FILE'], status);
    expect(h.runArgs.any((r) => r.first.toLowerCase().contains('powershell')), isFalse);
    expect(h.runArgs.where((r) => r.first == 'icacls.exe').single,
      [ 'icacls.exe', key, '/inheritance:r', '/grant:r', r'NOHUT-PC\kasa:(F)']);
    expect(h.files[p.join('C:', 'AppData', 'NohutFalafel', 'QrPublisher', 'publisher.pid')], '4242');
    expect(h.deleted, contains(p.join('C:', 'AppData', 'Microsoft', 'Windows', 'Start Menu',
      'Programs', 'Startup', 'Nohut QR Publisher.lnk')), reason: 'old PowerShell sign-in shortcut removed');
  });

  test('a file that is not a private key is refused before anything starts', () async {
    final h = ready()..files.remove(key);
    final bad = p.join('C:', 'User', 'Desktop', 'notes.pem');
    h.files[bad] = 'hello';
    final d = await sup(h).start(keyFile: bad);
    expect(h.launches, isEmpty);
    expect(d.issue, PublisherIssue.keyMissing);
    expect(h.files[status], contains('private key'));
  });

  test('a start that never answers becomes startFailed, not a silent stop', () async {
    final h = ready();
    final d = await sup(h).start();
    expect(d.issue, PublisherIssue.startFailed);
    expect(h.launches, hasLength(1));
  });

  test('auto start never prompts and never runs without prerequisites', () async {
    for (final h in [
      ready()..files.remove(key),
      ready()..runs.remove(node),
      ready()..files.remove(script),
      ready()..portIsOpen = true,
    ]) {
      await sup(h).ensureRunning();
      expect(h.launches, isEmpty);
    }
  });

  test('a chosen key is copied into the protected folder before start', () async {
    final h = ready()..files.remove(key);
    final chosen = p.join('C:', 'User', 'Desktop', 'app.pem');
    h.files[chosen] = '-----BEGIN RSA PRIVATE KEY-----\nk\n-----END RSA PRIVATE KEY-----';
    h.onLaunch = (_) => h.healthBody = {'service': 'Nohut QR Publisher',
      'version': qrPublisherVersion};
    expect((await sup(h).start()).issue, PublisherIssue.keyMissing);
    expect(h.launches, isEmpty);
    expect((await sup(h).start(keyFile: chosen)).ok, isTrue);
    expect(h.files[key], h.files[chosen]);
  });

  test('outdated publisher is asked to stop, then the bundled one starts', () async {
    final h = ready()..healthBody = {'service': 'Nohut QR Publisher'}..shutdownWorks = true;
    h.onLaunch = (_) => h.healthBody = {'service': 'Nohut QR Publisher',
      'version': qrPublisherVersion};
    expect((await sup(h).ensureRunning()).ok, isTrue);
    expect(h.launches.single, [node, script]);
    // If the old one cannot be replaced, it stays reported as outdated and
    // only a node.exe owning exactly this port is ever targeted.
    final stuck = ready()..healthBody = {'service': 'Nohut QR Publisher'}
      ..runs['netstat.exe'] = '  TCP    127.0.0.1:18787   0.0.0.0:0   LISTENING   777\r\n'
          '  TCP    127.0.0.1:8787    0.0.0.0:0   LISTENING   555\r\n';
    expect((await sup(stuck).start()).issue, PublisherIssue.outdated);
    expect(stuck.runArgs.where((r) => r.first == 'taskkill.exe').single,
      ['taskkill.exe', '/PID', '777', '/F', '/FI', 'IMAGENAME eq node.exe']);
    expect(stuck.launches, isEmpty);
  });

  test('diagnostics never include key contents or tokens', () async {
    final d = await sup(ready()).diagnose();
    final text = d.facts.map((f) => '${f.$1} ${f.$2}').join('\n');
    expect(text, isNot(contains('never read')));
    expect(text, contains('bulundu'));
  });

  test('atlas photos crop to the one dish the public menu shows', () {
    final c = qrAtlasCrop('assets/wrap-cutouts/wraps-transparent.webp',
      'Patates Dürüm')!;
    expect(c.canvas, const Size(1536, 1024));
    expect(c.crop, const Rect.fromLTWH(520, 76, 480, 362));
    expect(qrAtlasCrop('assets/wrap-cutouts/wraps-transparent.webp', 'Yeni Dürüm'),
      isNull);
    expect(isQrAtlas('assets/wrap-cutouts/wraps-transparent.webp'), isTrue);
    expect(qrAtlasCrop('assets/products/kibbe-6003492c.jpg', 'Kibbe (3 Adet)'),
      isNull);
    expect(isQrAtlas('assets/products/kibbe-6003492c.jpg'), isFalse);
  });
  // Replaces the old PowerShell lifecycle script: real node.exe, real
  // icacls, real /health and /shutdown, in an isolated profile.
  test('Windows: POS starts, replaces and stops the real publisher without PowerShell', () async {
    final root = Directory.systemTemp.createTempSync('nohut-qrpub-').path;
    final pos = Directory(p.join(root, 'POS', 'QRPublisher'))..createSync(recursive: true);
    File(p.join('windows', 'installer', 'qr-publisher', 'server.mjs')).copySync(p.join(pos.path, 'server.mjs'));
    final gen = await Process.run('node', ['-e',
      "process.stdout.write(require('crypto').generateKeyPairSync('rsa',{modulusLength:2048}).privateKey.export({type:'pkcs8',format:'pem'}))"]);
    final chosen = p.join(root, 'User', 'Desktop', 'nohut.pem');
    File(chosen)..createSync(recursive: true)..writeAsStringSync('${gen.stdout}');
    final host = IsolatedHost(root);
    final s = QrPublisherSupervisor(endpoint: 'http://127.0.0.1:18919',
        client: QrPublisherClient('db', testToken: 'w' * 48), host: host);
    expect((await s.diagnose()).issue, PublisherIssue.keyMissing);
    final d = await s.start(keyFile: chosen);
    expect(d.ok, isTrue, reason: '${d.title} ${d.help} ${d.logTail}');
    expect(File(s.keyFile).existsSync(), isTrue);
    expect(jsonDecode(File(s.statusFile).readAsStringSync())['state'], 'running');
    expect(await host.shutdown(Uri.parse('http://127.0.0.1:18919/'), 'w' * 48), isTrue);
    for (var i = 0; i < 40 && await host.portOpen(Uri.parse('http://127.0.0.1:18919/')); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    expect((await s.diagnose()).issue, PublisherIssue.stopped);
    expect((await s.ensureRunning()).ok, isTrue, reason: 'auto start reuses the protected key');
    await host.shutdown(Uri.parse('http://127.0.0.1:18919/'), 'w' * 48);
  }, skip: (Platform.isWindows && Platform.environment['GITHUB_ACTIONS'] == 'true') ||
          Platform.environment['NOHUT_PUBLISHER_LIFECYCLE'] == '1'
      ? false : 'Windows CI only (or NOHUT_PUBLISHER_LIFECYCLE=1)', timeout: const Timeout(Duration(minutes: 2)));
}
