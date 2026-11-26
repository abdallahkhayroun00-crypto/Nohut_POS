/// Encrypted backup container and staged restore (spec V5.1 §12.1, PR-02).
///
/// File format `*.nohutbak` (all integers big-endian):
///
/// ```text
/// "NOHUTBK1" | u32 headerLength | header (UTF-8 JSON) | ciphertext | 16-byte GCM tag
/// ```
///
/// * Plaintext = gzip(`VACUUM INTO` snapshot of the whole SQLite database:
///   state_snapshot, command_receipts, deleted_requests and any future
///   table, consistent while WAL is active).
/// * Key = Argon2id(owner Recovery Key, random 16-byte salt). The Recovery
///   Key is 260 random bits shown once to the owner and kept offline; it is
///   independent of Windows/DPAPI so a backup restores on another PC.
/// * AES-256-GCM with a random 96-bit nonce; the exact header bytes are the
///   AAD, so any change to the manifest or parameters fails authentication.
/// * The manifest records schema/revision/time/app version/table counts and
///   the SHA-256 of the uncompressed database, re-checked after decryption.
///
/// Restore is staged: decrypt + verify + `PRAGMA integrity_check` into a
/// staging file, write a pending marker, and apply only at the next start,
/// before the database is opened, with a safety copy and automatic rollback.
/// Restored print jobs and platform tickets are never replayed.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as paths;
import 'package:sqlite3/sqlite3.dart';

import 'pos_store.dart';

const backupMagic = 'NOHUTBK1';
const backupFormatVersion = 1;
const backupExtension = '.nohutbak';

/// Argon2id parameters stored in each header (so they can be raised later
/// without breaking old backups). Defaults exceed the OWASP minimum.
class BackupKdf {
  const BackupKdf({
    this.memoryKiB = 65536,
    this.iterations = 3,
    this.parallelism = 1,
  });
  final int memoryKiB, iterations, parallelism;

  Map<String, Object> toJson(List<int> salt) => {
    'alg': 'Argon2id',
    'memoryKiB': memoryKiB,
    'iterations': iterations,
    'parallelism': parallelism,
    'salt': base64Encode(salt),
  };

  static (BackupKdf, List<int>) fromJson(Map json) {
    if (json['alg'] != 'Argon2id') {
      throw const BackupException('Desteklenmeyen anahtar türetme yöntemi.');
    }
    final kdf = BackupKdf(
      memoryKiB: json['memoryKiB'] as int,
      iterations: json['iterations'] as int,
      parallelism: json['parallelism'] as int,
    );
    // Refuse downgraded parameters that a tampered header might carry.
    if (kdf.memoryKiB < 19456 || kdf.iterations < 1 ||
        kdf.parallelism < 1 || kdf.memoryKiB > 1048576) {
      throw const BackupException('Yedek anahtar parametreleri geçersiz.');
    }
    return (kdf, base64Decode(json['salt'] as String));
  }
}

class BackupException implements Exception {
  const BackupException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Owner Recovery Key: 52 Crockford-style base32 characters (260 bits)
/// shown as 13 groups of 4, e.g. `7KQ2-…`.
class RecoveryKey {
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  static String generate([Random? random]) {
    final r = random ?? Random.secure();
    final chars = List.generate(52, (_) => _alphabet[r.nextInt(32)]);
    return [
      for (var i = 0; i < 52; i += 4) chars.sublist(i, i + 4).join(),
    ].join('-');
  }

  /// Uppercases, removes spaces/dashes, maps easily confused letters.
  static String normalize(String text) {
    final clean = text
        .toUpperCase()
        .replaceAll(RegExp(r'[\s-]'), '')
        .replaceAll('O', '0')
        .replaceAll(RegExp('[IL]'), '1');
    if (clean.length != 52 ||
        clean.split('').any((c) => !_alphabet.contains(c))) {
      throw const BackupException(
        'Kurtarma anahtarı 52 karakter olmalı (13 grup × 4).',
      );
    }
    return clean;
  }
}

class BackupManifest {
  const BackupManifest({
    required this.backupId,
    required this.createdAt,
    required this.revision,
    required this.appVersion,
    required this.tableCounts,
    required this.orderCount,
    required this.bytesUncompressed,
    required this.sha256Uncompressed,
    this.schemaVersion = 1,
  });

