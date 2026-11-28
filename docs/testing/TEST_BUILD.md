# Isolated TEST build (owner request 7236201964)

Sign in with username `test` and PIN `00000` on Windows-served clients: Personel and Yönetici Android, and the local Personel and Yönetici web apps. This works **only** against a TEST build of Windows POS:

```
cd flutter_desktop
flutter build windows --release --dart-define=NOHUT_TEST_BUILD=true
```

## What a TEST build does

| Area | TEST build | Normal build |
|---|---|---|
| Data | `%APPDATA%\NohutFalafel-TEST`, fresh synthetic staff (Test Yönetici, Test Personel A/B); `NOHUT_POS_DATABASE` is ignored | `%APPDATA%\NohutFalafel` |
| `test` / `00000` | Accepted for the seeded `test` owner account. PIN `00000` is allowed for that account only | Not seeded; `test` / `00000` is refused; `00000` stays a weak PIN |
| Other accounts | Same password and PIN rules as production | Unchanged |
| Network | Outgoing HTTP only to this computer (`127.0.0.1` / `localhost`): no Trendyol, Yemeksepeti, Google, GitHub, Supabase or market prices | Unchanged |
| QR menu | Publisher never started; publisher calls refused | Unchanged |
| Printing | Refused | Unchanged |
| Payments | No live provider exists in either build | — |
| Screen | Red "TEST SÜRÜMÜ · sentetik veri · canlı işlemler kapalı" banner, window title "Nohut Falafel · TEST" | — |

A normal build compiles all of this away (`NOHUT_TEST_BUILD` is a compile-time constant).

## Rules

- Never install a TEST build on the restaurant PC.
- Never point it at production Supabase or the production PWAs.
- The cloud PWAs (nohut-personel / nohut-yonetici .pages.dev) are production and get no test account. A separate TEST PWA would be a new Cloudflare project, which needs the owner's approval.
- Phones show the account they sign in with. Pair them only with the TEST computer.

CI runs `test/test_build_test.dart` twice: once normally, to check that production has no fixture, and once with the define, to check isolation and the blocks.
