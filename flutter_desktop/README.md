# Nohut Falafel — native Flutter for Windows

Native Yönetici Paneli / Kasa (PC), not a WebView. The original HTML demonstration and production QR menu remain in their existing folders.

Read [FEATURE_PARITY.md](FEATURE_PARITY.md) for the feature-by-feature audit, code/test mappings, synchronization decisions and remaining device acceptance checks. It separates native workflows, deliberate simulations and unverified physical connections.

## Windows download

Open the successful **Build Flutter Windows POS** Actions run for this branch/PR and download **NohutFalafel-Windows-Flutter**. Extract the entire ZIP before starting `nohut_falafel_desktop.exe`. Keep all DLLs and `data` beside the EXE. `build-manifest.json` identifies the source revision and SHA-256 of packaged files. An artifact being uploaded is not proof of physical-device integration.

The release includes the employee page and menu inside Flutter assets. There is no separate `site` folder or Python server to install. The PC opens the manager directly; the prototype has no role chooser or passwords.

## Worker phones

1. Keep the Windows app running and the laptop awake, on trusted private staff Wi-Fi.
2. Open **Personel Wi-Fi**, choose the actual Wi-Fi IPv4 and scan the QR in Chrome.
3. The URL is `http://<LAPTOP_IP>:8787/personel`. Choose an active worker name.
4. Submit a Masa 1–5 or Gel-Al order. Telephone orders are pickup-only. Occupied-table orders become additional batches.
5. Wait for the confirmed SQLite order number. On a lost response, use **Aynı İsteği Yeniden Dene**. The persisted request ID prevents double submission. On a revision conflict, fetch current data, inspect the retained cart and resubmit.

Payments and management are native PC workflows. The LAN server does not serve the old manager HTML and rejects snapshot PUT requests. The HTTP prototype is still password-free and unencrypted; this is not production authentication. Keep it off guest Wi-Fi/public Internet. A real two-phone Wi-Fi test is still required. Windows Firewall private-network permission must be handled on the actual laptop. Do not run the older Python server on port 8787 at the same time.

## Native workflows

- Exactly five interactive tables with saved draggable floor positions.
- Local catalog/category selection, notes/removals, added batches, quantity/full cancellation with correction tickets, pickup details and independent service completion.
- Cash/card/partial/mixed entries, change, partial/full refunds, product-level guest shares, equal cent-conserving splits and mapping earlier payments to guests.
- Opening/closing cash sessions, counted variance, cash in/out and historical refund dates.
- Staff creation/editing/activation, local price configuration, filtered history and collection/product/staff reports, CSV exports, consistent SQLite backups.
- Single persistent kitchen printer queue, automatic Windows driver printing for Masa / Gel-Al and added batches, branded previews and printable bill summaries.
- Explicit platform simulation tabs for orders, acceptance/status/cancellation, store hours, catalog/mapping/prices, claims, reviews, invoice links and sync request log; settlements under Reports, configuration under Settings.

**No Yemeksepeti/Trendyol Go API, bank POS or fiscal ÖKC is connected.** Windows receipt printing now uses the installed driver; physical device acceptance remains required. Card and platform entries are prototypes. Courier delivery and platform collections remain with the platforms; the restaurant has no courier workflow. Yemeksepeti unverified management capabilities stay gated. Invoice-link submission does not generate a fiscal invoice. The example 15% commission is not an accounting rate.

## Storage and concurrency

Default database: `%APPDATA%\NohutFalafel\nohut-pos.sqlite3`. `NOHUT_POS_DATABASE` can select a separate test database before launch. The app never silently imports the old Python database or fake HTML seed orders.

SQLite uses WAL, FULL synchronous commits, a busy timeout and immediate writer transactions. PC writes compare revisions. Phones submit validated order commands rather than replacing the database. Request receipts and orders commit atomically, so retries survive restarts. The state remains a versioned JSON aggregate in SQLite, with explicit domain validation and typed report/check projections; it is not a certified accounting ledger.

