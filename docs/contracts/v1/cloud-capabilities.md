# Cloud Capabilities v1 Contract (`cloud-capabilities`)

Status: **Implemented / Tested (pending independent cross-review)**.

## Purpose
Allows a freshly installed Windows POS PC to discover which external integrations are hosted centrally in Supabase Edge Function Secrets — eliminating per-PC `.pem` file pickers and manual API credential entry once each cloud integration is verified and enabled.

## Endpoint
- **URL:** `GET` or `POST` `/functions/v1/cloud-capabilities`
- **Authentication:** `x-nohut-agent-token: <64-hex Windows agent opaque token>` (verified server-side via `nohut_private.authenticate_windows_agent(token)`).
- **POST body (optional):** Empty body or `{}` (`Content-Type: application/json`). Any unknown keys return `400 {"error":"invalid_request"}`.
- **Response headers:** `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`.

## Response (`200 OK`)
```json
{
  "version": 1,
  "qrPublish": false,
  "providers": {
    "trendyol_go": false,
    "yemeksepeti": false,
    "migros_yemek": false,
    "uber_eats": false
  }
}
```

## Security & Fail-Closed Guarantees
1. **Zero secret material:** Only booleans and `version: 1` are ever returned — never secret values, secret names, diagnostic hints, or tenant IDs.
2. **Fail-closed by default:** Every boolean stays `false` until **both** the explicit `NOHUT_*_ENABLED=true` cutover flag **and** all required Supabase Edge Function secrets are syntactically present.
3. **Tenant isolation:** Provider secrets are pinned to a restaurant UUID (`NOHUT_<PROVIDER>_RESTAURANT_ID`; optional `NOHUT_QR_RESTAURANT_ID` for QR). A Windows agent for a different restaurant always receives `false`.
4. **Error codes:**
   - `401 {"error":"unauthorized"}` — missing or non-64-hex `x-nohut-agent-token`.
   - `403 {"error":"forbidden"}` — unknown or revoked Windows agent token.
   - `405 {"error":"method_not_allowed"}` — methods other than `GET`/`POST`.
   - `503 {"error":"capabilities_unavailable"}` — database unreachable (client must keep existing local fallback behavior).

## Windows Client Cutover Rule
- When `qrPublish === true`, Windows hides the local `.pem` picker and routes QR publish/reconcile calls to `/functions/v1/qr-publisher`.
- When `providers.trendyol_go === true`, Windows hides the local Trendyol API credential form and routes Trendyol operations to `/functions/v1/trendyol-proxy`.
- When `providers.yemeksepeti`, `providers.migros_yemek`, or `providers.uber_eats` is `true`, Windows hides local credential prompts for that provider and uses its cloud proxy.
- When any capability is `false` (or the endpoint is unreachable/offline), existing local paths and DPAPI/backup behavior remain untouched.
