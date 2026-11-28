# Premium UI/UX: per-surface inventory and review tracker

Owner mandate (ChatGPT relay 7227699704, 2026-11-27): Premium UI/UX is a top priority and a **release gate** for every page, option, control and workflow on the Windows POS, the native Android Personel and Yönetici APKs, the iPhone PWAs, and the cloud and LAN browser links. Two statuses are tracked separately, and both must pass before release:

- **Visual:** owner approval of the visual direction, plus Antigravity's visual and accessibility audit.
- **Functional:** tests and the QA matrix.

The rules:
- No invented features and no fake live data.
- Business rules, authorization, financial logic and offline-first behaviour stay unchanged.
- The public QR visitor website is not changed without separate approval.

## 1. Design system (one system, every platform)

| Token / rule | Value |
|---|---|
| Brand | Nohut green `#123e30` (panel / primary), gold `#a58336` (accent only), cream `#f6f2e7` background (light), `#0d1713` (dark). Original logo only; no stock illustrations |
| Typography | Barlow (sans) for all UI text, numbers and labels. Bree (serif) only for the brand wordmark and at most one page title per screen. Scale: 12.5 label caps · 14 body · 15–16 list titles · 19–22 section/page · 22–26 key numbers |
| Spacing | 4-pt grid; screen gutter 16 (phone) / 24 (desktop); card padding 12–16; list rows ≥ 48 dp; touch targets ≥ 44×44 |
| Components | One card style (12–18 radius, 1-px outline, no stacked decorative cards); compact action tiles (icon + one-line label, ≥ 52 dp) instead of launcher tiles; status pills (success/warning/danger/neutral); metric strips; segmented tabs; bottom sheets (phone) / right drawers (desktop) for editors; a single primary action per state |
| Navigation | Phone: bottom bar with always-visible labels, safe area. Tablet/desktop: rail or sidebar. Browser: top tabs with the same names |
| States | Every data surface has loading, empty, error, offline, conflict and permission-denied states, written in honest Turkish with a next action |
| Data viz | Simple bars/sparklines with the dataviz palette; numbers formatted `1.760,00 ₺`, `16 sa 30 dk`, `Cum 27 Kas` |
| Accessibility | WCAG AA contrast in light and dark; font scaling to 1.3× without clipping; semantic labels on icon buttons; keyboard focus and shortcuts on Windows |
| Validation | 320 / 360 / 390 / 430 dp, tablet, desktop 1536×864 and 1100×720 / 760×900, light/dark, 1.3× text, long Turkish names and labels; native Flutter renders + real browser (Playwright) screenshots; physical-device tests recorded separately |

## 2. Surface inventory

Legend for the Visual column:
- ✅ means the owner approved it.
- 🟡 means alternatives were shown and the owner's choice is pending.
- 🔄 means it has been redesigned and not yet reviewed.
- ⬜ means the legacy UI is still to be redesigned.

The Functional column records test coverage.

### Windows POS (`flutter_desktop`)

