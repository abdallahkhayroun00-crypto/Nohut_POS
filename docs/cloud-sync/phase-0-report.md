# Phase 0 (PR-01) — Report

Spec: NOHUT POS 2.0 Master Specification V5.1 (`NOHUT_POS_2.0_MASTER_SPEC_v5.1.md`).

**Status:**
- Phase 0 deliverables are complete except the QR repository audit (BLOCKED, §4).
- No production data, cloud account, upload or schema migration was touched.
- No PR was merged by this work; the owner merges.

## 1. Baseline

| Item | Value |
|---|---|
| `main` at the start of Phase 0 | `cbbb130defdc7df73c9cb61331b4ab42571ba887` (PR #27 merged) |
| `main` this PR is based on | `dbd809b` (PR #30 merged at the owner's request: receipt margins, 57 mm paper, order slips print again) |
| Open PR conflict register | `data-inventory.md` §8 |

## 2. Deliverables

| Spec item | Deliverable | Evidence |
|---|---|---|
| §4.1 / §18.2 inventory | `docs/cloud-sync/data-inventory.md` | Code inspection (method in the file) |
| §4.4 drift guard | `flutter_desktop/lib/sync_registry.dart` + `test/sync_registry_drift_test.dart` | **Executed test**, 5 tests pass |
| §11.1 first Gel-Al receipt | `newLocalOrder(customer:, staffId:)`; callers in `main.dart` and `staff_commands.dart` | **Executed tests** in `test/receipt_text_test.dart`: cashier path, LAN/phone path, additions, no phone |
| §19.9 storage benchmark | `docs/cloud-sync/storage-benchmark.md` + `test/benchmark/storage_benchmark_test.dart` | **Executed** on 1k/10k/50k synthetic orders |
| §19.9 platform policy | `docs/cloud-sync/platform-data-policy.md` | Code inspection |
| V5.1 owner update | `NOHUT_POS_2.0_MASTER_SPEC_v5.1.md` (§9.4, §10.3, §15, §16, new §20) + `docs/contracts/v1/permissions.json` | Document; enforcement is Phase 3 |

## 3. Commands and results (executed in this session)

Tooling: Flutter 3.50.1, Linux x86_64.

| Command | Result |
|---|---|
| `cd flutter_desktop && flutter analyze --no-fatal-infos` | 0 errors, 0 warnings (557 infos, pre-existing style lints) |
| `cd flutter_desktop && flutter test` | **264 passed**, 3 skipped (2 pre-existing + the opt-in benchmark) |
| `cd flutter_personel && flutter analyze` | 0 errors, 0 warnings (11 infos) |
| `cd flutter_personel && flutter test` | **15 passed** |
| `cd packages/nohut_core && flutter analyze` | No issues found (the package has no own `test/`; it is exercised by both apps' tests) |
| `NOHUT_BENCH=1 NOHUT_BENCH_SIZES=1000,10000,50000 flutter test test/benchmark/storage_benchmark_test.dart` | Results in `storage-benchmark.md`; 4 m 38 s |

## 4. Blocked or not done

1. **QR menu repository audit (spec §1.3) is BLOCKED.** Attaching `nohutfalafel/qr-menu` to this session was refused by the session's permission policy. The owner has to allow access, or run the audit in another session.
2. Physical checks are out of scope for an automated session:
   - XP-237B print of the first Gel-Al ticket;
   - measuring the production database size on the restaurant PC.

## 5. Decisions needed from the owner before Phase 1/2

1. **Write latency (storage-benchmark finding 1):** about 1.7 s per save at 10 000 orders and about 7.9 s at 50 000. Recommendation: bring forward the local per-entity tables (spec §2.2 allows this) together with PR-04.
2. **`deleteOrder` physically deletes history and command receipts** (`data-inventory.md` §1). Replace it with tombstones?
3. **Platform PII TTL** and stop collecting `customerEmail` (`platform-data-policy.md` §6).
4. **Cloud projection of saved Gel-Al customers (`customers`)** and the Gel-Al phone.
5. **Old PRs #15, #16, #17** are fully contained in `main` and can be closed. #2, #14 and #19 need a keep, salvage or close decision.
