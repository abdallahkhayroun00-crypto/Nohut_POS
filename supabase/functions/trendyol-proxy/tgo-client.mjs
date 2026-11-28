// Fixed-host HTTPS client for official Uber Eats Trendyol GO Meal APIs.
// Enforces: no redirects, bounded timeout, bounded response body, Basic Auth,
// strict typed projection matching Windows normalizeTgoPackage (B4 + N2 KVKK).

const MAX_RESPONSE_BYTES = 2 * 1024 * 1024; // 2 MB
const DEFAULT_TIMEOUT_MS = 10_000;
const MASKED_RE = /(\*|xxx|•••)/i;

function toBase64(str) {
  if (typeof btoa === 'function') {
    const bytes = new TextEncoder().encode(str);
    let bin = '';
    for (const b of bytes) bin += String.fromCharCode(b);
    return btoa(bin);
  }
  return Buffer.from(str, 'utf8').toString('base64');
}

function cleanStr(v, maxLen = 240) {
  if (typeof v !== 'string') return null;
  const s = v.trim();
  return s ? s.slice(0, maxLen) : null;
}

function isMasked(s) {
  return typeof s === 'string' && MASKED_RE.test(s);
}

function projectWorkingHours(list) {
  if (!Array.isArray(list)) return [];
  const out = [];
  for (const h of list) {
    if (!h || typeof h !== 'object') continue;
    const dayOfWeek = cleanStr(h.dayOfWeek, 20);
    const openingTime = cleanStr(h.openingTime, 16);
    const closingTime = cleanStr(h.closingTime, 16);
    if (dayOfWeek && openingTime && closingTime) {
      out.push({ dayOfWeek, openingTime, closingTime });
    }
  }
  return out;
}

function projectAddressParts(addr) {
  if (!addr || typeof addr !== 'object') return null;
  const parts = [
    addr.address1,
    addr.address2,
    addr.neighborhood,
    addr.district,
    addr.city,
    addr.doorNumber ? `Kapı: ${addr.doorNumber}` : null,
    addr.floor ? `Kat: ${addr.floor}` : null,
    addr.apartmentNumber ? `Daire: ${addr.apartmentNumber}` : null,
    addr.addressDescription,
  ]
    .map((p) => (typeof p === 'string' ? p.trim() : ''))
    .filter((p) => p.length > 0 && !isMasked(p));
  return parts.length > 0 ? parts.join(', ').slice(0, 400) : null;
}

function projectPhone(addr) {
  if (!addr || typeof addr !== 'object') return null;
  const p = cleanStr(addr.phone, 40);
  if (!p || isMasked(p)) return null;
  return p;
}

function projectIngredients(list) {
  if (!Array.isArray(list)) return [];
  return list
    .filter((x) => x && typeof x === 'object')
    .map((x) => ({
      id: x.id != null ? String(x.id) : null,
      name: cleanStr(x.name, 120) || '',
      price: typeof x.price === 'number' ? x.price : Number(x.price || 0),
    }))
    .filter((x) => x.name.length > 0);
}

function projectModifiers(list, depth = 0) {
  if (!Array.isArray(list) || depth > 4) return [];
  return list
    .filter((m) => m && typeof m === 'object')
    .map((m) => ({
      name: cleanStr(m.name, 120) || '',
      price: typeof m.price === 'number' ? m.price : Number(m.price || 0),
      removedIngredients: projectIngredients(m.removedIngredients),
      extraIngredients: projectIngredients(m.extraIngredients),
      modifierProducts: projectModifiers(m.modifierProducts, depth + 1),
    }));
}