| Surface | Code | Visual | Functional | Notes / known gaps |
|---|---|---|---|---|
| Login, owner MFA, Kullanıcılar & Güvenlik | `main.dart`, `accounts_ui.dart` | ⬜ | tests ✓ | Needs the shared form, sheet and state components |
| Masalar (floor plan, table detail) | `tables_panel.dart`, `floor_plan.dart` | 🔄 board done, owner review pending | tests ✓ (`masalar_render_test`, `tables_panel_test`) | `MasalarBoard`: shared `TableTone` colours; legend pills; status tiles under 740 px (was plain buttons); open-orders list moves below the plan under 1150 px (it used to disappear) in 2 columns; layout-editing banner. Rendered 1536/1100/720/420 and 1.3× text. Windows POS has no dark theme yet (light only). Table detail dialog next |
| Sipariş composer, product customization | `order_composer.dart`, `product_customization.dart` | 🔄 product grid done, owner review pending | tests ✓ (`pos_flow_render_test`, `campaign_ui_test`) | Price beside the product name, quantity badge under it; tiles reserve description space only when a category has one (176 → 106 px), so more products fit without scrolling. Before/after at 1280 and 1536 in the project Library (screens/premium). Sepet and customization dialog still to review |
| Payment, split, refund, mixed card | `payment_dialog.dart`, `group_payments.dart`, `card_terminal.dart` | 🔄 payment dialog reviewed, unchanged; Hesap ve Sipariş rows compacted (`operations_ui.dart`) | tests ✓ | Financial logic frozen; visual only. Without guests, Adet İptal sits on the product row. Split/refund dialogs still to review |
| Receipts preview, printer | `receipt_preview.dart`, `printer_management.dart` | ⬜ | tests ✓ | Receipt layout is printed output; not changed |
| Online orders (Trendyol Go, alarms) | `online_orders.dart`, `trendyol_go_ui.dart`, `platform_ui.dart` | 🔄 board reviewed, unchanged (3 stage columns, provider chips, honest empty states) | tests ✓ | No live platform actions in testing. Rendered at 1536 and 1280 in `pos_flow_render_test`; populated-order cards still to review |
| Google business, reviews | `google_business_ui.dart`, `review_display.dart`, `compact_review_card.dart` | ⬜ | tests ✓ | |
| QR Menü Yönetimi | `qr_menu_management.dart` | 🔄 owner screenshot review (relay 7228172987) addressed, awaiting re-review | 14 ✓ | Single heading (window header only); compact publisher status card with one fix button and folded *Teknik ayrıntılar*; offline draft no longer shown as a red error; stable **Önizle** button; *Yayınlanamaz: …* reason when changes exist but publishing is blocked; aligned column headers (Ürün, Kategori, Fiyat, Stok, QR); atlas photos (wraps, sides, salads, fatte) cropped to the one dish the public menu shows, never the whole sheet |
| Açık hesaplar | `open_accounts_ui.dart` | 🔄 duplicate page title removed (window header names the page) | tests ✓ | |
| Raporlar, Yoğunluk, Gün Sonu | `sales_reports.dart`, `daily_report_ui.dart`, `report_activity.dart`, `dashboard_sales.dart` | 🔄 duplicate page title removed; section renders in `sections_render_test` (all 11 sidebar sections, 1536 and 1280) | tests ✓ | Data viz palette |
| Finans, giderler | `finance_ui.dart` | 🔄 duplicate page title removed; cards and pills already on the shared tokens | tests ✓ | |
| Market takibi | `market_prices.dart`, `market_price_tracking.dart` | ⬜ | tests ✓ | |
| Personel, Mesai, Vardiya, Maaş | `operations_ui.dart`, `workforce.dart`, `payroll.dart`, `shifts.dart` | ⬜ | tests ✓ | |
| Bildirimler | `notifications_ui.dart`, `notification_center.dart` | ⬜ | tests ✓ | |
| Ayarlar (9 pages), Yedekleme, Bulut | `simple_settings.dart`, `backup_ui.dart` | 🔄 (IA regrouped) | tests ✓ | Sync/backup stay Windows-only |
| Dialogs, menus, empty/error/offline states | across | ⬜ | — | Shared components first |

### Android Personel (`flutter_personel`, staff mode)