  final String backupId, createdAt, appVersion, sha256Uncompressed;
  final int revision, orderCount, bytesUncompressed, schemaVersion;
  final Map<String, int> tableCounts;

  Map<String, Object> toJson() => {
    'backupId': backupId,
    'schemaVersion': schemaVersion,
    'createdAt': createdAt,
    'revision': revision,
    'appVersion': appVersion,
    'tableCounts': tableCounts,
    'orderCount': orderCount,
    'bytesUncompressed': bytesUncompressed,
    'sha256Uncompressed': sha256Uncompressed,
  };

  factory BackupManifest.fromJson(Map json) => BackupManifest(
    backupId: json['backupId'] as String,
    schemaVersion: json['schemaVersion'] as int,
    createdAt: json['createdAt'] as String,
    revision: json['revision'] as int,
    appVersion: json['appVersion'] as String,
    tableCounts: (json['tableCounts'] as Map).map(
      (k, v) => MapEntry('$k', v as int),
    ),
    orderCount: json['orderCount'] as int,
    bytesUncompressed: json['bytesUncompressed'] as int,
    sha256Uncompressed: json['sha256Uncompressed'] as String,
  );
}

class BackupResult {
  const BackupResult(this.file, this.manifest, this.encryptedBytes);
  final File file;
  final BackupManifest manifest;
  final int encryptedBytes;
}

/// Facts read from a plain SQLite snapshot (also used to compare a staged
/// restore with the current database before the owner confirms).
BackupManifest inspectDatabase(
  String sqlitePath, {
  required String backupId,
  required String appVersion,
  required List<int> bytes,
}) {
  final db = sqlite3.open(sqlitePath, mode: OpenMode.readOnly);
  try {
    final check = db.select('PRAGMA integrity_check').single.values.first;
    if (check != 'ok') {
      throw BackupException('Veritabanı bütünlük kontrolü başarısız: $check');
    }
    final tables = [
      for (final row in db.select(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
      ))
        row['name'] as String,
    ];
    final counts = <String, int>{
      for (final t in tables)
        t: db.select('SELECT count(*) AS n FROM "$t"').single['n'] as int,
    };
    final snap = db.select(
      'SELECT revision,payload FROM state_snapshot WHERE id=1',
    );
    if (snap.isEmpty) throw const BackupException('POS durumu bulunamadı.');
    final payload = jsonDecode(snap.single['payload'] as String) as Map;
    return BackupManifest(
      backupId: backupId,
      createdAt: DateTime.now().toUtc().toIso8601String(),
      revision: snap.single['revision'] as int,
      appVersion: appVersion,
      tableCounts: counts,
      orderCount: (payload['orders'] as List? ?? const []).length,
      bytesUncompressed: bytes.length,
      sha256Uncompressed: hash.sha256.convert(bytes).toString(),
    );
  } finally {
    db.dispose();
  }
}

class BackupContainer {
  BackupContainer({this.kdf = const BackupKdf(), Random? random})
    : _random = random ?? Random.secure();

  final BackupKdf kdf;
  final Random _random;

  List<int> _bytes(int n) => List.generate(n, (_) => _random.nextInt(256));

  Future<SecretKey> _key(String recoveryKey, BackupKdf params, List<int> salt) =>
      Argon2id(
        parallelism: params.parallelism,
        memory: params.memoryKiB,
        iterations: params.iterations,
        hashLength: 32,
      ).deriveKey(
        secretKey: SecretKey(utf8.encode(RecoveryKey.normalize(recoveryKey))),
        nonce: salt,
      );