// Typed allowlist matching Windows normalizeTgoPackage + owner-approved receipt fields
// (unitSellingPrice, removedIngredients, extraIngredients, nested modifierProducts,
// payment.paymentType, storePickupSelected; KVKK-minimized, zero email).
export function projectPackage(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const id = raw.id != null ? String(raw.id) : null;
  if (!id) return null;
  const addr = raw.address && typeof raw.address === 'object' ? raw.address : null;
  const deliveryType = cleanStr(raw.deliveryType, 24) || 'UNKNOWN';
  const storePickupSelected = Boolean(raw.storePickupSelected);
  const exposeDeliveryContact = deliveryType.toUpperCase() === 'STORE' && !storePickupSelected;

  const lines = Array.isArray(raw.lines)
    ? raw.lines
        .filter((l) => l && typeof l === 'object')
        .map((l) => ({
          name: cleanStr(l.name, 160) || '',
          unitSellingPrice:
            typeof l.unitSellingPrice === 'number'
              ? l.unitSellingPrice
              : typeof l.price === 'number'
                ? l.price
                : Number(l.unitSellingPrice ?? l.price ?? 0),
          price: typeof l.price === 'number' ? l.price : Number(l.price || 0),
          items: Array.isArray(l.items)
            ? l.items.map((it) => ({
                packageItemId: it?.packageItemId != null ? String(it.packageItemId) : null,
                isCancelled: Boolean(it?.isCancelled),
              }))
            : [],
          removedIngredients: projectIngredients(l.removedIngredients),
          extraIngredients: projectIngredients(l.extraIngredients),
          modifierProducts: projectModifiers(l.modifierProducts, 0),
        }))
    : [];

  return {
    id,
    orderCode: cleanStr(raw.orderCode, 64),
    orderNumber: cleanStr(raw.orderNumber, 64),
    packageStatus: cleanStr(raw.packageStatus, 32) || 'Unknown',
    deliveryType,
    storePickupSelected,
    payment: {
      paymentType: cleanStr(raw.payment?.paymentType, 48),
    },
    totalPrice: typeof raw.totalPrice === 'number' ? raw.totalPrice : Number(raw.totalPrice || 0),
    packageCreationDate: typeof raw.packageCreationDate === 'number' ? raw.packageCreationDate : null,
    packageModificationDate: typeof raw.packageModificationDate === 'number' ? raw.packageModificationDate : null,
    customerNote: cleanStr(raw.customerNote, 300),
    customerFirstName: cleanStr(raw.customer?.firstName, 80),
    customerLastName: cleanStr(raw.customer?.lastName, 80),
    // KVKK minimization: expose unmasked contact/address ONLY for restaurant-managed delivery (never Gel-Al / GO)
    customerPhone: exposeDeliveryContact ? projectPhone(addr) : null,
    deliveryAddress: exposeDeliveryContact ? projectAddressParts(addr) : null,
    lines,
  };
}

