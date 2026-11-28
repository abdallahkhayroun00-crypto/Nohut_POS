import test from 'node:test';
import assert from 'node:assert/strict';
import { loadProxyConfig } from './config.mjs';
import { createTgoClient } from './tgo-client.mjs';
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
  assert.equal((await handler(makeReq({ version: 1, action: 'verify' }, { token: 'c'.repeat(64) }))).status, 403);
});

test('verify performs read-only GET /stores and never leaks credentials or customer data', async () => {
  const calls = [];
  const config = loadProxyConfig(makeEnv());
  const tgo = createTgoClient(config, {
    fetchImpl: async (url, init) => {
      calls.push({ url, method: init.method, redirect: init.redirect });
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
  assert.equal(calls[0].redirect, 'error');
});

test('B4 + N2: poll projects unitSellingPrice, removed/extra ingredients, nested modifiers, paymentType, storePickupSelected and KVKK masking', async () => {
  const config = loadProxyConfig(makeEnv());
  const tgo = createTgoClient(config, {
    fetchImpl: async () =>
      new Response(
        JSON.stringify({
          totalPages: 1,
          content: [
            {
              id: 'pkg-store-delivery',
              orderCode: 'ORD-1',
              packageStatus: 'Created',
              deliveryType: 'STORE',
              storePickupSelected: false,
              payment: { paymentType: 'PAY_WITH_CARD' },
              totalPrice: 210,
              customer: { firstName: 'Ayşe', lastName: 'K.', email: 'hidden@example.invalid' },
              address: { phone: '05551234567', address1: 'İstiklal Cad. No:5', district: 'Beyoğlu', city: 'İstanbul' },
              lines: [
                {
                  name: 'Falafel Dürüm',
                  price: 200,
                  unitSellingPrice: 185,
                  items: [{ packageItemId: 'i1', isCancelled: false }],
                  removedIngredients: [{ id: 10, name: 'Soğan', price: 0 }],
                  extraIngredients: [{ id: 11, name: 'Humus', price: 25 }],
                  modifierProducts: [
                    {
                      name: 'İçecek Seçimi',
                      price: 0,
                      removedIngredients: [{ id: 12, name: 'Buz', price: 0 }],
                      extraIngredients: [{ id: 13, name: 'Limon', price: 0 }],
                      modifierProducts: [{ name: 'Ayran', price: 0 }],
                    },
                  ],
                },
              ],
            },
            {
              id: 'pkg-store-pickup',
              orderCode: 'ORD-2',
              packageStatus: 'Created',
              deliveryType: 'STORE',
              storePickupSelected: true,
              payment: { paymentType: 'ONLINE' },
              totalPrice: 150,
              address: { phone: '05559998877', address1: 'Should Not Expose For Gel-Al', city: 'İstanbul' },
              lines: [],
            },
            {
              id: 'pkg-store-masked',
              orderCode: 'ORD-3',
              packageStatus: 'Created',
              deliveryType: 'STORE',
              storePickupSelected: false,
              address: { phone: '0555xxx8877', address1: 'Gizli ••• Sokak', city: 'İstanbul' },
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

  const now = Date.now();
  const res = await handler(makeReq({ version: 1, action: 'poll', startMs: now - 3600_000, endMs: now, page: 0, size: 50 }));
  assert.equal(res.status, 200);
  const json = await res.json();
  const [delivery, pickup, masked] = json.packages;

  // B4 kitchen/receipt fields
  assert.equal(delivery.payment.paymentType, 'PAY_WITH_CARD');
  assert.equal(delivery.storePickupSelected, false);
  assert.equal(delivery.lines[0].unitSellingPrice, 185);
  assert.equal(delivery.lines[0].removedIngredients[0].name, 'Soğan');
  assert.equal(delivery.lines[0].extraIngredients[0].name, 'Humus');
  assert.equal(delivery.lines[0].modifierProducts[0].removedIngredients[0].name, 'Buz');
  assert.equal(delivery.lines[0].modifierProducts[0].modifierProducts[0].name, 'Ayran');
  assert.equal(delivery.customerPhone, '05551234567');
  assert.ok(delivery.deliveryAddress.includes('İstiklal Cad. No:5'));

  // N2 KVKK: Gel-Al pickup omits phone & address even on STORE courier
  assert.equal(pickup.storePickupSelected, true);
  assert.equal(pickup.customerPhone, null);
  assert.equal(pickup.deliveryAddress, null);

  // N2 KVKK: xxx and ••• masked values are omitted
  assert.equal(masked.customerPhone, null);
  assert.equal(masked.deliveryAddress, 'İstanbul');
});

test('B2 + N3: execute uses {action, packageId, preparationMinutes}, validates prep range, maps DB throw to 503', async () => {
  let pkgStatus = 'Created';
  let putCalls = 0;
  let force504 = false;
  let throwDb = false;
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

  let activePayload = { packageId: 'pkg-42', action: 'accept', preparationMinutes: 20 };
  const handler = createTrendyolProxyHandler({
    config,
    tgo,
    ports: {
      authenticateAgent: async () => ({ restaurantId: SYNTH_RESTAURANT }),
      validateCommandLease: async () => {
        if (throwDb) throw new Error('db_connection_lost');
        return { valid: true, payload: activePayload };
      },
    },
  });

  // N3: DB throw before PUT -> 503 unreachable
  throwDb = true;
  const rDb = await handler(makeReq({ version: 1, action: 'execute', commandId: CMD_ID, leaseGeneration: 1, envelopeSha256: ENV_SHA }));
  assert.equal(rDb.status, 503);
  assert.equal((await rDb.json()).status, 'unreachable');
  assert.equal(putCalls, 0);
  throwDb = false;

  // B2: invalid preparationMinutes rejected with 400 before PUT
  activePayload = { packageId: 'pkg-42', action: 'accept', preparationMinutes: 'not-an-int' };
  const rBadPrep = await handler(makeReq({ version: 1, action: 'execute', commandId: CMD_ID, leaseGeneration: 1, envelopeSha256: ENV_SHA }));
  assert.equal(rBadPrep.status, 400);
  assert.equal(putCalls, 0);

  // B2: valid Kabul Et (action='accept', preparationMinutes=20)
  activePayload = { packageId: 'pkg-42', action: 'accept', preparationMinutes: 20 };
  const rAccept = await handler(makeReq({ version: 1, action: 'execute', commandId: CMD_ID, leaseGeneration: 1, envelopeSha256: ENV_SHA }));
  assert.equal(rAccept.status, 200);
  assert.equal((await rAccept.json()).status, 'confirmed');
  assert.equal(putCalls, 1);

  // Hazır with 504 -> unknown, single attempt
  activePayload = { packageId: 'pkg-42', action: 'ready' };
  force504 = true;
  const rUnknown = await handler(makeReq({ version: 1, action: 'execute', commandId: CMD_ID, leaseGeneration: 2, envelopeSha256: ENV_SHA }));
  assert.equal(rUnknown.status, 200);
  assert.equal((await rUnknown.json()).status, 'unknown');
  assert.equal(putCalls, 2);

  // Reconcile is strictly read-only
  const rRec = await handler(makeReq({ version: 1, action: 'reconcile', commandId: CMD_ID, leaseGeneration: 2, envelopeSha256: ENV_SHA }));
  assert.equal(rRec.status, 200);
  assert.equal((await rRec.json()).packageStatus, 'Picking');
  assert.equal(putCalls, 2);
});

test('N1: store_status_set refuses mismatched payload.storeId, confirms matching OPEN->CLOSED with readback', async () => {
  let workingStatus = 'OPEN';
  let putCalls = 0;
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
        workingStatus = JSON.parse(init.body).status;
        return new Response('', { status: 200 });
      }
      return new Response('', { status: 404 });
    },
  });

  let leasePayload = { storeId: '999999', targetStatus: 'CLOSED', expectedStatus: 'OPEN' };
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

  // N1: mismatched storeId -> 409 conflict before PUT
  const rWrongStore = await handler(makeReq({ version: 1, action: 'store_status_set', commandId: CMD_ID, leaseGeneration: 1, envelopeSha256: ENV_SHA }));
  assert.equal(rWrongStore.status, 409);
  assert.equal(putCalls, 0);

  // Matching storeId -> confirmed CLOSED
  leasePayload = { storeId: '316490', targetStatus: 'CLOSED', expectedStatus: 'OPEN' };
  const rClose = await handler(makeReq({ version: 1, action: 'store_status_set', commandId: CMD_ID, leaseGeneration: 1, envelopeSha256: ENV_SHA }));
  assert.equal(rClose.status, 200);
  const jClose = await rClose.json();
  assert.equal(jClose.status, 'confirmed');
  assert.equal(jClose.workingStatus, 'CLOSED');
  assert.equal(putCalls, 1);
});
