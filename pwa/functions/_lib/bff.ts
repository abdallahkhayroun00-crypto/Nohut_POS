// Phase 3B-2 Login BFF (spec §23, §24.2): same-origin Cloudflare Pages
// Functions between the web apps and Supabase Auth. The refresh token lives
// only in an HttpOnly cookie; the short-lived access token is handed to the
// page in memory, and after a reopen only once the trusted-device PIN has
// been verified on the server. Identity always comes from the provider JWT;
// the database wrappers (public.nohut_*) decide everything else.
//
// No secret is needed: only the Supabase URL and the PUBLISHABLE key.
// Accounts are signed in as `<username>@<NOHUT_LOGIN_DOMAIN>` in Supabase Auth.

export interface BffEnv {
  SUPABASE_URL?: string;
  SUPABASE_PUBLISHABLE_KEY?: string;
  /** Domain of the provider e-mail used for usernames. Default users.nohut.invalid */
  NOHUT_LOGIN_DOMAIN?: string;
}

export type Fetcher = (input: string, init?: RequestInit) => Promise<Response>;

export const COOKIE = '__Host-nohut_rt';
const COOKIE_MAX_AGE = 30 * 24 * 3600;
const MAX_BODY = 4096;
const USERNAME = /^[a-z0-9][a-z0-9._-]{2,31}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const CLIENTS = new Set(['personel', 'yonetici']);

/** Best-effort per-isolate throttle; Supabase Auth also rate-limits. */
export class Throttle {
  private hits = new Map<string, { n: number; until: number }>();
  constructor(private limit = 5, private windowMs = 15 * 60_000, private now = () => Date.now()) {}
  blocked(key: string): boolean {
    const h = this.hits.get(key);
    if (!h) return false;
    if (this.now() > h.until) { this.hits.delete(key); return false; }
    return h.n >= this.limit;
  }
  fail(key: string): void {
    const h = this.hits.get(key);
    if (!h || this.now() > h.until) this.hits.set(key, { n: 1, until: this.now() + this.windowMs });
    else h.n++;
  }
  clear(key: string): void { this.hits.delete(key); }
}

interface Tokens { access_token: string; refresh_token: string; expires_in?: number }

class BffError extends Error {
  constructor(readonly status: number, readonly code: string) { super(code); }
}

function json(status: number, body: unknown, cookie?: string): Response {
  const headers = new Headers({
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
  });
  if (cookie) headers.append('Set-Cookie', cookie);
  return new Response(JSON.stringify(body), { status, headers });
}

export const setCookie = (refresh: string) =>
  `${COOKIE}=${encodeURIComponent(refresh)}; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=${COOKIE_MAX_AGE}`;
export const clearCookie = () => `${COOKIE}=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0`;

export function readCookie(request: Request): string | null {
  for (const part of (request.headers.get('Cookie') ?? '').split(';')) {
    const [k, ...v] = part.trim().split('=');
    if (k === COOKIE) {
      const value = decodeURIComponent(v.join('='));
      return value.length > 0 && value.length <= 2048 ? value : null;
    }
  }
  return null;
}

/** Sends a provider/database error code through only when it is a known one. */
const PUBLIC_CODES = new Set([
  'password_required', 'weak_pin', 'session_revoked', 'device_revoked', 'client_not_allowed',
  'inactive', 'unknown_user', 'mfa_required', 'invalid_pin', 'locked', 'invalid_code',
]);

export class LoginBff {
  constructor(
    private env: BffEnv,
    private fetcher: Fetcher = fetch,
    private throttle = new Throttle(),
  ) {}

  private get base(): string {
    const url = (this.env.SUPABASE_URL ?? '').trim();
    if (!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(url)) throw new BffError(503, 'not_configured');
    return url;
  }
  private get key(): string {
    const k = (this.env.SUPABASE_PUBLISHABLE_KEY ?? '').trim();
    if (k.length < 20) throw new BffError(503, 'not_configured');
    return k;
  }
  private email(username: string): string {
    const domain = (this.env.NOHUT_LOGIN_DOMAIN ?? 'users.nohut.invalid').trim().toLowerCase();
    return `${username}@${domain}`;
  }