export function createTgoClient(config, { fetchImpl = fetch, timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  const authHeader = `Basic ${toBase64(`${config.apiKey}:${config.apiSecret}`)}`;
  const commonHeaders = {
    Authorization: authHeader,
    'User-Agent': `${config.supplierId} - SelfIntegration`,
    'x-agentname': 'NohutFalafelPOS',
    'x-executor-user': config.executorUser,
    Accept: 'application/json',
  };

  async function request(method, path, bodyObj) {
    const url = `${config.apiBase}${path}`;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const headers = { ...commonHeaders };
      let body;
      if (bodyObj !== undefined) {
        headers['Content-Type'] = 'application/json';
        body = JSON.stringify(bodyObj);
      }
      const res = await fetchImpl(url, {
        method,
        headers,
        body,
        redirect: 'error',
        signal: controller.signal,
      });
      const buf = new Uint8Array(await res.arrayBuffer());
      if (buf.byteLength > MAX_RESPONSE_BYTES) {
        return { ok: false, status: 502, error: 'upstream_response_too_large' };
      }
      const text = new TextDecoder().decode(buf);
      let json = null;
      if (text.trim().length > 0) {
        try {
          json = JSON.parse(text);
        } catch {
          json = null;
        }
      }
      return { ok: res.ok, status: res.status, json };
    } catch (err) {
      const isTimeout = err && (err.name === 'AbortError' || String(err).includes('abort'));
      return { ok: false, status: 0, error: isTimeout ? 'upstream_timeout' : 'upstream_unreachable' };
    } finally {
      clearTimeout(timer);
    }
  }

  return {
    async getStores({ page = 0, size = 50 } = {}) {
      const p = Math.max(0, Math.min(9, Number(page) | 0));
      const s = Math.max(1, Math.min(50, Number(size) | 0));
      const r = await request(
        'GET',
        `/integrator/store/meal/suppliers/${config.supplierId}/stores?page=${p}&size=${s}`,
      );
      if (!r.ok || !r.json || !Array.isArray(r.json.restaurants)) {
        return { ok: false, status: r.status, error: r.error || 'stores_fetch_failed' };
      }
      const stores = r.json.restaurants
        .filter((st) => st && typeof st === 'object' && String(st.supplierId ?? config.supplierId) === config.supplierId)
        .map((st) => ({
          id: String(st.id),
          name: cleanStr(st.name, 160) || '',
          supplierId: String(st.supplierId ?? config.supplierId),
          workingStatus: st.workingStatus === 'OPEN' || st.workingStatus === 'CLOSED' ? st.workingStatus : 'UNKNOWN',
          deliveryType: cleanStr(st.deliveryType, 24) || 'UNKNOWN',
          workingHours: projectWorkingHours(st.workingHours),
        }));
      const matched = config.pinnedStoreId
        ? stores.find((st) => st.id === config.pinnedStoreId) || null
        : stores.length === 1
          ? stores[0]
          : null;
      return { ok: true, status: r.status, stores, matched };
    },

    async setStoreStatus({ storeId, status }) {
      if (status !== 'OPEN' && status !== 'CLOSED') {
        throw new Error('invalid_store_status');
      }
      return request(
        'PUT',
        `/integrator/store/meal/suppliers/${config.supplierId}/stores/${encodeURIComponent(String(storeId))}/status`,
        { status },
      );
    },

    async pollPackages({ startMs, endMs, page = 0, size = 50 }) {
      const qs = new URLSearchParams({
        page: String(page),
        size: String(size),
        packageModificationStartDate: String(startMs),
        packageModificationEndDate: String(endMs),
      });
      const r = await request(
        'GET',
        `/integrator/order/meal/suppliers/${config.supplierId}/packages?${qs.toString()}`,
      );
      if (!r.ok || !r.json || !Array.isArray(r.json.content)) {
        return { ok: false, status: r.status, error: r.error || 'packages_fetch_failed' };
      }
      const packages = r.json.content.map(projectPackage).filter(Boolean);
      const totalPages = Number(r.json.totalPages || 0);
      return {
        ok: true,
        status: r.status,
        page,
        hasNextPage: totalPages > 0 ? page + 1 < totalPages : packages.length === size,
        packages,
      };
    },

    async getPackage({ packageId }) {
      const r = await request(
        'GET',
        `/integrator/order/meal/suppliers/${config.supplierId}/packages/${encodeURIComponent(String(packageId))}`,
      );
      if (!r.ok || !r.json) {
        return { ok: false, status: r.status, error: r.error || 'package_fetch_failed' };
      }
      return { ok: true, status: r.status, pkg: projectPackage(r.json) };
    },

    async acceptPackage({ packageId, preparationTime }) {
      if (!Number.isInteger(preparationTime) || preparationTime < 5 || preparationTime > 120) {
        throw new Error('invalid_preparation_time');
      }
      return request(
        'PUT',
        `/integrator/order/meal/suppliers/${config.supplierId}/packages/picked`,
        { packageId: String(packageId), preparationTime },
      );
    },

    async markPackageReady({ packageId }) {
      return request(
        'PUT',
        `/integrator/order/meal/suppliers/${config.supplierId}/packages/invoiced`,
        { packageId: String(packageId) },
      );
    },
  };
}
