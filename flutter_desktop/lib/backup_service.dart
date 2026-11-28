/// Backup destinations, history and automatic backups (spec V5.1 §12.1,
/// §6.3, §20.2 "Yedekleme & Geri Yükleme"; Phase 1 / PR-03).
///
/// * Primary folder: always local (`%APPDATA%\NohutFalafel\Yedekler` by
///   default). Optional mirror folder: USB stick, NAS share or a Google
///   Drive / OneDrive *desktop-synced* folder — 0 TL, no OAuth, no card.
///   Every mirror copy is re-hashed and compared before it counts.
/// * History lives in the `backup_history` table (spec §4.4) and the
///   backup files themselves stay listable after a restore.
/// * Automatic backup needs the Recovery Key on this PC: it is kept only in
///   Windows DPAPI (current user). The owner keeps the printed key for
///   disaster recovery on another PC. Nothing is ever deleted automatically.
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as hash;
import 'package:path/path.dart' as paths;

import 'backup_container.dart';
import 'integration_secrets.dart';
import 'trendyol_go_readonly.dart';
import 'pos_store.dart';
import 'windows_vault.dart';

/// Where this PC keeps the Recovery Key for automatic backups.
abstract class RecoveryKeyStore {
  Future<String?> load();
  Future<void> save(String key);
  Future<void> clear();
}

class DpapiRecoveryKeyStore implements RecoveryKeyStore {
  DpapiRecoveryKeyStore(String databasePath)
    : vault = WindowsVault(File(paths.join(
        paths.dirname(databasePath), 'backup-recovery-key.dpapi')));
  final WindowsVault vault;

