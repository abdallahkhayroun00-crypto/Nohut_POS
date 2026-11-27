# Nohut POS — Cross-platform logic and functional QA matrix

Owner mandates of record: 2026-11-27 18:50 ("Mandatory Architecture, Native Application Quality & Full Functional Audit") and 18:52/18:53 ("Real Business Logic, Roles and Complete Cross-Platform Audit"). This file is the audit record. A row is **Verified** only when the evidence column names an automated test or a rendered run that was actually executed. Nothing here claims a physical-device test or an independent review unless the evidence says so.

Platforms: **W** Windows POS · **AP** Android Personel APK (`flutter_personel/lib/main.dart`) · **AY** Android Yönetici APK (`flutter_personel/lib/manager_main.dart`) · **PP** Personel cloud PWA · **YP** Yönetici cloud PWA · **LP** local Personel browser app (`assets/staff.html`) · **LY** local Yönetici browser app (`assets/yonetici.html`).

Status words: Verified · Implemented (not yet verified end-to-end) · Partial · Restricted (intentional) · Not available · Not yet audited.

## 1. Audit progress by module

| Module | W | AP | AY | PP | YP | LP | LY | Audit state |
|---|---|---|---|---|---|---|---|---|
| Authentication, sessions, PIN lock | Verified | Not yet audited | Not yet audited | Not yet audited | Not yet audited | Verified | Verified | Server gate audited (LAN). Cloud A2 pending (Codex #39). |
| Identity bound to session | — | Not yet audited | Not yet audited | Not yet audited | Not yet audited | Verified | Verified | Fixed D-01, D-02 below. |
| Employee profiles / roles / payroll eligibility | Verified | — | Not yet audited | — | Not yet audited | — | Verified (API) | D-04…D-07 fixed. |
| Vardiya (planned shifts) | Not available | Not yet audited | Not yet audited | Not yet audited | Not yet audited | Verified | Partial (view only) | Manager editing others in UI pending. |
| Mesai (actual hours) + weekly submission | Not available | Not yet audited | Not yet audited | Not yet audited | Not yet audited | Verified | Verified (team view) | Windows screen pending. |
| Payroll (rates, ledger, statuses) | Partial (rate + eligibility in Personel; ledger in finance totals) | — | Not yet audited | — | Not yet audited | Verified (own pay only) | Verified | Android/cloud projection = Codex. |
| Payroll reminders | Verified (domain) | Not yet audited | Not yet audited | Not yet audited | Not yet audited | Verified (feed) | Verified (feed) | Push (FCM) not approved. |
| Hızlı Gider Ekle | Verified | — | Implemented | — | Not yet audited | — | Verified | |
| Gün Sonu Raporu | Verified (domain) | — | Not yet audited | — | Not yet audited | — | Verified | |
| Masalar, orders, Ek Sipariş, Gel-Al | Verified (domain) | Not yet audited | — | Not yet audited | — | Partial (identity fix D-01) | — | Table transfer refuses occupied tables (`owner_money_scenarios_test`); stale revisions conflict, retries idempotent (`remote_commands_test`, SQLite optimistic revisions); extra order credited to original owner. UI walkthrough per platform still pending. |
| Payments, refunds, split, receipts | Verified (domain) | — | — | — | — | — | — | `owner_money_scenarios_test`: partial cash + change, overpay/short cash refused, Karma atomic, equal split 100,01 → 33,34+33,34+33,33, refund ≤ collected with reason, cancel refused while money held, closed account takes no money. Terminal: unknown outcome blocks deletion, retry does not charge twice (`updates16_test`). Receipt/reprint guard tests exist. Physical printer and card terminal: owner device test. |
| Online orders, campaigns, menu | Not yet audited | — | — | — | — | — | — | |
| Fixed costs, market prices, open accounts | Not yet audited | — | Not yet audited | — | Not yet audited | — | Not yet audited | |
| Sales analytics, Yoğunluk | Not yet audited | — | Not yet audited | — | Not yet audited | — | Not yet audited | |
| Customer reviews | Paused by owner | — | — | — | — | — | — | |
| Notifications | Verified (history, dedup) | Not yet audited | Not yet audited | Not yet audited | Not yet audited | Verified | Verified | |
| Cloud sync, offline, backup | Restricted (Windows only) | Not yet audited | Not yet audited | Not yet audited | Not yet audited | — | — | Codex owns sync (#39). |

Native Android architecture check (2026-11-27): `flutter_personel/pubspec.yaml` has no WebView dependency (`http`, `share_plus`, `mobile_scanner`, `flutter_secure_storage`, `flutter_local_notifications`); both APKs are Flutter widget apps built from two entry points. Biometrics, native date pickers, haptics and offline states have **not yet been audited** on Android; no emulator run has been done in this cycle.

## 2. Defects found and fixed (PR #44)

| ID | Feature | Intended user | Actual behavior (before) | Expected | Severity | Fix | Automated evidence | Rendered evidence |
|---|---|---|---|---|---|---|---|---|
| D-01 | Staff actions over LAN | Personel | A signed-in account **not linked to an employee** could send any `staffId` and act as that employee | Identity always from the session; unlinked accounts refused | Critical (security) | `LanAuthGate.withIdentity` refuses unlinked sessions | `lan_auth_gate_test` "signed-in identity overrides…" | — |
| D-02 | Employee selector | Personel | Selector visible after individual login (showed another name next to the username) | No selector for signed-in staff; header shows linked profile | High (trust/UX) | `staff.html` hides selector, shows `username · profile` | — | Playwright iPhone 13: selector hidden, header "personela · Test Personel A" |
| D-03 | `/api/work/week?employeeId=` | Personel | Already returned own week (verified, no defect) | Same | — | Regression test added | `workforce_test` LAN test | Playwright: tampered request returned own id |
| D-04 | Payroll scope | Owner | Every active profile (incl. owner) in payroll, reminders and Mesai reminders | Owner excluded by default; explicit eligibility flag | High (financial) | `employees[].payrollEligible`; owner-linked profile defaults to `false` once; Windows › Personel "Maaş bordrosu" | `payroll_test` owner rules | Playwright: owner's 13 h not listed in payroll |
| D-05 | Payroll statuses | Manager, Personel | No work / no rate shown as "Ödenmedi" | Çalışma kaydı yok · Ücret belirlenmedi · Ödenmedi · Kısmen Ödendi · Ödendi | High (financial) | `payrollStatus` derivation | `payroll_test` statuses | Rendered Yönetici + Personel |
| D-06 | Payday reminders | Manager | Fired while any status unresolved, incl. unknown amounts | Only eligible people with real outstanding earnings | Medium | `payroll_reminders.dart` | `payroll_test` reminders | — |
| D-07 | Rate edit on Windows › Personel | Owner | Overwrote current rate with no effective date → silently changed past weeks | Change starts today; history preserved | High (financial) | Uses `setEmployeeRate(effectiveFrom: today)` | `control_workflows_test` staff edit | — |
| D-08 | Windows › Personel edit | Owner | Edited person found **by name** (wrong person if names repeat) | By id | Medium | `operations_ui.dart` | `control_workflows_test` | — |
| D-09 | Back-dated rate | Manager | A rate could start inside a week that already has payments | Refused with explanation | High (financial) | `PayrollConflict` in `setEmployeeRate` | `payroll_test` acceptance | — |
| D-10 | Fresh install data | Owner | New database seeded three named employees | No people until the owner adds them | Medium (data integrity) | `emptyPosState()` seeds none; tests use synthetic names | full suite | — |
| D-11 | Personel own payment history | Personel | Not shown | Own payments only | Medium | `/api/work/week` adds own `payments` | — | Playwright: "Ödeme geçmişim" |
| D-12 | Overdue label | Manager | "gecikti" on weeks whose amount is unknown | Only when money is actually outstanding | Low | `payrollStatus.overdue` | `payroll_test` | Rendered |

| D-13 | Android Personel orders/actions (`/api/mobile/*`) | Personel | A paired device sent any `staffId`; the path ignored *Bireysel giriş zorunlu* | Same gate as the browser app: individual session required when enforced; session fixes the employee | Critical (security) | `lan_server.dart` mobile branch uses `_guard` + `withIdentity` | `lan_auth_gate_test` "Android paired-device writes…" | — |
| D-14 | Android Yönetici owner identity | Owner | Owner found by the hardcoded name "Ömer Yılmaz" (Windows, server and APK) | Owner = profile linked to the owner account; name from that profile; legacy name accepted only while no owner is linked (upgrade safety) | High (data integrity) | `FinanceSyncServer.owner(ownerIds:)`, APK shows `ownerName` from Windows, Windows labels say "İşletme sahibi" | `owner_identity_test` | — |

Owner acceptance example (8 h × 100 TL + 8 h × 120 TL = 1.760 TL; pay 800 → Kısmen Ödendi, kalan 960; pay 960 → Ödendi; later raise not retroactive): **Verified** in `payroll_test` and in a rendered LAN run (Yönetici records 800 TL Nakit → Kısmen Ödendi, kalan 960,00 ₺; Personel sees the same numbers).

## 3. Open findings (not yet fixed)

| ID | Finding | Severity | Next step |
|---|---|---|---|
| O-01 | `staff.html` ignores dark mode (Yönetici supports it) | Low (visual) | Premium UI pass |
| O-02 | Personel rate card shows the rate at week start when the rate changed mid-week | Low | Show both rates for the week |
| O-03 | Payroll on Android Yönetici and cloud PWAs not yet projected | High (parity) | Codex: cloud projection of `payHistory`, `payrollPayments`, `payrollReviews`, `payrollEligible` |
| O-04 | Order, payment, refund, receipt, analytics modules not re-audited in this cycle | — | Next audit pass |
| O-05 | No emulator/APK screenshots in this cycle | — | Android audit pass |
| O-06 | No independent review yet | — | Request on PR #44 |
| O-07 | Android Personel APK has no individual login yet; it still shows an employee picker (legacy shared mode). With *Bireysel giriş zorunlu* on, its writes are now refused (401) until it signs in | High (parity) | Native login + 5-digit PIN in the APK (W6/A2) |
| O-08 | An old Yönetici APK compares the owner name with "Ömer Yılmaz"; after linking the owner account to a differently named profile it needs the new APK from CI | Medium (upgrade) | Install the APK built from #44 |

## 4. Physical-device tests required from the owner

Recorded in PROGRESS.md; none performed by Claude.
