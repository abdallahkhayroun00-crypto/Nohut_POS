// HTTP handler for Trendyol Cloud Proxy v1 (/functions/v1/trendyol-proxy).
// Actions: verify, poll, execute (Kabul Et / Hazır), reconcile, store_status_read, store_status_set (Aç/Kapat).
// B2 fix: matches platform_action payload keys { action: 'accept'|'ready', packageId, preparationMinutes? }.
// N1 fix: enforces payload.storeId === pre.matched.id on store_status_set.
// N3 fix: maps DB/port errors before PUT to 503 unreachable.

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const HEX64_RE = /^[0-9a-f]{64}$/;
const MAX_BODY_BYTES = 32 * 1024;
const MAX_POLL_WINDOW_MS = 7 * 24 * 60 * 60 * 1000;

const ALLOWED_KEYS = {
  verify: new Set(['version', 'action']),
  poll: new Set(['version', 'action', 'startMs', 'endMs', 'page', 'size']),
  execute: new Set(['version', 'action', 'commandId', 'leaseGeneration', 'envelopeSha256']),
  reconcile: new Set(['version', 'action', 'commandId', 'leaseGeneration', 'envelopeSha256']),
  store_status_read: new Set(['version', 'action']),
  store_status_set: new Set(['version', 'action', 'commandId', 'leaseGeneration', 'envelopeSha256']),
};

function jsonResponse(status, payload) {
  return new Response(JSON.stringify({ version: 1, ...payload }), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
    },
  });
}

function validateLeaseEnvelope(body) {
  return (
    typeof body.commandId === 'string' &&
    UUID_RE.test(body.commandId) &&
    Number.isInteger(body.leaseGeneration) &&
    body.leaseGeneration > 0 &&
    typeof body.envelopeSha256 === 'string' &&
    HEX64_RE.test(body.envelopeSha256)
  );
}

