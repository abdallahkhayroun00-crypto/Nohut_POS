# Encrypted Backup & Restore (Phase 1)

Spec: V5.1 §12.1, §15 Phase 1, §16 suite 7.

## PR-02: container and staged restore

Code: `flutter_desktop/lib/backup_container.dart`. Tests: `test/backup_container_test.dart`.

### File format

The file has the extension `.nohutbak`, laid out as:

`"NOHUTBK1" | u32 header length | header JSON | AES-256-GCM ciphertext | 16-byte tag`

| Part | Content | Notes |
|---|---|---|
| Plaintext | gzip of a `VACUUM INTO` snapshot of the whole SQLite file: every table, consistent while WAL is active. | |
| Key | Argon2id (64 MiB, t=3, p=1; parameters stored in the header) of the owner's **Recovery Key**: 52 base32 characters, 260 random bits, shown as 13 groups of 4. | The key is independent of Windows/DPAPI, so the backup can be restored on any PC. Headers asking for weaker parameters than the OWASP minimum are rejected. |
| Header | Includes the manifest: backup ID, schema version, revision, time, app version, row counts per table, order count, size and SHA-256 of the uncompressed database. | The header is the GCM additional authenticated data (AAD), so editing it makes decryption fail. |
| Verification | Every backup is decrypted again from disk immediately after writing. | Then the SHA-256 is checked, followed by `PRAGMA integrity_check`. |
| Temporary copy | The plaintext snapshot exists only in a private temp folder. | Deleted in `finally`. |

### Staged restore

1. `RestoreManager.stage` runs after the owner confirms. It decrypts, verifies and runs the integrity check into `<db>.restore-staged`, then writes `<db>.restore-pending.json`. The live database is not changed.
2. `RestoreManager.applyPending` runs at the next start, **before** the database opens:
   - The current database (and its WAL/SHM files) is moved to `<db>.pre-restore-<UTC>`. This is a safety copy and is never deleted automatically.
   - The staged file is put in place.
   - Waiting print jobs become `Kontrol gerekli` and Trendyol tickets waiting to print are marked the same way, so nothing prints by itself.
   - `settings.restoredAt`, `restoredFromBackupId` and a new `autoPrintEnabledAt` are recorded.
   - Any failure rolls back to the original files.

### Tested

| Case | Result |
|---|---|
| Recovery key format and normalization | Passes |
| No plaintext business or customer text in the file | Passes |
| Wrong key | Rejected |
| One flipped ciphertext byte | Rejected |
| Edited manifest (revision) | Rejected |
| Foreign or junk file | Rejected |
| **Restore on a second "machine"** (separate folder; only the backup file travels) | Identical order count, paid totals and Trendyol orders; revision +1; **zero prints** from the receipt printer pump |
| Restore over an existing database | Safety copy kept |
| Corrupted staged file | Rolls back with the original intact |
| Cancelling a staged restore | Changes nothing |

### Still open (spec gate)

The Phase 1 gate requires a physical restore on a **second clean Windows machine/profile**. That needs the owner's PC and is not done in CI.

Cloud epochs and anti-replay across restore belong to Phase 2: command receipts and `deleted_requests` are restored with the database.

## PR-03: destinations, history, automatic backup, screen

Code: `lib/backup_service.dart`, `lib/backup_ui.dart`, the `backup_history` table in `PosStore`, and wiring in `main.dart`. Tests: `test/backup_service_test.dart`, `test/backup_ui_test.dart`.

**Ayarlar → Yedekleme ve Geri Yükleme (Windows):**
- Status tiles show the last backup, the Recovery Key on this PC, automatic backup state and the number of backups.
- **Kurtarma Anahtarı Oluştur:**
  1. The key is shown once.
  2. The owner retypes the last group to confirm.
  3. The key is stored with DPAPI for automatic backups.

  **Var Olan Anahtarı Gir** is for a new PC.
