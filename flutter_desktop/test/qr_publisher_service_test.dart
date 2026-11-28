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
  /// What happens when the script is launched.
  void Function(List<String> args)? onLaunch;

  @override bool get isWindows => windows;
  @override String get executableDir => p.join('C:', 'POS');
  @override Map<String, String> get env => {
    'APPDATA': p.join('C:', 'AppData'),
    'LOCALAPPDATA': p.join('C:', 'Local'),
    'USERPROFILE': p.join('C:', 'User'),
    'ProgramFiles': p.join('C:', 'PF'),
  };
  @override Future<bool> fileExists(String path) async => files.containsKey(path);
  @override Future<List<String>> listFiles(String dir) async =>
      files.keys.where((f) => p.dirname(f) == dir).toList();
  @override Future<List<String>> listDirs(String dir) async => dirs[dir] ?? const [];
  @override Future<String?> readText(String path) async => files[path];
  @override Future<String?> run(String exe, List<String> args) async => runs[exe];
  @override Future<Map<String, dynamic>?> health(Uri base) async => healthBody;
  @override Future<bool> portOpen(Uri base) async => portIsOpen || healthBody != null;
  @override Future<void> launch(String exe, List<String> args) async {
    launches.add([exe, ...args]);
    onLaunch?.call(args);
  }
  @override Future<void> wait(Duration d) async {}
}

final script = p.join('C:', 'POS', 'QRPublisher', 'start-windows.ps1');
final node = p.join('C:', 'PF', 'nodejs', 'node.exe');
final key = p.join('C:', 'AppData', 'NohutFalafel', 'QrPublisher',
  'github-app-private-key.pem');
final status = p.join('C:', 'AppData', 'NohutFalafel', 'QrPublisher', 'status.json');

FakeHost ready() => FakeHost()
  ..files[script] = ''
  ..files[node] = ''
  ..runs[node] = 'v22.11.0\n'
  ..files[key] = 'never read';

QrPublisherSupervisor sup(FakeHost h, {String endpoint = 'http://127.0.0.1:18787'}) =>
    QrPublisherSupervisor(endpoint: endpoint,
      client: QrPublisherClient('db', testToken: 'x' * 40), host: h,
      startTimeout: const Duration(milliseconds: 50));

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

  test('bundled runtime works without system Node and takes precedence', () async {
    final bundled = p.join('C:', 'POS', 'QRPublisher', 'runtime', 'node.exe');
    final h = ready()..files.remove(node)..runs.remove(node)
      ..files[bundled] = ''..runs[bundled] = 'v22.23.5';
    final d = await sup(h).diagnose();
    expect(d.issue, PublisherIssue.stopped);
    expect(d.node, contains(bundled));
    h.files[node] = '';
    h.runs[node] = 'v26.0.0';
    expect((await sup(h).diagnose()).node, contains(bundled));
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

  test('start launches the bundled script hidden, without prompts, and waits for health', () async {
    final h = ready();
    h.onLaunch = (_) => h.healthBody = {'service': 'Nohut QR Publisher',
      'version': qrPublisherVersion};
    final d = await sup(h).start();
    expect(d.ok, isTrue);
    expect(h.launches.single, containsAllInOrder(
      ['powershell.exe', '-NoProfile', '-WindowStyle', 'Hidden', '-File', script,
       '-Port', '18787', '-NoPrompt']));
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

  test('choosing the key is the only path that allows the file picker', () async {
    final h = ready()..files.remove(key);
    h.onLaunch = (_) => h.healthBody = {'service': 'Nohut QR Publisher',
      'version': qrPublisherVersion};
    expect((await sup(h).start()).issue, PublisherIssue.keyMissing);
    expect(h.launches, isEmpty);
    expect((await sup(h).start(allowPrompt: true)).ok, isTrue);
    expect(h.launches.single, isNot(contains('-NoPrompt')));
  });

  test('outdated publisher is replaced by running the bundled script', () async {
    final h = ready()..healthBody = {'service': 'Nohut QR Publisher'};
    h.onLaunch = (_) => h.healthBody = {'service': 'Nohut QR Publisher',
      'version': qrPublisherVersion};
    expect((await sup(h).ensureRunning()).ok, isTrue);
    expect(h.launches.single, contains('-NoPrompt'));
    // If the old one cannot be replaced, it stays reported as outdated.
    final stuck = ready()..healthBody = {'service': 'Nohut QR Publisher'};
    expect((await sup(stuck).start()).issue, PublisherIssue.outdated);
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
}