  @override
  Future<String?> load() async {
    try {
      return (await vault.load())?['recoveryKey'] as String?;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(String key) =>
      vault.save({'recoveryKey': RecoveryKey.normalize(key)});

  @override
  Future<void> clear() async {
    if (await vault.file.exists()) await vault.file.delete();
  }
}

class MemoryRecoveryKeyStore implements RecoveryKeyStore {
  String? value;
  @override
  Future<String?> load() async => value;
  @override
  Future<void> save(String key) async => value = RecoveryKey.normalize(key);
  @override
  Future<void> clear() async => value = null;
}

class BackupFileInfo {
  const BackupFileInfo(this.file, this.manifest, this.bytes, {this.error});
  final File file;
  final BackupManifest? manifest;
  final int bytes;
  final String? error;
}

class BackupRunResult {
  const BackupRunResult({
    required this.ok,
    required this.message,
    this.file,
    this.mirrorFile,
    this.manifest,
  });
  final bool ok;
  final String message;
  final File? file, mirrorFile;
  final BackupManifest? manifest;
}

/// Settings keys under `settings` (opaque in the field registry):
/// `backupFolder`, `backupMirrorFolder`, `backupAuto` (bool),
/// `backupLastSuccessAt`, `backupLastId`, `backupLastError`.
class BackupService {
  BackupService(
    this.store, {
    required this.keyStore,
    BackupContainer? container,
    this.appVersion = 'unknown',
    DateTime Function()? clock,
    SecretRecordVault? trendyolVault,
  }) : container = container ?? BackupContainer(),
       _clock = clock ?? (() => DateTime.now().toUtc()),
       _trendyolVault = trendyolVault;

  final SecretRecordVault? _trendyolVault;
  /// This PC's Trendyol vault; its credentials go into owner backups
  /// encrypted with the Recovery Key (`integration_secrets.dart`).
  SecretRecordVault get trendyolVault => _trendyolVault ??
      WindowsVault(TgoWindowsVault.defaultFile(store.filePath));
  /// What the last successful backup included (shown in Yedekleme).
  IntegrationCapture? lastTrendyolCapture;

  final PosStore store;
  final RecoveryKeyStore keyStore;
  final BackupContainer container;
  final String appVersion;
  final DateTime Function() _clock;
  bool _running = false;
  Timer? _timer;

  static const autoInterval = Duration(hours: 24);

  Map get _settings => store.read().data['settings'] as Map? ?? const {};

  String get defaultFolder =>
      paths.join(paths.dirname(store.filePath), 'Yedekler');
  String get folder {
    final v = '${_settings['backupFolder'] ?? ''}'.trim();
    return v.isEmpty ? defaultFolder : v;
  }

  String? get mirrorFolder {
    final v = '${_settings['backupMirrorFolder'] ?? ''}'.trim();
    return v.isEmpty ? null : v;
  }

  bool get running => _running;

  void _setSettings(Map<String, Object?> values) {
    for (var attempt = 0; attempt < 5; attempt++) {
      final snap = store.read();
      final next = Map<String, dynamic>.from(snap.data);
      final settings = Map<String, dynamic>.from(
          next['settings'] as Map? ?? const {});
      settings.addAll(values);
      next['settings'] = settings;
      if (store.replace(next, snap.revision).ok) return;
    }
  }

  /// Saves folders after checking they are writable (never the DB folder's
  /// parent of the live file itself being overwritten).
  Future<void> configure({String? folder, String? mirror, bool? auto}) async {
    for (final dir in [folder, mirror].whereType<String>()) {
      if (dir.trim().isEmpty) continue;
      final d = Directory(dir.trim());
      await d.create(recursive: true);
      final probe = File(paths.join(d.path, '.nohut-write-test'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
    }
    _setSettings({
      if (folder != null) 'backupFolder': folder.trim(),
      if (mirror != null) 'backupMirrorFolder': mirror.trim(),
      if (auto != null) 'backupAuto': auto,
    });
  }

  /// One backup now (single-flight). Writes primary, mirrors with hash
  /// check, records history. Never throws; the result explains failures.
  Future<BackupRunResult> runNow({String reason = 'manual'}) async {
    if (_running) {
      return const BackupRunResult(ok: false,
          message: 'Bir yedekleme zaten çalışıyor.');
    }
    _running = true;
    final started = _clock();
    try {
      final key = await keyStore.load();
      if (key == null) {
        return _fail(started, reason,
            'Kurtarma anahtarı bu bilgisayarda yok. Önce anahtarı oluşturun '
            'veya girin.');
      }
      final captured = captureIntegrationSecrets(trendyolVault);
      final result = await container.create(store, Directory(folder),
          recoveryKey: key, appVersion: appVersion,
          integrations: captured.payload);
      lastTrendyolCapture = captured.trendyol;
      File? mirror;
      String? mirrorError;
      final target = mirrorFolder;
      if (target != null) {
        try {
          await Directory(target).create(recursive: true);
          final dest = File(paths.join(target, paths.basename(result.file.path)));
          final part = File('${dest.path}.part');
          await result.file.copy(part.path);
          final a = hash.sha256.convert(await result.file.readAsBytes());
          final b = hash.sha256.convert(await part.readAsBytes());
          if (a != b) throw const BackupException('Kopya özeti uyuşmuyor.');
          await part.rename(dest.path);
          mirror = dest;
        } catch (e) {
          mirrorError = 'Ayna klasörüne kopyalanamadı: $e';
        }
      }
      store.recordBackupHistory(
        backupId: result.manifest.backupId,
        createdAt: result.manifest.createdAt,
        revision: result.manifest.revision,
        fileSizeBytes: result.manifest.bytesUncompressed,
        compressedBytes: result.encryptedBytes,
        sha256: result.manifest.sha256Uncompressed,
        destination: [result.file.path, ?mirror?.path].join(' | '),
        status: mirrorError == null ? 'ok' : 'ok_mirror_failed',
        verifiedAt: _clock().toIso8601String(),
        reason: reason,
        error: mirrorError,
      );
      _setSettings({
        'backupLastSuccessAt': started.toIso8601String(),
        'backupLastId': result.manifest.backupId,
        'backupLastError': mirrorError,
      });
      return BackupRunResult(
        ok: true,
        message: '${mirrorError ?? 'Yedek oluşturuldu ve doğrulandı.'} '
            '${integrationCaptureText(captured.trendyol)}',
        file: result.file,
        mirrorFile: mirror,
        manifest: result.manifest,
      );
    } catch (e) {
      return _fail(started, reason, 'Yedekleme başarısız: $e');
    } finally {
      _running = false;
    }
  }

  BackupRunResult _fail(DateTime at, String reason, String message) {
    try {
      store.recordBackupHistory(
        backupId: 'failed-${at.microsecondsSinceEpoch}',
        createdAt: at.toIso8601String(),
        revision: store.read().revision,
        fileSizeBytes: 0,
        compressedBytes: 0,
        sha256: '',
        destination: folder,
        status: 'failed',
        reason: reason,
        error: message,
      );
      _setSettings({'backupLastError': message});
    } catch (_) {}
    return BackupRunResult(ok: false, message: message);
  }

  /// True when automatic backup is on and the last success is older than
  /// [autoInterval] (or there is none).
  bool get autoBackupDue {
    if (_settings['backupAuto'] != true) return false;
    final last = DateTime.tryParse('${_settings['backupLastSuccessAt'] ?? ''}');
    return last == null || _clock().difference(last) >= autoInterval;
  }

  /// Checks every [every]; runs at most once per [autoInterval]. A local
  /// failure never blocks sales and is shown in the Yedekleme screen.
  void startAutomatic({Duration every = const Duration(minutes: 30)}) {
    _timer?.cancel();
    Future<void> tick() async {
      if (autoBackupDue && !_running) await runNow(reason: 'auto');
    }
    unawaited(tick());
    _timer = Timer.periodic(every, (_) => unawaited(tick()));
  }

  void dispose() => _timer?.cancel();

  /// Lists `*.nohutbak` in the primary (and mirror) folder, newest first,
  /// reading only the (unverified) manifest.
  List<BackupFileInfo> listBackups() {
    final seen = <String>{};
    final out = <BackupFileInfo>[];
    for (final dir in [folder, ?mirrorFolder]) {
      final d = Directory(dir);
      if (!d.existsSync()) continue;
      for (final f in d.listSync().whereType<File>()) {
        if (!f.path.endsWith(backupExtension)) continue;
        final name = paths.basename(f.path);
        if (!seen.add(name)) continue;
        try {
          out.add(BackupFileInfo(
              f, BackupContainer.readUnverifiedManifest(f), f.lengthSync()));
        } catch (e) {
          out.add(BackupFileInfo(f, null, f.lengthSync(), error: '$e'));
        }
      }
    }
    out.sort((a, b) =>
        paths.basename(b.file.path).compareTo(paths.basename(a.file.path)));
    return out;
  }
}
