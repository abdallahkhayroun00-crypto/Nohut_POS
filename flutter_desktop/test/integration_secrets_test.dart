// Portable Trendyol credentials through an owner backup (#44 7230877753).
// Synthetic values only; a fake vault stands in for per-user DPAPI.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/backup_container.dart';
import 'package:nohut_falafel_desktop/backup_service.dart';
import 'package:nohut_falafel_desktop/integration_secrets.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/windows_vault.dart';

import 'support/synthetic_pos.dart';

/// A file "wrapped" for one Windows profile: readable only by that profile,
/// exactly like DPAPI (another PC or user gets an exception).
class ProfileVault implements SecretRecordVault {
  ProfileVault(this.file, this.profile);
  final File file;
  final String profile;
  @override
  bool get exists => file.existsSync();
  @override
  Map<String, dynamic>? read() {
    if (!file.existsSync()) return null;
    final m = jsonDecode(file.readAsStringSync()) as Map;
    if (m['profile'] != profile) {
      throw const FormatException('Windows güvenli kasa işlemi başarısız.');
    }
    // "Encrypted": reversed base64 so the plain secret never sits in the file.
    final inner = utf8.decode(base64Decode(String.fromCharCodes(
        (m['blob'] as String).codeUnits.reversed)));
    return (jsonDecode(inner) as Map).cast<String, dynamic>();
  }
  @override
  void write(Map<String, dynamic> fields) {
    file.parent.createSync(recursive: true);
    final blob = String.fromCharCodes(
        base64Encode(utf8.encode(jsonEncode(fields))).codeUnits.reversed);
    file.writeAsStringSync(jsonEncode({'profile': profile, 'blob': blob}));
  }
  @override
  String? setAside(String suffix) {
    if (!file.existsSync()) return null;
    final to = '${file.path}.$suffix';
    file.renameSync(to);
    return to;
  }
}

const secretKey = 'SYNTH-KEY-7f3a91c2d4e5';
const secretSecret = 'SYNTH-SECRET-b8e2a0f1c3d4';
final creds = {
  'supplierId': '123456',
  'apiKey': secretKey,
  'apiSecret': secretSecret,
  'email': 'entegrasyon@example.test',
};

final fast = BackupContainer(
  kdf: const BackupKdf(memoryKiB: 19456, iterations: 1),
  random: Random(3),
);

