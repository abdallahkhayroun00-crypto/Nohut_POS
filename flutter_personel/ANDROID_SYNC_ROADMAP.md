# Android / Windows unification — development status

Stacked development PR on Finans PR #21. Not yet a verified production release.

## Implemented in source
- Common Dart package for exact kuruş parsing, market choices and expense totals.
- Android phone/tablet/landscape responsive layouts and eight viewport tests. Previous compact grid overflow was addressed.
- Quick expense create, edit, historical date selection and cancellation. Durable restaurant-scoped local outbox using Android secure storage. A queued operation is persisted before sending, and its immutable request ID is reused after a lost acknowledgement. Acknowledged records are cached locally; full quick-expense pages are pulled from Windows, including cancellation markers.
- Sync is attempted on successful staff LAN refresh (app open/resumed) and via manual button. Windows SQLite is authoritative. Server uses existing transactional command receipts, validates the same desktop finance rules, and rejects stale edits instead of overwriting them. Conflicts are retained until explicit discard/reload.
- The finance key is separate from ordinary staff PIN/bearer access. From Windows local Android pairing panel, generate a 256-bit key, transfer it physically to the trusted Android device, and enter it under Gider → Finans Anahtarı. Finance messages use AES-256-GCM with restaurant-bound request/response authentication. Windows stores the key in DPAPI vault; Android in secure storage. Rotation/revocation affects all devices sharing this key. No plaintext finance snapshot is exposed by the existing staff endpoints.
- Unit tests for cryptographic authentication, authoritative idempotency, stale edits, cancellation and lost-acknowledgement retry after restart.

## Still required before full release
- CI and physical phone/tablet + Windows LAN testing, including cold start, reconnection, app termination, Windows DB restore, key rotation and persistence failure. Existing staff transport remains HTTP, and the Windows local admin panel lacks strong login. Treat as a trusted-device development feature; individual device manager grants/revocation and full access-control audit are still required.
- This is quick expenses only, not full database replication. No wage, other finance categories, private customer history, platform credentials, or complete SQLite snapshots are transferred. Existing financial PDFs are Windows-only. Complete shared finance UI, other validated command types, manager report cache, combined/custom-period PDFs and secure storage lifecycle still need work.
- No background guarantee when Android OS stops the app. No cloud. Do not expose the Windows LAN server to the public internet. Keep Windows as authoritative; never silently replace whole databases or count unacknowledged drafts as settled expenses.
