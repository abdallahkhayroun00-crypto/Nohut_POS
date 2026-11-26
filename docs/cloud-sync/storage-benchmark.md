# Storage Benchmark — Phase 0 baseline (synthetic, measured)

Spec: V5.1 §2.2, §13, §19.7 and §19.9 (PR-01).

All figures below are **measured** on synthetic data in a CI-like Linux container. None of them is a production measurement, and none is a saving achieved by optimization: nothing has been optimized yet. This is the *before* picture.

## How to reproduce

```bash
cd flutter_desktop
NOHUT_BENCH=1 NOHUT_BENCH_SIZES=1000,10000,50000 \
  NOHUT_BENCH_OUT=bench.json flutter test test/benchmark/storage_benchmark_test.dart
```

The test is skipped in normal CI unless `NOHUT_BENCH=1` is set.

| Item | Value |
|---|---|
| Fixture | `test/benchmark/storage_benchmark_test.dart`, `Random(seed: 20261127)` |
| Machine | Linux x86_64 container, 4 vCPU (not the restaurant's Windows laptop) |
| Tooling | Flutter 3.50.1 (`ae9b586f34`), `sqlite3` Dart package, WAL, `synchronous=FULL` |
| Wall time for all three sizes | 4 m 38 s |

## Fixture (realistic shape, real code paths)

Every order is created by the production functions:
- `newLocalOrder`, `addOrderBatch` (15 % of orders have an added batch);
- `cancelProduct` (5 % have a cancelled line);
- `recordPayment` (cash with received/change, card, 10 % split cash + card);
- `refundPayment` (5 %);
- `queuePaymentReceipt` (30 %);
- `normalizeTgoPackage` (25 % of orders are Trendyol Go with options, removed ingredients, notes and the customer fields stored today).

The data contains Turkish text (`ğ ş ı İ ö ü ç`), notes, removed ingredients and campaign-shaped menu lines with components. Every local batch produces its real print-job snapshot. One command receipt is added per Gel-Al order, using the real staff phone-order payload shape.

Order rate: 60 orders/day. At that rate, 10 000 orders ≈ 5.5 months and 50 000 orders ≈ 2.3 years.

## Results

| Orders (local + Trendyol) | State JSON | Orders JSON | Print-job JSON | Trendyol JSON | Command receipts | SQLite file* | `VACUUM INTO` backup | gzip(backup)** | Write p50 | Write p95 |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 000 (742 + 258) | 1.77 MB | 0.77 MB | 0.73 MB | 0.23 MB | 0.11 MB | 3.56 MB | 1.92 MB | 0.12 MB | **150 ms** | 223 ms |
| 10 000 (7 485 + 2 515) | 17.4 MB | 7.74 MB | 7.39 MB | 2.27 MB | 1.07 MB | 34.9 MB | 18.7 MB | 1.12 MB | **1 686 ms** | 1 828 ms |
| 50 000 (37 474 + 12 526) | 87.1 MB | 38.8 MB | 36.9 MB | 11.4 MB | 5.36 MB | 174.5 MB | 93.3 MB | 5.56 MB | **7 888 ms** | 8 617 ms |

Notes on the table:
- MB is decimal (10^6 bytes). Raw numbers are in the JSON printed by the test.
- `*` The SQLite file is about twice the `VACUUM INTO` size because every write rewrites the whole payload, which leaves free pages behind.
- `**` gzip on synthetic data with a fixed vocabulary compresses far better than real data. **Do not use this ratio for capacity planning**; measure on a real backup.

Per-record slope (stable across the three sizes):

| Record | Bytes (JSON, measured) |
|---|---:|
| Local order (header, batches, lines, payments, events) | ≈ 1 036 B |
| Its print-job snapshots | ≈ 985 B per local order (**≈ 95 % of the order itself**) |
| Trendyol Go order (normalized) | ≈ 905 B |
| Staff command receipt | ≈ 353 B |
| Whole state per order (all entities) | ≈ 1.74 KB |
| On disk after `VACUUM INTO` | ≈ 1.87 KB per order |

## Findings

1. **Write amplification is real and already large.** `PosStore.replace` and `command` re-encode, validate and write the *entire* `state_snapshot.payload` on every change. The latency of saving one order grows linearly with history:
   - about 0.15 s at 1 000 orders;
   - about 1.7 s at 10 000 orders (≈ 5–6 months at 60/day);
   - about 7.9 s at 50 000 orders.

   This hits every tap on Windows, phone orders and payments. It is also the hard limit in `PosStore.validate`, which refuses more than 50 000 orders.

   Spec §2.2 allows moving local normalization earlier "if benchmark requires". **This benchmark says it is required**, before the cloud work makes writes heavier. Recommendation: plan PR-04 (outbox) together with a local per-entity table split, and gate both on parity tests.
2. **Print snapshots nearly double order storage.** Each Sipariş Fişi snapshot copies the batch lines. Spec §19.3 allows an immutable reference to the order/batch version plus the frozen facts. Expected effect: remove most of the ≈ 985 B per order. This must be measured again after the change, not assumed.
3. **The idle SQLite file holds about 2× its live data** because of whole-payload rewrites. Per-entity tables (finding 1) also remove this.
4. **Trendyol rows include customer PII** (name, phone, email, address), stored permanently. Removing it is a privacy issue first (`platform-data-policy.md`) and only a small size effect.
5. **Gel-Al command receipts store the full payload, including the phone.** These bytes are small; the issue is privacy.

## Against the spec model (§19.7)

| Model | KB/order |
|---|---:|
| V4 unoptimized PostgreSQL planning reference | 12.1 |
| V5 scenarios | 1.5 / 3 / 5 |
| **Measured today, local SQLite JSON** (no indexes, no PostgreSQL overhead) | **≈ 1.87 on disk** |

PostgreSQL overhead (tuples, indexes, TOAST, MVCC) is not measured here. It will be measured in Phase 2 on the compact schema, as §19.9 requires. No PostgreSQL figure is claimed.

## Not yet measured

- Real production database size and counts on the restaurant PC. A local-only diagnostic that prints counts and bytes without exporting records is proposed for PR-02.
- Latency on the actual Windows laptop (only Linux was measured).
- Network sync bytes per change (Phase 2).
- Cloud storage per order on PostgreSQL (Phase 2).

---

## Phase 1B: before and after (measured)

**Setup:**
- Same machine, same fixture and seed, run back to back with nothing else running.
- "Before" is `main` at `f89d7aa` (single-JSON storage). "After" is the PR #33 branch (per-entity tables).
- The test-suite field validator (`flutter_test_config.dart`) is switched off inside the benchmark, so only the POS itself is measured.
- *Save* = `PosStore.replace` of a state with one new order.
- *Edit* = `read()` + change + save, which is what a cashier action costs.

| Orders | Edit p50 before | Edit p50 after | Edit p95 after | Save p50 before | Save p50 after | SQLite file before | SQLite file after | `VACUUM INTO` before | after | gzip before | after |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 000 | 177 ms | **30 ms** | 63 ms | 130 ms | **22 ms** | 3.6 MB | 2.4 MB | 1.9 MB | 2.4 MB | 0.12 MB | 0.21 MB |
| 10 000 | 1 890 ms | **337 ms** | 414 ms | 1 447 ms | **194 ms** | 34.9 MB | 22.8 MB | 18.7 MB | 22.7 MB | 1.12 MB | 1.91 MB |
| 50 000 | 9 139 ms | **1 811 ms** | 1 911 ms | 6 867 ms | **1 088 ms** | 174.5 MB | 114.2 MB | 93.3 MB | 113.8 MB | 5.55 MB | 9.51 MB |
| 100 000 | refused (old 50 000 ceiling) | **3 502 ms** | 3 646 ms | refused | **1 898 ms** | — | 228.5 MB | — | 227.7 MB | — | 19.08 MB |

### Reading the results honestly

- **Speed:** an edit is about **5× faster** at 10k and 50k orders, and a save about 6–7× faster. 100 000 orders now work; before, the ceiling refused them.
- **Live database file:** about 35 % smaller, because writes no longer leave a whole-payload free page behind on every save.
- **Compact copy and backup are larger:**
  - The `VACUUM INTO` copy is about 20 % larger: one row per entity plus indexes, against one large text value.
  - The gzip backup is about 1.7× larger: per-row JSON compresses less well than one long string.
  - Both are well within the free backup targets: 9.5 MB for 50 000 orders.
- **Edits are still proportional to the number of orders.** At about 60 orders/day: about 0.34 s after 5–6 months and about 1.8 s after about 2.3 years. Three linear passes remain on every edit: the copy made for the caller, `validate()` over every order, and the row comparison.
- **Next steps:** incremental validation of changed orders only, and a copy-on-read for unchanged rows. They are tracked for Phase 2 and must again be measured, not assumed.
- **Not measured yet:**
  - PostgreSQL size and sync payload size (Phase 2, on the cloud schema);
  - the restaurant's Windows laptop.
