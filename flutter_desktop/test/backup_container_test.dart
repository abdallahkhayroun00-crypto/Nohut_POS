// Phase 1 / PR-02 acceptance tests (spec V5.1 §12.1, §15 Phase 1 gate,
// §16 suite 7). Synthetic data only.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/backup_container.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/receipt_printer.dart';

import 'support/synthetic_pos.dart';

// OWASP-minimum Argon2id keeps the suite fast; production uses defaults.
final fastContainer = BackupContainer(
  kdf: const BackupKdf(memoryKiB: 19456, iterations: 1),
  random: Random(42),
);

int paidTotal(Json state) =>
    asMaps(state['orders']).fold(0, (n, o) => n + orderPaidCents(o));

void main() {
  late Directory machineA, machineB;
  late PosStore store;
  late String key;

  setUp(() {
    machineA = Directory.systemTemp.createTempSync('nohut-pc-a');
    machineB = Directory.systemTemp.createTempSync('nohut-pc-b');
    store = PosStore(databaseFile: '${machineA.path}/nohut-pos.sqlite3');
    final state = buildSyntheticState(250);
    // One unprinted job and one Trendyol ticket waiting, to prove that a
    // restore never replays them.
    (asMaps(state['printJobs']).isEmpty ? <Json>[] : state['printJobs'] as List)
        .cast<Map>()
        .last['state'] = 'Bekliyor';
    (state['trendyolGoOrders'] as List).cast<Map>().first['kitchenPrintState'] =
        'Bekliyor';
    state['settings'] = {'printerName': 'XP-237B', 'autoPrint': true};
    expect(store.replace(state, store.read().revision).ok, true);
    key = RecoveryKey.generate(Random(7));
  });

  tearDown(() {
    store.dispose();
    machineA.deleteSync(recursive: true);
    machineB.deleteSync(recursive: true);
  });

  test('recovery key: 260 bits, grouped, normalizes typing mistakes', () {
    expect(key.split('-'), hasLength(13));
    expect(RecoveryKey.normalize(key.toLowerCase().replaceAll('-', ' ')),
        key.replaceAll('-', ''));
    expect(() => RecoveryKey.normalize('ABCD-EFGH'), throwsA(isA<BackupException>()));
  });

  test('backup is encrypted, compressed, verifiable and carries the manifest',
      () async {
    final result = await fastContainer.create(store,
        Directory('${machineA.path}/Yedekler'), recoveryKey: key,
        appVersion: '0.6.7+13');
    final bytes = result.file.readAsBytesSync();
    expect(ascii.decode(bytes.sublist(0, 8)), backupMagic);
    // No plaintext business data or customer data in the file.
    final text = latin1.decode(bytes);
    // The header manifest is readable by design (counts and revision, and it
    // is authenticated as AAD); business rows are not.
    for (final needle in ['Falafel', 'Ayşe', 'Gülşen', 'Atatürk Mah']) {
      expect(text.contains(needle), false, reason: needle);
    }
    final manifest = result.manifest;
    expect(manifest.revision, store.read().revision);
    expect(manifest.orderCount, asMaps(store.read().data['orders']).length);
    expect(manifest.tableCounts.keys,
        containsAll(['state_snapshot', 'command_receipts', 'deleted_requests']));
    expect(result.encryptedBytes, lessThan(manifest.bytesUncompressed));
    final verified = await fastContainer.verify(result.file, recoveryKey: key);
    expect(verified.sha256Uncompressed, manifest.sha256Uncompressed);
    expect(BackupContainer.readUnverifiedManifest(result.file).backupId,
        manifest.backupId);
    // The private plaintext temp copy is gone; only the .nohutbak remains.
    expect(Directory('${machineA.path}/Yedekler').listSync().map((f) =>
        f.path.endsWith(backupExtension)), everyElement(true));
  });

  test('wrong key, tampered ciphertext and tampered manifest are rejected',
      () async {
    final result = await fastContainer.create(store, machineA,
        recoveryKey: key);
    await expectLater(
      fastContainer.verify(result.file,
          recoveryKey: RecoveryKey.generate(Random(8))),
      throwsA(isA<BackupException>()),
    );
    final original = result.file.readAsBytesSync();
    final cipher = List<int>.from(original);
    cipher[cipher.length - 40] ^= 1;
    final tampered = File('${machineA.path}/tampered$backupExtension')
      ..writeAsBytesSync(cipher);
    await expectLater(fastContainer.verify(tampered, recoveryKey: key),
        throwsA(isA<BackupException>()));
    // Edit the visible manifest (revision) without the key: AAD must fail.
    final text = latin1.decode(original);
    final revision = '"revision":${result.manifest.revision}';
    final forged = latin1.encode(text.replaceFirst(revision,
        '"revision":${result.manifest.revision + 1}'.padRight(revision.length)
            .substring(0, revision.length)));
    final forgedFile = File('${machineA.path}/forged$backupExtension')
      ..writeAsBytesSync(forged);
    await expectLater(fastContainer.verify(forgedFile, recoveryKey: key),
        throwsA(isA<BackupException>()));
    // Truncated / foreign files.
    final junk = File('${machineA.path}/junk$backupExtension')
      ..writeAsStringSync('hello');
    await expectLater(fastContainer.verify(junk, recoveryKey: key),
        throwsA(isA<BackupException>()));
  });

  test('restore on a second machine: identical data, no print replay',
      () async {
    final before = store.read();
    final result = await fastContainer.create(store, machineA,
        recoveryKey: key);
    // Only the backup file travels to the new PC (USB / Drive).
    final copied = result.file.copySync('${machineB.path}/from-usb$backupExtension');
    final dbB = '${machineB.path}/nohut-pos.sqlite3';
    final manager = RestoreManager(dbB);
    final manifest = await manager.stage(copied, recoveryKey: key,
        confirmedBy: 'Ömer', container: fastContainer);
    expect(manifest.revision, before.revision);
    expect(manager.hasPending, true);
    final outcome = manager.applyPending();
    expect(outcome.applied, true, reason: outcome.message);
    expect(manager.hasPending, false);

    final restored = PosStore(databaseFile: dbB);
    final sent = <String>[];
    final printer = ReceiptPrinter(restored, transport: (text, name) async {
      sent.add(text);
    });
    try {
      final data = restored.read().data;
      expect(restored.remoteExecutionAllowed, false,
          reason: 'restore must fence cloud execution until authority reconciliation');
      expect(asMaps(data['orders']).length, asMaps(before.data['orders']).length);
      expect(paidTotal(data), paidTotal(before.data));
      expect(asMaps(data['trendyolGoOrders']).length,
          asMaps(before.data['trendyolGoOrders']).length);
      expect(restored.read().revision, before.revision + 1);
      expect(asMaps(data['printJobs']).where((j) => j['state'] == 'Bekliyor'),
          isEmpty);
      expect(asMaps(data['trendyolGoOrders'])
          .where((o) => o['kitchenPrintState'] == 'Bekliyor'), isEmpty);
      for (var i = 0; i < 4; i++) {
        await printer.pump();
      }
      expect(sent, isEmpty, reason: 'restored jobs must never auto-print');
      expect((data['settings'] as Map)['restoredFromBackupId'],
          manifest.backupId);
    } finally {
      printer.dispose();
      restored.dispose();
    }
  });

  test('restore over an existing database keeps a safety copy; failure rolls '
      'back', () async {
    final result = await fastContainer.create(store, machineA,
        recoveryKey: key);
    final dbB = '${machineB.path}/nohut-pos.sqlite3';
    final existing = PosStore(databaseFile: dbB);
    final s = existing.read().data;
    s['nextId'] = 999999;
    existing.replace(s, existing.read().revision);
    existing.dispose();

    // Failure path: a corrupted staged file must leave the original intact.
    final manager = RestoreManager(dbB);
    await manager.stage(result.file, recoveryKey: key, confirmedBy: 'Ömer',
        container: fastContainer);
    manager.stagedFile.writeAsStringSync('not a database');
    final failed = manager.applyPending();
    expect(failed.applied, false);
    final after = PosStore(databaseFile: dbB);
    expect(after.read().data['nextId'], 999999);
    after.dispose();

    // Success path: the previous database is kept as a safety copy.
    await manager.stage(result.file, recoveryKey: key, confirmedBy: 'Ömer',
        container: fastContainer);
    final ok = manager.applyPending();
    expect(ok.applied, true, reason: ok.message);
    final safety = PosStore(databaseFile: ok.safetyCopy!);
    expect(safety.read().data['nextId'], 999999);
    safety.dispose();
  });

  test('cancelling a staged restore changes nothing', () async {
    final result = await fastContainer.create(store, machineA,
        recoveryKey: key);
    final manager = RestoreManager(store.filePath);
    await manager.stage(result.file, recoveryKey: key, confirmedBy: 'Ömer',
        container: fastContainer);
    await manager.cancelPending();
    expect(manager.hasPending, false);
    expect(manager.applyPending().applied, false);
  });
}