| Surface | Code | Visual | Functional | Notes |
|---|---|---|---|---|
| Pairing, login, PIN, unlock, İlk Aktivasyon | `pair_page.dart`, `home.dart`, `activation_page.dart` | 🔄 pairing two-step redesign (390227c), activation 3-step screen (454e886); awaiting owner approval | `login_render_test` (6), `activation_page_test` (4) ✓ | Login sheet unchanged apart from the activation link |
| Ana Sayfa | `personel_dashboard.dart` | ✅ A "Özet kartı" (owner 2026-11-27) | 10 render + suite ✓ | Antigravity accessibility audit pending |
| Masalar, Sipariş/Ürünler, Sepet, Siparişler | `home.dart` | 🔄 first pass | `order_tabs_render_test` (13: phone, dark, 320 px at 1.3×) ✓ | Fixed: product categories showed raw Windows keys (`wrap`, `plate`, `drink`); now Dürümler / Porsiyonlar / İçecekler in Windows order (`menuCategoryLabels`). Siparişler rows gain source icon and item count. Renders: `screens/personel/orders/`. Sepet polish 7e00813: qty × unit price, Not/Çıkar details, compact stepper, Ek sipariş hint, sticky total + send. Next: table tile status word |
| Mesai ve Maaşım (Mesai, Vardiya, Maaş) | `work_page.dart` | 🔄 | ✓ | |
| Menü Yönetimi | `menu_admin_page.dart` | 🔄 | 8 ✓ | Full parity incl. publish (ea4b42b) |
| Daha Fazla, Gider taslakları, Ayarlar | `home.dart`, `expense_drafts.dart` | ⬜ | ✓ | |

### Android Yönetici (`flutter_personel`, manager mode)

| Surface | Code | Visual | Functional | Notes |
|---|---|---|---|---|
| Ana Sayfa / dashboard | `manager_main.dart` | 🔄 | ✓ | |
| Personel, Maaş, Ekip Performansı | `manager_main.dart`, `owner_payroll.dart`, `team_performance_page.dart` | 🔄 | ✓ `team_performance_page_test` (3) | |
| Raporlar: Satış Analizi, Yoğunluk | `sales_page.dart`, `demand_page.dart` | 🔄 new, awaiting owner approval | `sales_page_test` (4), `demand_page_test` (4) ✓ | |
| Pairing | `manager_main.dart` (`_OwnerPair`) | 🔄 redesign 83bd4fd | `login_render_test` ✓ | |
| Finans | `manager_finance.dart` | ⬜ | ✓ | |
| QR Menü, Ayarlar | `manager_main.dart` | 🔄 | ✓ | |

### LAN browser apps (`flutter_desktop/assets/staff.html`, `yonetici.html`)

| Surface | Visual | Functional | Notes |
|---|---|---|---|
| Personel: login/PIN, Masalar, Ürünler, Sepet, Siparişler, detail, Mesai, Menü | ⬜ (Menü 🔄) | Playwright smoke ✓ | Serif-heavy legacy CSS; align to tokens |
| Yönetici: Özet, Sipariş, Menü, Personel, Finans, Gün Sonu | ⬜ (Menü 🔄) | smoke ✓ | |

### Cloud PWAs (`pwa/src/personel`, `pwa/src/yonetici`)

| Surface | Visual | Functional | Notes |
|---|---|---|---|
| Login, activation, PIN (on top of BFF) | ⬜ | BFF 7 ✓ | Screens still to build; this needs the Codex relay for live data |
| Personel / Yönetici views | ⬜ | ✓ | Must not show fake live data |

## 3. Order of work

1. Shared components and tokens, in Flutter (`style.dart` for both apps) and in the browser CSS.
2. The highest-traffic screens: Windows Masalar, the order composer and payment; Personel Masalar, Sipariş and Siparişler.
3. Owner review of the redesigned Windows QR Menü (🔄). Ana Sayfa A is approved; its patterns (week card, compact tiles, metric strip) set the direction for the other dashboards.
4. Dashboards and reports with data visualization.
5. Ayarlar, notifications, finance, market and the remaining screens.
6. Browser and PWA alignment.
7. Every surface's empty, error, offline and conflict states.

Each step ships with:
- renders at all sizes, light and dark, at 1.3× text;
- functional tests unchanged or extended;
- a row update here and in `docs/qa/FUNCTIONAL_QA_MATRIX.md`.

The owner reviews each visual direction. Nothing is merged or deployed before approval.