export function createTrendyolProxyHandler({ config, tgo, ports }) {
  return async function handle(req) {
    if (req.method !== 'POST') {
      return jsonResponse(405, { status: 'method_not_allowed' });
    }
    if (!config || !config.enabled) {
      return jsonResponse(503, { status: 'proxy_disabled' });
    }

    const token = (req.headers.get('x-nohut-agent-token') || '').trim();
    if (!token || token.length < 32 || token.length > 256) {
      return jsonResponse(401, { status: 'denied' });
    }

    let rawText;
    try {
      const buf = new Uint8Array(await req.arrayBuffer());
      if (buf.byteLength === 0 || buf.byteLength > MAX_BODY_BYTES) {
        return jsonResponse(400, { status: 'invalid_request' });
      }
      rawText = new TextDecoder().decode(buf);
    } catch {
      return jsonResponse(400, { status: 'invalid_request' });
    }

    let body;
    try {
      body = JSON.parse(rawText);
    } catch {
      return jsonResponse(400, { status: 'invalid_request' });
    }

    if (!body || typeof body !== 'object' || Array.isArray(body) || body.version !== 1) {
      return jsonResponse(400, { status: 'invalid_request' });
    }
    const allowed = ALLOWED_KEYS[body.action];
    if (!allowed) {
      return jsonResponse(400, { status: 'invalid_request' });
    }
    for (const key of Object.keys(body)) {
      if (!allowed.has(key)) {
        return jsonResponse(400, { status: 'invalid_request' });
      }
    }

    let agent;
    try {
      agent = await ports.authenticateAgent(token);
    } catch {
      return jsonResponse(503, { status: 'unreachable' });
    }
    if (!agent || !agent.restaurantId || agent.restaurantId.toLowerCase() !== config.restaurantId) {
      return jsonResponse(403, { status: 'denied' });
    }

    // 1. Safe read-only credential & store verification
    if (body.action === 'verify') {
      const st = await tgo.getStores({ page: 0, size: 50 });
      if (!st.ok) {
        if (st.status === 401 || st.status === 403) return jsonResponse(401, { status: 'auth_failed' });
        return jsonResponse(503, { status: 'unknown' });
      }
      if (!st.matched) {
        return jsonResponse(503, { status: 'unknown', reason: 'store_not_uniquely_verified' });
      }
      return jsonResponse(200, {
        status: 'ok',
        verifiedStoreId: st.matched.id,
        verifiedStoreName: st.matched.name,
        workingStatus: st.matched.workingStatus,
      });
    }

    // 2. Bounded read-only order polling
    if (body.action === 'poll') {
      const { startMs, endMs, page = 0, size = 50 } = body;
      if (
        !Number.isInteger(startMs) ||
        !Number.isInteger(endMs) ||
        endMs < startMs ||
        endMs - startMs > MAX_POLL_WINDOW_MS ||
        !Number.isInteger(page) ||
        page < 0 ||
        page > 9 ||
        !Number.isInteger(size) ||
        size < 1 ||
        size > 50
      ) {
        return jsonResponse(400, { status: 'invalid_request' });
      }
      const res = await tgo.pollPackages({ startMs, endMs, page, size });
      if (!res.ok) {
        if (res.status === 401 || res.status === 403) return jsonResponse(401, { status: 'auth_failed' });
        return jsonResponse(503, { status: 'unreachable' });
      }
      return jsonResponse(200, {
        status: 'ok',
        page: res.page,
        hasNextPage: res.hasNextPage,
        packages: res.packages,
      });
    }

    // 3. Read-only store status & working hours (Platform Yönetimi)
    if (body.action === 'store_status_read') {
      const st = await tgo.getStores({ page: 0, size: 50 });
      if (!st.ok) {
        if (st.status === 401 || st.status === 403) return jsonResponse(401, { status: 'auth_failed' });
        return jsonResponse(503, { status: 'unknown' });
      }
      if (!st.matched) {
        return jsonResponse(503, { status: 'unknown', reason: 'store_not_uniquely_verified' });
      }
      return jsonResponse(200, {
        status: 'ok',
        provider: 'trendyol_go',
        verifiedStoreId: st.matched.id,
        verifiedStoreName: st.matched.name,
        workingStatus: st.matched.workingStatus,
        workingHours: st.matched.workingHours,
        verifiedAt: new Date().toISOString(),
      });
    }

    // Helper for lease validation with N3 error mapping before any PUT
    async function loadLease(expectedActionType) {
      try {
        return {
          ok: true,
          lease: await ports.validateCommandLease({
            token,
            commandId: body.commandId,
            leaseGeneration: body.leaseGeneration,
            envelopeSha256: body.envelopeSha256,
            expectedActionType,
          }),
        };
      } catch {
        return { ok: false };
      }
    }

    // 4. Lease-bound order execution: Kabul Et (action='accept') / Hazır (action='ready')
    if (body.action === 'execute') {
      if (!validateLeaseEnvelope(body)) return jsonResponse(400, { status: 'invalid_request' });
      const loaded = await loadLease('platform_action');
      if (!loaded.ok) return jsonResponse(503, { status: 'unreachable' });
      if (!loaded.lease || !loaded.lease.valid) return jsonResponse(409, { status: 'conflict' });

      const payload = loaded.lease.payload || {};
      const packageId = typeof payload.packageId === 'string' && payload.packageId.trim() ? payload.packageId.trim() : null;
      const op = payload.action;
      if (!packageId || (op !== 'accept' && op !== 'ready')) {
        return jsonResponse(400, { status: 'invalid_request' });
      }

      let prepMinutes = 15;
      if (op === 'accept' && payload.preparationMinutes !== undefined && payload.preparationMinutes !== null) {
        if (
          !Number.isInteger(payload.preparationMinutes) ||
          payload.preparationMinutes < 5 ||
          payload.preparationMinutes > 120
        ) {
          return jsonResponse(400, { status: 'invalid_request' });
        }
        prepMinutes = payload.preparationMinutes;
      }

      const pre = await tgo.getPackage({ packageId });
      if (!pre.ok || !pre.pkg) {
        if (pre.status === 401 || pre.status === 403) return jsonResponse(401, { status: 'auth_failed' });
        return jsonResponse(503, { status: 'unknown' });
      }
      const cur = pre.pkg.packageStatus;
      if (op === 'accept') {
        if (cur === 'Picking' || cur === 'Invoiced') {
          return jsonResponse(200, { status: 'no_change', packageStatus: cur });
        }
        if (cur !== 'Created') {
          return jsonResponse(409, { status: 'conflict', packageStatus: cur });
        }
        const put = await tgo.acceptPackage({ packageId, preparationTime: prepMinutes });
        if (put.ok) return jsonResponse(200, { status: 'confirmed', packageStatus: 'Picking' });
        if (put.status === 400 || put.status === 409) return jsonResponse(409, { status: 'conflict' });
        return jsonResponse(200, { status: 'unknown' });
      } else {
        if (cur === 'Invoiced') {
          return jsonResponse(200, { status: 'no_change', packageStatus: cur });
        }
        if (cur !== 'Picking') {
          return jsonResponse(409, { status: 'conflict', packageStatus: cur });
        }
        const put = await tgo.markPackageReady({ packageId });
        if (put.ok) return jsonResponse(200, { status: 'confirmed', packageStatus: 'Invoiced' });
        if (put.status === 400 || put.status === 409) return jsonResponse(409, { status: 'conflict' });
        return jsonResponse(200, { status: 'unknown' });
      }
    }

    // 5. Read-only reconciliation for unknown order outcomes (NEVER mutates)
    if (body.action === 'reconcile') {
      if (!validateLeaseEnvelope(body)) return jsonResponse(400, { status: 'invalid_request' });
      const loaded = await loadLease('platform_action');
      if (!loaded.ok) return jsonResponse(503, { status: 'unreachable' });
      if (!loaded.lease || !loaded.lease.valid || !loaded.lease.payload?.packageId) {
        return jsonResponse(409, { status: 'conflict' });
      }
      const cur = await tgo.getPackage({ packageId: loaded.lease.payload.packageId });
      if (!cur.ok || !cur.pkg) return jsonResponse(503, { status: 'unknown' });
      return jsonResponse(200, {
        status: 'ok',
        packageId: cur.pkg.id,
        packageStatus: cur.pkg.packageStatus,
      });
    }

    // 6. Lease-bound store Aç/Kapat (Platform Yönetimi) with storeId check & readback verification
    if (body.action === 'store_status_set') {
      if (!validateLeaseEnvelope(body)) return jsonResponse(400, { status: 'invalid_request' });
      const loaded = await loadLease('platform_store_status_set');
      if (!loaded.ok) return jsonResponse(503, { status: 'unreachable' });
      if (!loaded.lease || !loaded.lease.valid) return jsonResponse(409, { status: 'conflict' });

      const { storeId, targetStatus, expectedStatus } = loaded.lease.payload || {};
      if ((targetStatus !== 'OPEN' && targetStatus !== 'CLOSED') || (expectedStatus !== 'OPEN' && expectedStatus !== 'CLOSED')) {
        return jsonResponse(400, { status: 'invalid_request' });
      }

      const pre = await tgo.getStores({ page: 0, size: 50 });
      if (!pre.ok || !pre.matched) {
        if (pre.status === 401 || pre.status === 403) return jsonResponse(401, { status: 'auth_failed' });
        return jsonResponse(503, { status: 'unknown' });
      }
      // N1: refuse if command payload storeId disagrees with verified store
      if (storeId != null && String(storeId) !== pre.matched.id) {
        return jsonResponse(409, { status: 'conflict', verifiedStoreId: pre.matched.id });
      }
      if (pre.matched.workingStatus === targetStatus) {
        return jsonResponse(200, {
          status: 'no_change',
          verifiedStoreId: pre.matched.id,
          workingStatus: pre.matched.workingStatus,
          verifiedAt: new Date().toISOString(),
        });
      }
      if (pre.matched.workingStatus !== expectedStatus) {
        return jsonResponse(409, {
          status: 'conflict',
          verifiedStoreId: pre.matched.id,
          workingStatus: pre.matched.workingStatus,
        });
      }

      const put = await tgo.setStoreStatus({ storeId: pre.matched.id, status: targetStatus });
      if (put.status === 400) return jsonResponse(409, { status: 'conflict' });
      if (put.status === 401 || put.status === 403) return jsonResponse(401, { status: 'auth_failed' });
      if (!put.ok) return jsonResponse(200, { status: 'unknown', verifiedStoreId: pre.matched.id });

      const post = await tgo.getStores({ page: 0, size: 50 });
      if (!post.ok || !post.matched) {
        return jsonResponse(200, { status: 'unknown', verifiedStoreId: pre.matched.id });
      }
      return jsonResponse(200, {
        status: post.matched.workingStatus === targetStatus ? 'confirmed' : 'unknown',
        verifiedStoreId: post.matched.id,
        workingStatus: post.matched.workingStatus,
        verifiedAt: new Date().toISOString(),
      });
    }

    return jsonResponse(400, { status: 'invalid_request' });
  };
}