void main() {
  late Directory pcA, pcB;
  late PosStore store;
  late String key;
  late ProfileVault vaultA;

  setUp(() {
    pcA = Directory.systemTemp.createTempSync('nohut-int-a');
    pcB = Directory.systemTemp.createTempSync('nohut-int-b');
    store = PosStore(databaseFile: '${pcA.path}/nohut-pos.sqlite3');
    final state = buildSyntheticState(20);
    state['tgoSyncInfo'] = {'supplierId': '123456', 'lastSync': '2026-11-27T20:00:00Z'};
    expect(store.replace(state, store.read().revision).ok, true);
    key = RecoveryKey.generate(Random(9));
    vaultA = ProfileVault(File('${pcA.path}/tgo.dpapi'), 'pc-a\\owner')..write(creds);
  });

  tearDown(() {
    store.dispose();
    pcA.deleteSync(recursive: true);
    pcB.deleteSync(recursive: true);
  });

  Future<File> backupWith(SecretRecordVault vault) async {
    final service = BackupService(store,
        keyStore: MemoryRecoveryKeyStore()..value = key,
        container: fast, trendyolVault: vault);
    await service.configure(folder: '${pcA.path}/Yedekler');
    final r = await service.runNow();
    expect(r.ok, isTrue, reason: r.message);
    return r.file!;
  }

  RestoreManager restorerOnB(String dbPath, ProfileVault tgoB) => RestoreManager(
    dbPath,
    vaultFor: (f) => ProfileVault(f, 'pc-b\\owner'),
    trendyolVault: tgoB,
  );

  test('new PC: original DPAPI unusable, restore re-wraps credentials', () async {
    final file = await backupWith(vaultA);
    final bytes = await file.readAsBytes();
    final text = latin1.decode(bytes);
    expect(text.contains(secretKey) || text.contains(secretSecret) ||
        text.contains('entegrasyon@'), isFalse, reason: 'no plaintext in backup');
    expect(BackupContainer.hasIntegrations(file), isTrue);

    // The copied DPAPI file from PC A is useless on PC B.
    final copied = ProfileVault(File('${pcB.path}/copied.dpapi'), 'pc-b\\owner');
    File(vaultA.file.path).copySync(copied.file.path);
    expect(copied.read, throwsFormatException);

    final dbB = '${pcB.path}/nohut-pos.sqlite3';
    final tgoB = ProfileVault(File('${pcB.path}/tgo.dpapi'), 'pc-b\\owner');
    final restorer = restorerOnB(dbB, tgoB);
    await restorer.stage(file, recoveryKey: key, confirmedBy: 'owner', container: fast);
    // Pending credentials are wrapped for PC B, never plain.
    final pending = restorer.pendingIntegrations.readAsStringSync();
    expect(pending.contains(secretKey), isFalse);
    expect(tgoB.exists, isFalse, reason: 'nothing written before apply');

    final out = restorer.applyPending();
    expect(out.applied, isTrue);
    expect(out.trendyol, IntegrationRestore.restored);
    expect(tgoB.read(), creds);
    expect(restorer.pendingIntegrations.existsSync(), isFalse);

    // SQLite never holds the secret; first Trendyol poll is a baseline.
    final db = File(dbB).readAsBytesSync();
    expect(latin1.decode(db).contains(secretKey), isFalse);
    final restored = PosStore(databaseFile: dbB);
    expect((restored.read().data['tgoSyncInfo'] as Map).containsKey('lastSync'), isFalse);
    restored.dispose();
  });

  test('working, different credentials on the new PC are kept', () async {
    final file = await backupWith(vaultA);
    final tgoB = ProfileVault(File('${pcB.path}/tgo.dpapi'), 'pc-b\\owner')
      ..write({...creds, 'supplierId': '999999'});
    final r = restorerOnB('${pcB.path}/nohut-pos.sqlite3', tgoB);
    await r.stage(file, recoveryKey: key, confirmedBy: 'owner', container: fast);
    final out = r.applyPending();
    expect(out.applied, isTrue);
    expect(out.trendyol, IntegrationRestore.keptExisting);
    expect(tgoB.read()!['supplierId'], '999999');
    expect(out.message, contains('korundu'));
  });

  test('an unreadable vault on the new PC is set aside, not deleted', () async {
    final file = await backupWith(vaultA);
    final tgoB = ProfileVault(File('${pcB.path}/tgo.dpapi'), 'pc-b\\owner');
    File(vaultA.file.path).copySync(tgoB.file.path); // old profile's file
    final r = restorerOnB('${pcB.path}/nohut-pos.sqlite3', tgoB);
    await r.stage(file, recoveryKey: key, confirmedBy: 'owner', container: fast);
    expect(r.applyPending().trendyol, IntegrationRestore.restored);
    expect(tgoB.read(), creds);
    expect(pcB.listSync().whereType<File>()
        .any((f) => f.path.contains('tgo.dpapi.unreadable-')), isTrue);
  });

  test('a backup made where the vault is unreadable is DB-only (format 1)', () async {
    // Written by another Windows user; this user cannot unwrap it.
    final foreign = ProfileVault(File('${pcA.path}/foreign.dpapi'), 'someone-else')..write(creds);
    final service = BackupService(store,
        keyStore: MemoryRecoveryKeyStore()..value = key,
        container: fast, trendyolVault: ProfileVault(foreign.file, 'pc-a\\owner'));
    await service.configure(folder: '${pcA.path}/Yedekler');
    final r = await service.runNow();
    expect(r.message, contains('okunamadı'));
    final file = r.file!;
    expect(BackupContainer.hasIntegrations(file), isFalse);
    final header = latin1.decode(file.readAsBytesSync().sublist(12, 200));
    expect(header, contains('"format":1'));
  });

  test('legacy format-1 backup restores and leaves the vault alone', () async {
    final file = await backupWith(ProfileVault(File('${pcA.path}/none.dpapi'), 'pc-a\\owner'));
    final tgoB = ProfileVault(File('${pcB.path}/tgo.dpapi'), 'pc-b\\owner');
    final r = restorerOnB('${pcB.path}/nohut-pos.sqlite3', tgoB);
    await r.stage(file, recoveryKey: key, confirmedBy: 'owner', container: fast);
    final out = r.applyPending();
    expect(out.applied, isTrue);
    expect(out.trendyol, IntegrationRestore.none);
    expect(tgoB.exists, isFalse);
  });

  test('wrong key or a tampered credentials box stages nothing', () async {
    final file = await backupWith(vaultA);
    final tgoB = ProfileVault(File('${pcB.path}/tgo.dpapi'), 'pc-b\\owner');
    final r = restorerOnB('${pcB.path}/nohut-pos.sqlite3', tgoB);
    await expectLater(
      r.stage(file, recoveryKey: RecoveryKey.generate(Random(1)), confirmedBy: 'o', container: fast),
      throwsA(isA<BackupException>()));
    final bytes = file.readAsBytesSync();
    bytes[bytes.length - 20] ^= 0x01; // inside the credentials ciphertext
    final bad = File('${pcB.path}/bad.nohutbak')..writeAsBytesSync(bytes);
    await expectLater(
      r.stage(bad, recoveryKey: key, confirmedBy: 'o', container: fast),
      throwsA(isA<BackupException>()));
    expect(r.hasPending, isFalse);
    expect(r.pendingIntegrations.existsSync(), isFalse);
    expect(tgoB.exists, isFalse);
  });

  test('crafted sections outside the allowlist are refused', () {
    expect(() => checkIntegrationPayload({'schema': 1, 'qrPrivateKey': 'x'}),
        throwsFormatException);
    expect(() => checkIntegrationPayload({'schema': 1,
        'trendyolGo': {...creds, 'extra': 'x'}}), throwsFormatException);
    expect(() => checkIntegrationPayload({'schema': 2}), throwsFormatException);
    expect(checkIntegrationPayload({'schema': 1, 'trendyolGo': creds})['trendyolGo'], creds);
  });

  test('a failed vault write keeps the pending record for the next start', () async {
    final file = await backupWith(vaultA);
    final tgoB = _FailingVault();
    final r = RestoreManager('${pcB.path}/nohut-pos.sqlite3',
        vaultFor: (f) => ProfileVault(f, 'pc-b\\owner'), trendyolVault: tgoB);
    await r.stage(file, recoveryKey: key, confirmedBy: 'owner', container: fast);
    final out = r.applyPending();
    expect(out.applied, isTrue, reason: 'database restore is not undone');
    expect(out.trendyol, IntegrationRestore.failed);
    expect(r.pendingIntegrations.existsSync(), isTrue);
    tgoB.fail = false;
    expect(r.applyPending().trendyol, IntegrationRestore.restored);
    expect(r.pendingIntegrations.existsSync(), isFalse);
  });
}

class _FailingVault implements SecretRecordVault {
  bool fail = true;
  Map<String, dynamic>? stored;
  @override
  bool get exists => stored != null;
  @override
  Map<String, dynamic>? read() => stored;
  @override
  void write(Map<String, dynamic> fields) {
    if (fail) throw const FileSystemException('locked');
    stored = fields;
  }
  @override
  String? setAside(String suffix) => null;
}
