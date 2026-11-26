# NOHUT POS 2.0 — Master Implementation Specification (V5.1)

**Document Version:** 5.1 (V5 preserved; V5.1 adds two separate mobile applications with three shared owner-grantable sections and a per-operation permission model — see Section 20, which is binding and supersedes conflicting text)  
**Target Audience:** Claude Code / Implementation Engineer  
**Status:** Architecture specification for staged, branch-isolated implementation; **not** yet a deployed production cloud service  
**Review evidence:** V2 and V3 were compared as supplied; earlier connector inspection confirmed the PR #27 first-ticket defect at `fcc6ffc`. Provider corrections use official sources checked on 2026-11-27. Repository baseline below is inherited from Gemini’s report, not a new full repository audit. Actual production database, physical devices, legal arrangements and deployment were not inspected. Treat assumptions as gates, not verified implementation.
**V5 owner clarification:** Do not create or expand a customer CRM/directory for Trendyol or other delivery-platform customers. Customer details come from authorized platform APIs for operational use only. Keep all necessary and permitted business history, with explicit data-minimization exceptions. Retain minimal local Gel-Al pickup details where needed; preserve any existing open-account obligations. Section 19 is binding and supersedes conflicting inherited examples. No new production measurement, repository audit or API-policy verification was performed for this revision.
**V5.1 owner update (2026-11-27):** Maintain two separate applications — `Nohut Personel` and `Nohut Yönetici` — each as a native Flutter Android APK **and** a dedicated iPhone PWA URL. `Menü & Kampanya Yönetimi`, `Bulut & Senkronizasyon` and `Yedekleme & Geri Yükleme` exist in BOTH applications on BOTH platforms; the owner grants/revokes each operation individually; sensitive actions require explicit authorization, owner confirmation and server-side enforcement. No duplicated business logic. Section 20.  
**Primary UI Language:** Turkish (Specification written in English for engineering precision)  
**Cost Target:** 0 TL/month recurring cost within verified free-tier limits (no paid plan or credit-card-gated overage service without explicit owner approval)  
**Explicit Scope Exclusions:** **Nohut AI**, AI analytics endpoints, LLM integrations, and AI UI menus are strictly excluded from this release. Do not add AI dependencies, routes, or placeholders.

---

## 1. Mission, Verified Repository Baseline, and Audit Constraints

### 1.1 Mission
Upgrade the existing Nohut Falafel Windows restaurant POS into a resilient, offline-first, multi-device restaurant management platform while preserving all working restaurant operations, Turkish UI conventions, Xprinter XP-237B thermal receipt printing, public QR menu publishing, and full historical data. Deliver:
1. Independent encrypted backup and verified cross-machine disaster recovery.
2. Complete, lossless synchronization of all legitimate business data (historical and live) from local SQLite to a private cloud projection.
3. Individual employee authentication (`Kullanıcı Adı` + `Şifre` + trusted-device 6-digit `PIN`) with server-side RBAC and Row-Level Security (RLS).
4. Upgraded native Android staff app (`flutter_personel` APK) and a dedicated lightweight installable iPhone PWA (`Nohut Personel` + role-gated `Nohut Yönetici` dashboard) hosted over HTTPS on Cloudflare Pages.
5. Safe, idempotent remote commands routed through the Windows POS transaction authority with idempotent business mutations and explicit uncertain physical/external side-effect handling (no unqualified exactly-once printing guarantee).

### 1.2 Verified Repository Baseline (Inspected November 27, 2026)
Both repositories were verified as **Public** during the architecture review:

