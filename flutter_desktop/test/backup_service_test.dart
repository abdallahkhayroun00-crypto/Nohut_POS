// Phase 1 / PR-03: destinations, mirror verification, history, automatic
// backup scheduling. Synthetic data only.
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/backup_container.dart';
import 'package:nohut_falafel_desktop/backup_service.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';

import 'support/synthetic_pos.dart';

void main() {
  late Directory root;
  late PosStore store;
  late MemoryRecoveryKeyStore keys;
  late DateTime now;
  late BackupService service;

  setUp(() {
    root = Directory.systemTemp.createTempSync('nohut-bksvc');
    store = PosStore(databaseFile: '${root.path}/db/nohut-pos.sqlite3');
    final state = buildSyntheticState(60)..['settings'] = {'autoPrint': true};
    store.replace(state, store.read().revision);
    keys = MemoryRecoveryKeyStore();
    now = DateTime.utc(2026, 11, 27, 23);
    service = BackupService(store,
        keyStore: keys,
        container: BackupContainer(
            kdf: const BackupKdf(memoryKiB: 19456, iterations: 1),
            random: Random(3)),
        appVersion: 'test',
        clock: () => now);
  });

  tearDown(() {
    service.dispose();
    store.dispose();
    root.deleteSync(recursive: true);
  });

  test('without a recovery key nothing is written and the failure is logged',
      () async {
    final result = await service.runNow();
    expect(result.ok, false);
    expect(result.message, contains('Kurtarma anahtarı'));
    expect(store.backupHistory().single['status'], 'failed');
    expect(Directory(service.folder).existsSync(), false);
  });

  test('backup goes to the default folder and a verified mirror copy',
      () async {
    await keys.save(RecoveryKey.generate(Random(1)));
    await service.configure(mirror: '${root.path}/usb');
    final result = await service.runNow();
    expect(result.ok, true, reason: result.message);
    expect(result.file!.path, startsWith(service.defaultFolder));
    expect(result.mirrorFile!.readAsBytesSync(), result.file!.readAsBytesSync());
    final row = store.backupHistory().single;
    expect(row['status'], 'ok');
    expect(row['revision'], result.manifest!.revision);
    expect('${row['destination']}', contains('usb'));
    final listed = service.listBackups();
    expect(listed, hasLength(1));
    expect(listed.single.manifest!.backupId, result.manifest!.backupId);
    final settings = store.read().data['settings'] as Map;
    expect(settings['backupLastId'], result.manifest!.backupId);
    // The copy restores with the same key.
    await service.container.verify(result.mirrorFile!,
        recoveryKey: (await keys.load())!);
  });

  test('a broken mirror never loses the primary backup', () async {
    await keys.save(RecoveryKey.generate(Random(2)));
    // The mirror path exists as a FILE, so the copy must fail.
    File('${root.path}/not-a-folder').writeAsStringSync('x');
    store.replace({
      ...store.read().data,
      'settings': {
        ...(store.read().data['settings'] as Map),
        'backupMirrorFolder': '${root.path}/not-a-folder',
      },
    }, store.read().revision);
    final result = await service.runNow();
    expect(result.ok, true);
    expect(result.mirrorFile, isNull);
    expect(result.message, contains('Ayna'));
    expect(store.backupHistory().single['status'], 'ok_mirror_failed');
    expect(result.file!.existsSync(), true);
  });

  test('automatic backup runs once per 24 h and only when enabled', () async {
    await keys.save(RecoveryKey.generate(Random(4)));
    expect(service.autoBackupDue, false);
    await service.configure(auto: true);
    expect(service.autoBackupDue, true);
    expect((await service.runNow(reason: 'auto')).ok, true);
    expect(service.autoBackupDue, false);
    now = now.add(const Duration(hours: 23));
    expect(service.autoBackupDue, false);
    now = now.add(const Duration(hours: 2));
    expect(service.autoBackupDue, true);
  });

  test('single flight: a second run while one is running is refused',
      () async {
    await keys.save(RecoveryKey.generate(Random(5)));
    final first = service.runNow();
    final second = await service.runNow();
    expect(second.ok, false);
    expect((await first).ok, true);
  });

  test('history is kept across many runs; nothing is deleted automatically',
      () async {
    await keys.save(RecoveryKey.generate(Random(6)));
    for (var i = 0; i < 3; i++) {
      now = now.add(const Duration(seconds: 1));
      expect((await service.runNow()).ok, true);
      // Distinct file names need distinct seconds.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
    }
    expect(store.backupHistory(), hasLength(3));
    expect(service.listBackups(), hasLength(3));
  });
}