  /// Creates `<directory>/nohut-<UTC stamp>-r<revision>.nohutbak`, written
  /// atomically, then decrypts it again to prove it is restorable. The
  /// plaintext snapshot exists only in a private temp folder and is deleted.
  Future<BackupResult> create(
    PosStore store,
    Directory directory, {
    required String recoveryKey,
    String appVersion = 'unknown',
  }) async {
    RecoveryKey.normalize(recoveryKey);
    await directory.create(recursive: true);
    final temp = await Directory.systemTemp.createTemp('nohut-bk-');
    try {
      final plainPath = paths.join(temp.path, 'snapshot.sqlite3');
      store.backup(plainPath);
      final plain = await File(plainPath).readAsBytes();
      final stamp = DateTime.now().toUtc();
      final id = '${stamp.toIso8601String().replaceAll(RegExp(r'[:.]'), '-')}'
          '-${base64Url.encode(_bytes(6))}';
      final manifest = inspectDatabase(
        plainPath,
        backupId: id,
        appVersion: appVersion,
        bytes: plain,
      );
      final salt = _bytes(16), nonce = _bytes(12);
      final header = utf8.encode(jsonEncode({
        'format': backupFormatVersion,
        'cipher': 'AES-256-GCM',
        'compression': 'gzip',
        'kdf': kdf.toJson(salt),
        'nonce': base64Encode(nonce),
        'manifest': manifest.toJson(),
      }));
      final box = await AesGcm.with256bits().encrypt(
        gzip.encode(plain),
        secretKey: await _key(recoveryKey, kdf, salt),
        nonce: nonce,
        aad: header,
      );
      final out = BytesBuilder(copy: false)
        ..add(ascii.encode(backupMagic))
        ..add((ByteData(4)..setUint32(0, header.length)).buffer.asUint8List())
        ..add(header)
        ..add(box.cipherText)
        ..add(box.mac.bytes);
      final bytes = out.takeBytes();
      final name = 'nohut-${stamp.toIso8601String().substring(0, 19).replaceAll(':', '')}'
          'Z-r${manifest.revision}$backupExtension';
      final target = File(paths.join(directory.path, name));
      if (await target.exists()) {
        throw const BackupException('Aynı isimde yedek zaten var.');
      }
      final part = File('${target.path}.part');
      await part.writeAsBytes(bytes, flush: true);
      await part.rename(target.path);
      // Verify the written file, not the bytes in memory.
      await verify(target, recoveryKey: recoveryKey);
      return BackupResult(target, manifest, bytes.length);
    } finally {
      await temp.delete(recursive: true);
    }
  }

  /// Reads the manifest without the key (authenticity is NOT proven yet).
  static BackupManifest readUnverifiedManifest(File file) =>
      BackupManifest.fromJson(_parse(file.readAsBytesSync()).header['manifest']
          as Map);

  /// Authenticates, decrypts, decompresses, re-checks SHA-256 and runs
  /// `PRAGMA integrity_check`. Throws [BackupException] on any problem.
  Future<BackupManifest> verify(File file, {required String recoveryKey}) async {
    final temp = await Directory.systemTemp.createTemp('nohut-verify-');
    try {
      return await decryptTo(
        file,
        paths.join(temp.path, 'verify.sqlite3'),
        recoveryKey: recoveryKey,
      );
    } finally {
      await temp.delete(recursive: true);
    }
  }

