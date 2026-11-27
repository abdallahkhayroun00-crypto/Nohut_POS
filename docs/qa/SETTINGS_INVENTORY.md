# Settings inventory (Q2, step 2)

Every setting the apps have today, with where it lives and whether it may sync.
This is the starting point for the Ayarlar audit. It lists only settings that exist in the code.
"Audit" says what has been checked end to end so far. "Not yet audited" means only that the code was read.

Sources:
- `flutter_desktop/lib/simple_settings.dart`, `accounts_ui.dart`, `qr_publisher_settings.dart`, `local_accounts.dart`, `sync_registry.dart`
- `flutter_personel/lib/*`
- `pwa/src/*`
- `assets/staff.html`, `assets/yonetici.html`

Scope:
- **Restaurant** means the setting lives in `state.settings` in the POS SQLite store.
- **Device** means it belongs to one computer or phone.
- **Account** means it belongs to one user.

## Windows POS

| Ayarlar page | Setting (key) | Scope | Default | Storage | Sync | Audit |
|---|---|---|---|---|---|---|
| Yazıcı & Fiş | Printer (`printerName`), mode (`printerMode`), transport (`receiptTransport`) | Device | XP-237B profile, Windows · Fiş görseli | `state.settings` | Never (device key) | Test print and uncertain-print guard are covered by tests. A spooler "accepted" status does not prove paper came out. |
| Yazıcı & Fiş | Paper width / printable width / margins / offset / logo size (`paperWidthMm`, `printableWidthMm`, `receiptMarginMm`, `receiptSidePaddingMm`, `receiptOffsetMm`, `receiptLogoMm`) | Device | 57 / 48 mm, 3 mm sides | `state.settings` | Never | Not yet audited |
| Yazıcı & Fiş | Auto print (`autoPrint`, `autoPrintEnabledAt`), receipt policy (`receiptPolicy`, `receiptPolicyVersion`) | Restaurant | Off | `state.settings` | Business setting | Not yet audited |
| Bildirimler & Sesler | Order sounds (`soundAlerts`, `onlineOrderSound`, `reviewNotificationSound`) | Device | On | `state.settings` | Business setting (candidate to make device-only) | Not yet audited |
| Bildirimler & Sesler | Gün Sonu Raporu time (`dailyReport`), payroll reminders (`payrollReminders`) | Restaurant | 21:30, on | `state.settings` | Business setting | Covered by `daily_report_test` and `payroll_test` (reminders) |
| Entegrasyonlar | Trendyol Go credentials | Restaurant (secret) | None | Windows vault (DPAPI) | **Never** | Masked in the UI. The status reads "Bağlı · Salt okunur" only after a successful sync. |
| Entegrasyonlar | Yemeksepeti, Migros | — | — | — | — | No live API. Shown as "bağlantı yok". No working control is presented. |
| Entegrasyonlar | Google Business Profile (OAuth) | Restaurant (secret) | Not connected | Windows vault | **Never** | Not yet audited |
| Menü & QR | QR auto sync (`qrAutoSync`), publisher URL/token | Restaurant / secret token | On | `state.settings` plus vault for the token | Token never | Public QR menu is unchanged by this work |
| Kullanıcılar & Güvenlik | Accounts, roles, grants, devices, sessions | Account | Owner created at first sign-in | Auth DB (`local_accounts.dart`) | Waits for A2 | Covered by `lan_auth_gate_test` and `local_accounts` tests |
| Kullanıcılar & Güvenlik | "Bireysel giriş zorunlu" (`lan_login_required`) | Restaurant | Off until switched on | Auth DB setting | Not synced | The work API uses `forceRequired`, so staff hours and pay always need a session. |
| Kullanıcılar & Güvenlik | "Yönetici uygulamasında finans verileri" over HTTP (`local_finance_http`) | Restaurant | Off | Auth DB setting | Not synced | When off, finance endpoints answer `https_required`. Covered by tests. |
| Kullanıcılar & Güvenlik | Idle lock (`idle_lock_minutes`) | Device | — | Auth DB setting | Not synced | Not yet audited |
| Personel | Employee profile, pay type, rate history (`payHistory`), `payrollEligible` | Restaurant | Owner excluded from payroll | `state.employees` | Synced (Codex projection pending, O-03) | Covered by `payroll_test` |
| Telefon Bağlantısı | Wi-Fi IPv4 choice, pairing QR, one-time PIN | Device | First private IPv4 | Memory / auth DB | Never | Not yet audited |
| Yedekleme & Geri Yükleme | Backup folder, mirror, auto backup (`backupFolder`, `backupMirrorFolder`, `backupAuto`) | Device | — | `state.settings` | **Never** (Windows-only administration) | Covered by the backup tests |
| Finans (not in Ayarlar) | Platform deduction rates (`platformDeductionRates`) | Restaurant | — | `state.settings` | Business setting | Not yet audited |
| Market Fiyat Takibi (not in Ayarlar) | Market price tracking (`priceAlerts`, location, refresh) | Restaurant | Off | `state.marketPrices.settings` | Business setting | Not yet audited |

