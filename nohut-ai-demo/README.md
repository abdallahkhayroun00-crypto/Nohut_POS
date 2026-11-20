# Nohut AI Lab — isolated GitHub Pages experiment

Test page (after GitHub Pages deployment):
https://abdallahkhayroun00-crypto.github.io/brand-management-proposal/nohut-ai-demo/

This is a separate folder. The existing official QR menu, POS, SQLite and payment systems remain untouched.

## Ready now

- Responsive Turkish-first UI, with English and Arabic choices.
- Reads public menu information from nohutfalafel.github.io/qr-menu (menu-data.js, menu-ar.js and campaigns-data.js); attempts to refresh price and availability from CMS JSON when CORS permits.
- Local no-key demo responses for budget, vegan-labelled products, menu descriptions, active offers, and group recommendations.
- Browser speech input on supported browsers.
- Best sellers: refuses to invent a ranking unless an authenticated POS aggregate was published.
- Optional Worker URL input under the settings gear. Do NOT put a Gemini key in the URL field.

## Enable Gemini with Cloudflare (manual setup; NOT deployed yet)

1. Revoke the API key previously pasted in chat. Create a new Authorization API key at https://aistudio.google.com/api-keys and check that the project/model are eligible for the Free Tier. Do not rely on ChatGPT/Gemini subscriptions for API credits.
2. In Cloudflare, log in with Wrangler, then in the nohut-ai-demo/cloudflare folder execute: npm install -g wrangler, wrangler login, and wrangler kv namespace create NOHUT_AI.
3. Replace the placeholder KV namespace ID in cloudflare/wrangler.toml.
4. Store three secrets with Wrangler (or Cloudflare dashboard): GEMINI_API_KEY (new Gemini key), POS_SYNC_SECRET (independent random HMAC key), and HASH_SALT (separate random salt). Use wrangler secret put GEMINI_API_KEY and similarly for the others. Never commit those values to GitHub.
5. Verify Google billing settings and rate limits. Then set AI_ENABLED=true in wrangler.toml (non-secret config) and run wrangler deploy.
6. Open the test page, tap the settings gear, and enter only the HTTPS Worker base URL, such as https://nohut-ai-lab.YOUR-SUBDOMAIN.workers.dev . The backend will use Gemini through its secret without revealing the key in the browser.

The default model ID is gemini-4-hydrogen, using the Google Interactions API with store:false. The model ID can be configured in Wrangler. This repo has NOT provisioned a Cloudflare account or tested a real Gemini request.

## Worker API routes

- GET /api/ai/status: AI availability, quota/cooldown state.
- POST /api/ai/chat: customer question in Turkish/English/Arabic; secure server-side Gemini call.
- GET /api/popular: last published sanitized seven-day Top 5, or empty ranking if not synced.
- POST /api/pos/sync: an authenticated aggregate data publisher for future Windows POS integration.

## How local POS best sellers would be connected (not yet implemented in Flutter)

The Windows laptop sends an outbound HTTPS request to the Worker. It NEVER exposes the SQLite DB to the internet. It exports only up to five approved product names and ranks, after excluding DEMO orders, refunds and cancellations, and verifying menu identity.

Headers:
- X-Nohut-Timestamp: current Unix timestamp in seconds
- X-Nohut-Signature: lowercase HMAC-SHA256 hex over timestamp + period + exact raw JSON body, with signed message equal to timestamp + "." + raw_body and key POS_SYNC_SECRET.

Example payload (FICTIONAL; NOT REAL SALES):

    {
      "period": "last_7_days",
      "ranking": [
        {"product_name":"Falafel Dürüm"},
        {"product_name":"Vegan Dürüm"}
      ]
    }

The Worker uses the official public CMS to validate product names and publishes no revenue, customer data, staff information, individual orders or sold quantities. Actual Windows POS export requires separate implementation and validation of the existing order/refund logic. No real data exists in the demo yet.

## Quota safeguards

The Worker has an internal soft limit of 60 calls per Pacific calendar day and 6 per anonymous browser per day (with a separate shared-IP ceiling of 60 per day). These are NOT Google limits, NOT an assertion that 60 free calls are guaranteed, and NOT a financial hard cap. Cloudflare KV counters are eventually consistent, so high concurrency can overrun them. For a strict cap, use an atomic Durable Object counter plus actual project quota/billing safeguards.

An upstream Google 429 triggers a temporary 90-second cooldown, not a claim that the full daily quota is gone. The frontend falls back to local menu responses when the Worker is offline. Public QR menu remains untouched.

Do not pass customer PII to Gemini. Free Tier prompts may be used by Google to improve products. Allergy safety and cross-contact should be confirmed by restaurant staff.

## Test cases

- Mobile Safari, Chrome/Android, desktop responsive tests.
- TR / EN / AR switching and RTL presentation.
- 200 TL budget never recommends a product above the available budget.
- Vegan only means officially labelled vegan in published data, not guaranteed allergy-safe.
- Campaigns automatically disappear after their end timestamp.
- Top sellers remain unavailable until POS aggregates are genuinely published.
- No billing, customer or raw staff data leaks via browser.
- API key must NOT appear in HTML, browser source, README or repository history.
- Malicious POST to /api/pos/sync without valid HMAC returns 401.
- AI quota exhausted or offline: local menu assistance works without crashing.

Official menu: https://nohutfalafel.github.io/qr-menu/
Google docs: https://aistudio.google.com/docs/interactions-overview
Cloudflare secrets: https://developers.cloudflare.com/workers/configuration/secrets/

STATUS: front-end is a real test page; Cloudflare deployment, live Gemini, real POS sync and device QA are pending.