- **Şimdi Yedekle** writes to the primary folder (default: `Yedekler` next to the database).
- The optional **ayna klasörü** (USB, NAS, or a Google Drive / OneDrive *synced* folder; 0 TL, no OAuth) gets a copy that is SHA-256-compared before it counts.
- **Otomatik Yedekleme:** once every 24 h while the program is open, checked every 30 minutes.
- **Doğrula** decrypts a backup and runs the integrity check.
- **Geri Yükle (owner only):**
  1. Enter the Recovery Key, type `GERİ YÜKLE` and the name of the person approving.
  2. Confirm the dialog that shows date, revision and order count.
  3. The restore is staged and applied on restart. A staged restore can be cancelled.
- Backup history comes from `backup_history`.
- Nothing is ever deleted automatically.

**Safety notes:**
- The old unencrypted "SQLite Yedeği" buttons were removed (spec §12.1).
- The application applies a staged restore at startup, **before** opening the database, and shows the outcome.

**Tested:**
| Case | Result |
|---|---|
| No key | Nothing written, failure logged |
| Primary + verified mirror | Mirror bytes identical; mirror copy decrypts |
| Broken mirror | Primary kept, status `ok_mirror_failed` |
| Automatic backup | Runs once per 24 h and only when enabled |
| Second run while one is running | Refused (single flight) |
| History | Kept across runs |
| UI | Disabled without a key; lists, verifies and restores with a key |

**Owner-only rule:** per-user permission checks (`backup.restore` is owner-only) arrive with Phase 3 accounts. Until then the Recovery Key plus typed confirmation is the gate.

## Portable Trendyol Go credentials (owner request, #44 7230877753)

The Trendyol seller ID, e-mail, API key and API secret live in
`%APPDATA%\NohutFalafel\trendyol-go-credentials.dpapi`, wrapped by the
original Windows user's DPAPI. A replacement PC cannot read that file, so the
owner backup now carries the credentials itself.

- **Format 2** (`lib/backup_container.dart`): only when this PC's Trendyol
  vault is readable and valid. A second AES-256-GCM box follows the database
  box; same Argon2id key from the Recovery Key, its own nonce, AAD = header +
  `|integrations`. The header records `sections.integrations.{nonce,
  cipherLength}`. Without credentials the backup stays format 1 (older apps
  keep restoring it); format 1 backups still restore unchanged.
- **Allowlist** (`lib/integration_secrets.dart`): `{schema:1, trendyolGo:
  {supplierId, apiKey, apiSecret, email}}`. Anything else is refused at
  restore. The QR GitHub App key, the recovery key and other vaults are never
  included.
- **Never in SQLite, sync, projections, logs, exports or client APIs.** The
  secret goes vault → encrypted backup box → (staging) a DPAPI file of the new
  PC (`<db>.restore-integrations.dpapi`) → the new PC's Trendyol vault.
- **Restore** (`RestoreManager`): staging decrypts and validates both boxes;
  wrong key or any tampering stages nothing. After the database is applied,
  credentials are written to this PC's vault:
  - no vault → written (*restored*);
  - same credentials → *alreadyPresent*;
  - different working credentials → kept, backup's not written (*keptExisting*);
  - unreadable vault (old profile's DPAPI file) → moved to
    `….unreadable-<stamp>`, then written;
  - a write failure keeps the pending record and retries at the next start;
    the database restore is not undone.
- **No replays:** the first Trendyol poll after a restore is a baseline
  (`tgoSyncInfo.lastSync` cleared): orders since the backup are fetched, but no
  new-order alerts or kitchen tickets are raised. The poll is read-only and
  doubles as connection verification.
- **UI:** Yedekleme shows *Trendyol Bağlantısı: Yedekte (şifreli) / Kayıtlı
  değil / Kasa okunamadı*; the restore confirmation says credentials will be
  moved; the restart message says what happened.
- **Tests:** `test/integration_secrets_test.dart` (8, fake per-profile vault
  that fails like DPAPI on another user/PC). **Owner physical gate:** restore a
  real backup on a second Windows PC/user (QA D-47).