Use **Ayarlar → Tutarlı SQLite Yedeği Oluştur** for a consistent single-file backup while WAL is active. Keep a backup before replacing any existing database. Restoring old data is a deliberate offline operation, not an automatic merge.

## Build and test on Windows

Prerequisites: Flutter stable and Visual Studio C++ Desktop development tools. Native runner source is committed; do not regenerate it over customizations.

```powershell
cd flutter_desktop
flutter pub get
flutter analyze
flutter test --reporter expanded
flutter build windows --release
```

At repository root:

```powershell
node pos-demo/tests/logic.test.cjs
python -m unittest discover -s pos-demo/tests -p test_local_server.py -v
```

GitHub Actions runs strict Flutter analysis, domain/SQLite/HTTP/widget tests, the preserved HTML regressions and a Windows release build, then uploads the whole release folder. Tests use isolated temporary databases. They do not establish real phone, printer, fiscal or platform readiness. Keep the HTML demo until the acceptance checks in the parity matrix are completed.

## Receipt printing, daily numbers and busy hours (0.2.0)

- Open **Ayarlar → Yazıcı Ayarı**, verify the selected XP-237B or enter its exact physical printer name shown in Windows **Printers & scanners**, and save. The setting enables **Otomatik Masa / Gel-Al Fişi**. Use the XP-237B Windows receipt driver with 58 mm continuous paper and receipt mode (ESC/POS), not TSPL label mode. The design uses its 48 mm printable area. Oversized content shrinks by default and is never enlarged. A uniquely named installed XP-237B is detected automatically; otherwise enter its exact Windows queue name. File-output printers such as Microsoft Print to PDF are rejected for automatic printing.
- Confirmed PC and staff-phone orders enter the same SQLite print queue. Only the laptop sends them to the selected printer, using the installed Windows driver and the packaged monochrome Nohut logo. Added items print only their new batch. Payments do not produce another kitchen ticket. Platform simulation printing remains separate.
- Old jobs from before printing was enabled are held for manual review. Use **Yazdırma Kuyruğu → Kontrol Ettim · Yeniden Kuyruğa Al** when an old job or a failed job really needs another copy. Never retry without checking the physical printer first.
- `Kuyruğa gönderildi` means Windows accepted the spool request, not that a paper sensor confirmed it. An interrupted or uncertain send becomes `Kontrol gerekli`, with no blind automatic retry. Order data stays saved even if printing fails.
- Visible receipt numbers start at **#1 at 00:00 Europe/Istanbul** each day; archived records are preserved. Stable database IDs never reset, so yesterday's open table, phone retries and payments keep pointing to the correct account. The order date distinguishes repeated daily numbers.
- **Raporlar → Saatlik Sipariş Yoğunluğu** shows the arrival count in each of the 24 Istanbul hours, highlights peaks and exports CSV. It uses the report's date/source/staff filters. Payments and extra batches are not extra arrivals; cancelled and unaccepted platform orders are excluded. This measures arriving orders, not queue length or occupied-seat duration.
- The HTML prototype has the same logo, daily numbering and workload chart. It automatically opens browser printing for newly confirmed local orders on the PC; normal browsers still show their print dialog. Use the Windows app for direct printing without that dialog.

Validation: HTML logic regressions, SQLite/domain/receipt/report tests and desktop widget tests. The Linux workspace cannot enumerate network interfaces (`Bad value for ai_flags`); the existing real HTTP concurrency test must run on Windows CI. A physical receipt test on the restaurant laptop remains necessary.

XP-237B specification: https://www.xprintertech.com/desktop-label-printer-xp-237b — 58 mm receipt paper, 48 mm print width, ESC/POS receipt mode. Browser print dialog preferences are owned by the browser; CSS constrains the receipt to the 48 mm content area.


## Nohut QR Menu full catalog sync — stable-ID version 1

When **Ayarlar → Resmî QR Menü · Otomatik Eşitleme** is enabled (default),
Windows POS checks the official published QR site after startup and every
**10 minutes**. Use **Şimdi Eşitle** to check immediately.

