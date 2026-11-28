import test from 'node:test';
import assert from 'node:assert/strict';
import { loadProxyConfig } from './config.mjs';
import { createTgoClient, projectPackage } from './tgo-client.mjs';
import { createTrendyolProxyHandler } from './handler.mjs';

const SYNTH_RESTAURANT = '11111111-1111-4111-8111-111111111111';
const OTHER_RESTAURANT = '22222222-2222-4222-8222-222222222222';
const SYNTH_TOKEN = 'a'.repeat(64);
const CMD_ID = '33333333-3333-4333-8333-333333333333';
const ENV_SHA = 'b'.repeat(64);

function makeEnv(overrides = {}) {
  const map = {
    NOHUT_TRENDYOL_PROXY_ENABLED: 'true',
    NOHUT_TRENDYOL_API_BASE: 'https://stageapi.tgoapis.com',
    NOHUT_TRENDYOL_SUPPLIER_ID: '999001',
    NOHUT_TRENDYOL_API_KEY: 'synthetic-key-never-leaked',
    NOHUT_TRENDYOL_API_SECRET: 'synthetic-secret-never-leaked',
    NOHUT_TRENDYOL_EXECUTOR_USER: 'synthetic@example.invalid',
    NOHUT_TRENDYOL_RESTAURANT_ID: SYNTH_RESTAURANT,
    NOHUT_TRENDYOL_STORE_ID: '316490',
    ...overrides,
  };
  return (k) => map[k];
}

function makeReq(body, { method = 'POST', token = SYNTH_TOKEN } = {}) {
  const headers = { 'Content-Type': 'application/json' };
  if (token !== null) headers['x-nohut-agent-token'] = token;
  return new Request('https://example.invalid/functions/v1/trendyol-proxy', {
    method,
    headers,
    body: method === 'POST' ? (typeof body === 'string' ? body : JSON.stringify(body)) : undefined,
  });
}

test('config is disabled by default and rejects non-allowlisted API bases', () => {
  assert.equal(loadProxyConfig(makeEnv({ NOHUT_TRENDYOL_PROXY_ENABLED: '' })).enabled, false);
  assert.throws(
    () => loadProxyConfig(makeEnv({ NOHUT_TRENDYOL_API_BASE: 'https://evil.example' })),
    /config_invalid_api_base/,
  );
});

test('handler refuses non-POST, disabled proxy, missing token, wrong tenant, and extra fields', async () => {
  const disabledHandler = createTrendyolProxyHandler({
    config: { enabled: false },
    tgo: null,
    ports: { authenticateAgent: async () => ({ restaurantId: SYNTH_RESTAURANT }) },
  });
  const rDisabled = await disabledHandler(makeReq({ version: 1, action: 'verify' }));
  assert.equal(rDisabled.status, 503);
  assert.equal((await rDisabled.json()).status, 'proxy_disabled');

  const config = loadProxyConfig(makeEnv());
  const handler = createTrendyolProxyHandler({
    config,
    tgo: createTgoClient(config, { fetchImpl: async () => new Response('{}', { status: 200 }) }),
    ports: {
      authenticateAgent: async (tok) =>
        tok === SYNTH_TOKEN ? { restaurantId: SYNTH_RESTAURANT } : { restaurantId: OTHER_RESTAURANT },
    },
  });

  assert.equal((await handler(makeReq({}, { method: 'GET' }))).status, 405);
  assert.equal((await handler(makeReq({ version: 1, action: 'verify' }, { token: null }))).status, 401);
  assert.equal((await handler(makeReq({ version: 1, action: 'verify', extra: 1 }))).status, 400);
  const rWrongTenant = await handler(makeReq({ version: 1, action: 'verify' }, { token: 'c'.repeat(64) }));
  assert.equal(rWrongTenant.status, 403);
});

