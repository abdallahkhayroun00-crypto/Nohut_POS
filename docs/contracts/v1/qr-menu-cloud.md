# Contract: QR Menu Management Cloud Integration (`v1`)

- **Owner:** Temporary Backend Continuation (`gemini/backend-continuation`, PR #46) in coordination with Claude (`qr_menu_remote.dart`, `#7228113217`)
- **Migrations:**
  - `supabase/migrations/20261127168000_nohut_qr_menu_cloud.sql`
  - `supabase/migrations/20261127169000_nohut_qr_menu_commands.sql`
- **Status:** `Implemented / Tested` (pending independent review by ChatGPT / Codex)

## Security & Authority Invariants

1. **Windows remains authoritative:** GitHub tokens and publisher keys stay strictly in Windows DPAPI. Cloud tables and command payloads reject any secret/token keys (`nohut_private.contains_forbidden_secret_key`).
2. **Role parity (Owner Decision `#7226936601` / `QA-18`):** Both `Personel` and `Yönetici` (plus `Müdür`) receive all 7 `menu.*` grants by default (`menu.view`, `menu.product.edit`, `menu.price.edit`, `menu.category.edit`, `menu.campaign.edit`, `menu.stock.toggle`, `menu.qr.publish`). `Muhasebe` retains `menu.view` only. No permissions outside `menu.*` are broadened.
3. **Zero direct table access:** `nohut_private.qr_menu_state` has `FORCE ROW LEVEL SECURITY` and all privileges revoked from `public`, `anon`, `authenticated`, and `service_role`.

## Sync Projection (`entity_type = 'qrMenuState'`, `entity_id = 'core'`)

Windows emits the current offline draft + published diff + bounded audit (`≤ 100` entries) via `serializeQrMenuCloudState(...)` (`flutter_desktop/lib/cloud_qr_menu_bridge.dart`).

## Authenticated Read RPC

### `public.nohut_qr_menu_view(p_device_id uuid, p_client text, p_permission_version bigint)`
- **Grant required:** `menu.view`
- **Returns:** Exact `#7228113217` shape (`available`, `stamp`, `revision`, `revisionLabel`, `offline`, `pendingPublish`, `can`, `publish: 'here'|'windows'`, optional `link: 'ready'|'no_key'|'service_down'`, `changes`, `catalog`, `recentAudit`) plus `syncMeta` (`sourceRevision`, `calculatedAt`, `syncedAt`, `stale`, `staleReason`).

## Remote Commands (`public.nohut_enqueue_command`)

All commands bind the acting user from JWT (`auth.uid()`), require an active session/device/permission_version, and preserve `requestId` idempotency (`accepted` / `duplicate` / `conflict`):

| `p_action` | Operation Grant | Required Payload | TTL |
|---|---|---|---|
| `qr_menu_write` | Per `payload.action`: `set_price` → `menu.price.edit`, `set_stock` → `menu.stock.toggle`, `set_visible`/`set_image`/`save_product` → `menu.product.edit`, `save_category` → `menu.category.edit`, `save_campaign` → `menu.campaign.edit` | `expectedStamp` (16-hex), `action`, entity fields | 15m |
| `qr_menu_publish` | `menu.qr.publish` | `expectedStamp` (16-hex), `confirmed: true`, optional `draftSha256` (64-hex, prefix must equal `expectedStamp`), optional `expectedRevision` | 5m |
| `qr_menu_reconcile` | `menu.qr.publish` | Exact `{"targetRequestId": "<UUID>", "mode": "reconcile" \| "cancel_before_attempt"}` (legacy `{}` denied per PR #49 / Claude `aea2861`) | 5m |
| `qr_menu_image` | `menu.product.edit` | `expectedStamp`, `id`, `mime` (`image/png`/`jpeg`/`webp`), `storagePath` (`qr-uploads/...`) or `base64`, optional `sizeBytes <= 6291456` | 10m |
| `qr_menu_sync` | `menu.product.edit` | `{}` | 5m |