Reads THREE public HTTPS endpoints:
- `https://nohutfalafel.github.io/qr-menu/cms/catalog-v1.json`
- `https://nohutfalafel.github.io/qr-menu/cms/menu-prices.json`
- `https://nohutfalafel.github.io/qr-menu/cms/campaigns.json`

**Important source rules:** the versioned catalog supplies **immutable product
IDs**, eight product categories (+ All), Turkish/English/Arabic names and
descriptions and original product image asset paths. The two independent CMS
files remain authoritative for **current prices and live offers**. If a CMS
product doesn't match a catalog name/category, sync refuses the whole update
and leaves local SQLite unchanged. QR cards and their original visual
composition in the customer-facing website are not modified by this POS feature.

On a successful sync, SQLite's `localMenu` products are matched by **ID,
not name**. Legacy IDs **0–50** are retained and the two new products use
**51 = Vegan Dürüm**, **52 = Layali Lübnan**. Product names, translated
copy, prices and source image paths are updated; missing new IDs are appended.
The order composer shows a thumbnail and Turkish product description. If
offline, images show an icon, while cached product data still works.

The local `qrCategories` and `qrCampaigns` metadata caches are updated,
but customer order history, customer data, payment records, receipt snapshots,
staff configuration, kitchen print jobs and platform demo menus are untouched.
Existing orders keep their original prices. POS-only local products are kept.
Collision with a custom local ID, duplicate ID, stale catalog, invalid feed
or network failure aborts the update without corrupting local orders. A failed
sync retains the previous SQLite menu; an unchanged sync makes no DB write.
A stored switch can disable auto-sync so owner-only price changes are kept.

Photos are URL-linked website assets, **not offline-downloaded originals**;
they need connectivity to display, unlike cached product text/prices.
The two products that do not have a distinct source image path use a fallback
icon in the POS; their current QR website graphics are unchanged.
The descriptions are restaurant copy and not structured allergen declarations.

To inspect:
- `flutter test test/qr_menu_reader_test.dart`
- `flutter test test/qr_menu_sync_test.dart`
- `flutter analyze --no-fatal-infos`

**Deployment:** changes on a GitHub branch have no impact on installed Windows
POS until merged, built and installed. Back up the live restaurant SQLite
database before upgrading. Only after passing CI and validating 53 products,
orders and the XP-237B printer on the real laptop should the new executable
replace the old one. GitHub Actions build artifacts are temporarily retained;
their presence alone does not mean the software is installed.


## 00:00 daily reset — Europe/Istanbul

The Windows POS dashboard automatically rolls over at **00:00 Türkiye time**
(UTC+03:00), even if the Windows machine has another timezone. Restarting after
midnight also selects the new business day. The next invoice number displayed
on receipts is **0001** (then 0002, etc.) for each new local day. Internal
SQLite order IDs are always unique and **never** reset.

The following **daily views** begin at zero at the new midnight:
- Today's order count and today's recent orders on Genel Bakış
- Günlük Son Fiş (last daily receipt counter) displays **0000** at midnight and
  increases to **0001** with the first new business-day order
- Today's net restaurant collection (cash/card receipts minus refunds, by the
  actual payment event timestamp, not the original order date)
- Raporlar by default: today's hourly density, financial ledger and product
  sales; historic data is available by changing/clearing the date filters
- Tüm Siparişler initially shows the new day's records, with earlier dates
  accessible from Sipariş Filtreleri.

**No destructive reset happens.** Open/unpaid tables, pending print jobs, cash
sessions, refunds, financial audit records, SQLite history and previous days'
sales remain intact. Operational counters such as `Dolu Masa`,
`Açık Sipariş`, `Yazdırma Bekleyen` and balances due continue across
midnight until resolved; zeroing them would hide genuine work or cash owed.
Cash drawer balances are NOT physically reset at midnight.

All results are scoped by **Europe/Istanbul calendar day**, and local
restaurant operations can proceed offline. The date boundary uses UTC+03:00,
not whatever timezone is configured in Windows.

Tests: `flutter test test/daily_midnight_test.dart`. The new POS build must
be installed on the restaurant's Windows laptop after backup and review;
merging the code does not remotely update an already-installed application.