  private async auth(path: string, body: unknown, bearer?: string, method = 'POST'): Promise<any> {
    const res = await this.fetcher(`${this.base}/auth/v1/${path}`, {
      method,
      headers: { apikey: this.key, 'Content-Type': 'application/json',
        ...(bearer ? { Authorization: `Bearer ${bearer}` } : {}) },
      body: method === 'GET' ? undefined : JSON.stringify(body ?? {}),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new BffError(res.status === 429 ? 429 : 401, res.status === 429 ? 'too_many_attempts' : 'invalid_credentials');
    return data;
  }

  private async rpc(fn: string, args: Record<string, unknown>, access: string): Promise<any> {
    const res = await this.fetcher(`${this.base}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: { apikey: this.key, Authorization: `Bearer ${access}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(args),
    });
    const text = await res.text();
    const data = text ? JSON.parse(text) : null;
    if (!res.ok) {
      const code = typeof data?.message === 'string' && PUBLIC_CODES.has(data.message) ? data.message : 'request_failed';
      throw new BffError(res.status === 401 ? 401 : 403, code);
    }
    return data;
  }

  private async whoami(access: string, deviceId: string, client: string) {
    const w = await this.rpc('nohut_whoami', { p_device_id: deviceId, p_client: client }, access);
    if (w?.status !== 'ok') throw new BffError(401, PUBLIC_CODES.has(w?.status) ? w.status : 'session_revoked');
    return w;
  }

  /** Entry point for /api/auth/:action. */
  async handle(request: Request, action: string): Promise<Response> {
    try {
      if (request.method !== 'POST') throw new BffError(405, 'method_not_allowed');
      const origin = request.headers.get('Origin');
      if (!origin || origin !== new URL(request.url).origin) throw new BffError(403, 'bad_origin');
      if (!(request.headers.get('Content-Type') ?? '').startsWith('application/json')) throw new BffError(415, 'json_required');
      const raw = await request.text();
      if (raw.length > MAX_BODY) throw new BffError(413, 'too_large');
      let body: Record<string, unknown>;
      try { body = raw ? JSON.parse(raw) : {}; } catch { throw new BffError(400, 'bad_request'); }
      if (typeof body !== 'object' || body === null || Array.isArray(body)) throw new BffError(400, 'bad_request');
      const deviceId = String(body.deviceId ?? '');
      const client = String(body.client ?? '');
      if (!UUID.test(deviceId) || !CLIENTS.has(client)) throw new BffError(400, 'bad_request');
      const ip = request.headers.get('CF-Connecting-IP') ?? 'unknown';
      switch (action) {
        case 'login': return await this.login(body, deviceId, client, ip);
        case 'unlock': return await this.unlock(request, body, deviceId, client, ip);
        case 'pin': return await this.setPin(request, body, deviceId, client, ip);
        case 'mfa': return await this.mfa(request, body, deviceId, client, ip);
        case 'logout': return await this.logout(request, deviceId);
        default: throw new BffError(404, 'not_found');
      }
    } catch (e) {
      if (e instanceof BffError) {
        const clear = e.code === 'session_revoked' || e.code === 'device_revoked' || e.code === 'inactive';
        return json(e.status, { error: e.code }, clear ? clearCookie() : undefined);
      }
      return json(502, { error: 'unavailable' });
    }
  }

  private async passwordTokens(username: string, password: string, ip: string): Promise<Tokens> {
    const key = `${ip}|${username}`;
    if (this.throttle.blocked(key) || this.throttle.blocked(`user|${username}`)) throw new BffError(429, 'too_many_attempts');
    try {
      const t = await this.auth('token?grant_type=password', { email: this.email(username), password });
      this.throttle.clear(key);
      return t as Tokens;
    } catch (e) {
      this.throttle.fail(key);
      this.throttle.fail(`user|${username}`);
      throw e;
    }
  }

  /** Username + password. Registers this device, then returns the session. */
  private async login(body: Record<string, unknown>, deviceId: string, client: string, ip: string) {
    const username = String(body.username ?? '').trim().toLowerCase();
    const password = String(body.password ?? '');
    if (!USERNAME.test(username) || password.length < 1 || password.length > 128) throw new BffError(401, 'invalid_credentials');
    const t = await this.passwordTokens(username, password, ip);
    const label = String(body.label ?? '').slice(0, 60);
    await this.rpc('nohut_register_device', { p_device_id: deviceId, p_client: client, p_label: label }, t.access_token);
    const w = await this.whoami(t.access_token, deviceId, client);
    return json(200, { session: w, accessToken: t.access_token, expiresIn: t.expires_in ?? 3600 }, setCookie(t.refresh_token));
  }

  /** Reopen or idle unlock: PIN before token. The refresh token is rotated
   *  either way; the access token is released only after the PIN is ok. */
  private async unlock(request: Request, body: Record<string, unknown>, deviceId: string, client: string, ip: string) {
    const refresh = readCookie(request);
    if (!refresh) throw new BffError(401, 'auth_required');
    const pin = String(body.pin ?? '');
    if (!/^[0-9]{5,6}$/.test(pin)) throw new BffError(400, 'invalid_pin');
    if (this.throttle.blocked(`pin|${ip}|${deviceId}`)) throw new BffError(429, 'too_many_attempts');
    let t: Tokens;
    try { t = await this.auth('token?grant_type=refresh_token', { refresh_token: refresh }); }
    catch { return json(401, { error: 'auth_required' }, clearCookie()); }
    const rotated = setCookie(t.refresh_token);
    const verdict = await this.rpc('nohut_verify_pin', { p_device_id: deviceId, p_pin: pin }, t.access_token);
    if (verdict === 'ok') {
      this.throttle.clear(`pin|${ip}|${deviceId}`);
      const w = await this.whoami(t.access_token, deviceId, client);
      return json(200, { session: w, accessToken: t.access_token, expiresIn: t.expires_in ?? 3600 }, rotated);
    }
    if (verdict === 'wrong') {
      this.throttle.fail(`pin|${ip}|${deviceId}`);
      return json(403, { error: 'invalid_pin' }, rotated);
    }
    // 'locked' (5th wrong PIN cleared it) or 'no_pin': password sign-in again.
    await this.auth('logout', {}, t.access_token).catch(() => undefined);
    return json(403, { error: 'password_required' }, clearCookie());
  }

  /** Set or replace this device's PIN. Replacing needs the password: the
   *  BFF signs in again so the JWT carries a fresh `amr` password stamp,
   *  which the database checks (migration 20261127211000). */
  private async setPin(request: Request, body: Record<string, unknown>, deviceId: string, client: string, ip: string) {
    const access = (request.headers.get('Authorization') ?? '').replace(/^Bearer /, '');
    if (access.length < 20) throw new BffError(401, 'auth_required');
    const pin = String(body.pin ?? '');
    let token = access, cookie: string | undefined;
    if (body.password != null) {
      const w = await this.whoami(access, deviceId, client);
      const t = await this.passwordTokens(String(w.username), String(body.password), ip);
      await this.rpc('nohut_register_device', { p_device_id: deviceId, p_client: client, p_label: '' }, t.access_token);
      token = t.access_token;
      cookie = setCookie(t.refresh_token);
    }
    await this.rpc('nohut_set_pin', { p_device_id: deviceId, p_pin: pin }, token);
    return json(200, { ok: true, ...(token !== access ? { accessToken: token } : {}) }, cookie);
  }

  /** Owner TOTP: raises the session to aal2 (owner administration). */
  private async mfa(request: Request, body: Record<string, unknown>, deviceId: string, client: string, ip: string) {
    const access = (request.headers.get('Authorization') ?? '').replace(/^Bearer /, '');
    if (access.length < 20) throw new BffError(401, 'auth_required');
    const code = String(body.code ?? '');
    if (!/^[0-9]{6}$/.test(code)) throw new BffError(400, 'invalid_code');
    if (this.throttle.blocked(`mfa|${ip}|${deviceId}`)) throw new BffError(429, 'too_many_attempts');
    const user = await this.auth('user', undefined, access, 'GET');
    const factor = (Array.isArray(user?.factors) ? user.factors : [])
      .find((f: any) => f?.factor_type === 'totp' && f?.status === 'verified');
    if (!factor || typeof factor.id !== 'string') throw new BffError(403, 'mfa_not_enrolled');
    const challenge = await this.auth(`factors/${encodeURIComponent(factor.id)}/challenge`, {}, access);
    let t: Tokens;
    try {
      t = await this.auth(`factors/${encodeURIComponent(factor.id)}/verify`, { challenge_id: challenge.id, code }, access);
    } catch {
      this.throttle.fail(`mfa|${ip}|${deviceId}`);
      throw new BffError(403, 'invalid_code');
    }
    const w = await this.whoami(t.access_token, deviceId, client);
    return json(200, { session: w, accessToken: t.access_token, expiresIn: t.expires_in ?? 3600 }, setCookie(t.refresh_token));
  }

  private async logout(request: Request, deviceId: string) {
    const access = (request.headers.get('Authorization') ?? '').replace(/^Bearer /, '');
    if (access.length >= 20) {
      await this.rpc('nohut_logout', { p_device_id: deviceId }, access).catch(() => undefined);
      await this.auth('logout', {}, access).catch(() => undefined);
    }
    return json(200, { ok: true }, clearCookie());
  }
}
