import test from "node:test";
import assert from "node:assert/strict";
import { evaluateCapabilities } from "./capabilities.mjs";
import { createCloudCapabilitiesHandler } from "./handler.mjs";

const TOKEN_A = "a".repeat(64);
const RESTAURANT_A = "11111111-1111-4111-8111-111111111111";
const RESTAURANT_B = "22222222-2222-4222-8222-222222222222";
const SYNTHETIC_PEM = "-----BEGIN PRIVATE KEY-----\nSYNTHETIC_TEST_KEY_DATA\n-----END PRIVATE KEY-----";

function makeEnv(map) {
  return (key) => map[key];
}

function makeFullSecretsEnv(overrides = {}) {
  return makeEnv({
    NOHUT_QR_PUBLISHER_ENABLED: "true",
    NOHUT_QR_GITHUB_APP_ID: "123456",
    NOHUT_QR_GITHUB_PRIVATE_KEY: SYNTHETIC_PEM,
    NOHUT_QR_RESTAURANT_ID: RESTAURANT_A,

    NOHUT_TRENDYOL_PROXY_ENABLED: "true",
    NOHUT_TRENDYOL_SUPPLIER_ID: "987654",
    NOHUT_TRENDYOL_API_KEY: "syn-tgo-key",
    NOHUT_TRENDYOL_API_SECRET: "syn-tgo-secret",
    NOHUT_TRENDYOL_EXECUTOR_USER: "syn-tgo-user",
    NOHUT_TRENDYOL_RESTAURANT_ID: RESTAURANT_A,

    NOHUT_YEMEKSEPETI_PROXY_ENABLED: "true",
    NOHUT_YEMEKSEPETI_API_KEY: "syn-ys-key",
    NOHUT_YEMEKSEPETI_RESTAURANT_ID: RESTAURANT_A,

    NOHUT_MIGROS_YEMEK_PROXY_ENABLED: "true",
    NOHUT_MIGROS_YEMEK_API_KEY: "syn-my-key",
    NOHUT_MIGROS_YEMEK_RESTAURANT_ID: RESTAURANT_A,

    NOHUT_UBER_EATS_PROXY_ENABLED: "true",
    NOHUT_UBER_EATS_CLIENT_ID: "syn-ue-client",
    NOHUT_UBER_EATS_CLIENT_SECRET: "syn-ue-secret",
    NOHUT_UBER_EATS_RESTAURANT_ID: RESTAURANT_A,
    ...overrides,
  });
}

test("defaults all five capabilities to false when unconfigured", () => {
  const res = evaluateCapabilities(makeEnv({}), RESTAURANT_A);
  assert.deepEqual(res, {
    version: 1,
    qrPublish: false,
    providers: {
      trendyol_go: false,
      yemeksepeti: false,
      migros_yemek: false,
      uber_eats: false,
    },
  });
});

test("fails closed when secrets exist but *_ENABLED flags are not true", () => {
  const env = makeFullSecretsEnv({
    NOHUT_QR_PUBLISHER_ENABLED: "false",
    NOHUT_TRENDYOL_PROXY_ENABLED: "",
    NOHUT_YEMEKSEPETI_PROXY_ENABLED: undefined,
    NOHUT_MIGROS_YEMEK_PROXY_ENABLED: "0",
    NOHUT_UBER_EATS_PROXY_ENABLED: "no",
  });
  const res = evaluateCapabilities(env, RESTAURANT_A);
  assert.equal(res.qrPublish, false);
  assert.deepEqual(res.providers, {
    trendyol_go: false,
    yemeksepeti: false,
    migros_yemek: false,
    uber_eats: false,
  });
});

test("fails closed when enabled flags are true but required secrets are missing or invalid", () => {
  const env = makeFullSecretsEnv({
    NOHUT_QR_GITHUB_PRIVATE_KEY: "not-a-pem",
    NOHUT_TRENDYOL_API_SECRET: "   ",
    NOHUT_YEMEKSEPETI_API_KEY: "",
    NOHUT_MIGROS_YEMEK_API_KEY: "",
    NOHUT_UBER_EATS_CLIENT_SECRET: "",
  });
  const res = evaluateCapabilities(env, RESTAURANT_A);
  assert.equal(res.qrPublish, false);
  assert.deepEqual(res.providers, {
    trendyol_go: false,
    yemeksepeti: false,
    migros_yemek: false,
    uber_eats: false,
  });
});

