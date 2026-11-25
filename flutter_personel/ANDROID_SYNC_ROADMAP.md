# Android / Windows unification — phase 1

This is a stacked development branch on the Finans PR, not a production release.

## Implemented
- Common pure Dart package nohut_core used by both Flutter apps for market identity, payment choices, exact kuruş parsing and quick-expense arithmetic.
- Existing native Android client retains live restaurant LAN ordering and existing pairing. Responsive content widths, compact headers, scrollable product layouts, portrait/landscape navigation and tests at eight logical viewport sizes.
- Previously paired Android devices can create, edit and delete quick-expense **local drafts**, with historical dates and multiple amounts; stored in Android secure storage keyed by paired server identity. These are not Windows financial records. The UI explicitly says not sent.
- Android and Windows workflows both watch the common package.

## Security and synchronization gates — not implemented here
The existing staff bearer token is transported via HTTP and is not manager authorization. Do not expose finance, wage, customer history, full state snapshots, or new finance writes on staff endpoints. Implement manager-approved role enrollment with authenticated encrypted transport (certificate pinning / trusted enrollment), revocation and least privilege before transmitting private financial records. Keep restaurant identity binding across DHCP changes.

Next: durable transactional outbox and local finance cache, server-validated mutation commands with stable IDs and stored idempotency receipts, entity-level version checks, explicit conflict resolution, pull updates by cursor, delete tombstones, and acknowledgement only after the authoritative transaction commits. Preserve unsent drafts across app restarts and never silently erase or auto-duplicate them. Use Windows as authoritative store. Live orders, payments and receipt printing remain online/Windows-authoritative. Add manager finance UI and shared PDF/report functionality incrementally, then test offline/reconnect, duplicate retries, concurrent edits, restored backups, authorization and real devices. Do not merge as a completed offline-sync solution.