There is no Bulut & Senkronizasyon page yet. It will be added when Codex's sync UI exists.

## Android Personel (native)

| Place | Setting | Scope | Storage | Sync | Audit |
|---|---|---|---|---|---|
| Hesabım | Pairing (server id, host, session) | Device | Secure storage | Never | Covered by `session_login_test` |
| Daha Fazla › Çalışmam | Mesailerim, Vardiyalarım, Maaş & Avans, Giderler (when drafts exist) | Account | Server session | — | Links only; covered by `personel_test` |
| Hesabım | Theme | Device | Follows the system light or dark setting | — | Rendered in both modes |
| Hesabım | Sign out / forget pairing | Device | Secure storage | — | Not yet audited |

## Android Yönetici (native)

| Place | Setting | Scope | Storage | Sync | Audit |
|---|---|---|---|---|---|
| Ayarlar › Hesap | Owner name and role (from the Windows pairing) | Account | Secure storage | Never | Read-only; rendered in light and dark |
| Ayarlar › Bağlantı | Windows host and status, "Finansı Yenile" with last sync time | Device | Secure storage / memory | Never | Rendered; the sync button calls the real finance sync |
| Ayarlar › Görünüm | Theme | Device | Follows the system light or dark setting | — | Rendered in both modes |
| Ayarlar › Windows’ta yönetilenler | Printer, integrations and API keys, users/grants/devices, backup and cloud sync | — | Windows only | — | Listed as information only, with no control (no dead switch) |
| Ayarlar › Bu cihaz | Owner pairing key (`owner_pairing_v1`), cached overviews, "Yönetim Bağlantısını Unut" | Device | Clears secure storage and keeps pending finance writes | Never | Confirm dialog; not yet tested on a device |

## Browser apps and PWAs

| App | Setting | Scope | Storage | Audit |
|---|---|---|---|---|
| Personel / Yönetici (LAN) | Session cookie `nohut_lan`, 5-digit PIN unlock | Account and device | Server session | Covered by `lan_auth_gate_test` |
| Personel / Yönetici PWA | Profile, 5-digit PIN (`set_pin`) | Account | Supabase `nohut_private` | Covered by `auth_api_test.sql` |
| All browser apps | Theme | Device | Follows the phone's light or dark setting | Rendered in both modes (D-29) |

Browser PIN change (Personel and Yönetici LAN pages, "PIN Değiştir"): the server now asks for the account password to replace an existing PIN, except in the PIN step within 5 minutes of a password sign-in. A password that is sent is always checked, wrong ones count toward the login lockout, and the reply is 403 so the session stays. Covered by `local_accounts_test` and `lan_auth_gate_test`, plus a Playwright run of both pages (wrong password refused, right one saved, Vazgeç closes).

## Rules carried into the redesign

- Secrets (API keys, OAuth tokens, finance keys, the QR publisher token) are masked and never synced.
- Printer and paper settings and backup folders stay on their own device.
- A setting is shown only if it really persists, or if it shows the real failure.
- Cash and card *recording* is kept separate from actual terminal connectivity.
- Payroll payments are records of payments made outside the POS. Nothing here moves money.
- Bulut & Senkronizasyon and Yedekleme are administered on Windows only, including by the owner on mobile.