test('verify performs read-only GET /stores and never leaks credentials or customer data', async () => {
  const calls = [];
  const config = loadProxyConfig(makeEnv());
  const tgo = createTgoClient(config, {
    fetchImpl: async (url, init) => {
      calls.push({ url, method: init.method, redirect: init.redirect, auth: init.headers.Authorization });
      return new Response(
        JSON.stringify({
          restaurants: [
            {
              id: 316490,
              name: 'Nohut Falafel Synthetic',
              supplierId: 999001,
              workingStatus: 'OPEN',
              deliveryType: 'GO',
              workingHours: [{ dayOfWeek: 'MONDAY', openingTime: '09:00:00', closingTime: '22:00:00' }],
            },
          ],
        }),
        { status: 200 },
      );
    },
  });
  const handler = createTrendyolProxyHandler({
    config,
    tgo,
    ports: { authenticateAgent: async () => ({ restaurantId: SYNTH_RESTAURANT }) },
  });

  const res = await handler(makeReq({ version: 1, action: 'verify' }));
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('cache-control'), 'no-store');
  const text = await res.text();
  assert.ok(!text.includes('synthetic-key-never-leaked'));
  assert.ok(!text.includes('synthetic-secret-never-leaked'));
  const json = JSON.parse(text);
  assert.equal(json.status, 'ok');
  assert.equal(json.verifiedStoreId, '316490');
  assert.equal(json.workingStatus, 'OPEN');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].method, 'GET');
  assert.equal(calls[0].redirect, 'error');
});

test('poll enforces bounds and KVKK minimization (STORE courier gets unmasked phone/address; GO courier omits them; no email)', async () => {
  const config = loadProxyConfig(makeEnv());
  const tgo = createTgoClient(config, {
    fetchImpl: async () =>
      new Response(
        JSON.stringify({
          totalPages: 1,
          content: [
            {
              id: 'pkg-store-1',
              orderCode: 'ORD-1',
              packageStatus: 'Created',
              deliveryType: 'STORE',
              totalPrice: 185,
              customer: { firstName: 'Ayşe', lastName: 'K.', email: 'hidden@example.invalid' },
              address: { phone: '05551234567', address1: 'İstiklal Cad. No:5', district: 'Beyoğlu', city: 'İstanbul' },
              lines: [{ name: 'Falafel Dürüm', price: 185, items: [{ packageItemId: 'i1', isCancelled: false }] }],
            },
            {
              id: 'pkg-go-2',
              orderCode: 'ORD-2',
              packageStatus: 'Created',
              deliveryType: 'GO',
              totalPrice: 120,
              customer: { firstName: 'Mehmet', lastName: 'Y.', email: 'hidden2@example.invalid' },
              address: { phone: '0555***4567', address1: 'Masked ***', city: 'İstanbul' },
              lines: [],
            },
          ],
        }),
        { status: 200 },
      ),
  });
  const handler = createTrendyolProxyHandler({
    config,
    tgo,
    ports: { authenticateAgent: async () => ({ restaurantId: SYNTH_RESTAURANT }) },
  });

  // Window > 7 days rejected
  const bad = await handler(makeReq({ version: 1, action: 'poll', startMs: 0, endMs: 9 * 86400_000, page: 0, size: 50 }));
  assert.equal(bad.status, 400);

  const now = Date.now();
  const res = await handler(makeReq({ version: 1, action: 'poll', startMs: now - 3600_000, endMs: now, page: 0, size: 50 }));
  assert.equal(res.status, 200);
  const json = await res.json();
  assert.equal(json.packages.length, 2);
  assert.equal(json.packages[0].customerPhone, '05551234567');
  assert.ok(json.packages[0].deliveryAddress.includes('İstiklal Cad. No:5'));
  assert.equal(json.packages[0].email, undefined);
  assert.equal(json.packages[1].customerPhone, null);
  assert.equal(json.packages[1].deliveryAddress, null);
});

