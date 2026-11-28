// Pure, fail-closed capability evaluator for Nohut POS Cloud Capabilities v1.
// Reads Supabase Edge Function secrets via the supplied `env(key)` getter and
// returns ONLY booleans scoped to the authenticated Windows agent's restaurant.
// Never returns, logs, or reflects any secret value, secret name, or tenant ID.

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DIGITS_RE = /^\d+$/;

function readTrimmed(env, key) {
  const v = env(key);
  return typeof v === "string" ? v.trim() : "";
}

function isEnabled(env, key) {
  return readTrimmed(env, key).toLowerCase() === "true";
}

function matchesTenant(env, key, restaurantId, { required = true } = {}) {
  const configured = readTrimmed(env, key);
  if (!configured) return !required;
  if (!UUID_RE.test(configured) || !UUID_RE.test(restaurantId)) return false;
  return configured.toLowerCase() === restaurantId.toLowerCase();
}

function hasPem(env, key) {
  const raw = env(key);
  if (typeof raw !== "string") return false;
  const trimmed = raw.trim();
  return trimmed.includes("-----BEGIN ") && trimmed.includes("PRIVATE KEY-----");
}

function hasNonEmpty(env, key) {
  return readTrimmed(env, key).length > 0;
}

/**
 * Evaluates which cloud-hosted integrations are both explicitly enabled and
 * backed by syntactically complete server-side secrets for `restaurantId`.
 */
export function evaluateCapabilities(env, restaurantId) {
  if (typeof env !== "function" || typeof restaurantId !== "string" || !UUID_RE.test(restaurantId)) {
    return {
      version: 1,
      qrPublish: false,
      providers: {
        trendyol_go: false,
        yemeksepeti: false,
        migros_yemek: false,
        uber_eats: false,
      },
    };
  }

  const qrPublish =
    isEnabled(env, "NOHUT_QR_PUBLISHER_ENABLED") &&
    DIGITS_RE.test(readTrimmed(env, "NOHUT_QR_GITHUB_APP_ID")) &&
    hasPem(env, "NOHUT_QR_GITHUB_PRIVATE_KEY") &&
    matchesTenant(env, "NOHUT_QR_RESTAURANT_ID", restaurantId, { required: false });

  const trendyolGo =
    isEnabled(env, "NOHUT_TRENDYOL_PROXY_ENABLED") &&
    DIGITS_RE.test(readTrimmed(env, "NOHUT_TRENDYOL_SUPPLIER_ID")) &&
    hasNonEmpty(env, "NOHUT_TRENDYOL_API_KEY") &&
    hasNonEmpty(env, "NOHUT_TRENDYOL_API_SECRET") &&
    hasNonEmpty(env, "NOHUT_TRENDYOL_EXECUTOR_USER") &&
    matchesTenant(env, "NOHUT_TRENDYOL_RESTAURANT_ID", restaurantId, { required: true });

  const yemeksepeti =
    isEnabled(env, "NOHUT_YEMEKSEPETI_PROXY_ENABLED") &&
    hasNonEmpty(env, "NOHUT_YEMEKSEPETI_API_KEY") &&
    matchesTenant(env, "NOHUT_YEMEKSEPETI_RESTAURANT_ID", restaurantId, { required: true });

  const migrosYemek =
    isEnabled(env, "NOHUT_MIGROS_YEMEK_PROXY_ENABLED") &&
    hasNonEmpty(env, "NOHUT_MIGROS_YEMEK_API_KEY") &&
    matchesTenant(env, "NOHUT_MIGROS_YEMEK_RESTAURANT_ID", restaurantId, { required: true });

  const uberEats =
    isEnabled(env, "NOHUT_UBER_EATS_PROXY_ENABLED") &&
    hasNonEmpty(env, "NOHUT_UBER_EATS_CLIENT_ID") &&
    hasNonEmpty(env, "NOHUT_UBER_EATS_CLIENT_SECRET") &&
    matchesTenant(env, "NOHUT_UBER_EATS_RESTAURANT_ID", restaurantId, { required: true });

  return {
    version: 1,
    qrPublish,
    providers: {
      trendyol_go: trendyolGo,
      yemeksepeti,
      migros_yemek: migrosYemek,
      uber_eats: uberEats,
    },
  };
}