  /// Decrypts [file] into a new SQLite file at [outputPath] after full
  /// verification. The output never overwrites an existing file.
  Future<BackupManifest> decryptTo(
    File file,
    String outputPath, {
    required String recoveryKey,
  }) async {
    final parsed = _parse(await file.readAsBytes());
    final header = parsed.header;
    if (header['format'] != backupFormatVersion ||
        header['cipher'] != 'AES-256-GCM' ||
        header['compression'] != 'gzip') {
      throw const BackupException('Bu yedek biçimi desteklenmiyor.');
    }
    final (params, salt) = BackupKdf.fromJson(header['kdf'] as Map);
    final List<int> compressed;
    try {
      compressed = await AesGcm.with256bits().decrypt(
        SecretBox(
          parsed.cipherText,
          nonce: base64Decode(header['nonce'] as String),
          mac: Mac(parsed.tag),
        ),
        secretKey: await _key(recoveryKey, params, salt),
        aad: parsed.headerBytes,
      );
    } on SecretBoxAuthenticationError {
      throw const BackupException(
        'Yedek açılamadı: kurtarma anahtarı yanlış veya dosya değiştirilmiş.',
      );
    }
    final plain = gzip.decode(compressed);
    final manifest = BackupManifest.fromJson(header['manifest'] as Map);
    if (plain.length != manifest.bytesUncompressed ||
        hash.sha256.convert(plain).toString() != manifest.sha256Uncompressed) {
      throw const BackupException('Yedek içeriği özet ile uyuşmuyor.');
    }
    final out = File(outputPath);
    if (await out.exists()) {
      throw const BackupException('Hedef dosya zaten var.');
    }
    await out.writeAsBytes(plain, flush: true);
    try {
      final check = inspectDatabase(
        outputPath,
        backupId: manifest.backupId,
        appVersion: manifest.appVersion,
        bytes: plain,
      );
      if (check.revision != manifest.revision ||
          check.orderCount != manifest.orderCount) {
        throw const BackupException('Yedek içeriği bildirimle uyuşmuyor.');
      }
    } catch (_) {
      await out.delete();
      rethrow;
    }
    return manifest;
  }
}

class _Parsed {
  const _Parsed(this.headerBytes, this.header, this.cipherText, this.tag);
  final List<int> headerBytes, cipherText, tag;
  final Map header;
}

_Parsed _parse(List<int> bytes) {
  const magicLength = 8;
  if (bytes.length < magicLength + 4 + 16 ||
      ascii.decode(bytes.sublist(0, magicLength), allowInvalid: true) !=
          backupMagic) {
    throw const BackupException('Bu dosya bir Nohut yedeği değil.');
  }
  final headerLength = ByteData.sublistView(
    Uint8List.fromList(bytes.sublist(magicLength, magicLength + 4)),
  ).getUint32(0);
  final start = magicLength + 4, end = start + headerLength;
  if (headerLength < 2 || headerLength > 65536 || end + 16 > bytes.length) {
    throw const BackupException('Yedek başlığı bozuk.');
  }
  final headerBytes = bytes.sublist(start, end);
  final Map header;
  try {
    header = jsonDecode(utf8.decode(headerBytes)) as Map;
  } catch (_) {
    throw const BackupException('Yedek başlığı okunamadı.');
  }
  return _Parsed(
    headerBytes,
    header,
    bytes.sublist(end, bytes.length - 16),
    bytes.sublist(bytes.length - 16),
  );
}

// ---------------------------------------------------------------------------
// Staged restore.

/// Outcome of applying a pending restore at startup (shown once in the UI).
class RestoreOutcome {
  const RestoreOutcome(this.applied, this.message, {this.safetyCopy});
  final bool applied;
  final String message;
  final String? safetyCopy;
}

class RestoreManager {
  RestoreManager(this.databasePath);
  final String databasePath;

  File get stagedFile => File('$databasePath.restore-staged');
  File get pendingMarker => File('$databasePath.restore-pending.json');

  /// Step 1 (owner-confirmed in the UI): verify and stage. Nothing in the
  /// live database changes. The app must restart to apply.
  Future<BackupManifest> stage(
    File backup, {
    required String recoveryKey,
    required String confirmedBy,
    BackupContainer? container,
  }) async {
    await cancelPending();
    final manifest = await (container ?? BackupContainer()).decryptTo(
      backup,
      stagedFile.path,
      recoveryKey: recoveryKey,
    );
    await pendingMarker.writeAsString(jsonEncode({
      'stagedAt': DateTime.now().toUtc().toIso8601String(),
      'source': backup.path,
      'confirmedBy': confirmedBy,
      'manifest': manifest.toJson(),
    }), flush: true);
    return manifest;
  }

