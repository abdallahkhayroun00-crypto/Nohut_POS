// Server-side Trendyol GO Cloud Proxy configuration.
// Reads ONLY preconfigured Supabase Secrets. Never logs or returns secret values.

const ALLOWED_BASES = new Set([
  'https://api.tgoapis.com',
  'https://stageapi.tgoapis.com',
]);

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DIGITS_RE = /^[0-9]{1,20}$/;

export function loadProxyConfig(env) {
  const enabled = String(env('NOHUT_TRENDYOL_PROXY_ENABLED') || '').trim().toLowerCase() === 'true';
  const apiBase = String(env('NOHUT_TRENDYOL_API_BASE') || 'https://api.tgoapis.com').trim().replace(/\/+$/, '');
  const supplierId = String(env('NOHUT_TRENDYOL_SUPPLIER_ID') || '').trim();
  const apiKey = String(env('NOHUT_TRENDYOL_API_KEY') || '').trim();
  const apiSecret = String(env('NOHUT_TRENDYOL_API_SECRET') || '').trim();
  const executorUser = String(env('NOHUT_TRENDYOL_EXECUTOR_USER') || '').trim();
  const restaurantId = String(env('NOHUT_TRENDYOL_RESTAURANT_ID') || '').trim();
  const pinnedStoreId = String(env('NOHUT_TRENDYOL_STORE_ID') || '').trim() || null;

  if (!enabled) {
    return { enabled: false };
  }
  if (!ALLOWED_BASES.has(apiBase)) {
    throw new Error('config_invalid_api_base');
  }
  if (!DIGITS_RE.test(supplierId)) {
    throw new Error('config_missing_supplier_id');
  }
  if (!apiKey || !apiSecret || !executorUser) {
    throw new Error('config_missing_credentials');
  }
  if (!UUID_RE.test(restaurantId)) {
    throw new Error('config_missing_restaurant_binding');
  }
  if (pinnedStoreId !== null && !DIGITS_RE.test(pinnedStoreId)) {
    throw new Error('config_invalid_store_id');
  }

  return {
    enabled: true,
    apiBase,
    supplierId,
    apiKey,
    apiSecret,
    executorUser,
    restaurantId: restaurantId.toLowerCase(),
    pinnedStoreId,
  };
}
