/// Portable integration credentials for backup and restore (owner request on
/// #44, 7230877753).
///
/// The Trendyol Go seller ID, e-mail, API key and API secret live in a DPAPI
/// file bound to the original Windows user. A replacement PC cannot read it.
/// So an owner backup carries them in their own AES-GCM section, encrypted
/// with the same Recovery Key as the database (see `backup_container.dart`),
/// and a restore re-wraps them into the new PC's DPAPI.
///
/// Rules:
/// * Only the allowlisted Trendyol fields. Never the QR GitHub App key, the
///   recovery key, finance pairing or any other secret.
/// * Never in SQLite, sync, projections, logs, exports or client APIs.
/// * A working vault on the new PC is never silently overwritten.
/// * An unreadable vault is set aside, not deleted.
library;

import 'trendyol_go_readonly.dart';
import 'windows_vault.dart';

const integrationSecretsSchema = 1;
const _tgoFields = ['supplierId', 'apiKey', 'apiSecret', 'email'];

/// What a backup could include from this PC.
enum IntegrationCapture { included, notConfigured, unreadable }

/// Result of putting restored credentials into this PC's vault.
enum IntegrationRestore {
  /// Nothing in the backup for this integration.
  none,
  /// Written into this PC's vault.
  restored,
  /// This PC already holds the same credentials.
  alreadyPresent,
  /// This PC holds different, working credentials; they were kept.
  keptExisting,
  /// The backup's record was malformed; nothing was written.
  invalid,
  /// Writing to this PC's vault failed; the pending record is kept.
  failed,
}

class CapturedSecrets {
  const CapturedSecrets(this.payload, this.trendyol);
  /// Null when there is nothing to include.
  final Map<String, dynamic>? payload;
  final IntegrationCapture trendyol;
}

/// Reads this PC's Trendyol vault for an owner backup.
CapturedSecrets captureIntegrationSecrets(SecretRecordVault trendyol) {
  if (!trendyol.exists) {
    return const CapturedSecrets(null, IntegrationCapture.notConfigured);
  }
  final TgoCredentials? creds;
  try {
    creds = TgoWindowsVault.fromFields(trendyol.read());
  } catch (_) {
    return const CapturedSecrets(null, IntegrationCapture.unreadable);
  }
  if (creds == null || !creds.valid) {
    return const CapturedSecrets(null, IntegrationCapture.notConfigured);
  }
  return CapturedSecrets({
    'schema': integrationSecretsSchema,
    'trendyolGo': TgoWindowsVault.toFields(creds),
  }, IntegrationCapture.included);
}

/// Validates a decrypted section; throws [FormatException] on anything
/// outside the allowlist so a crafted backup cannot plant extra secrets.
Map<String, dynamic> checkIntegrationPayload(Object? value) {
  if (value is! Map || value['schema'] != integrationSecretsSchema) {
    throw const FormatException('Entegrasyon bölümü desteklenmiyor.');
  }
  final extra = value.keys.where((k) => k != 'schema' && k != 'trendyolGo');
  if (extra.isNotEmpty) {
    throw const FormatException('Entegrasyon bölümünde bilinmeyen alan var.');
  }
  final tgo = value['trendyolGo'];
  if (tgo != null) {
    if (tgo is! Map ||
        tgo.keys.toSet().difference(_tgoFields.toSet()).isNotEmpty ||
        !_tgoFields.every((k) => tgo[k] is String)) {
      throw const FormatException('Trendyol kaydı geçersiz.');
    }
    final c = TgoWindowsVault.fromFields(tgo.cast<String, dynamic>())!;
    if (!c.valid) throw const FormatException('Trendyol kaydı geçersiz.');
  }
  return value.cast<String, dynamic>();
}

/// Puts restored Trendyol credentials into this PC's vault.
IntegrationRestore restoreTrendyol(
  Map<String, dynamic> payload,
  SecretRecordVault target, {
  required String stamp,
}) {
  final Map<String, dynamic> checked;
  try {
    checked = checkIntegrationPayload(payload);
  } on FormatException {
    return IntegrationRestore.invalid;
  }
  final tgo = checked['trendyolGo'];
  if (tgo == null) return IntegrationRestore.none;
  final incoming = TgoWindowsVault.fromFields((tgo as Map).cast<String, dynamic>())!;
  if (target.exists) {
    TgoCredentials? current;
    var readable = true;
    try {
      current = TgoWindowsVault.fromFields(target.read());
    } catch (_) {
      readable = false;
    }
    if (readable && current != null && current.valid) {
      final same = current.supplierId == incoming.supplierId &&
          current.email == incoming.email &&
          current.apiKey == incoming.apiKey &&
          current.apiSecret == incoming.apiSecret;
      return same ? IntegrationRestore.alreadyPresent : IntegrationRestore.keptExisting;
    }
    // Unreadable here (another user's DPAPI) or empty: keep the file aside.
    try {
      target.setAside('unreadable-$stamp');
    } catch (_) {
      return IntegrationRestore.failed;
    }
  }
  try {
    target.write(TgoWindowsVault.toFields(incoming));
  } catch (_) {
    return IntegrationRestore.failed;
  }
  return IntegrationRestore.restored;
}

String integrationRestoreText(IntegrationRestore r) => switch (r) {
  IntegrationRestore.none => '',
  IntegrationRestore.restored =>
    'Trendyol bağlantı bilgileri bu bilgisayara aktarıldı; bağlantı salt okunur olarak doğrulanıyor.',
  IntegrationRestore.alreadyPresent =>
    'Trendyol bağlantı bilgileri bu bilgisayarda zaten aynıydı.',
  IntegrationRestore.keptExisting =>
    'Bu bilgisayarda farklı ve çalışan Trendyol bilgileri vardı; korundu, yedekteki bilgiler yazılmadı.',
  IntegrationRestore.invalid =>
    'Yedekteki Trendyol kaydı geçersizdi; hiçbir şey yazılmadı.',
  IntegrationRestore.failed =>
    'Trendyol bilgileri bu bilgisayarın güvenli kasasına yazılamadı; bir sonraki açılışta yeniden denenecek.',
};

String integrationCaptureText(IntegrationCapture c) => switch (c) {
  IntegrationCapture.included => 'Trendyol bağlantısı yedeğe şifreli olarak dahil edildi.',
  IntegrationCapture.notConfigured => 'Trendyol bağlantısı kayıtlı değil; yedekte yok.',
  IntegrationCapture.unreadable =>
    'Trendyol güvenli kasası bu Windows kullanıcısıyla okunamadı; yedekte yok.',
};
