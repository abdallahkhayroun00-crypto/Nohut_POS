# Nohut Falafel — working defaults and continuity (2026-11-20)

> **Working reference for the DRAFT development branch only.** This is not a production release and does not override restaurant data, live provider records, or the official published menu. Keep old orders, product IDs, and historical prices unchanged.

## Projects and source of truth

- Windows POS: `flutter_desktop/`; live operational data is kept in the restaurant PC's SQLite database, **not** the public POS demo.
- Native Android staff app: `flutter_personel/`; paired via one-time QR + PIN on trusted restaurant Wi-Fi.
- Published customer QR menu: `https://nohutfalafel.github.io/qr-menu/`; official source repository `nohutfalafel/qr-menu`. Do **not** treat the old `nohut-menu/` copy or bundled POS menu JSON as the final menu catalog.
- Windows/QR CMS proposal: POS draft PR #17 must be coordinated with `nohutfalafel/qr-menu` draft PR #7. Do not merge/deploy only one side without verifying the matching protocol.
- Platform integrations: Trendyol Go, Yemeksepeti and Migros Yemek require their **real approved permissions**. No demo order may be counted as live revenue. Remote acceptance/readiness/cancellation must remain disabled until tested with official access.
- Google Business Profile: OAuth, authorised locations and permitted review/reply access required; no fake connection state.

## Default staff notification 🔔

- **Preserve the user-supplied audio file:** `flutter_desktop/assets/notifications/staff-order.mp3` (do not replace it with a generic ringtone).
- Flutter bundles the entire `assets/notifications/` folder in `pubspec.yaml`.
- On **new or added orders arriving from a staff phone**, use `queueStaffPhoneOrderSoundTwice()` in `lib/order_alerts.dart`: play this MP3 **two times**, serialised, and show the Windows popup identifying staff, table/order and newly added items.
- If Windows MP3 decoding fails, use the built-in audible fallback. Acknowledging the popup never changes the restaurant or delivery-provider order status.
- **Keep delivery-platform alarms separate:** each platform has its own alarm and verified-remote-status stop condition. Do not reuse the staff MP3 for the three recurring delivery alarms unless explicitly requested.

## Restaurant workflows to preserve

- Masa 1–5 on the initial staff view; order additions to existing tables; kitchen delta tickets for only new items.
- Split by product/equally/custom amount; cash/card combinations, avoid double charging and preserve immutable payment history.
- Individual attribution for creation, additions, cancellation and receipt; manager-only sensitive controls.
- Cash and platform receivables must not be conflated with gross sales or estimated profit.
- The cashier/kitchen printer names are chosen from installed Windows queues (including the restaurant's XP-237B as applicable), not guessed.
- QR CMS: simple, attractive product/price edit experience; **keep local offline drafts** until intentional publication; handle conflict by SHA and do not discard existing orders. Draft-only until local GitHub App publisher is working and tested.
- No private key, bank-terminal secret, API key, token, client secret, or restaurant customer data in GitHub/Pages.
- Windows node publisher requires Node.js 22+; resolve actual node.exe with PowerShell `-NoProfile` (including fnm installations). Never parse versions via a broken `split(.)` expression.
- POS financial terminal inPOS M530 was removed from **new** terminal selections; preserve reconciliation of old pending operations.

## Previous attached project documents used for context

1. `إعادة صياغة نظام المطعم.txt` — architecture, tables, payments, staff management and analytics (multiple earlier revisions).
2. `Check Website Logic.txt` — earlier POS demo and local SQLite rationale; superseded where real Flutter implementation exists.
3. `اقتراح تفاعلات الروبوت.txt` — optional Nohutçuk mascot requirements; a separate roadmap, not a release blocker for POS.
4. `رابط نظام Flutter.txt` — code audit from an older snapshot; re-check each finding against the current branch before treating as unfixed.

These were supplied in the Nohut Falafel project conversation. This index avoids copying unreviewed archived conversation text into the public repository.

## Development / release rule

- Continue from the latest **draft branch and PR state**, not a November 14 or November 18 snapshot.
- Before each Windows/Android delivery: read the current PR head; run Flutter analyze/test and GitHub Actions build; check POS+QR contracts and test on the restaurant hardware.
- Preserve functioning features and draft data. Changes go to the active feature branch first; do not silently merge into `main` or claim live API access.
- Restaurant deployment needs backup of the SQLite DB, authorised owner acceptance, and actual Windows printer/phone/audio QA.

## Current PR chain (as checked 2026-11-20)

- POS PR #15 — partner orders, traffic/reporting, Google Business UI, inPOS M530 cleanup.
- POS PR #16 — online alarms, partner safeguards, native Android staff app and default staff MP3.
- POS PR #17 — customer accounts/open receivables, QR CMS/publisher, printer settings.
- QR PR #7 — multilingual QR CMS overlay + secure local GitHub App publisher.

This file is documentation of agreed project defaults, **not** a claim that all listed features are live.