| Repository / Tracker | Verified URL | Verified State (Nov 27, 2026) |
|---|---|---|
| POS Repository | [brand-management-proposal](https://github.com/abdallahkhayroun00-crypto/brand-management-proposal) | Public; default branch `main`; 25 branches, 870 commits; HEAD `300e6754cfbb1d6807fc9e116635939a7f760c0d` (PR #26 merged: *"Finans: fixed expenses keep history, no future-dated expenses, clearer month and fixed list"*) |
| QR Menu Repository | [nohutfalafel/qr-menu](https://github.com/nohutfalafel/qr-menu) | Public; default branch `main`; 10 branches, 132 commits; HEAD `8242741` |
| Backup & Sync Issue | [Issue #28](https://github.com/abdallahkhayroun00-crypto/brand-management-proposal/issues/28) | Open (Backlog), 0 comments — *"Cloud Sync phase 1: encrypted full-state backup and safe recovery"* |
| Staff & Mobile Issue | [Issue #29](https://github.com/abdallahkhayroun00-crypto/brand-management-proposal/issues/29) | Open (Backlog), 0 comments — *"Cloud Sync phase 2: unified staff accounts, Android app and iPhone PWA"* (depends on #28) |
| Receipt Refactor PR | [PR #27](https://github.com/abdallahkhayroun00-crypto/brand-management-proposal/pull/27) | **Open Draft** (`claude/inspiring-mccarthy-t5ywuv`, commit `fcc6ffc`, 17 files, +565/-136, 2/2 checks passing) — *"Receipts: one Sipariş Fişi + new print layout"* |

**V5.1 baseline correction (Phase 0, verified 2026-11-27):** PR #27 was merged into `main` (`cbbb130`), followed by PR #30 (`dbd809b`: receipt margins, 57 mm paper, order slips print again). The first Gel-Al receipt defect (§11.1) was still present on `main` after #27 and is fixed in PR-01 with tests. PRs #15, #16 and #17 are fully contained in `main` (0 commits ahead); #2, #14 and #19 contain unmerged commits — see `docs/cloud-sync/data-inventory.md` §8.

**Other Open PRs requiring reconciliation before editing (do not overwrite or assume merged):**
- PR #19 (*Windows Ctrl+P-style receipt dialog*), PR #17 (*Gel-Al müşteri rehberi, açık hesaplar, kurye ve yönetim analitiği*), PR #16 (*Online Alarm 2.0, reviews cache, integration safety and reporting*), PR #15 (*Windows 0.6.7: online orders, reports and Google Business Profile*), PR #14 (*Trendyol Go read-only live orders, secure Ayarlar*), PR #2 (*Draft: Native Windows POS staff sessions*).

**Verified Existing Implementation vs. Unfinished vs. Proposed:**
- **Existing on `main`:**
  - `flutter_desktop/lib/pos_store.dart`: Local SQLite database at `%APPDATA%\NohutFalafel\nohut-pos.sqlite3` (overridable via `NOHUT_POS_DATABASE`), pragmas `journal_mode=WAL`, `busy_timeout=15000`, `synchronous=FULL`. Contains exactly **3 tables**: `state_snapshot` (`id=1`, `revision`, `payload TEXT`, `updated_at`), `command_receipts` (`request_id`, `payload`, `result`), and `deleted_requests` (`request_id`). Includes `backup(String destination)` using `VACUUM INTO`.
  - `flutter_desktop/lib/lan_server.dart` (569 lines): `PosLanServer` on port `8787`, serving `staffHtml`, delegating to `staff_commands.dart`, `mobile_pairing.dart`, `finance_sync_server.dart`, and Trendyol Go `platformAction` (`Kabul Et` / `Hazır`).
  - `flutter_desktop/lib/finance_sync_server.dart` (504 lines): Existing DPAPI-protected (`WindowsVault`, sidecar `<db>.finance-sync.dpapi`) financial sync capability with `FinanceWire.createKey()`, owner key rotation, and active-owner enforcement (`managementOwnerName`).
  - `flutter_desktop/lib/printer_management.dart`, `receipt_layout.dart`, `receipt_preview.dart`, `receipt_printer.dart`: Xprinter XP-237B thermal receipt printing subsystem.
  - `flutter_personel/`: Existing native Flutter Android app with `ANDROID_SYNC_ROADMAP.md` and shared core package `packages/nohut_core/` (PR #22 merged: responsive phones/tablets, shared Flutter finance core, offline expense drafts).
  - `.github/workflows/`: Existing CI pipelines including `flutter-desktop-windows.yml`, `flutter-personel-android.yml`, `flutter-yonetim-android.yml`, and `pos-logic.yml`.
  - `nohutfalafel/qr-menu`: `cms/pos-managed-status.json` (`{"schemaVersion": 1, "enabled": true}`), `cms/pos-managed-menu.json` (46.6 KB, multilingual `tr`/`en`/`ar`), `cms/menu-prices.json` (4.02 KB), `cms/campaigns.json`, `cms/catalog-v1.json`, `cms/product-ids.json`, and `services/qr-publisher`.
- **Unfinished / In-Flight:** PR #27 (draft receipt consolidation; first Gel-Al receipt defect confirmed at the inspected commit, not fixed by that revision) and open PRs #2, #14, #15, #16, #17, #19.
- **Proposed (Not Yet Implemented):** Encrypted cloud backup/restore (Issue #28), transactional outbox & incremental cloud sync, first-sync wizard, Supabase schema/RLS/Auth, dedicated iPhone PWA, and unified remote manager dashboard (Issue #29).

### 1.3 Mandatory Phase 0 Verification Scope (Files Not Line-Audited During Review)
During the V3 architecture review, automated read access was capped before opening the full text of the following files. Claude Code **must** inspect these files line-by-line in Phase 0 before writing production code:
- `flutter_desktop/lib/pos_logic.dart` and `flutter_desktop/lib/operations.dart` (complete `state_snapshot.payload` key inventory and `newLocalOrder` / `queueLocalKitchen` execution order on `main` vs. PR #27).
- `flutter_desktop/lib/staff_commands.dart`, `mobile_pairing.dart`, `windows_vault.dart`, `partner_credentials.dart`, and `receipt_printer.dart`.
- `flutter_personel/lib/` and `flutter_personel/ANDROID_SYNC_ROADMAP.md`.
- `flutter_desktop/assets/staff.html` and `packages/nohut_core/lib/`.
- `nohutfalafel/qr-menu` client scripts (`cms-live.js`, `cms-pos-live.js`, `menu.js`, `campaigns-data.js`).

**Security Invariant:** Both GitHub repositories are public. Never commit production SQLite files, real customer data, employee payroll, API keys, service-role tokens, DPAPI blobs, or backup recovery keys to either repository, git history, CI logs, or build artifacts.

---

## 2. Non-Negotiable Architecture Principles & V2→V5 Decisions

1. **Single-Writer Local Transactional Authority:** Windows POS SQLite remains the sole authoritative transactional database. Cloud PostgreSQL is a verified, versioned projection + authenticated command inbox. Never run SQLite and PostgreSQL as dual writable masters.
2. **Eliminate the Monolithic JSON Write-Amplification Risk (New in V3):** Because `pos_store.dart` currently stores all business state inside a single `state_snapshot.payload` JSON row, rewriting the growing JSON blob on each committed mutation creates a measurable performance risk. No specific order-count cliff has been measured. This release requires:
   - **Immediate (Phase 2):** Add a local transactional `sync_outbox` table populated inside the same SQLite transaction as every state mutation via deterministic entity diffing / domain event emission (avoiding a risky big-bang UI rewrite while enabling true incremental sync).
   - **Conditional local normalization/compaction (Phase 6 or earlier if benchmark requires):** Migrate suitable historical entities to dedicated local tables only after auditing all reads, writes, reports, customer balances, corrections and reprints. Keep records accessible through a unified repository. Use reversible migrations, exact financial and history parity tests. The 90-day / 5 MB figures are candidate benchmark targets, not retention or deletion rules.
3. **Complete Business Data Coverage With Zero Silent Exclusions:** Every persisted business entity, historical record, tombstone, and command receipt must be inventoried; synchronize the complete permitted business representation, not redundant copies or unnecessary third-party personal data. Apply explicit exceptions in Sections 4.3 and 19.
4. **Honest Platform Capabilities (iOS Safari & Free Tiers):** Never promise capabilities iOS Safari blocks (such as HTTPS PWA fetching an unencrypted HTTP LAN API without verified browser support and secure transport or guaranteed background polling) or unlimited free cloud storage.
5. **Turkish KVKK Article 9 Compliance Gate (New in V3):** No real personal data may be transferred to unapproved infrastructure until the restaurant owner completes the applicable legal and provider review (see Section 12.2). Keep the cloud database schema standard PostgreSQL and behind a repository adapter so domestic Türkiye hosting remains a migration option subject to adapter, authentication and security testing.
6. **Zero Recurring Cost Discipline:** Target 0 TL/month with hard quota guards (70% / 85% / 95% warnings), zero silent auto-upgrades, and zero credit-card-required overage traps unless explicitly approved by the owner.

---

## 3. Technology Stack Selection & Verified Alternatives Comparison

### 3.1 Cloud & Hosting Stack Comparison (Provider Comparison — Planning Limits, Recheck at Setup)

| Service / Layer | Free Tier Quotas & Limits | Inactivity / Hard Caps | Card Required? | Commercial Use | Verdict for Nohut POS (1 Restaurant) |
|---|---|---|---|---|---|
| **Supabase Free** ([Pricing](https://supabase.com/pricing), [Billing Docs](https://supabase.com/docs/guides/platform/billing-on-supabase), [DB Size](https://supabase.com/docs/guides/platform/database-size)) | 500 MB Postgres DB, 1 GB file storage, 5 GB uncached + 5 GB cached egress, 50K Auth MAU, 500K Edge Functions, 2M Realtime msgs, 200 concurrent connections, 2 active projects | Pauses after **7 days of inactivity**; **no automatic backups**; 500 MB database quota is distinct from the 2 GB disk; read-only at 95% disk usage, other restrictions may apply under current billing/fair-use terms | No | Allowed under [Supabase Terms](https://supabase.com/terms) (no SLA on Free) | **SELECTED for Cloud DB + Auth + RLS + Realtime.** Best relational/RLS/Auth fit; mitigate 500 MB cap with tiered hot/cold storage and 7-day pause with pause/unpause runbook. **Do NOT use for DB backups.** |
| **Firebase Spark** ([Pricing](https://firebase.google.com/pricing)) | 1 GiB Firestore, 50K reads/day, 20K writes/day, 20K deletes/day, 10 GiB egress/mo, 50K Auth MAU | **Cloud Functions & new Storage buckets disabled on Spark** (require Blaze billing); hard daily write cap blocks fast first-sync | Blaze requires billing account | Allowed | **REJECTED.** No SQL/joins for financial reconciliation, no server-side functions on Spark for username auth/command validation, and 20K writes/day throttles initial historical import. |
| **Cloudflare D1 + Workers Free** ([D1 Pricing](https://developers.cloudflare.com/d1/platform/pricing/), [Workers Pricing](https://developers.cloudflare.com/workers/platform/pricing/)) | 5 GB aggregate account storage, max 500 MB per individual database on Free; 5M rows read/day, 100K rows written/day, 100K Worker req/day (10 ms CPU), $0 egress | No inactivity pause; **no integrated Supabase-style Auth/RLS**; SQLite-backed Durable Objects are available on Workers Free and support WebSockets within their limits | No (Workers/D1/Pages) | Allowed ([Cloudflare Community](https://community.cloudflare.com/t/is-commercial-use-allowed-on-the-free-plan-for-pages-functions-kv/971058)) | **SECONDARY / FALLBACK.** Excellent 5 GB SQLite capacity, but building custom Auth + RBAC + polling Realtime increases complexity and security surface for a single restaurant. |
| **Cloudflare Pages Free** ([Pages Limits](https://developers.cloudflare.com/pages/platform/limits/)) | Unlimited bandwidth, 500 builds/mo, 20,000 files, 25 MiB max file size, 100 custom domains, automatic HTTPS | No inactivity pause | No | Allowed | **SELECTED for iPhone PWA & Yönetici Web Hosting.** Zero-cost, fast global/Istanbul edge HTTPS, GitHub CI auto-deploy. |
| **Cloudflare R2 Free** ([R2 Pricing](https://developers.cloudflare.com/r2/pricing/)) | 10 GB-mo Standard storage, 1M Class A ops, 10M Class B ops, $0 egress | Usage beyond 10 GB is billed ($0.015/GB-mo) — not hard-capped | **YES** ([Cloudflare Community](https://community.cloudflare.com/t/why-using-r2-free-tier-involves-giving-card-info/945179)) | Allowed | **OPTIONAL BACKUP DESTINATION (Owner Approval Required).** Ideal 10 GB encrypted backup target *if* owner approves adding a card; otherwise use owner Google Drive/OneDrive + local USB/NAS. |
| **Neon Postgres Free** ([Neon FAQs](https://neon.com/faqs/free-plan-limits-and-quotas)) | 1 GB Postgres/project, 100 CU-hours/mo (≈400 hrs at 0.25 CU), 5 GB egress, 6-hr instant restore | Scales to zero after 5 min; suspends if 100 CU-hours exhausted; no built-in Realtime | No | Allowed | **NOT SELECTED.** 400 active hrs/month (~13.3 hrs/day) can be exhausted by a restaurant open 14–16 hrs/day with 60s heartbeats. |
| **GitHub Actions Free** ([GitHub Billing](https://docs.github.com/billing/managing-billing-for-github-actions/about-billing-for-github-actions)) | Free standard runners on public repos; private repos get $12/mo included compute + 500 MB artifacts | Public repos must never contain secrets/PII | No | Allowed | **SELECTED for CI/CD & APK builds** (keep source repos free of all business data/secrets). |

### 3.2 Recommended Architecture (V4)

```mermaid
flowchart TD
  W[Windows Flutter POS] --> SQL[(Authoritative Local SQLite WAL + sync_outbox)]
  SQL --> PRN[Xprinter XP-237B 48mm]
  SQL <--> AGENT[Windows Sync & Command Worker]
  AGENT <-->|Outbound authenticated HTTPS (TLS 1.2+)| SB[Supabase Private Postgres + Auth + RLS + Realtime + Edge Functions]
  AND[Android flutter_personel APK] <-->|HTTPS| SB
  AND -. Authenticated LAN TLS fallback (when verified) .-> LAN[PosLanServer :8787]
  PWA[iPhone Lightweight TS PWA + Yonetici Web on Cloudflare Pages] <-->|HTTPS| SB
  IPH_LAN[iPhone local secure HTTPS fallback if verified; otherwise drafts] -. Local Wi-Fi Only .-> LAN
  SQL --> BKP[Encrypted AES-256-GCM Backup Engine]
  BKP --> BKP_DEST[Owner-Approved Off-Site Storage + Local/USB Copy]
  SQL --> QRPUB[Public-Menu-Only Allowlist Publisher]
  QRPUB --> QRREPO[Public GitHub nohutfalafel/qr-menu]
```

**Rejected/Replaced V2 Decisions:**
- **Replaced:** V2 left iPhone PWA tech stack open (Flutter Web vs. lightweight PWA) and suggested HTTPS PWA → LAN fallback "if technically viable". **V4 Decision:** Build a **dedicated lightweight TypeScript + Vite PWA** (not Flutter Web) for iPhone `Nohut Personel` + responsive `Nohut Yönetici`. Drop HTTPS-PWA-to-HTTP-LAN fallback (not a secure or reliably supported Safari design); instead, evaluate a separate trusted HTTPS local origin for both mobile clients. A raw HTTP LAN bookmark is not a secure authenticated fallback; never transmit reusable credentials, bearer tokens, payroll, customer data or payment commands over HTTP. If secure local access cannot be deployed and verified on actual Safari, retain offline drafts and Windows operation. Do not install untrusted root CAs or disable TLS validation.
- **Replaced:** V2 proposed storing backups in cloud object storage alongside Supabase without resolving the 1 GB Supabase Storage limit or Cloudflare R2 card requirement. **V4 Decision:** Strictly decouple encrypted backups from Supabase Storage (1 GB is insufficient for multi-year retention). Support a pluggable `BackupStorageAdapter` targeting: (1) Local + USB/NAS mirror (always on), (2) Owner-approved Google Drive / OneDrive (different shared free storage limits; verify actual available quota and OAuth setup), or (3) Cloudflare R2 (10 GB free, only if owner approves card-on-file).
- **Added:** Explicit **KVKK Article 9 compliance gate**, **Supabase 7-day inactivity recovery handling**, and **tiered hot/cold cloud storage hygiene** to prevent hitting the 500 MB Supabase Free capacity risk; no guaranteed multi-year free retention.

---

## 4. Complete Data Inventory & Hybrid Synchronization Data Model

### 4.1 Phase 0 Persistence Audit Requirement
Before writing any sync code, Claude Code must inspect `pos_store.dart`, `pos_logic.dart`, `operations.dart`, `finance_sync_server.dart`, `lan_server.dart`, `mobile_pairing.dart`, `windows_vault.dart`, `partner_credentials.dart`, `printer_management.dart`, and all `flutter_desktop/lib/` modules, and generate `docs/cloud-sync/data-inventory.md` listing **every single persisted SQLite table, JSON state key inside `state_snapshot.payload`, sidecar file (`.dpapi`, caches, CSV exports, settings), and QR menu JSON file**.

Each row in `docs/cloud-sync/data-inventory.md` must document:
- **Identity:** Source file/function, table/key/file path, stable primary key.
- **Classification:** `PUBLIC`, `INTERNAL`, `PERSONAL_PII`, `FINANCIAL`, `SECRET`, `DEVICE_LOCAL`, or `DERIVED`.
- **Sync Policy:** Cloud table target, sync direction, create/update/delete semantics, conflict rule, retention/compaction rule.
- **Access Control:** Permitted roles and Postgres RLS policy name.
- **Verification Status:** `VERIFIED_EXISTING`, `IN_FLIGHT_PR`, or `PROPOSED_V5`.

### 4.2 Complete Business Data Coverage & Hybrid Cloud Schema
**Architecture Choice: Hybrid Relational + Compact JSONB + Append-Only Event/Audit Tables.**
- Use **normalized relational tables** in PostgreSQL for all queryable, reportable, and RLS-filtered entities (enabling fast SQL aggregations for `Genel Bakış`, `Finans`, `Raporlar`, `Yoğunluk`, and strict row-level isolation for `Mesailerim` and `Maaş & Avans`).
- Use **compact `JSONB` columns** only for variable nested structures (e.g., ingredient removals/substitutions, campaign selections, allowlisted platform operational metadata (not raw API responses)) so schema evolution does not break sync.
- Every synced table includes: `restaurant_id UUID NOT NULL`, `entity_version BIGINT NOT NULL`, `source_revision BIGINT NOT NULL`, `updated_at TIMESTAMPTZ NOT NULL`, and `deleted_at TIMESTAMPTZ NULL` (soft-delete tombstone).

| Domain | Cloud Table(s) | Required Fields & Historical Coverage | Sync Direction | Compaction / Hygiene Policy |
|---|---|---|---|---|
| **Masalar** | `pos_tables` | Table ID, label (`Masa 1–5+`), layout/order, active `order_id`, status, transfer history | POS → Cloud (Commands: Cloud → POS) | Preserve authorized history under approved retention policy |
| **Siparişler** | `orders`, `order_items`, `order_events` | Stable ID, order number, channel (`masa`, `gel_al`, `trendyol`, `yemeksepeti`, `migros`), table ref, staff ID, timestamps, status, subtotal/discount/total, line items, batches, customizations/removed ingredients/notes (`JSONB`), cancellations | POS → Cloud (Commands: Cloud → POS) | Preserve all authorized history; optional verified remotely retrievable archive with owner approval and provider retention constraints |
| **Gel-Al** | `orders` (`channel='gel_al'`), `pickup_details` | Source (`Tezgahtan`/`Telefon`), minimal order-specific pickup name and promised time when entered, delivery status/timestamp; phone only if needed, separately protected and subject to retention; no new CRM | POS → Cloud (Commands: Cloud → POS) | Retain under approved retention and KVKK rules |
| **Online Siparişler** | `orders`, `platform_order_records` | Platform code, external order ID scoped to restaurant/platform, stable item/option identifiers and versions, quantities, gross/commission/discount/net amounts when supplied, status transitions, cancellation reasons, action outcomes; no general customer profile | POS → Cloud (Commands: Cloud → POS) | Keep permitted business facts; do not retain full raw API payloads by default; transient personal fields follow Section 19; archive only with owner approval and API retention rules |
| **Ödemeler & İadeler** | `payments` | Stable ID, `order_id`, method (`nakit`/`kart`/platform), amount, cash received, change, partial/split allocation, refund/void link, staff ID, timestamp | POS → Cloud (Commands: Cloud → POS) | **Append-only ledger with linked reversals; retention/legal rules and explicit authorized archival** |
| **Existing local open accounts (if present)** | Existing verified account/ledger mapping only | Preserve real outstanding balances, settlements and required historical attribution. Do not create a customer directory for platform customers or a new CRM. Minimize contact fields. | POS → Cloud only if authorized and required | Explicit legal/retention review; no silent deletion of obligations; platform customer profiles excluded |
| **Personel** | `employees`, `employee_roles`, `employee_permissions` | Immutable `employee_id`, display name, active flag, role, granular permissions JSONB, auth `user_id` mapping | POS → Cloud (business fields; owner commands Cloud → POS) | Preserve necessary historical attribution; deactivate accounts and apply lawful retention/anonymization |
| **Mesai (Shifts)** | `shifts`, `shift_corrections` | Shift ID, `employee_id`, clock-in/out timestamps, duration, break, audited owner corrections | POS → Cloud (Clock-in/out via command) | Approved retention; RLS restricts staff to own rows |
| **Maaş & Avans** | `payroll_rates`, `payroll_advances`, `payroll_payments` | Hourly/weekly/monthly rates, advances, bonuses, deductions, payout records, period dates | POS → Cloud (Owner-only commands) | Approved retention; RLS strictly restricts staff to own rows |
| **Finans & Tedarik** | `suppliers`, `material_purchases`, `expenses`, `fixed_expenses`, `market_price_history` | Daily material purchases, supplier records, units/prices, fixed recurring expenses (preserving PR #26 history & no-future-date rules), rent, utilities, platform fees | POS → Cloud (Owner/authorized commands) | Preserve authorized history under approved retention policy |
| **Menü & Kampanyalar** | `categories`, `products`, `campaigns` | Stable product/category/ingredient IDs; multilingual names (`tr`/`en`/`ar`), prices, ingredients, customization rules, visibility, campaign definitions & selectable components stored once per relevant immutable version | POS → Cloud (Owner commands) | Preserve authorized history under approved retention policy |
| **Stok** | `stock_items`, `stock_adjustments` | Product/ingredient availability flags, quantities (if tracked), adjustment history & staff attribution | POS → Cloud (Authorized commands) | Preserve authorized history under approved retention policy |
| **Fişler** | `receipt_snapshots`, `print_jobs` | Immutable compact receipt snapshot/reconstruction contract using versioned references and frozen sale facts (without pickup phone number or unnecessary platform PII), print job ID, status (`queued`, `printed`, `failed`, `ambiguous`), retry metadata, timestamps | POS → Cloud | Optional verified cold archive only; preserve complete receipt content and authorized retrieval; never auto-purge |
| **Raporlar** | Computed SQL views + `saved_report_configs` | Underlying raw facts synced above; saved report presets/filters synced; PDFs generated on demand | Derived in Cloud + POS | Do not duplicate rendered PDFs in DB |
| **Google Business** | `google_business_cache` (only if authorized) | Permitted reviews/metrics/replies per Google Business Profile API retention rules | POS → Cloud | Enforce API TTL/refresh policy |
| **Ayarlar** | `restaurant_settings` | Non-secret business settings, receipt layout policy, operating hours, tax/commission settings, feature flags | POS → Cloud (Owner commands) | Preserve authorized history under approved retention policy |
| **İşlem Geçmişi & Sync** | `audit_logs`, `command_queue`, `command_receipts`, `sync_checkpoints`, `deleted_tombstones` | Monotonic revision, `request_id` idempotency receipts, command outcomes, security events, soft-delete tombstones | Separate streams: POS-authoritative outcomes/projection; cloud-authored pending inbox; no dual-writer business entity | Keep durable anti-replay identity and outcome across retention, restore and epochs; archive bulky details only with verified retrieval and explicit policy |
| **Ekler (Attachments)** | `attachment_metadata` + Object Storage | Expense/invoice photos (lossless originals when required; optional compressed preview, target ≤200 KB), SHA-256 hash, MIME type, linked entity ID | POS/Manager → Protected Object Storage | Stored outside Postgres DB; subject to storage quota alerts |

### 4.3 Explicit Exceptions (Protected Separately — Never Plaintext in Business Tables)
1. **Authentication Passwords & PINs:** Managed exclusively by Supabase Auth (passwords) and hardened device/server verification (PINs). Never stored in `state_snapshot`, Postgres business tables, logs, or git.
2. **External API Credentials & Vault Secrets:** Trendyol Go / Yemeksepeti / Migros API keys, Google Business OAuth tokens, QR publisher GitHub PAT/App keys, Supabase sync agent tokens, and `WindowsVault` `.finance-sync.dpapi` blobs remain in Windows DPAPI / OS secure storage. Reauthorization on a replacement PC is explicitly documented in the Recovery Runbook (Section 11).
3. **Payment Card Data:** Never capture, log, or sync PAN, CVV, or raw POS terminal card track data. Store only payment method, amount, and non-sensitive terminal reference if needed.
4. **Machine-Local Hardware State:** Local Xprinter COM/USB port binding, Windows printer driver name, local file paths, and UI window geometry stay local. Historical `print_jobs` sync for audit visibility, **never** for automatic replay on another machine.
5. **Public QR Menu Output:** Strictly allowlisted public catalog fields (`categories`, `products`, `prices`, `availability`, `campaigns`). Automated CI/publisher schema check must fail if any private field (`customer`, `phone`, `employee`, `salary`, `expense`, `order`) appears in published JSON.

6. **Platform customer data:** Do not create a persistent profile or CRM for Trendyol or other delivery-platform customers. Use only required API-provided fields for active fulfillment and authorized receipts; store permitted order/business facts separately. Do not duplicate raw payloads or PII in projections, logs, commands or backups beyond justified retention. Follow Section 19.

### 4.4 Local SQLite Schema Additions (Windows POS)

Schema examples below are proposals, not executable migrations. Add `authority_epoch`, `tx_id`, `event_ordinal`, `event_count`, `schema_version` and scoped `restaurant_id` to the event envelope and appropriate keys/indexes. Add migration manifest and durable batch ledger, server-side projection checkpoint and immutable request identity ledger. Derive entity IDs once at migration, persist mapping (including nested order/batch/item identities); never use list index, display number or name as ID. Enforce composite restaurant-scoped foreign keys. Soft-delete business records where appropriate; never silently discard permitted historical facts. Auth identity, device/session registry and command inbox are control-plane records with separate authority, not replicated POS business rows. Employee activation/role changes must be coordinated fail-closed, not overwritten by older projection events. Store only necessary redacted command metadata in cloud; full payloads are subject to privacy classification. Backup artifacts and metadata get their own inventory entries. Retain required original documents even if reports are normally derived. CI coverage must inspect dynamic/nested keys and sidecar paths, not merely top-level defaults.
Add the following local tables alongside `state_snapshot`, `command_receipts`, and `deleted_requests` inside `nohut-pos.sqlite3` (versioned migration, zero data loss):
- `sync_outbox (seq INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT UNIQUE NOT NULL, revision INTEGER NOT NULL, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL, op TEXT NOT NULL CHECK(op IN ('upsert','delete')), payload_json TEXT NOT NULL, payload_sha256 TEXT NOT NULL, created_at TEXT NOT NULL, sent_at TEXT, acked_at TEXT, retry_count INTEGER NOT NULL DEFAULT 0, last_error TEXT)`
- `sync_state (key TEXT PRIMARY KEY, value TEXT NOT NULL)` — stores `first_sync_status`, `migration_id`, `snapshot_revision`, `last_acked_seq`, `last_acked_revision`, `cloud_project_ref`, `auto_sync_enabled`, `last_sync_at`, `last_reconcile_at`.
- `backup_history (backup_id TEXT PRIMARY KEY, created_at TEXT NOT NULL, revision INTEGER NOT NULL, file_size_bytes INTEGER NOT NULL, compressed_bytes INTEGER NOT NULL, sha256 TEXT NOT NULL, destination TEXT NOT NULL, status TEXT NOT NULL, verified_at TEXT, error_message TEXT)`

**Schema Drift Guard:** Add a unit/CI test that serializes all keys of actual defaults, normalizers, migrations and every persisted write path (discover real function names; e.g. `emptyPosState()`) and asserts every top-level key is explicitly registered in the Sync Entity Registry (either mapped to a cloud table or explicitly marked `DEVICE_LOCAL`/`SECRET`). Any newly added feature key fails CI until its sync mapping is declared.

---

## 5. First Synchronization — Owner-Controlled Initial Migration

Entry point (owner-only): `Ayarlar → Bulut & Senkronizasyon → İlk Senkronizasyonu Başlat`.
Before first sync completes and passes verification, **automatic ongoing sync is OFF**, `Şimdi Senkronize Et` is disabled, and cloud staff/manager clients display a gated *"İlk kurulum bekleniyor"* state.

Before uploading, compute the permitted V5 canonical projection and dictionary versions, classify legacy platform personal fields separately, and show source versus eligible counts/bytes and exclusion reasons. Reconcile projected records rather than requiring byte-identical raw payloads. Never upload old raw API caches merely because they were present locally. See Section 19.

### 5.1 Mandatory 18-Step First-Sync State Machine

| Step | Phase Name | Exact Technical Behavior & Failure Safeguard |
|---|---|---|
| 1 | **Connection & Auth Check** | Verify TLS connectivity to Supabase project, owner JWT validity, Owner MFA confirmation, and restaurant ownership claim. |
| 2 | **Cloud Destination Verification** | Verify `cloud_project_ref` matches configured restaurant ID, Postgres schema version matches POS expected migration version, and RLS policies are active. **Check if cloud DB is non-empty:** if business rows exist outside the same authenticated resumable migration/generation, **HARD BLOCK** ordinary first sync and show non-destructive Reconciliation / Recovery instructions (never auto-truncate or overwrite). |
| 3 | **Storage & Quota Preflight** | Query cloud DB current size and storage quota; verify projected post-import DB size, staging overhead and measured headroom against the chosen plan. Warn at configured thresholds (70/85/95%); block if projected use exceeds safe usable capacity or legal approval is missing. Do not impose a universal 375 MB migration limit. |
| 4 | **Local DB Integrity Check** | Run `PRAGMA integrity_check;` and `PRAGMA foreign_key_check;` on local SQLite. Require `integrity_check` to return `ok` and `foreign_key_check` to return zero violation rows; also check application-level relationships and JSON schema. Abort on violation. |
| 5 | **Consistent Encrypted Local Backup** | Run `PosStore.backup()` (`VACUUM INTO`) to a temporary staging file, encrypt with AES-256-GCM using the owner's configured recovery key, verify decryptability + SHA-256 checksum, and store locally (and off-site if configured) before touching cloud data. |
| 6 | **Complete Historical Data Discovery** | Enumerate every registered entity across `state_snapshot`, `command_receipts`, `deleted_requests`, and inventoried sidecars. Display a Turkish pre-flight summary table to the owner (exact counts per category: Siparişler, Ödemeler, Gel-Al, existing open accounts if any, Personel, Mesai, Maaş, Finans, Menü, Fişler, Tombstones; show explicit excluded/transient field categories without exposing PII). |
| 7 | **Actual Data-Size Estimation** | Compute actual serialized payload bytes + estimated PostgreSQL index/tuple overhead (×2.2 factor) and display estimated MB vs. available cloud quota. Require explicit owner confirmation click (`Onayla ve Başlat`). |
| 8 | **Outbox Activation & Revision-Fenced Snapshot** | Install transactional outbox on ALL write paths before snapshot. Take a consistent SQLite backup; read actual revision and outbox high-water sequence FROM that backup (do not assume a revision read before VACUUM INTO equals snapshot revision). Atomically persist migration ID, actual snapshot revision/cursor, digest, authority epoch and generation; keep outbox from before snapshot. Capture post-snapshot writes and replay seq > snapshot cursor. Use a short bounded local serialization barrier or supported backup/read-transaction mechanism as needed; network never holds a write lock. Protect staging with owner-only ACL and encryption at rest. |
| 9 | **Dependency-Ordered Batch Upload** | Upload from the pinned snapshot in dependency order established by actual FK graph. Insert base tables/existing authorized account references/employees/catalog versions before orders, then items, payments, receipts, audit/tombstones. Defer cyclic active-table/order links and refund/other self-references until parents exist, then validate every relationship before publication. Stage by migration generation; partial data must not be client-visible. Use bounded batches (e.g., 200–500 rows or ≤512 KB per HTTP request) with real progress UI (uploaded/total rows, category, MB sent, elapsed time — never fake timer progress). |
| 10 | **Idempotent Duplicate Prevention** | Every batch carries `(migration_id, batch_index, idempotency_key)` and uses PostgreSQL an atomic server RPC that deduplicates event/batch ID and canonical payload hash, validates schema/epoch and expected sequence, accepts only strictly newer versions (equal version + same hash is a no-op; equal version + different hash is a conflict). Reject gaps, stale events and conflicting generation. Tombstone versions prevent resurrection. Starting the same migration twice resumes the existing `migration_id` rather than duplicating rows. |
| 11 | **Durable Interrupt & Resume** | Persist `last_completed_batch` per category in `sync_state` after each server-acknowledged batch. On Wi-Fi drop, app crash, PC reboot, or owner clicking `Duraklat`, retain the snapshot file and checkpoint. On restart, offer `Devam Et` to resume from the exact next batch without re-uploading completed batches or touching local POS data. |
| 12 | **Concurrent Delta Catch-Up** | Once all snapshot batches (`≤ R_snap`) succeed, drain all `sync_outbox` events committed during the upload (`revision > R_snap`) up to a fixed captured committed high-water revision and sequence `R_final/S_final`. Continue capturing later transactions separately; do not chase a moving target. Use atomic transaction groups, not partially applied order/payment entities. |
| 13 | **Record-Count & Content Hash Reconciliation** | Run a server-side PostgreSQL RPC `reconcile_migration(migration_id, expected_revision)` comparing local vs. cloud row counts and canonical sorted per-record SHA-256 manifest or domain-separated Merkle/chunk digests (not XOR alone) for **every** category at `R_final`. |
| 14 | **Financial-Total Reconciliation** | Compare exact integer/decimal sums (in kuruş / `NUMERIC(12,2)`) between local SQLite and cloud Postgres at `R_final`: total gross sales, cash collected, card collected, platform collections, total refunds/voids, unpaid table/customer balances, total expenses, total material purchases, and total payroll/advances. Zero tolerance for discrepancy (`diff == 0.00`) after documented conversion to authoritative exact kuruş semantics. Reject or flag source precision anomalies rather than silently rounding away differences. |
| 15 | **Missing-Record Detection** | If any category count, hash, or financial total mismatches, run key-set diff (chunked ID lists) to identify exact missing or mismatched record IDs, display them in diagnostics, and allow targeted retry without wiping data. |
| 16 | **Final Checkpoint Verification** | Atomically mark cloud migration verified and commit immutable checkpoint at the exact verified revision/cursor/epoch/generation. Persist its acknowledged receipt in local `sync_state`. If acknowledgement is lost, query the existing migration receipt and resume idempotently. Do not promote incomplete data. Cross-system transition is a recoverable state machine, not a distributed atomic transaction. |
| 17 | **Completion Acknowledgement** | Display `İlk Senkronizasyon Tamamlandı` with timestamp, verified revision, and category totals. Remove temporary plaintext staging promptly after durable completion; do not promise forensic erasure on SSDs. Prefer encrypted staging, restricted ACLs, crash cleanup and no plaintext backup in cloud or GitHub. |
| 18 | **Automatic Sync Activation** | Only after Step 17 succeeds, persist auto_sync_enabled=true and advance the cloud migration gate only after verified receipt and separate owner-approved rollout/auth/privacy gates. Idempotent restart reconciles either side of activation. Resume later outbox events; never discard them. Business clients unlock only for authorized roles and approved release flags. On future POS restarts, resume incremental mode automatically; replace the prominent first-start CTA with completion metadata. |

### 5.2 First-Sync Edge-Case Matrix

| Failure / Edge Scenario | Required System Behavior |
|---|---|
| Cloud DB already contains data | Resume the same verified partial migration if its manifest matches; otherwise hard block at Step 2 and display remote row count & last revision; direct owner to `Tam Yeniden Senkronizasyon` or Recovery workflow. Zero silent overwrite. |
| Fails halfway / internet drops | Pause cleanly with exponential backoff or manual `Tekrar Dene`; local POS continues taking orders and printing; resume from last persisted batch checkpoint. |
| Windows POS crashes or PC restarts | Snapshot file + `sync_state` checkpoint survive on disk; on relaunch show banner *"Yarım kalan ilk senkronizasyon devam ettirilebilir"* with `Devam Et` / `İptal Et (Güvenli)`. |
| New orders/payments arrive during upload | Captured in `sync_outbox` with `revision > R_snap` and replayed seamlessly in Step 12. |
| Cloud storage quota insufficient | Blocked at Step 3 before uploading a single row; show exact MB needed vs. available + compaction options. |
| Owner clicks Start twice / double-click | Single-flight mutex + persisted `migration_id` prevents concurrent upload workers; idempotent `ON CONFLICT` prevents duplicate rows. |

---

## 6. Manual, Automatic, and Recovery Operations

### 6.1 Strict Distinction of 7 Operations (Never Conflate)

| Operation | Turkish UI Label | Trigger & Scope | Writes Full DB? | Destructive? |
|---|---|---|---|---|
| 1. Initial Synchronization | `İlk Senkronizasyonu Başlat` | One-time owner-gated full historical migration | Yes (batched) | No |
| 2. Incremental Auto Sync | `Otomatik Senkronizasyon` | Default ON after first sync; event-driven debounce (2–5s) + 60s reconciliation heartbeat | **No** (outbox deltas only) | No |
| 3. Manual Sync | `Şimdi Senkronize Et` | Owner-only on-demand flush of pending outbox + command pull + cursor check | **No** (coalesced with single worker) | No |
| 4. Periodic Reconciliation | *(Background / 60s + Daily)* | Compares local vs. cloud revision, daily order count & financial totals; surfaces drift | **No** (summary RPC only) | No |
| 5. Advanced Full Resync | `Gelişmiş: Tam Yeniden Senkronizasyon` | Owner-only recovery after unresolvable drift; requires backup + MFA + dry-run diff + confirmation | Delta-repaired full check | Never deletes newer records |
| 6. Encrypted Backup | `Şimdi Yedekle` / `Otomatik Yedekleme` | Independent `VACUUM INTO` + zstd/gzip + AES-256-GCM snapshot to separate backup storage | Yes (compressed snapshot) | No |
| 7. Disaster Restore | `Gelişmiş: Verileri Geri Yükle` | Owner-only full local DB replacement from verified encrypted backup | Replaces local DB safely | Staged + rollback-safe |

### 6.2 Recommended Incremental Sync Mechanics (Hybrid Event-Driven + Heartbeat)
- **Single-Worker Architecture:** Exactly one `SyncWorker` isolate/service runs inside Windows POS. Manual `Şimdi Senkronize Et` signals this same worker (coalescing concurrent requests).
- **Outgoing Flush:** Whenever a local transaction commits to `sync_outbox`, schedule a debounced flush (**2 seconds** debounce, **5 seconds** max wait) to batch rapid multi-item table edits into a single HTTP request (measure actual message and request savings).
- **Incoming Commands:** Maintain a Supabase Realtime subscription on `command_queue` (`status = 'pending'`) for sub-2-second delivery, backed by a **30–60 second polling fallback** in case WebSocket drops silently.
- **Reconciliation Heartbeat:** Every **60 seconds** (when online and idle), verify `last_acked_revision`; once per day (or at shift close), run a lightweight financial/count integrity check RPC.
- **Supabase low-activity pause:** Normal business traffic may keep the project active; no guarantee. Do not send artificial traffic to evade free-tier rules. If the restaurant closes for >5 days (e.g., holiday), the owner receives a reminder or runs a manual check; if paused, the POS displays *"Bulut projesi uyku modunda — Supabase panelinden uyandırın"* while supported local operations continue offline.

### 6.3 Required `Ayarlar → Bulut & Senkronizasyon` UI Controls
Preserve the Turkish settings layout from V2 with clear status separation:
- `Bağlantı Durumu` (`Bağlı` / `Çevrimdışı` / `Uyku Modunda` / `Hata` / `Yapılandırılmadı`)
- `İlk Senkronizasyon` status + `[Bağlantıyı Test Et]` + `[İlk Senkronizasyonu Başlat]` (replaced after completion by `İlk Senkronizasyon Tamamlandı` + timestamp)
- `Otomatik Senkronizasyon` toggle (enabled by default post-first-sync; pausing never pauses local POS)
- `Son Senkronizasyon` (timestamp + relative age + confirmed revision), `Yerel Revizyon`, `Bulut Revizyonu`, `Bekleyen İşlemler` (outgoing + incoming counts)
- `[Şimdi Senkronize Et]`, `[Senkronizasyon Geçmişi]`, `[Hataları Yeniden Dene]`
- `Depolama Kullanımı` (measured Postgres MB / 500 MB + Backup storage MB + 70% / 85% / 95% warning banners)
- `Yedekleme ve Geri Yükleme`: `Son Yedekleme`, `Otomatik Yedekleme` schedule, `[Şimdi Yedekle]`, `[Yedekleme Geçmişi]`, `Gelişmiş: [Tam Yeniden Senkronizasyon] [Verileri Geri Yükle]`

---

## 7. Windows Offline-First Architecture & Outage Matrix

### 7.1 Authoritative Model Comparison
- **Local-Authoritative (SQLite Master — SELECTED):** No cloud round trip on local checkout, immune to Turkish ISP outages or Supabase pauses, single-writer thermal printing, zero split-brain on payments/order numbers.
- **Cloud-Authoritative (Rejected for this release):** Breaks POS ordering and printing when internet fails; creates split-brain risk if local fallback is bolted on later.
- **Hybrid Read/Draft + Command Queue (Applied on Top of Local-Authoritative):** Remote mobile clients read the latest cloud projection (with explicit staleness badge) and submit version-checked commands that only become authoritative once committed by Windows POS.

### 7.2 Complete Outage & Failure Behavior Matrix

| Scenario | Windows POS | Android Personel | iPhone Personel / Yönetici | Safety Guarantee |
|---|---|---|---|---|
| **Internet down, Wi-Fi UP, Windows ON** | normal for supported local operations; internet-dependent integrations remain unavailable; `sync_outbox` queues deltas | Switches only to previously enrolled, authenticated and TLS-verified LAN fallback; otherwise drafts | Secure local HTTPS fallback only if deployed and verified; otherwise drafts; HTTPS PWA shows offline banner | Zero lost orders; zero duplicate sync on reconnect |
| **Supabase down / paused** | normal for supported local operations; internet-dependent integrations remain unavailable; shows actionable warning; retries with backoff | Uses authenticated LAN fallback inside restaurant | Verified secure local mode or drafts; remote access shows *"Bulut erişilemiyor"* | Local restaurant unaffected |
| **Restaurant Wi-Fi fails completely** | normal for supported local operations; internet-dependent integrations remain unavailable (USB Xprinter works directly) | Offline mode: local draft cart only (cannot confirm order/payment until reconnected) | Offline mode: local draft cart only | No false confirmation; clear offline badge |
| **Windows PC switched OFF** | Off | Read-only last synced state with prominent *"Kasa Çevrimdışı — Son veri: HH:MM"* banner; **no payments, prints, or platform actions allowed**; optional non-financial drafts only if explicitly enabled | Manager (`Yönetici`) can view all synced sales, reports, finance, shifts with staleness timestamp; destructive/financial/print commands disabled | Zero split-brain; never claims payment/print succeeded |
| **Employee outside restaurant** | Normal | Connects via HTTPS to Supabase; permitted actions obey role and owner policy; no mandatory location tracking, and IP is not proof of attendance | Connects via HTTPS to Cloudflare Pages + Supabase | Role & RLS enforced server-side |
| **Xprinter XP-237B disconnected** | Order commits safely to SQLite; `print_job` marked `failed` / `ambiguous` with visible retry button | Sees order confirmed + *"Yazıcı hatası — kasadan tekrar yazdırın"* | Sees order confirmed + print status badge | Order never lost; no silent auto-reprint storm |
| **Cloud command submitted, not yet acknowledged** | Worker picks up on next poll/Realtime event, checks `expires_at` + `expected_revision` | Shows `Gönderildi / Onay Bekleniyor` spinner; blocks duplicate tap using same `request_id` | Shows `Gönderildi / Onay Bekleniyor` | Duplicate retry with same `request_id` returns cached outcome; expired financial/print commands rejected |

---

## 8. Android Personel & iPhone Personel (PWA) Architecture

### 8.1 Android Personel (`flutter_personel`)
- **Reuse & Upgrade:** Keep the existing `flutter_personel` Flutter app and `packages/nohut_core` shared Dart models/finance logic (preserving PR #22 work).
- **Distribution:** Signed release APK built via `.github/workflows/flutter-personel-android.yml` (0 TL, no Google Play fee). Add in-app version check banner pointing to the latest authorized APK release.
- **Dual-Transport Client:** Implement a `PosTransportClient` interface with:
  1. `SupabaseCloudTransport` (primary HTTPS + Realtime when online).
  2. `AuthenticatedLanTransport` (automatic local Wi-Fi fallback to `PosLanServer :8787` when cloud is unreachable, using bounded, audience-scoped locally verifiable credentials on TLS-verified connections; do not forward cloud refresh tokens to LAN. Inspect existing pairing first; migrate safely and disable legacy unauthenticated routes.).

### 8.2 iPhone Personel & Yönetici — Dedicated Lightweight PWA vs. Flutter Web

| Evaluation Criterion | Flutter Web | Dedicated Lightweight TS + Vite PWA (**SELECTED**) |
|---|---|---|
| Initial payload & cold start on iOS Safari | depends on build/render mode; benchmark actual release | **target <150 KB gzipped app shell**; benchmark on actual device and network |
| iOS Safari scroll, keyboard & safe-area feel | Canvas-rendered; occasional keyboard/focus quirks | Native DOM scrolling, native Turkish keyboard, `env(safe-area-inset-*)` |
| Add to Home Screen (`Ana Ekrana Ekle`) | Works, heavier memory footprint | First-class standalone display, minimal RAM |
| Offline caching & Service Worker | Heavy asset cache | Clean Workbox/SW app-shell cache; clears private data on logout |
| Push notifications (iOS 16.4+ Home Screen PWA) | Requires JS interop anyway | Native Web Push API ([Apple Developer Docs](https://developer.apple.com/documentation/usernotifications/sending-web-push-notifications-in-web-apps-and-browsers)) — permission-gated, Home Screen only |
| Maintainability & shared business logic | Shares Dart UI, but POS business authority lives on Windows anyway | Thin client over a **single versioned JSON Command & Projection Contract** (`docs/contracts/v1/`); zero duplicated pricing/tax/payment math |

### 8.3 iOS Safari Technical Realities (Hard Constraints — Do Not Overpromise)
1. **No HTTPS-to-HTTP LAN Fallback:** Safari may block mixed-content `fetch()` calls from an `https://` PWA to `http://192.168.x.x:8787` ([MDN Mixed Content](https://developer.mozilla.org/en-US/docs/Web/Security/Defenses/Mixed_content)). Do **not** ship broken mixed-content code or ask staff to install untrusted Root CA certificates. Instead, provide `Yerel Ağ Yedek Modu` only if a separately trusted HTTPS endpoint and enrolled local session are verified on real Safari; otherwise offer offline draft mode with clear limitation. HTTP bookmark must never be used for login or private data. Local-network-access permissions vary by browser/version; do not assume any exception works without testing.
2. **No Continuous Background Sync:** iOS suspends PWA service workers when backgrounded. Rely on foreground Realtime reconnect + manual refresh + optional iOS 16.4+ Web Push (tested on physical iPhone) for urgent alerts (e.g., new online order).
3. **Storage Eviction:** iOS can evict IndexedDB/cache for unused origins; treat PWA local storage as an ephemeral cache (cleared on logout) and never as authoritative storage.

---

## 9. Unified Staff Authentication, Username/Password, and Trusted-Device PIN

### 9.1 Authentication architecture — managed identity, no custom password database
- Use Supabase Auth or a legally approved equivalent. The visible login is username/password; design an owner-provisioned private mapping from normalized username to provider-supported identifier. Validate synthetic identifiers and recovery with provider sandbox before choosing them; do not invent deliverable email addresses, auto-confirm arbitrary public signup, or depend on unavailable SMTP. Owner-assisted reset and recovery is required. Never log passwords or expose user enumeration.
- Edge Function or secure BFF for lookup and login; private schema, minimal grants, fixed search_path for privileged SQL, input limits and generic failure. Provider issues JWTs; never mint arbitrary privileged tokens. Use provider-supported access token hooks if appropriate, and server-side `auth.uid()` mapping plus live device/employee/permission status, not user-editable metadata. Rate-limit username/IP/device and handle lockout/DoS; check native Auth endpoints cannot bypass custom policy. Do not claim mandatory custom password hook is available on Free until verified. Disable public signup and unused login routes. Test direct provider login, refresh and credential reset. Browser BFF with Secure/HttpOnly/SameSite cookies, CSRF defense, strict origin/CSP and no-store responses is preferred; benchmark supported alternatives. Never persist unrestricted credentials in JS storage.
- Map provider user UUID to immutable employee ID; control-plane session/permissions state separate from POS business projection. Store no plaintext passwords or PINs in business records. Owner-created identity must not accidentally grant production access before employee mapping and permissions commit. Enforce least privilege on every operation, RLS, RPC, object and stream. Cloud read and write access require active employee, active session, correct restaurant, permission version and authorized device. JWT expiry alone is not immediate revocation. Check live session/role for requests and command execution; private Realtime channels should carry minimal invalidation notices, reauthorize and fetch scoped data; disconnect revoked clients as soon as possible and test stale socket/token behavior. No promise of instantaneous revocation of an offline device.
- Windows sync agent has separate revocable, per-restaurant/device scoped service identity for outbox ingestion, migration, command polling and results. Do not ship a project-wide service-role key in desktop, APK or PWA. Privileged provider keys only in owner-approved backend secret storage; server functions explicitly check scope, since service roles can bypass RLS. Agent enrollment requires owner MFA and secure rotation. No public write access to projection tables.

### 9.2 Trusted-device PIN
- Username/password for first login and every new device. Six-digit PIN for a previously enrolled valid session only; never a remote standalone password. Do not encrypt an exportable refresh token solely with a six-digit PIN, even with a slow KDF. Use OS-keystore protected key + bounded local unlock policy, or server-verified device-bound PIN with rate limit and revocation. Five failed attempts is a proposed initial policy; use tamper-resistant counters, escalation and password reauthentication. Store PIN verifiers only with secure KDF/salt and appropriate device/server secret protection; no PINs in logs, cloud business data or recoverable backup. If safe protection cannot be validated, disable PIN on that device. Prefer WebAuthn/passkeys for PWA where feasible, with password fallback; test on real iPhone. A device fingerprint is not authentication.
- Owner TOTP MFA for sensitive cloud access, provisioning, first sync, full resync, restore and permission changes. Offline owner recovery must be separately authenticated locally; no cloud-dependent MFA for disaster restore when internet is unavailable. Establish a recovery procedure and spare recovery material. Shared Windows counter supports quick staff switching only through distinct identity; never expose prior employee's private session or data.

### 9.3 Local authorization and account management
- Preserve existing local operating workflow until new auth is verified. Do not copy Supabase password hashes or cache user passwords. Provision separate scoped local offline credentials/role snapshots on authenticated enrollment; use DPAPI/Keystore and bounded offline validity with explicit local emergency owner procedure. Offline permissions permit only approved local operations. Revocation cannot be received offline; enforce on reconnect and require online reauth for high-risk remote actions. Test time rollback, expired lease, stolen device, user deactivation, local account removal and recovery with provider unavailable.
- Owner UI: `Kullanıcı Adı Oluştur`, `Şifre Belirle / Sıfırla`, `PIN Sıfırla`, `Yetkiler`, `Bağlı Cihazlar`, `Son Giriş`, `Hesabı Devre Dışı Bırak`, `Tüm Oturumları Kapat`; log identity and result, never credentials. Use scoped roles and server-side checks. Optional `Developer` role restricted to staging/synthetic data, no default production access. Optional `Muhasebe` read/export only if approved.

### 9.4 Role & Permission Matrix (Server-Enforced via RLS + Windows Authority) — superseded in detail by §20.3

Roles are **default permission bundles only**. The effective authority of a user is the set of individual operation grants (§20.3) that the owner assigned, checked server-side on every request and again by the Windows POS before a command commits. Defaults below are starting templates the owner can change per user.

| Capability (default template) | Personel | Müdür | Yönetici | Muhasebe (Optional) |
|---|---|---|---|---|
| Masalar, Sipariş Al, Ek Sipariş, Gel-Al | Yes | Yes | Yes | No |
| Permitted Payments (Cash/Card/Split) | Yes | Yes | Yes | No |
| Cancel / Refund / Void | Per-user grant | Per-user grant | Yes | No |
| Stok Durumu view / edit | View (Edit: grant) | Yes | Yes | No |
| Menü & Kampanya Yönetimi — view | Yes (section visible in Personel app) | Yes | Yes | Read-only |
| Menü & Kampanya — price/product/category/campaign edit, QR publish | Per-operation grant | Per-operation grant | Yes | No |
| Bulut & Senkronizasyon — view status/history/storage/errors | Per-operation grant | Yes | Yes | Read-only (if granted) |
| Bulut & Senkronizasyon — manual sync, retry, auto-sync settings | Per-operation grant | Per-operation grant | Yes | No |
| Bulut — initial migration, cloud configuration, full resync | **Owner only** (non-delegable, MFA) | Owner only | Owner only | No |
| Yedekleme — view history / verification status | Per-operation grant | Yes | Yes | Read-only (if granted) |
| Yedekleme — manual backup, automatic backup settings, verify backup | Per-operation grant | Per-operation grant | Yes | No |
| Yedekleme — database restore | **Owner only** (non-delegable, MFA, Windows-local confirmation) | Owner only | Owner only | No |
| Mesailerim & Maaş/Avans (Own) | Own only (RLS) | Own only (RLS) | Own + All | Read-only export (if granted) |
| Finans, Satışlar, Raporlar, Yoğunluk | No | Scoped grant | Yes | Scoped read/export |
| Personel, Kullanıcılar & Yetkiler, Cihazlar | No | No | Yes | No |

## 10. Staff & Manager Functional Parity & Reuse Map

Preserve all working Turkish UI labels and existing screen flows. Do not redesign working screens without functional justification.

### 10.1 Personel Screens (Android APK + iPhone PWA Parity)
First screen after login remains **Masalar** (fast table access, large touch targets, no unnecessary product photos in ordering lists):
1. **Masalar:** Masa 1–5+ status, active totals, open orders, additions, permitted table transfers.
2. **Sipariş Al / Ek Sipariş:** Categories, instant search, quantities, custom products, campaign selections, notes, removed ingredients, live stock validation.
3. **Gel-Al:** Channel (`Tezgahtan` / `Telefon`), customer name, phone only if operationally required and protected (**never** on print snapshot), promised time, additions, mark delivered.
4. **Online Siparişler:** Unified view of Trendyol Go, Yemeksepeti, Migros Yemek with clear platform badges; action buttons (`Kabul Et`, `Hazır`) enabled **only** for verified, active integrations (never fake/demo actions).
5. **Ödemeler:** Cash/card, mixed, partial, and item-split payments, cash received/change calculation, live remaining balance check.
6. **Fişler:** Permitted receipt preview and print request with explicit confirmation/error/ambiguous states.
7. **Stok Durumu:** Live availability toggles and authorized stock adjustments.
8. **Mesailerim:** Own shift history, `Mesai Başlat` / `Mesai Bitir`, visible audited owner corrections.
9. **Maaş & Avans:** Own wage, advance, and payout history only (strict RLS isolation).
10. **Bildirimler:** Scoped operational alerts, pending command queue status, and sync/offline indicators.
11. **Profil:** Account info, trusted devices, `Şifre Değiştir`, `PIN Sıfırla`, `Çıkış Yap`.

### 10.2 Yönetici Screens (Responsive Web Dashboard — Laptop, Android, iPhone)
Shares the Cloudflare-hosted PWA shell with role-gated `/yonetici/*` routes (also check `.github/workflows/flutter-yonetim-android.yml` in Phase 0 to document existing native manager packaging and preserve it unless owner explicitly approves replacement):
- **Genel Bakış:** Gross sales vs. actual collections, Nakit/Kart breakdown, unpaid balances, refunds, order counts, average ticket, active tables/pickups, platform net deductions (preserving PR #20 logic), previous-period deltas, and prominent `Son Senkronizasyon` freshness indicator.
- **Satışlar & Yoğunluk Grafikleri:** Hourly/weekday heatmaps, top products/categories, channel split, date filters — all reconciled directly against raw `orders` + `payments` tables.
- **Finans:** Daily market-linked material purchases, suppliers, fixed expenses (preserving PR #26 history & no-future-date validation), operating expenses, payroll, platform commissions, and estimated net operating result (explicitly labeled as estimated operational result, not statutory accounting profit).
- **Raporlar:** Daily/weekly/monthly reports, CSV/PDF export, exact financial definitions matching Windows POS (preserving PR #25).
- **Personel Yönetimi, Mesai Yönetimi, Maaşlar:** Employee directory, shift approvals/corrections, hourly/weekly payroll, advances, payouts.
- **Açık Hesaplar (existing functionality only, if present):** Preserve authorized local account balances, settlements and necessary order links; do not introduce a customer directory or CRM. Platform customer details are accessed through the authorized API only as required for active order operations (Section 19).
- **Menü Yönetimi, Stok, Kampanyalar:** Authoritative command-based edits + QR menu publish status and deployed-version verification (`cms/pos-managed-status.json` + `cms/pos-managed-menu.json`).
- **Entegrasyonlar:** Trendyol Go, Yemeksepeti, Migros Yemek, Google Business Profile — honest status (`Aktif`, `Salt Okunur`, `Onay Bekliyor`, `Yapılandırılmadı`).
- **Kullanıcılar & Yetkiler, Bağlı Cihazlar, Bulut & Senkronizasyon, Yedekleme & Geri Yükleme, İşlem Geçmişi:** Full owner administration and security audit trail.

### 10.3 Shared Sections in BOTH Applications (V5.1)
`Menü & Kampanya Yönetimi`, `Bulut & Senkronizasyon` and `Yedekleme & Geri Yükleme` appear in **Nohut Personel** and **Nohut Yönetici**, on Android APK and iPhone PWA. Each button is rendered from the user's effective grants: a missing grant hides or disables the control with a Turkish explanation (`Bu işlem için yetkiniz yok`) — the server still rejects a forged call. Full content and gates: §20.2.

---

## 11. Printing, Payments, and Transactional Integrity

### 11.1 Mandatory Regression Gate: First Gel-Al Receipt Bug (PR #27)
- **Known Root Cause:** `newLocalOrder` previously created an order with empty customer fields and immediately invoked `queueLocalKitchen`, freezing an immutable print snapshot *before* callers (`_composer` and `submitStaffOrder`) populated the pickup customer's name and promised time.
- **Verified Status (Nov 27, 2026):** Draft **PR #27** (`fcc6ffc`) claims to fix this alongside consolidating `MUTFAK` + `SİPARİŞ FİŞİ` into a single 48 mm Xprinter XP-237B `SİPARİŞ FİŞİ`, **but PR #27 is NOT yet merged into `main`**.
- **V5 Requirement:** In Phase 0, inspect `main` and PR #27 diffs. Ensure validated customer name and promised time are passed into `newLocalOrder` **before** the initial print snapshot is created across **all** entry paths (Windows composer, LAN `staff_commands`, Android, and iPhone PWA). Enforce that customer phone number is **never** written into `receipt_snapshots` or printed output. Add automated tests asserting both the **first** receipt and subsequent additional-order receipts.

### 11.2 Command State Machine & Idempotency Rules

The JSON below is the server-created immutable envelope, not a trusted client payload. Client sends action, target, expected entity version and request ID; backend derives restaurant, actor, session, hash, expiry and permissions. Include authority epoch, schema version, authenticated issue time and claim lease generation. Compute hash over canonical immutable envelope (document normalization; exclude mutable status). Check caller authorization before returning cached results. Request ID must remain unique across restore and long-lived retries; expired or unknown pre-epoch commands are rejected. Expected entity version is the concurrency guard; do not reject an unrelated table because global revision advanced unless command actually depends on whole-state revision. Revalidate stock/price, financial balance and permission in SQLite transaction. Cloud claims do not themselves prove a local commit; publish confirmation only after stored command receipt is durably acknowledged. If physical terminal/payment provider or delivery platform outcome is uncertain, query provider state or require owner reconciliation before retrying. Never assume local idempotency makes an external non-idempotent API exactly-once.
Every remote mutation (`create_order`, `add_order_items`, `record_payment`, `refund_payment`, `cancel_order`, `print_receipt`, `clock_in_out`, `platform_action`, `update_menu`, `update_stock`) uses a single unified contract:

```json
{
  "request_id": "uuid-v7",
  "restaurant_id": "uuid",
  "actor_employee_id": "derived-from-jwt-server-side",
  "device_session_id": "uuid",
  "action_type": "record_payment",
  "expected_revision": 14820,
  "entity_id": "ord_1042",
  "expected_entity_version": 3,
  "payload_sha256": "hex",
  "expires_at": "2026-11-27T14:05:00Z",
  "payload": {}
}
```

- **State Machine:** `pending` → `processing` (claimed by Windows POS with lease) → `confirmed` | `conflict` | `rejected` | `expired` | `reconciliation_required` (uncertain side effects).
- **Idempotency:** Windows POS checks `command_receipts(request_id)` inside the same SQLite transaction as the business mutation:
  - Same `request_id` + same `payload_sha256` → return stored `result` immediately (no duplicate local business mutation; physical/external outcome must be handled separately).
  - Same `request_id` + different `payload_sha256` → reject with `409 IDEMPOTENCY_PAYLOAD_MISMATCH` + security audit log.
- **Staleness & Expiry:** Time-sensitive actions (`record_payment`, `refund_payment`, `print_receipt`, `platform_action`) expire after a bounded TTL (e.g., 5 minutes for print/platform actions, 15 minutes for payments) so a command queued before a 2-hour outage is **never** blindly replayed after reconnect.
- **Ambiguous Printer Acknowledgements:** Physical USB/thermal printers cannot guarantee exactly-once physical paper output if power drops mid-feed. Mark uncertain jobs `ambiguous` and require an explicit staff `Tekrar Yazdır` click (creating a new `print_job` referencing the original snapshot) rather than silent auto-retry.
- **Financial Precision:** Store and reconcile all monetary amounts in exact integer kuruş (`BIGINT`) or `NUMERIC(12,2)` — never binary floating-point comparison for balances or refunds.

---

## 12. Backup, Disaster Recovery, Security, and Turkish KVKK Compliance

### 12.1 Encrypted Backup & Cross-Machine Restore (Phase 1 — First Milestone)
Backup scope and transfer destination must respect Section 19: a consistent local pre-migration snapshot may include legacy personal fields and must remain protected locally until its separate retention and transfer review. Never assume encryption alone authorizes an off-site transfer. Preserve required recovery material and records, not unnecessary long-lived transient API caches.
1. **Consistent Snapshot:** Reuse `PosStore.backup()` (`VACUUM INTO`) to capture `state_snapshot`, `command_receipts`, `deleted_requests`, `sync_outbox`, `sync_state`, and any future local tables consistently while WAL is active. Bundle a JSON manifest (`schema_version`, `revision`, `created_at`, `pos_app_version`, `table_counts`, `sha256_uncompressed`).
2. **Compression & Authenticated Encryption:** Compress with `gzip`/`zstd` (compression ratio must be measured), then encrypt with **AES-256-GCM** using a random 96-bit nonce per backup and a 256-bit key derived via **Argon2id** (or PBKDF2-HMAC-SHA256 ≥600,000 iterations) from an **owner-held Recovery Key** (32-byte random base32/passphrase printed/stored offline by the owner, independent of the Windows user profile/DPAPI). Authenticate the manifest as AES-GCM AAD so tampering is detected immediately.
3. **Storage & Retention (Decoupled from Supabase 1 GB):**
   - Always keep a rolling local backup folder + optional local USB drive mirror.
   - Off-site destination (owner-approved): **Option A (0 TL, no card):** Owner's dedicated Google Drive / OneDrive app folder (15 GB / 5 GB free); **Option B (0 TL up to 10 GB, card on file):** Cloudflare R2 private bucket. **Never** use a public GitHub repo.
   - **Recommended Schedule & Retention:** Daily automatic encrypted backup at closing + configurable intra-day backup based on owner-approved RPO/RTO + pre-migration/pre-first-sync and manual `Şimdi Yedekle`. Live replication is NOT a backup and may lag/offline. Proposed 7 daily + 4 weekly + 6 monthly snapshots only if measured capacity permits; adjust with owner-approved retention, no silent deletion. Maintain independent offline/offsite copy and verify restore. A single PC disk failure can lose all unsynced transactions since last recoverable backup; surface risk and last verified recovery point.
4. **Safe Staged Restore Procedure:**
   - Download/select backup → prompt for Owner Recovery Key → decrypt & verify AAD/SHA-256 → run `PRAGMA integrity_check` on staged SQLite file → display metadata comparison (backup date/revision vs. current DB) → require explicit owner confirmation → pause writes & sync worker → take safety backup of current DB → close all SQLite handles, checkpoint/handle WAL and SHM correctly, stage atomic replacement with fsync/rollback journal for restore → suppress historical print jobs and old command replay → reauthorize devices/integrations. Keep sync and remote writes disabled. Fence prior writer, mint new authority epoch only after reconciling local restored checkpoint with verified cloud and any archived changes, quarantine commands from older epochs, reconstruct newer committed records only using audited recovery workflow. If cloud is newer, never upload stale restore over it; show missing data and owner-approved reconciliation. Reconcile external platform/payment/printing outcomes separately. Preserve current DB and rollback on failure; verify no data beyond backup is silently lost. Test physical power interruption and recovery without original PC.

### 12.2 Security Threat Model & Turkish KVKK Legal Requirements
- **KVKK Article 9 — legal gate, not a legal determination:** Review current Law No. 6698 Art. 9 ([official text](https://www.kvkk.gov.tr/Icerik/6649/Personal-Data-Protection-Law)) and [authority announcement/standard contract materials](https://www.kvkk.gov.tr/Icerik/7999/Announcement-on-the-Translation-of-By-Law-on-The-Procedures-And-Principles-For-the-Transfer-of-Personal-Data-Abroad-and-Standard-Contract-Texts). Determine lawful processing basis and applicable transfer mechanism, including adequacy, appropriate safeguards or narrow exceptional grounds as applicable. If relying on standard contract, the law requires notification within five business days after signature. Do not assume blanket consent, encryption or pseudonymization resolves a recurring cross-border transfer. Do not assert zero adequate countries or that a provider will/will not sign without current official verification. Obtain qualified Turkish legal review and provider contract/region/subprocessor evidence before production.
- **Production gate:** No real personal data (including auth identities, IP/session logs, employee payroll, customer contacts, analytics, backups/archives and support logs) transferred to unapproved foreign services. Domestic hosting also needs review of subprocessors, backups and remote support. Pseudonymized data may still be personal data. Fully anonymized non-personal aggregates may be considered separately after review; cannot label that as full sync. Apply access/retention/deletion rights and legally required record preservation to live DB, local archive, backup expiry and cloud restore. Review provider policies for third-party platform data (Google/food platforms). Owner must explicitly approve lawful destinations, retention and cost before upload; if unresolved, continue local operation and synthetic development. Do not require real data for tests.
- Standard PostgreSQL helps portability, but Supabase Auth, RLS integration, Realtime, Storage and Edge Functions are provider-specific. Keep adapters/contracts and migration/export tests; a domestic replacement requires auth/data migration and security verification, not merely changing a connection string.

- **Threat Mitigations:**
  - Zero service-role keys, DPAPI secrets, or platform API keys in APK, PWA bundle, or git.
  - RLS plus minimum grants, private schemas and secure views/RPCs on exposed resources; test service-role bypass, auth/session revocation, object access, direct REST, Realtime and cross-restaurant isolation. `FORCE ROW LEVEL SECURITY` alone does not constrain a BYPASSRLS role.
  - Structured safe logging: automated redaction filter stripping `password`, `pin`, `token`, `authorization`, `phone`, and `recovery_key` from all logs and crash reports.

---

## 13. Realistic Storage, Backup & Bandwidth Simulation

The inherited figures in Sections 13.1–13.3 are an unoptimized planning reference, not a measured Nohut baseline or a promise of V5 savings. Section 19 adds compact-footprint scenarios and mandatory benchmarks.

### 13.1 Measured Baseline vs. Explicit Assumptions
- **Measured from Repo:** `cms/pos-managed-menu.json` = **46.6 KB**; `cms/menu-prices.json` = **4.02 KB**; local SQLite uses 3 tables (`state_snapshot`, `command_receipts`, `deleted_requests`). *(Actual production `nohut-pos.sqlite3` size was not accessed; owner/Claude Code should measure it locally in Phase 0 without uploading it.)*
- **Explicit Modeling Assumptions:**
  - **Raw per-order logical data:** ~5.5 KB/order (order + ~2.8 items + ~1.2 payments = 2.8 KB; 48 mm thermal receipt snapshot = 1.2 KB; command receipt + audit = 1.5 KB).
  - **PostgreSQL (Supabase) footprint (uncompacted):** ~12.1 KB/order (×2.2 tuple/index/MVCC overhead) + 15 MB base + 31.2 MB/yr non-order records (finance, shifts, payroll, stock, audit).
  - **SQLite / Cloudflare D1 footprint:** ~8.0 KB/order (×1.45 B-tree/index overhead) + 2 MB base + 20.4 MB/yr non-order records.
  - **Encrypted compressed backup:** ~28% of SQLite size (gzip/zstd on text/JSON).
  - **Attachments (Object Storage, NOT Postgres):** ~30 compressed expense photos/mo × 150 KB = 54 MB/yr (270 MB over 5 years).
  - **Monthly Egress (5 active devices):** 5 devices × 0.5 MB/day startup + 4 Realtime updates/order × 5 devices × 2.5 KB + 150 MB manager queries.

### 13.2 Corrected scenario table (illustrative, not measured)
Using decimal MB/KB and 365 operating days: PostgreSQL size(y) = 15 + y × (365 × orders/day × 12.1 / 1000 + 31.2) MB; SQLite size(y) = 2 + y × (365 × orders/day × 8 / 1000 + 20.4) MB. Backup = 0.28 × SQLite; 17 equally large snapshots is a conservative storage upper approximation, not a measured retention forecast. Egress per 30-day month = 225 + 1.5 × orders/day MB under the V3 stated assumptions. All inputs are hypothetical; no production DB measurement has occurred. Actual Postgres indexes, TOAST, bloat, WAL/disk, attachments and request overhead must be measured separately.

| Orders/day | Postgres Y1 MB | Y3 MB | Y5 MB | 500 MB reached from empty | SQLite Y5 MB | One compressed backup Y5 MB | 17 backups Y5 | Monthly egress |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 30 | 178.7 | 506.1 | 833.5 | 2.96 years | 542.0 | 151.8 | 2.58 GB | 270.0 MB |
| 50 | 267.0 | 771.1 | 1,275.1 | 1.92 years | 834.0 | 233.5 | 3.97 GB | 300.0 MB |
| 100 | 487.8 | 1,433.5 | 2,379.2 | 1.03 years | 1,564.0 | 437.9 | 7.44 GB | 375.0 MB |
| 150 | 708.7 | 2,096.0 | 3,483.4 | 0.70 years | 2,294.0 | 642.3 | 10.92 GB | 450.0 MB |
| 200 | 929.5 | 2,758.5 | 4,587.5 | 0.53 years | 3,024.0 | 846.7 | 14.39 GB | 525.0 MB |

### 13.3 Capacity, archival and owner access
- 500 MB is not enough to promise all records live online forever. At 100 orders/day even halving only the per-order Postgres assumption leaves a five-year footprint above 500 MB; never promise 45–50% savings without measurement. Show measured base/data/index sizes, disk/WAL usage separately, attachment and backup usage, local outbox growth, egress and API quotas. Benchmarks at realistic historic scale precede cloud provider selection and compaction.
- Preserve all authorized existing and future business records, including receipt content, cancellations, platform outcomes and historical detail. Public QR image references can be reused; reports may be generated on demand only where original documents are not required. Compression/deduplication must preserve original semantics and required evidence; don't downsample original invoices when legally/operationally required. Keep protected originals if necessary.
- Hot/cold storage is an optional owner-approved capacity design, NOT a silent deletion or replacement of full-history remote access. An archive must be independently encrypted, indexed by tenant/date/entity, verified before removal, recoverable through authorized on-demand retrieval/export from owner dashboard when PC is off if remote access is promised; disclose archive availability and latency. If only local archive is feasible, explicitly label historical data unavailable remotely and do not declare full remote parity. No pruning of idempotency protections without a proven replay/epoch strategy. If no lawful and free storage can meet all-data remote requirement, stop cloud expansion, keep complete local data/outbox/backup, present measured choices: approved archive, domestic/alternative service, or owner-approved paid plan. No silent purges or extra paid project.
- Warning thresholds 70/85/95% of relevant quota; forecast headroom and preflight first sync based on measured growth, not a universal hard 75% cut-off. At quota pressure, display actual capacity and failure, pause unsafe writes to cloud and keep local operations with durable backlog. Supabase 500 MB quota differs from 2 GB disk and 95% disk read-only threshold ([official size docs](https://supabase.com/docs/guides/platform/database-size)). No guaranteed unlimited free tier. Don't generate artificial keepalive traffic to circumvent inactivity rules; show pause/unpause instructions and owner reminders.

---

## 14. Practical Operational Improvements

| Improvement | Operational Benefit | Feasibility & Complexity | Cost / Security Impact | Priority & Release |
|---|---|---|---|---|
| **1. `state_snapshot` Local Compaction (benchmark-driven)** | Prevents Windows POS UI lag from rewriting a multi-MB JSON blob on every order | High / Medium | 0 TL target / requires migration and report parity proof | **High — benchmark in Phase 0; conditional migration in Phase 6 or earlier if needed** |
| **2. Shift-Close Z-Report Reconciliation Check** | Automatically verifies Local SQLite vs. Cloud daily totals (Nakit/Kart/Online/İade) at closing | High / Low | 0 TL / Catches silent sync drift early | **High — Current Release (Phase 2)** |
| **3. Shared Counter Fast PIN Switch** | Allows multiple cashiers on the single Windows PC without sharing credentials or logging out | High / Low | 0 TL / Eliminates staff impersonation | **High — Current Release (Phase 3)** |
| **4. Secure `Yerel Ağ Yedek Modu` for iPhones** | Verified trusted HTTPS local endpoint, optional QR to that origin only; otherwise offline drafts | Conditional / Medium | Cost/TLS feasibility to verify | **Medium — Phase 5 feasibility gate** |
| **5. Supabase 7-Day Pause Watchdog & Holiday Reminder** | Alerts owner if no sync occurred for 5 days so cloud doesn't silently pause during holidays | High / Low | 0 TL / Prevents surprise remote outage | **Medium — Current Release (Phase 2)** |
| **6. Optional Expense Photo Preview Compression** | Generate smaller previews without replacing required originals; strip unnecessary EXIF from previews | Conditional / Low | Measure actual savings; preserve required originals | **Medium — Future Release (Phase 6+)** |

---

## 15. Staged Implementation Plan, PR Sequence & Acceptance Gates

Work on isolated feature branches with small, reviewable PRs (<600 LOC where feasible) and feature flags (`cloudSyncEnabled`, `cloudAuthEnabled`, `remoteCommandsEnabled`) defaulting to `false`.

| Phase | Ordered PR Sequence | Key Dependencies & Rollback Strategy | Hard Acceptance Gate Before Next Phase |
|---|---|---|---|
| **Phase 0: Audit & Baseline** | `PR-01`: Complete `docs/cloud-sync/data-inventory.md` and V5 size/PII baseline, reconcile PR #27 (first Gel-Al receipt regression and verified fix required) + open PRs, add Sync Registry drift test | No schema change; pure docs + tests + PR #27 regression fix | Baseline `flutter analyze` & `flutter test` green; first Gel-Al receipt verified on all local paths |
| **Phase 1: Encrypted Backup & Restore** | `PR-02`: `BackupContainer` (VACUUM INTO + gzip + AES-256-GCM + Recovery Key)<br>`PR-03`: `BackupStorageAdapter` (Local/USB + owner cloud adapter) & `Yedekleme ve Geri Yükleme` UI | Zero impact on live POS writes; feature-flagged | Synthetic DB encrypted, tampered-file rejected, wrong-key rejected, and **restored on a second clean Windows machine/profile** with no automatic historic print replay |
| **Phase 1B: Local Normalization & Soft Deletion (owner decision 2026-11-27, §21)** | `PR-03b`: per-entity local SQLite tables behind a unified repository (orders, batches, lines, payments, refunds, print jobs, platform orders, finance rows), additive reversible migration from `state_snapshot`, dual-read compare, then single-writer switch; stable IDs for lines and payments; catalog fields no longer copied into every line/snapshot<br>`PR-03c`: remove the 50 000-order ceiling (no replacement limit) + audited soft deletion with tombstones | Depends on Phase 1 verified backup/restore (pre-migration encrypted backup mandatory); rollback = keep reading `state_snapshot` (never dropped until parity proven) | Exact report/financial parity (0.00 TL) against the JSON source for all fixtures; benchmarks 1k/10k/50k/100k before/after (p50/p95 write latency, SQLite size, backup size, projected sync payload); soft-deleted and cancelled orders correct in every report |
| **Phase 2: Outbox, Cloud Schema & First Sync** | `PR-04`: Local `sync_outbox` + `sync_state` migration & diff-on-commit writer<br>`PR-05`: Supabase SQL migrations + V5 normalized/versioned dictionary projection + RLS + reconciliation RPCs<br>`PR-06`: 18-step First-Sync Wizard + Incremental `SyncWorker` + `Bulut & Senkronizasyon` UI | Depends on Phase 1 backup and scoped technical agent/bootstrap auth (implemented before any cloud data transfer); rollback = disable transport flag; retain all pending outbox records and migration history, never drop populated data | Synthetic full first sync passes interrupt/crash/resume, concurrent-order, V5 lossless canonical business projection/PII allowlist, measured storage benchmark and **0.00 TL financial-total reconciliation** tests |
| **Phase 3: Unified Auth & RBAC** | `PR-07`: Supabase Edge Function username login + `device_sessions` + RLS policies + Owner MFA<br>`PR-08`: Windows `Personel Yönetimi` UI + counter PIN switch + offline verifier cache | Depends on Phase 2 schema and bootstrap identity; rollback = keep local auth flag | Direct API forgery, forged `staffId`, revoked device, disabled user, and cross-staff payroll access all return `403` |
| **Phase 4: Read-Only Mobile & PWA Pilot** | `PR-09`: Upgrade `flutter_personel` (both entrypoints: Personel `lib/main.dart`, Yönetici `lib/manager_main.dart`) with unified auth + Supabase read transport + read-only `Menü & Kampanya`, `Bulut & Senkronizasyon`, `Yedekleme & Geri Yükleme` status screens from one shared module<br>`PR-10`: Lightweight TS/Vite iPhone PWAs — two separate URLs/manifests (`Nohut Personel`, `Nohut Yönetici`) from one shared codebase — deployed to Cloudflare Pages (read-only pilot) | Depends on Phase 3 auth | Physical Android APK + physical iPhone Safari Add-to-Home-Screen verified; staleness badges & logout cache-clear verified |
| **Phase 5: Remote Commands & LAN Fallback** | `PR-11`: `command_queue` worker + idempotency + conflict/expiry enforcement on Windows<br>`PR-12`: Enable write commands on Android/PWA + Android authenticated LAN fallback + iPhone secure LAN feasibility / offline drafts | Depends on Phase 4 + verified PR #27 regression fix | Concurrent table edit, duplicate tap, partial/split payment, refund, printer-offline, and outage-reconnect tests all pass |
| **Phase 6: Yönetici Dashboard & Full Parity** | `PR-13`: Yönetici app screens on APK + PWA (Genel Bakış, Yoğunluk, Finans, Raporlar, Menü/Stok/Kampanyalar, Entegrasyonlar) and grant-gated write operations of the three shared sections in both apps (§20.5)<br>`PR-14`: Benchmark-gated local normalization/compaction + authorized cold archive utility | Depends on Phase 5 | Every report total independently recomputed from raw records matches Windows POS to 0.00 TL |
| **Phase 7: Independent QA & Production Cutover** | `PR-15`: Owner Setup Guide (`docs/cloud-sync/owner-setup-guide.md`), QA Coverage Matrix sign-off, KVKK checklist | **Owner Gate:** Owner creates cloud accounts, completes KVKK review, approves backup destination, runs synthetic drill | Zero open P0/P1 defects; owner-authorized First Sync verified on production |

---

## 16. Comprehensive Testing & QA Verification Strategy

A passing build or unit test count is **not** proof of operational correctness. Maintain `docs/cloud-sync/qa-coverage-matrix.md` recording every screen, button, API/RPC, persistence path, and hardware interaction with status (`PASS`, `FAIL`, `PARTIAL`, `MISSING`, `NOT TESTED`, `BLOCKED`) and exact evidence (`Executed Test` vs. `Code Inspection Only`).

### Mandatory Verification Suites
1. **Regression Suite (Existing POS):** Run existing `flutter analyze` and `flutter test` across `flutter_desktop`, `flutter_personel`, and `packages/nohut_core`; verify zero regression in Masa, Gel-Al, Trendyol Go, Finans (PR #26), and Raporlar (PR #25).
2. **Data Round-Trip & Drift Suite:** Synthetic database containing every entity type, Turkish characters (`ğ, ş, ı, İ, ö, ü, ç`), nested customizations, refunds, and tombstones → First Sync → verify 100% row count, SHA-256 checksum, and kuruş-exact financial match.
3. **First-Sync Chaos Suite:** Simulate (a) non-empty cloud DB, (b) unconfigured/unauthorized destination, (c) mid-transfer network drop, (d) process kill + restart, (e) 10 concurrent orders + payments during upload, (f) double-start click, and (g) intentional 1-row mismatch to prove reconciliation catches it.
4. **Concurrency & Financial Integrity Suite:** Two devices editing the same table simultaneously; duplicate `request_id` replay; same `request_id` with mutated amount; partial payment followed by extra items; mixed cash/card + change; void/refund; negative amount rejection; midnight rollover order numbering.
5. **Security & RLS Penetration Suite:** Direct Supabase REST/RPC calls using a `Personel` JWT attempting to read another employee's `payroll_payments`, read `expenses`, forge `actor_employee_id`, or execute after session revocation / account deactivation.
6. **Printing & PR #27 Suite:** First Gel-Al receipt and subsequent additions from Windows, LAN, Android, and iPhone — assert customer name & promised time appear, phone number **never** appears in `receipt_snapshots` or ESC/POS output, printer disconnect produces `failed`/`ambiguous` without losing the order, and restored backup suppresses all old print jobs.
7. **Backup & Disaster Recovery Drill:** Corrupt 1 byte of ciphertext → decrypt fails; wrong recovery key → decrypt fails; cross-machine restore on a fresh Windows user profile succeeds and preserves current DB on simulated mid-restore failure.
8. **QR Menu Privacy & Allowlist Suite:** Attempt to publish with an injected private field (`phone`, `salary`) → publisher fails closed; verify `cms/pos-managed-menu.json` contains public fields only.
9. **Physical Hardware Suite (Clearly Separated from Emulated Tests):** Real Android phone APK install + LAN fallback with router WAN unplugged; real iPhone Safari `Ana Ekrana Ekle`, keyboard/viewport check, logout cache wipe, and verified secure LAN test or documented drafts-only behavior; real Xprinter XP-237B 48 mm print verification.
10. **V5.1 Two-App Permission Suite (§20.6):** for each of the three shared sections and each operation, in both apps and both platforms: granted → allowed; revoked → hidden/disabled in UI **and** rejected server-side and by the Windows authority; owner-only operations rejected for every non-owner even with a forged grant.

---

## 17. Instructions for Claude Code

1. Start with **Phase 0** on a new branch from `main` (`git fetch --all`, record current HEAD SHA and inspect open PRs, especially Draft PR #27 and the unverified files listed in Section 1.3).
2. Produce `docs/cloud-sync/data-inventory.md` from actual source code before writing any sync or backup code.
3. Implement strictly in the Phase 0 → Phase 7 PR order above, using synthetic data only. Never create production cloud accounts, merge PRs automatically, or upload real restaurant data.
4. Report exact commands run, test outputs, commit SHAs, and explicitly separate executed tests from code inspection and owner-gated external setup steps.
5. **Final Reminder:** Preserve all existing restaurant operations. Target 0 TL/month within verified free limits. **No Nohut AI in this release.**


---

## 18. V5 binding implementation clarifications and acceptance gates

These are binding refinements of the preceding sections. If any inherited example conflicts, these safety requirements govern. Do not begin production deployment based on architecture claims alone.

### 18.1 First sync and transaction invariants
- Before data import, provision a private synthetic cloud project or emulator, owner bootstrap authentication/MFA, scoped agent enrollment, schema and access policies. This is a Phase 2 dependency; full employee lifecycle remains Phase 3. Do not use a privileged desktop service-role credential as a shortcut. First production sync requires completed privacy, backup and owner configuration gates.
- Explicit migration states: unconfigured, ready, preflight, backup_verified, snapshot_ready, uploading, paused, catching_up, verifying, verified_pending_activation, active, failed, safely_aborted. Persist exact checkpoint and migration generation on both sides; crash/restart and duplicate start resume same job. Same-migration partial staging is not a nonempty unrelated destination. Cloud data may be invisible to clients until atomic generation promotion; avoid requiring double quota without preflight. Initial sync includes business data, historical records, sidecar policy and permitted attachments, not old active sessions or reusable secrets.
- Outbox must be durable within the same transaction as the business update, command receipt and tombstone. Audit `replace`, `command`, deletion, migrations and every direct SQL/sidecar path; transactional or durable intent + recovery for external files. Do not call network while holding SQLite transaction. Store stable authority UUID/epoch, source revision, transaction ID and contiguous sequence range, versioned schema and canonical event hash. Atomic cloud commit of complete transaction groups or staged bounded chunks with one promotion marker. ACK only durable contiguous watermark, never skip a gap. Duplicate/lost ACK returns same result; test same ID/different body and same version/different hash. Entity deletions use versioned tombstones. No physical side effect on import or replication.
- Snapshot revision MUST come from the consistent snapshot itself; compare outbox high-water there. Reconcile local and cloud at exactly the same revision, using retained reference snapshot/event replay or brief bounded local read fence. Later writes remain queued, not compared against old cloud data. Use canonical sorted manifests with per-category/per-chunk counts and hashes; exact kuruş totals by date/channel/status/payment/refund and balances; check FK and ID sets. Canonical numeric, date, Unicode and nullable field representation must be identical in Dart and server. Do not infer equality from an HTTP success, global sums alone or equal counts.
- `Tam Yeniden Senkronizasyon` separate from manual flush, uses dry run, owner MFA, independent backup, epoch fencing and non-destructive repair. A verified full import must never overwrite a newer generation. Migration and resync commands owner-only. Pause/resume affects upload, not local sales. While auto-sync paused, remote mutations must be visibly disabled or separately owner-approved and processed under safe policy, never appear accepted.
- Owner settings show first-sync status/progress per category, counts/bytes/actual errors, local/cloud revision and pending queues, completion receipt, last success, sync age, automatic toggle ON by default after verified first sync, manual `Şimdi Senkronize Et`, retry, history and backup controls. Auto flush on commit (2–5s target), startup, reconnect; manual same worker; 60s configurable health/checkpoint check. All timing targets subject to measured network/quotas. Never label stale data current.

### 18.2 Full data and security inventory — completion contract
Include all V2 legitimate business categories subject to the explicit V5 no-new-CRM/API-personal-data scope, actual historical entities, attachments, reports' source facts, settings, backup metadata, external platform permissions and future schema keys. For each row specify existing vs proposed, identifiers, ownership, classification, cloud mapping, historical retrieval mode (online/authorized archive/device-local/secret/legal restriction), recovery and retention. No silent exclusions. The requirement is full authorized data preservation and remote access to approved business history; do not substitute aggregate-only replication or a backup-only product. If legal/capacity constraints block full cloud scope, explicitly mark BLOCKED and keep local data intact; obtain owner decision. No external data beyond API terms. Protect payroll/customer data, not just keys. Review KVKK before any real-data transfer, including backups and auth provider. No production account provisioning, cost, uploads or automatic merging without owner approval.

### 18.3 Independent test gates and deliverables
Add tests for: revision read-before-backup race; new order during snapshot; same-migration resume with nonempty staging; lost ACK after cloud commit; wrong epoch and restored stale DB; partial multi-row payment projection; future unknown nested keys; direct bypass of username wrapper; provider token after logout/revocation; old websocket and device/session; owner MFA offline recovery; iPhone TLS failure; 500 MB capacity forecast; archive retrieval when PC off; recover original invoice; no plaintext backup or credential in logs/build. Benchmark full history on synthetic fixture and compare exact Windows/cloud reports for archived and active records. Verify business-day/timezone Europe/Istanbul and UTC instants, daily order numbering, currency integer kuruş, discounts and refunds, cross-midnight and concurrent orders. Keep receipt paper width configuration and verify actual printable area on Xprinter, not assume fixed 48 mm for every profile.

Required versioned engineering deliverables: baseline SHA and open PR conflict register; complete persisted data/write-path inventory; feature/option/API parity matrix; architecture decisions and threat model; versioned schemas and command/sync contracts; reproducible local synthetic fixtures and migrations; owner configuration/runbook with no secrets; current pricing/capacity measurement; backup/restore and epoch recovery runbook; QA evidence per test and physical device; rollback and cutover plan; PR links and exact commands/results. Preserve existing manager Android packaging and Masalar-first employee screen unless owner approves change. No live production platform actions or real card charges during tests; use authorized isolated synthetic printer tests for physical QA. Existing features must stay available.

### 18.4 Provider facts checked and unresolved items
- Supabase official [pricing](https://supabase.com/pricing), [database and disk size](https://supabase.com/docs/guides/platform/database-size), [free project pausing](https://supabase.com/docs/guides/platform/free-project-pausing): 500 MB DB quota and 2 GB disk are different; 7-day low-activity pause is not prevented by a guarantee of traffic.
- Cloudflare [D1 limits](https://developers.cloudflare.com/d1/platform/limits/), [Durable Objects limits](https://developers.cloudflare.com/durable-objects/platform/limits/), [Durable Objects pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/): Free D1 individual DB max 500 MB; free SQLite Durable Objects exist, with 1 GB per object cap. Do not claim one free D1 database is 5 GB or WebSockets require paid. Re-evaluate if needed but avoid custom auth complexity absent proof.
- Supabase [session behavior](https://supabase.com/docs/guides/auth/sessions), [signout](https://supabase.com/docs/guides/auth/signout), [auth hooks](https://supabase.com/docs/guides/auth/auth-hooks), [rate limits](https://supabase.com/docs/guides/auth/rate-limits), [Realtime authorization](https://supabase.com/docs/guides/realtime/authorization): revocation and stale sockets require explicit checks, not blind reliance on expiry or JWT role. Validate feature availability, recovery flow and direct endpoints on selected free plan.
- Browser [mixed content](https://developer.mozilla.org/en-US/docs/Web/Security/Defenses/Mixed_content), [local network access](https://developer.mozilla.org/en-US/docs/Web/Security/Defenses/Local_network_access): no assumption that a public HTTPS PWA can use HTTP LAN; no reusable credential over plaintext.
- Official [KVKK law](https://www.kvkk.gov.tr/Icerik/6649/Personal-Data-Protection-Law), [authority contract announcement](https://www.kvkk.gov.tr/Icerik/7999/Announcement-on-the-Translation-of-By-Law-on-The-Procedures-And-Principles-for-the-Transfer-of-Personal-Data-Abroad-and-Standard-Contract-Texts): counsel and provider-specific contract verification required.
- Other inherited vendor quotas and comparative estimates are planning values; validate official current terms, available region, card/billing requirements, commercial use, SMTP, device installation, storage, backup and provider contracts before selection. Cloudflare R2/Drive/OneDrive optional only after owner confirms actual account quota, OAuth, legal destination and no unexpected billing.
- No Nohut AI, AI analytics endpoints, AI UI or dependencies in this release.

### 18.5 Historical V2/V3 → V4 change log
Retained V3 detailed first-sync wizard, outbox, schema registry, Android/PWA parity and phased PR structure; restored V2's optional Developer staging-only role and owner control over native manager app, manual sync and archival. Corrected provider quota and Durable Object claims, inconsistent storage arithmetic and unmeasured performance guarantees. Fixed snapshot fencing, resumption, atomic group/checkpoint and restore epoch requirements. Hardened local fallback, auth/session and scoped agent design. Made first-sync bootstrap dependency explicit and kept full history remotely accessible or visibly blocked. Expanded legal gate to all personal data and backups without treating pseudonymization as exemption. Phase 0 must verify actual source/PRs and measure actual DB size locally; no real data uploaded during review.

---

## 19. V5 — Compact Storage, Lossless Business History & API-First Customer Data (Binding)

### 19.1 Owner decision and priorities

- Reduce **bytes per record**, not the number of legitimate business transactions. Retain the complete authorized historical business data needed for orders, accounting, operations, receipts, corrections and auditability. No silent loss, no summary-only replacement of history and no deletion to stay below a free quota.
- The owner clarified that the restaurant does not use an independent delivery-customer database; customer details come from Trendyol API. **Do not build a new Müşteriler CRM, persistent third-party customer profiles, marketing directory or cross-platform identity matching.** Existing local Gel-Al details and any actual open-account feature are separate operational/financial obligations; inspect them, preserve them as needed and do not assume they are unused or delete them automatically.
- GitHub remains for code and allowlisted public menu data, not real orders or credentials. Keep the selected SQLite/Supabase architecture subject to capacity, security, cost and legal gates. Nohut AI remains excluded. All V4 first/manual/automatic sync, Android APK, iPhone PWA, owner dashboard, offline-first, security, backup and QA requirements remain binding.
- No production database or real order corpus was measured for V5. All concrete ID assignments, field types, example values and estimated byte sizes below are proposed until verified in Phase 0. The official provider terms and platform data-retention permissions must be checked before activation; do not assume platform data can be fetched forever.

### 19.2 Store references instead of repeated labels

Use compact numeric IDs or stable keys for products, product versions, categories, ingredients, campaign versions, employees, staff roles, tables, channels, payment methods, statuses, suppliers, expense categories and other repeatable dimensions where useful. IDs must be stable across local/cloud/mobile and scoped to the restaurant. A short display code such as `FP` may be a UI/search alias, but must never be the sole identity, a mutable foreign key or a replacement for the display name. Do not manually shorten the Turkish UI or printed receipts. Use a small lookup table or versioned enum for truly finite values; retain unknown platform codes faithfully, and never silently map unknown values to a known status.

Illustrative example (not actual Nohut IDs or prices):

```json
{
  "product_id": 17,
  "version_id": 104,
  "quantity": 2,
  "unit_price_kurus": 25000,
  "discount_kurus": 0,
  "employee_id": 2,
  "table_id": 3,
  "removed_ingredient_ids": [8]
}
```

Dictionary: `product_id=17`, `version_id=104`, display name `Falafel Porsiyon`, category ID, ingredients and applicable campaign definitions. The screen and print still show **Falafel Porsiyon**, 2 × 250.00 TL, the original applicable options and staff/table labels. Store the original realized monetary values in integer kuruş, not just the product's current price. Never derive a historical total from today's price or renamed catalog. Stable order, batch, line, payment, refund and external references are never recycled even if a display number is reused. IDs from different platforms must not collide. Preserve unmatched platform products and custom products as immutable transaction-specific labels/versioned references; never guess a match from similar names.

### 19.3 Immutable history and versioning rules

Proposed normalized schema elements (adapt to actual source, do not apply as unreviewed SQL):

| Entity | Compact representation | Historical invariant |
|---|---|---|
| Products, ingredients, campaigns | Stable ID plus immutable version ID; only one version for identical canonical content within scope | Renames, translations, ingredient changes and promotion edits cannot rewrite old orders |
| Order header / batch / lines | Stable IDs, time, channel, status, references, quantity, actual money, immutable customization details | All ordered/cancelled quantities, original labels, notes and totals remain reconstructible |
| Staff and table | ID references; historical label version or frozen label when required | Renaming/deactivating staff or changing table layout preserves old attribution |
| Payments/refunds | Append-only amounts, references, method code, time, corrections and allocations | Exact totals, cash/card split, refund and change history |
| Platform orders | Platform code plus provider order/package/item identifiers and mapped internal IDs; structured financial and operational facts | Old sales reports work without a historical API call; no inferred commissions or fabricated fields |
| Receipt content | Versioned template, immutable structured receipt facts and referenced immutable dictionaries; retain original required artifact/text when reconstruction is not proven equivalent | Old receipt remains reproducible including Turkish labels, additions, notes, timestamps, cancellations and actual prices |
| Audit and commands | Compact action/actor/entity IDs, immutable outcomes, request identity, canonical hash, versions/epochs and required evidence | Anti-replay protection survives cleanup, restore and retries |

Use foreign keys, versioned dictionaries, and canonical content hashes with actual byte/content comparison when reusing a hash. Avoid excessive dimension tables if they increase size, latency or complexity; benchmark representative data. Never deduplicate separate economic transactions just because their amounts and contents match. Preserve custom free-text notes and original text where they carry business meaning; do not abbreviate or truncate them to save bytes. Do not normalize Unicode, case, null/empty semantics, numeric precision or timestamps in ways that change business meaning. Use tenant-scoped stable identity and versioned serialization. Preserve appropriate historical template/rendering information and original required receipt artifacts, not every repeated raster buffer. No phone on Gel-Al receipts. If a third-party customer name is required on a receipt, handle that field under the platform's operational/retention rules; do not create a reusable profile.

### 19.4 Trendyol and other external platform data policy

Apply at ingestion, API caches, local storage, cloud projection, mobile caches, logs, command receipts, exports, backups and support diagnostics. Start from actual API documentation and existing ingestion/printing logic; do not invent fields, permissions or retrieval guarantees. Extend to Yemeksepeti/Migros only when integrations are authorized.

| Field class | Proposed treatment |
|---|---|
| Order/package/external item IDs, dates, status transitions and action results | Retain stable scoped IDs and permitted historical operational facts; these can still be personal data if linkable; protect accordingly |
| Product/options/quantities, monetary amounts, discounts, commissions, delivery fees, net settlement, taxes if supplied | Store required actual business facts durably in compact typed records; distinguish missing values from zero and estimates from actuals |
| Customer name, phone, delivery address, contact instructions | Obtain via authorized API for active fulfillment when needed; transient scoped display/cache with minimum required fields and owner-approved TTL; no independent customer directory or automatic replication to all clients. Do not store a phone/address if fulfillment does not require it. Retain a particular field only if a documented obligation or approved operational necessity requires it |
| Raw response/webhook JSON, verbose headers or debug logs | No routine permanent duplicate raw response archive. Parse into allowlisted typed records. Only a documented, permitted operational/legal exception may retain a minimal protected payload for a specified time. Never persist credentials or unredacted debug payloads |
| Customer-provided order note or customization | Retain required preparation/business content, separate unnecessary contact details; preserve required evidence. Avoid blind text truncation or overbroad automatic redaction that changes order intent |
| Old orders after API access expires | All retained authorized financial and operational history remains available from local/cloud business records. Show unavailable API-only personal details as unavailable; do not promise historical customer lookup or require it to compute reports |

For active orders, use the existing authorized Windows integration as the API boundary; mobile/owner clients receive only their permitted minimal operational projection. No platform secret in browser/Android. Fetch or refresh API-only details on demand where the provider actually supports it; if not available, show an explicit unavailable state. Offline local operation remains intact using permitted transient operational cache where lawful; if an action genuinely needs missing API data, block that action rather than invent it. Use an explicit `TRANSIENT_API`/`NOT_COLLECTED` classification in the inventory, with source, retention, role and reason. No new platform customer profiles or cross-order PII linkage. Do not equate pseudonymized identifiers with anonymous data. Employee and legitimate local pickup information remain subject to the existing KVKK gate. Check provider terms and local legal duties for receipt retention, accounting evidence and data subjects' rights before deciding a TTL. No guessed universal retention period.

### 19.5 Local Gel-Al and existing balances

For `Gel-Al Telefon`/`Tezgahtan`, keep the order-specific name and pickup time if entered and needed, and a phone only if actually needed for contact. Correct PR #27 on the first ticket and all clients; no telephone number in print snapshots. Keep contact data separately scoped, with approved retention. Do not create saved-customer profiles unless an existing feature is verified and its continued scope is explicitly approved. Existing Açık Hesaplar or local customer-linked financial records, if present, must survive migration with correct outstanding balances, settlements, refunds and legally required attribution. Do not add a CRM or erase legacy obligations on the basis of this clarification. Inventory old personal fields and propose an owner-approved retention/migration plan; do not silently erase, upload or expose them.

### 19.6 Deduplication, storage and network hygiene

1. Store each catalog/label version, image reference and reusable configuration once; avoid copying the complete menu or employee object into every order. Keep local and remote logical representations compatible. Use compact scalar types when actual ranges allow; preserve UUIDs/external IDs when required for identity. Do not weaken ID uniqueness to save bytes.
2. Generate derived reports and optional PDFs on demand from immutable facts. Cache only when justified, bounded and invalidatable. Preserve original documents when legally/operationally required; never replace originals with lossy images merely to save quota. Keep attachments in protected object storage, content-hash dedup within the same access domain, with reference counting, encryption and restore verification. Reuse public QR product-image URLs where appropriate.
3. Serialize outgoing deltas compactly; do not repeatedly send the whole JSON state. Use bounded batches, safe transport compression when supported, canonical encoding for hashes and idempotency, and avoid redundant change broadcasts. Compression of network payloads does not automatically reduce PostgreSQL on-disk size. Preserve atomic transactions and ACK checkpoints from Section 18.
4. Keep necessary indexes and measure index overhead; remove only proven redundant indexes. Use normal supported vacuum/maintenance operations, not destructive cleanup or guaranteed physical size shrinkage. Measure heap, indexes, TOAST, bloat, WAL/disk and storage separately. Compress encrypted backups **before** encryption using supported algorithms, benchmark compression ratios, maintain independent restore tests. Do not assume content-addressed encrypted backup dedup is safe across keys/tenants.
5. Retire acknowledged outbox payload bodies only after durable local/cloud reconciliation, independently verified recovery coverage and safe replay/epoch policy. Keep compact durable event/request identity, canonical hash and committed outcome as required. Never remove pending, ambiguous, failed or still-replayable financial/print/platform actions. Do not retain unnecessary raw API PII in command or audit rows. Define retention for transient caches separately from durable business history.
6. Optional cold archive only as in Sections 13.3 and 18: verified full authorized retrieval, not automatic deletion; preserve remote access when promised and PC is off. If the free plan cannot meet measured requirements, tell the owner and offer alternatives, never quietly omit history or automatically upgrade a paid plan.

### 19.7 Quantitative scenarios (not measured results)

Use the inherited V4 reference: 15 MB fixed + 31.2 MB/year non-order data + 365 × orders/day × physical KB/order ÷ 1000 MB/year. This simplified model assumes 365 trading days, decimal MB and constant order mix. For V5 planning, test 1.5, 3 and 5 KB/order including order-related indexes, snapshots, compact audit and metadata overhead. These are **hypothetical scenarios, not achieved storage sizes or guaranteed savings**. Retain the 12.1 KB/order V4 unoptimized planning reference for comparison. Existing history consumes capacity on day one; these projections start with the assumed 15 MB base, not an already-populated database. Attachments, backups and other quotas are separate; real non-order growth may differ. No promise of remaining below 500 MB indefinitely.

| Orders/day | Physical KB/order | Year 1 MB | Year 3 MB | Year 5 MB | Approx. years to 500 MB from modeled base |
|---:|---:|---:|---:|---:|---:|
| 30 | 1.5 | 62.6 | 157.9 | 253.1 | 10.18 |
| 30 | 3 | 79.0 | 207.1 | 335.2 | 7.57 |
| 30 | 5 | 101.0 | 272.9 | 444.8 | 5.64 |
| 30 | 12.1 | 178.7 | 506.1 | 833.5 | 2.96 |
| 50 | 1.5 | 73.6 | 190.7 | 307.9 | 8.28 |
| 50 | 3 | 101.0 | 272.9 | 444.8 | 5.64 |
| 50 | 5 | 137.4 | 382.4 | 627.2 | 3.96 |
| 50 | 12.1 | 267.0 | 771.1 | 1275.1 | 1.92 |
| 100 | 1.5 | 101.0 | 272.9 | 444.8 | 5.64 |
| 100 | 3 | 155.7 | 437.1 | 718.5 | 3.45 |
| 100 | 5 | 228.7 | 656.1 | 1083.5 | 2.27 |
| 100 | 12.1 | 487.8 | 1433.5 | 2379.2 | 1.03 |
| 150 | 1.5 | 128.3 | 355.0 | 581.6 | 4.28 |
| 150 | 3 | 210.4 | 601.3 | 992.2 | 2.48 |
| 150 | 5 | 319.9 | 929.8 | 1539.8 | 1.59 |
| 150 | 12.1 | 708.7 | 2096.0 | 3483.4 | 0.70 |
| 200 | 1.5 | 155.7 | 437.1 | 718.5 | 3.45 |
| 200 | 3 | 265.2 | 765.6 | 1266.0 | 1.94 |
| 200 | 5 | 411.2 | 1203.6 | 1996.0 | 1.22 |
| 200 | 12.1 | 929.5 | 2758.5 | 4587.5 | 0.53 |

At 100 orders/day, the 3 KB scenario corresponds to 109.5 MB/year of order-related storage, 140.7 MB/year total assumed growth, and 155.7 MB total after year one. It is not a production benchmark. Relative to the 12.1 KB assumption, the 3 KB scenario is approximately 75% smaller for the order-related portion only, not necessarily for the whole database. Shortening `Falafel Porsiyon` to `FP` alone cannot produce this saving. Measure actual SQL overhead and all record classes before choosing a cloud capacity strategy. If production data is already available locally, measure it on the restaurant PC without transmitting its contents.

### 19.8 First sync, manual sync and settings changes

Keep `Ayarlar → Bulut & Senkronizasyon → İlk Senkronizasyonu Başlat`, then `Şimdi Senkronize Et` and automatic incremental sync enabled by default after verified first import. Add the following owner-only diagnostics to the existing settings design (proposed Turkish labels): `Veri Boyutu`, `Bulut Depolama Kullanımı`, `Yerel Veri Boyutu`, `Tahmini Veri Artışı`, `Veri Türlerine Göre Kullanım`, `Senkronizasyon Kuyruğu`, `Veri Bütünlüğünü Kontrol Et`. No destructive “storage cleanup” button. Before the first sync, show source and eligible projected entity counts, estimated storage including indexes/metadata, archived/device-local/transient/excluded categories with reasons, available quota, and unresolved classifications as blockers. Do not reveal raw customer contacts in this report.

First sync must create all required dictionary/version references before publishing dependent orders; retain atomic snapshot fencing and ongoing outbox capture from Sections 5 and 18. A first sync interrupted halfway resumes the same migration and mapping, not a new set of IDs. Verify source-versus-projection counts per domain, relationship integrity, exact financial totals, immutable historic display and receipt reconstruction, approved attachment checksums, and explicitly excluded/transient fields. The canonical comparison excludes only documented policy omissions and redundant representations; keep separate integrity verification of the protected local backup. A byte-for-byte copy of raw provider responses is neither required nor permitted as a general sync strategy. Mark active only when eligible data is fully reconciled and all required dependencies exist. Manual sync flushes deltas through the same worker; automatic remains incremental. Quota warnings and capacity stop rules in V4 remain unchanged.

### 19.9 Implementation and acceptance gates for Claude Code

**PR-01 / Phase 0:** inspect every actual persistence path and platform ingestion path; produce `docs/cloud-sync/data-inventory.md`, `docs/cloud-sync/storage-benchmark.md`, and `docs/cloud-sync/platform-data-policy.md`. Record current commit SHA, existing customer/open-account features and actual data mapping. Classify legacy raw payloads, phone fields and receipt fields. Measure a synthetic realistic dataset before proposing a migration; optionally provide a local-only diagnostic to measure actual production size/counts without exporting records. Benchmark 1k/10k/50k orders with realistic Turkish text, multi-item campaigns, cancelled lines, partial payments, refunds, print snapshots, platform status events and audit; measure total bytes, per-entity size, per-order slope, p50/p95 write latency, sync bytes, index/TOAST and backup size separately. Record commands, fixture seed, DB version and exact results. No fabricated compression percentage.

**PR-04/05 / Phase 2:** build normalized versioned projection and stable-ID registry; add recursive schema drift/allowlist validation and versioned migration tests. Preserve local original state and safe rollback; use additive migrations and dual-read/compare during migration, not dual-authoritative writes. Gate any local normalization on actual benchmark results and full functional parity. Enforce allowlists at server and local ingestion; reject unknown sensitive fields from projection pending review, not from necessary local restaurant operations. Add compact audit/outbox with durable request identity and no raw PII. Test first sync on the compact schema before enabling remote reads.

**Phase 4–7:** test historical UI/receipt display across Windows, Android and iPhone after rename, price change, category/ingredient change, employee deactivation, deleted product, unknown platform product, campaign replacement, and archive retrieval. Test API outage and expired API history, access denied, cache expiry, logout and role isolation. Verify no third-party CRM is created; test that no phone/address or raw API response leaks into public QR, cloud projections, print snapshots, logs or backups except explicitly authorized field-specific retention. Test local pickup name/time on first receipt with no phone. Validate open accounts, split payments and refunds exactly, replay after cleanup/restore and duplicate request detection. Require authorized physical device/printer tests separately from synthetic tests.

**Hard release gates:** 100% of eligible business data mapped and verified; all explicit exceptions documented; zero financial reconciliation discrepancy; no unresolved P0/P1 defect; no missing history due to mutable dictionary references; no accidental third-party customer database; no unapproved PII transfer; measured capacity/latency and rollback runbook accepted by owner; no automatic paid plan, production upload or merge. If storage objectives fail, report measured alternatives and retain data rather than declaring success. Nohut AI excluded.

### 19.10 V4 → V5 change log

- Owner clarification: no new platform customer database; external customer details API-first, operational and minimized; keep required local pickup details and existing financial obligations separately.
- Normalized stable IDs/immutable versions instead of repeated product/ingredient/staff/table names, preserving full UI labels and historical sale prices; protect custom/unmapped product text and all financial facts.
- Compact receipt and audit representation, deduplicated safe attachments and generated reports; no raw platform response duplication or unsafe pruning of anti-replay history.
- Added measurable size scenarios, explicit source/projection reconciliation, storage diagnostics, phase-specific migration and regression tests. V4 safety requirements preserved; no production code or real data changed by this document.

---

## 20. V5.1 — Two Separate Applications, Three Shared Sections & Per-Operation Permissions (Binding)

### 20.1 Applications and distribution
| Application | Android | iPhone | Audience |
|---|---|---|---|
| **Nohut Personel** | Native Flutter APK (`flutter_personel`, entrypoint `lib/main.dart`, workflow `flutter-personel-android.yml`) | Dedicated PWA URL (e.g. `personel.<domain>`), own manifest/icon | Staff; Masalar-first |
| **Nohut Yönetici** | Native Flutter APK (same Flutter package, entrypoint `lib/manager_main.dart`, workflow `flutter-yonetim-android.yml`) | Dedicated PWA URL (e.g. `yonetici.<domain>`), own manifest/icon | Owner / managers |

- Two separately installable apps per platform (different Android application IDs and launcher names; different PWA origins or scopes so Home Screen installs, storage and logout are isolated). Exact domains are owner-gated; Cloudflare Pages free tier, 0 TL.
- **No duplicated business logic:** both Android apps use `packages/nohut_core` and one shared Dart feature module for the three sections; both PWAs are built from one TS/Vite codebase with two entry configurations. Pricing, sync state, backup state and permission evaluation come from the same versioned contracts (`docs/contracts/v1/`) and the same authority (Windows POS + cloud projection). The apps differ only in navigation, default landing screen and which sections the user's grants unlock.
- All previous V5 requirements remain: offline-first, Windows single-writer authority, compact storage, lossless history, KVKK gates, 0 TL target, Nohut AI excluded.

### 20.2 The three shared sections (content in both apps, both platforms)
**Menü & Kampanya Yönetimi**
- Ürün yönetimi (create/edit/deactivate; new immutable product version per change)
- Fiyat güncelleme (versioned; never rewrites historical order prices)
- Kategoriler
- Kampanya yönetimi (versioned campaign definitions and components)
- Stok / satış durumu (availability toggles)
- QR menü senkronizasyonu ve yayın durumu (published version, last publish result, `cms/pos-managed-status.json` verification)

**Bulut & Senkronizasyon**
- Bağlantı Durumu
- İlk Senkronizasyon durumu and authorized setup (owner-only start/resume)
- Şimdi Senkronize Et (manual sync — same single SyncWorker, §6.2)
- Otomatik Senkronizasyon settings
- Son Başarılı Senkronizasyon
- Bekleyen İşlemler
- Senkronizasyon Geçmişi
- Depolama Kullanımı (measured, §19.8)
- Hata Tanılama ve Tekrar Dene

**Yedekleme & Geri Yükleme**
- Şimdi Yedekle (manual backup)
- Otomatik Yedekleme settings
- Yedekleme Geçmişi
- Yedek Doğrulama (decrypt + checksum + integrity check of a chosen backup)
- Veritabanı kurtarma / geri yükleme durumu (status of any staged or completed restore)

**Execution boundary:** mobile clients never touch SQLite, backup files or keys. Every write in these sections is a §11.2 command executed by the Windows POS (or, for cloud-configuration reads, by the scoped backend). If the Windows POS is off, write controls show *"Kasa Çevrimdışı"* and stay disabled; status screens show last-synced values with a staleness badge.

### 20.3 Per-operation permission model
- Permissions are **individual operation grants** (stable string IDs), not roles. Roles (Personel, Müdür, Yönetici, Muhasebe) are only default templates. The owner can grant or revoke any delegable operation per user from `Kullanıcılar & Yetkiler`, on Windows or in the Yönetici app.
- Every grant change is an owner command: versioned (`permission_version`), audited (who, when, before → after), immediately invalidates cached UI state; server and Windows re-check the live grant on every request (§9.1). Offline devices lose access no later than their bounded offline lease.

| Operation ID | Section | Default: Personel | Müdür | Yönetici | Sensitivity |
|---|---|---|---|---|---|
| `menu.view` | Menü & Kampanya | ✓ | ✓ | ✓ | normal |
| `menu.product.edit` | Menü & Kampanya | – | ✓ | ✓ | elevated (confirm) |
| `menu.price.edit` | Menü & Kampanya | – | – | ✓ | elevated (confirm, shows old → new) |
| `menu.category.edit` | Menü & Kampanya | – | ✓ | ✓ | elevated |
| `menu.campaign.edit` | Menü & Kampanya | – | – | ✓ | elevated |
| `menu.stock.toggle` | Menü & Kampanya | ✓ | ✓ | ✓ | normal |
| `menu.qr.publish` | Menü & Kampanya | – | – | ✓ | elevated (public output; allowlist check) |
| `sync.view` | Bulut & Senk. | – | ✓ | ✓ | normal |
| `sync.manual` | Bulut & Senk. | – | ✓ | ✓ | normal |
| `sync.retry` | Bulut & Senk. | – | ✓ | ✓ | normal |
| `sync.auto.configure` | Bulut & Senk. | – | – | ✓ | elevated |
| `sync.initial.start` | Bulut & Senk. | – | – | owner | **owner-only, non-delegable**, MFA + backup verified |
| `sync.cloud.configure` | Bulut & Senk. | – | – | owner | **owner-only, non-delegable**, MFA |
| `sync.full_resync` | Bulut & Senk. | – | – | owner | **owner-only, non-delegable**, MFA + dry-run |
| `backup.view` | Yedekleme | – | ✓ | ✓ | normal |
| `backup.manual` | Yedekleme | – | ✓ | ✓ | normal |
| `backup.auto.configure` | Yedekleme | – | – | ✓ | elevated |
| `backup.verify` | Yedekleme | – | ✓ | ✓ | normal |
| `backup.restore` | Yedekleme | – | – | owner | **owner-only, non-delegable**, MFA + local Windows confirmation |
| `backup.delete` / any destructive cleanup | Yedekleme | – | – | owner | **owner-only**; V5 forbids silent deletion; requires retention policy + confirmation |

Sensitive-action rules:
1. **Owner-only non-delegable:** `sync.initial.start`, `sync.cloud.configure`, `sync.full_resync`, `backup.restore` and every destructive change. The grant UI cannot assign them; the server rejects them for any identity that is not the verified owner, regardless of stored grants.
2. **Owner confirmation:** owner-only actions require a fresh owner MFA step-up and an explicit typed confirmation showing the impact (revision, time, data that would be replaced). Restore additionally requires confirmation on the Windows POS itself (physical presence), because it replaces the local authority (§12.1).
3. **Elevated actions** (price, campaign, QR publish, auto-sync/backup settings) show a confirmation dialog with before → after values and are audited with actor, device and request ID.
4. **Server-side enforcement:** client-side hiding is convenience only. Enforcement points: cloud RPC/RLS, the Windows command worker (re-checks grant + permission_version inside the SQLite transaction), and the LAN server for LAN-fallback devices. A command carrying an outdated permission_version is rejected.

### 20.4 Shared implementation contract
- One permission catalogue (`docs/contracts/v1/permissions.json`) used by Windows, both Android apps, both PWAs and the server; unknown operation IDs fail closed.
- One command contract (§11.2) for all section writes: `menu_update`, `stock_update`, `qr_publish`, `sync_request`, `sync_settings_update`, `backup_request`, `backup_settings_update`, `backup_verify`, `restore_request` (owner-only), `permission_update` (owner-only).
- One status projection per section (`menu_status`, `sync_status`, `backup_status`) with `as_of` timestamp for staleness badges.

### 20.5 Roadmap changes (applied to §15)
- **Phase 1 (backup):** BackupContainer + adapter must expose the status/history/verify data later shown in both apps (`backup_history` table from §4.4).
- **Phase 2 (sync):** `sync_state` and outbox expose the status fields of §20.2.
- **Phase 3 (auth):** implement the per-operation grant catalogue, owner-only list, permission_version, audit and step-up MFA (§20.3) — not only roles.
- **Phase 4:** read-only versions of the three sections in both Android apps and both PWAs.
- **Phase 5:** write commands for the three sections, grant-checked at all enforcement points.
- **Phase 6:** Yönetici dashboards + parity; owner-only sensitive flows (initial sync start, restore) end-to-end.

### 20.6 Acceptance tests (added to §16)
1. Both Android APKs install side-by-side with distinct names/IDs; both PWAs install separately on the same iPhone; logout in one does not affect the other.
2. All three sections are present in both apps on both platforms; with zero grants every write control is hidden/disabled and every forged write returns `403` from server, Windows worker and LAN server.
3. Each delegable operation: grant → succeeds; revoke → next request rejected (online immediately, offline within lease); permission_version bump invalidates cached UI.
4. Owner-only operations: rejected for Müdür/Yönetici accounts even with a manually inserted grant row; succeed for owner only after MFA step-up; restore additionally blocked until Windows-local confirmation.
5. Price/campaign edit via either app creates a new version; historical orders and receipts still show the original label and price (§19.3).
6. Sync/backup status screens show identical values in both apps for the same `as_of`; stale data shows a staleness badge; Windows-off disables writes.
7. Audit log records actor, device, operation ID, before → after, request ID for every elevated and owner-only action; no secrets/PII in the log.
8. No business logic duplication check: section logic lives in shared modules (Dart package / shared TS module); CI fails if section commands are implemented outside the shared modules (lint/import rule).

---

## 21. Owner Decisions 2026-11-27 (Binding)

Full table: `docs/cloud-sync/owner-decisions.md`.

### 21.1 Local normalization before cloud sync
Order of work: Phase 1 (encrypted backup + restore verified) → **Phase 1B (local per-entity transactional tables)** → Phase 2 (outbox, cloud schema, first sync). The Phase 0 benchmark measured p50 write latency of 150 ms / 1.7 s / 7.9 s at 1k / 10k / 50k orders caused by whole-state JSON rewrites; this is the trigger allowed by §2.2. Migration is progressive and reversible: the JSON snapshot remains readable until parity is proven. The 50 000-order validation ceiling in `PosStore.validate` is removed in Phase 1B and **not** replaced by any other history limit; protections against runaway memory move to per-entity streaming/pagination, not to a cap on history. Benchmarks at 1k/10k/50k/100k before and after: p50/p95 write latency, SQLite file and backup size, PostgreSQL size (Phase 2, on the compact schema) and sync payload bytes per change.

### 21.2 Soft deletion
Legitimate business records are never physically deleted by normal operations. `Sil` becomes an audited soft delete (actor, time, reason, request ID) that keeps financial history, cancellation reasons, command receipts/idempotency and emits a sync tombstone. Every report must define and test how soft-deleted and cancelled orders are counted (default: excluded from sales, visible in İptaller/audit). Legally required personal-data erasure (KVKK data-subject requests) is a separate, owner-approved flow that redacts personal fields while keeping the commercial facts.

### 21.3 Delivery-platform customer data
No CRM. E-mail is not collected (implemented in PR-01). Name, phone and address are used only when operationally necessary through the authorized API; the retention policy proposal in `platform-data-policy.md` §7 requires owner approval and KVKK review before implementation. All commercial and financial history is preserved. Nested records, caches, print snapshots and logs are scanned for PII replication by automated tests.

### 21.4 Gel-Al customers
The existing local customer directory and Açık Hesaplar are preserved unchanged. Personal contact details stay local; the cloud projection contains only commercial/financial records and the pseudonymous customer ID. No expansion of the directory and no automatic deletion.

### 21.5 Sync registry
Schema guarantees are layered: (1) top-level drift guard; (2) nested field registry; (3) runtime validation of every committed state in the test suite and fail-closed cloud projection in production (an undeclared field is never uploaded, local operation is never blocked); (4) explicit cloud field allowlist plus a "never projected" list; (5) typed per-table serializers with stable IDs and integer kuruş (PR-04/05).

### 21.6 QR menu audit
Pending repository access; focus files: `cms-live.js`, `cms-pos-live.js`, `menu.js`, `cms/menu-prices.json`, `cms/pos-managed-menu.json`, `cms/pos-managed-status.json`.