test("reports true for all five capabilities when enabled, configured, and tenant matches", () => {
  const res = evaluateCapabilities(makeFullSecretsEnv(), RESTAURANT_A);
  assert.deepEqual(res, {
    version: 1,
    qrPublish: true,
    providers: {
      trendyol_go: true,
      yemeksepeti: true,
      migros_yemek: true,
      uber_eats: true,
    },
  });
});

test("enforces tenant isolation: another restaurant sees false for tenant-pinned capabilities", () => {
  const res = evaluateCapabilities(makeFullSecretsEnv(), RESTAURANT_B);
  assert.deepEqual(res, {
    version: 1,
    qrPublish: false,
    providers: {
      trendyol_go: false,
      yemeksepeti: false,
      migros_yemek: false,
      uber_eats: false,
    },
  });
});

test("HTTP handler enforces auth, method, body strictness, and zero secret leakage", async () => {
  const env = makeFullSecretsEnv();
  const handle = createCloudCapabilitiesHandler({
    env,
    ports: {
      async authenticateAgent(token) {
        if (token === TOKEN_A) return { restaurantId: RESTAURANT_A };
        return null;
      },
    },
  });

  // 405 on unsupported method
  const r405 = await handle(new Request("https://example.invalid/cloud-capabilities", { method: "PUT" }));
  assert.equal(r405.status, 405);

  // 401 on missing/malformed token
  const r401 = await handle(new Request("https://example.invalid/cloud-capabilities", { method: "GET" }));
  assert.equal(r401.status, 401);

  // 403 on unknown/revoked agent token
  const r403 = await handle(
    new Request("https://example.invalid/cloud-capabilities", {
      method: "GET",
      headers: { "x-nohut-agent-token": "b".repeat(64) },
    })
  );
  assert.equal(r403.status, 403);

  // 400 on unknown keys in POST body
  const r400 = await handle(
    new Request("https://example.invalid/cloud-capabilities", {
      method: "POST",
      headers: {
        "x-nohut-agent-token": TOKEN_A,
        "content-type": "application/json",
      },
      body: JSON.stringify({ restaurantId: RESTAURANT_A }),
    })
  );
  assert.equal(r400.status, 400);

  // 200 on GET and POST {}
  for (const req of [
    new Request("https://example.invalid/cloud-capabilities", {
      method: "GET",
      headers: { "x-nohut-agent-token": TOKEN_A },
    }),
    new Request("https://example.invalid/cloud-capabilities", {
      method: "POST",
      headers: {
        "x-nohut-agent-token": TOKEN_A,
        "content-type": "application/json",
      },
      body: "{}",
    }),
  ]) {
    const res = await handle(req);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("cache-control"), "no-store");
    assert.equal(res.headers.get("x-content-type-options"), "nosniff");
    const text = await res.text();
    for (const forbidden of [
      "SYNTHETIC_TEST_KEY_DATA",
      "syn-tgo-key",
      "syn-tgo-secret",
      "syn-ys-key",
      "syn-my-key",
      "syn-ue-client",
      "syn-ue-secret",
      "NOHUT_",
      RESTAURANT_A,
    ]) {
      assert.ok(!text.includes(forbidden), `response leaked forbidden string: ${forbidden}`);
    }
    assert.deepEqual(JSON.parse(text), {
      version: 1,
      qrPublish: true,
      providers: {
        trendyol_go: true,
        yemeksepeti: true,
        migros_yemek: true,
        uber_eats: true,
      },
    });
  }
});

test("HTTP handler returns 503 when DB authentication throws", async () => {
  const handle = createCloudCapabilitiesHandler({
    env: makeFullSecretsEnv(),
    ports: {
      async authenticateAgent() {
        throw new Error("db_connection_refused");
      },
    },
  });
  const res = await handle(
    new Request("https://example.invalid/cloud-capabilities", {
      method: "GET",
      headers: { "x-nohut-agent-token": TOKEN_A },
    })
  );
  assert.equal(res.status, 503);
  assert.deepEqual(await res.json(), { error: "capabilities_unavailable" });
});