test('execute Kabul Et / Hazır: preflight check, single PUT, unknown on 5xx, reconcile read-only', async () => {
  let pkgStatus = 'Created';
  let putCalls = 0;
  let force504 = false;
  const config = loadProxyConfig(makeEnv());
  const tgo = createTgoClient(config, {
    fetchImpl: async (url, init) => {
      if (init.method === 'GET' && url.includes('/packages/pkg-42')) {
        return new Response(JSON.stringify({ id: 'pkg-42', packageStatus: pkgStatus, deliveryType: 'GO', lines: [] }), { status: 200 });
      }
      if (init.method === 'PUT' && url.endsWith('/packages/picked')) {
        putCalls++;
        if (force504) return new Response('', { status: 504 });
        pkgStatus = 'Picking';
        return new Response('', { status: 200 });
      }
      if (init.method === 'PUT' && url.endsWith('/packages/invoiced')) {
        putCalls++;
        if (force504) return new Response('', { status: 504 });
        pkgStatus = 'Invoiced';
        return new Response('', { status: 200 });
      }
      return new Response('', { status: 404 });
    },
  });

  let activePayload = { packageId: 'pkg-42', operation: 'accept', preparationTime: 15 };
  const handler = createTrendyolProxyHandler({
    config,
    tgo,
    ports: {
      authenticateAgent: async () => ({ restaurantId: SYNTH_RESTAURANT }),
      validateCommandLease: async () => ({ valid: true, payload: activePayload }),
    },
  });

  // 1. Kabul Et (Created -> Picking)
  const rAccept = await handler(makeReq({ version: 1, action: 'execute', commandId: CMD_ID, leaseGeneration: 1, envelopeSha256: ENV_SHA }));
  assert.equal(rAccept.status, 200);
  assert.equal((await rAccept.json()).status, 'confirmed');
  assert.equal(putCalls, 1);

  // 2. Hazır with 504 timeout -> returns unknown, single attempt only (no blind retry)
  activePayload = { packageId: 'pkg-42', operation: 'ready' };
  force504 = true;
  const rUnknown = await handler(makeReq({ version: 1, action: 'execute', commandId: CMD_ID, leaseGeneration: 2, envelopeSha256: ENV_SHA }));
  assert.equal(rUnknown.status, 200);
  assert.equal((await rUnknown.json()).status, 'unknown');
  assert.equal(putCalls, 2);

  // 3. Reconcile is strictly read-only (does not increment putCalls)
  const rRec = await handler(makeReq({ version: 1, action: 'reconcile', commandId: CMD_ID, leaseGeneration: 2, envelopeSha256: ENV_SHA }));
  assert.equal(rRec.status, 200);
  assert.equal((await rRec.json()).packageStatus, 'Picking');
  assert.equal(putCalls, 2);
});

test('store_status_set (Aç/Kapat): preflight + single PUT + GET /stores readback; 5xx returns unknown without retry', async () => {
  let workingStatus = 'OPEN';
  let putCalls = 0;
  let failPut = false;
  const config = loadProxyConfig(makeEnv());
  const tgo = createTgoClient(config, {
    fetchImpl: async (url, init) => {
      if (init.method === 'GET' && url.includes('/stores')) {
        return new Response(
          JSON.stringify({
            restaurants: [{ id: 316490, name: 'Nohut Falafel', supplierId: 999001, workingStatus, workingHours: [] }],
          }),
          { status: 200 },
        );
      }
      if (init.method === 'PUT' && url.endsWith('/stores/316490/status')) {
        putCalls++;
        if (failPut) return new Response('', { status: 503 });
        const b = JSON.parse(init.body);
        workingStatus = b.status;
        return new Response('', { status: 200 });
      }
      return new Response('', { status: 404 });
    },
  });

  let leasePayload = { targetStatus: 'CLOSED', expectedStatus: 'OPEN' };
  const handler = createTrendyolProxyHandler({
    config,
    tgo,
    ports: {
      authenticateAgent: async () => ({ restaurantId: SYNTH_RESTAURANT }),
      validateCommandLease: async (a) => ({
        valid: a.expectedActionType === 'platform_store_status_set',
        payload: leasePayload,
      }),
    },
  });

  // 1. Successful OPEN -> CLOSED with readback confirmation
  const rClose = await handler(makeReq({ version: 1, action: 'store_status_set', commandId: CMD_ID, leaseGeneration: 1, envelopeSha256: ENV_SHA }));
  assert.equal(rClose.status, 200);
  const jClose = await rClose.json();
  assert.equal(jClose.status, 'confirmed');
  assert.equal(jClose.workingStatus, 'CLOSED');
  assert.equal(putCalls, 1);

  // 2. CLOSED -> OPEN with upstream 503 -> returns unknown, single attempt only
  leasePayload = { targetStatus: 'OPEN', expectedStatus: 'CLOSED' };
  failPut = true;
  const rUnk = await handler(makeReq({ version: 1, action: 'store_status_set', commandId: CMD_ID, leaseGeneration: 2, envelopeSha256: ENV_SHA }));
  assert.equal(rUnk.status, 200);
  assert.equal((await rUnk.json()).status, 'unknown');
  assert.equal(putCalls, 2);
});