  Future<void> cancelPending() async {
    if (await pendingMarker.exists()) await pendingMarker.delete();
    if (await stagedFile.exists()) await stagedFile.delete();
  }

  bool get hasPending => pendingMarker.existsSync() && stagedFile.existsSync();

  /// Step 2, at startup BEFORE [PosStore] opens the database. Moves the
  /// current database (with its WAL/SHM) to a timestamped safety copy, puts
  /// the staged file in place, suppresses replay of historical print jobs,
  /// and rolls everything back on any failure. Never deletes the safety copy.
  RestoreOutcome applyPending() {
    if (!hasPending) {
      if (pendingMarker.existsSync()) pendingMarker.deleteSync();
      return const RestoreOutcome(false, '');
    }
    final marker = jsonDecode(pendingMarker.readAsStringSync()) as Map;
    final stamp = DateTime.now().toUtc().toIso8601String()
        .substring(0, 19).replaceAll(':', '');
    final safety = '$databasePath.pre-restore-$stamp';
    final moved = <(String, String)>[];
    try {
      for (final suffix in ['', '-wal', '-shm']) {
        final f = File('$databasePath$suffix');
        if (f.existsSync()) {
          f.renameSync('$safety$suffix');
          moved.add(('$databasePath$suffix', '$safety$suffix'));
        }
      }
      stagedFile.renameSync(databasePath);
      _suppressReplay(databasePath, marker);
      pendingMarker.deleteSync();
      final manifest = marker['manifest'] as Map;
      return RestoreOutcome(
        true,
        'Yedek geri yüklendi: ${manifest['createdAt']} · revizyon '
        '${manifest['revision']} · ${manifest['orderCount']} sipariş. '
        'Eski yazdırma işleri tekrar basılmadı.',
        safetyCopy: safety,
      );
    } catch (e) {
      // Roll back: put the original database files back exactly.
      final restored = File(databasePath);
      if (restored.existsSync() && moved.isNotEmpty) {
        restored.renameSync(stagedFile.path);
      }
      for (final (original, copy) in moved.reversed) {
        if (File(copy).existsSync()) File(copy).renameSync(original);
      }
      return RestoreOutcome(false, 'Geri yükleme yapılamadı, mevcut veriler korundu: $e');
    }
  }

  /// Restored queues must never print again on this or another machine.
  static void _suppressReplay(String path, Map marker) {
    final db = sqlite3.open(path);
    try {
      db.execute('PRAGMA journal_mode=WAL');
      db.execute('BEGIN IMMEDIATE');
      final row = db.select(
        'SELECT revision,payload FROM state_snapshot WHERE id=1',
      ).single;
      final state = jsonDecode(row['payload'] as String) as Map;
      final now = DateTime.now().toUtc().toIso8601String();
      for (final job in (state['printJobs'] as List? ?? const [])) {
        if (job is Map && ['Bekliyor', 'Gönderiliyor'].contains(job['state'])) {
          // Never printed automatically; staff may reprint after checking.
          job['state'] = 'Kontrol gerekli';
          job['error'] = 'Yedekten geri yüklendi; otomatik yazdırılmadı.';
        }
      }
      for (final order in (state['trendyolGoOrders'] as List? ?? const [])) {
        if (order is Map &&
            ['Bekliyor', 'Gönderiliyor'].contains(order['kitchenPrintState'])) {
          order['kitchenPrintState'] = 'Kontrol gerekli';
        }
      }
      final settings = state.putIfAbsent('settings', () => <String, dynamic>{})
          as Map;
      settings['autoPrintEnabledAt'] = now;
      settings['restoredAt'] = now;
      settings['restoredFromBackupId'] =
          (marker['manifest'] as Map)['backupId'];
      db.execute(
        'UPDATE state_snapshot SET revision=?,payload=?,updated_at=? WHERE id=1',
        [(row['revision'] as int) + 1, jsonEncode(state), now],
      );
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    } finally {
      db.dispose();
    }
  }
}
