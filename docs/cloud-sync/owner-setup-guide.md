# Owner Setup Guide: steps only the owner can do

Spec V5.1 §15 Phase 7 and §18.4. Everything here is **free (0 TL)** and needs no credit card. Never paste any secret into GitHub issues, chat or the repository; use GitHub → *Settings → Secrets and variables → Actions* only.

Nothing in this guide is done on the restaurant computer. There the owner only runs the Windows Setup and clicks through the Turkish screens.

## 1. Android signing key (needed so app updates install over old ones)

On your own computer, once (Java's `keytool` comes with Android Studio or any JDK):

```bash
keytool -genkeypair -v -keystore nohut-release.jks -alias nohut -keyalg RSA -keysize 4096 -validity 10000
```

```bash
base64 -w0 nohut-release.jks > nohut-release.jks.b64
```

Add these four repository secrets:

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | content of `nohut-release.jks.b64` |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | `nohut` |
| `ANDROID_KEY_PASSWORD` | key password |

Keep `nohut-release.jks` and its passwords offline, for example on a USB stick in a safe. **If they are lost, the apps can never be updated in place again.**

## 2. Release files (Setup.exe + 2 APKs)

After the secrets exist, push a version tag (or run *Actions → Publish Nohut release → Run workflow* with a tag such as `v2.0.0`). The release workflow builds and tests everything and attaches these files to *Releases*:
- `Nohut-POS-Setup-vX.exe`
- `Nohut-Personel-vX.apk`
- `Nohut-Yonetici-vX.apk`
- `SHA256SUMS.txt`

## 3. Cloudflare Pages: two permanent PWA URLs (Phase 4)

1. Create a free Cloudflare account (no card is required for Pages).
2. *Workers & Pages → Create → Pages → Connect to Git*, then authorize **only** this repository.
3. Create two projects from the same repository:
   - `nohut-personel`: build command and output folder as given in the Phase 4 PR.
   - `nohut-yonetici`: same repository, different build target.
4. Production branch: `main`. Preview deployments: on.

Result: `https://nohut-personel.pages.dev` and `https://nohut-yonetici.pages.dev`. Custom domains are optional.

GitHub Pages is not used, because of its commercial-use restriction.

## 4. Supabase: cloud database, login and permissions (Phase 2–3)

> **KVKK gate (spec §12.2):** create the project only for **synthetic** testing until a qualified legal review approves transferring personal data (employees, payroll, customers) abroad. Nohut does not upload real data before you confirm this review in writing.

1. Create a free Supabase account and a project (choose the EU region closest to Türkiye).
2. Turn on MFA for the owner account.
3. Do not create any API keys in the apps yourself. The Phase 2 PR contains the SQL migrations, RLS policies and the exact list of secrets to add as GitHub secrets.
4. Free plan notes: the project **pauses after 7 days without activity**; the POS shows a warning and continues offline. 500 MB database quota. No automatic backups (Nohut's own encrypted backups cover this).

## 5. QR menu repository audit

Give this repository's automation read access to `nohutfalafel/qr-menu`, or approve adding it to a session, so the audit in spec §21.6 can finish.

## 6. First installation at the restaurant (no terminal, no SQL)

1. Before installing, close the old program. The new version opens the existing database in place; its format is unchanged by Phase 1.
2. Install `Nohut-POS-Setup-vX.exe` and open the program.
3. Go to **Ayarlar → Yedekleme ve Geri Yükleme → Kurtarma Anahtarı Oluştur**. Write the key on paper and keep it safe. **Without it, backups cannot be opened.**
4. Choose a **mirror folder** (a USB stick or a Google Drive / OneDrive folder), press **Şimdi Yedekle**, then press **Doğrula** on the new backup.
5. Turn on **Otomatik Yedekleme**.
6. Only after that, continue using the POS.

**İlk Senkronizasyonu Başlat** becomes available only after Phase 2, the Supabase setup and the KVKK confirmation.
