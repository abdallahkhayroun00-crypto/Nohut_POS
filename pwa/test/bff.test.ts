// Login BFF (3B-2) against a synthetic Supabase stand-in: no network.
import { describe, expect, it } from 'vitest';
import { COOKIE, LoginBff, Throttle, readCookie } from '../functions/_lib/bff';

const ORIGIN = 'https://nohut-personel.pages.dev';
const DEV = '2b1c9e0a-5d0f-4a4e-9b51-3f2d6a7c8e90';
const env = { SUPABASE_URL: 'https://synthetic-test.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_synthetic_000000' };

/** Synthetic Supabase: one user `deniz` / `synthetic-pass-1`, PIN 58291. */
function fakeSupabase() {
  const calls: string[] = [];
  let n = 0, pin: string | null = null, pinFailed = 0;
  const live = new Set<string>();
  const fresh = new Set<string>(); // access tokens that carry a recent password amr
  const tokens = (pw = false) => {
    n++;
    const t = { access_token: `access-token-synthetic-${n}`, refresh_token: `refresh-synthetic-${n}`, expires_in: 3600 };
    live.add(t.refresh_token);
    if (pw) fresh.add(t.access_token);
    return t;
  };
  const ok = (b: unknown) => new Response(JSON.stringify(b), { status: 200 });
  const fetcher = async (url: string, init?: RequestInit) => {
    const path = url.replace(env.SUPABASE_URL, '');
    calls.push(path);
    const body = init?.body ? JSON.parse(String(init.body)) : {};
    const bearer = String((init?.headers as Record<string, string>)?.Authorization ?? '').replace('Bearer ', '');
    if (path === '/auth/v1/token?grant_type=password') {
      return body.email === 'deniz@users.nohut.invalid' && body.password === 'synthetic-pass-1'
        ? ok(tokens(true)) : new Response('{"error":"invalid_grant"}', { status: 400 });
    }
    if (path === '/auth/v1/token?grant_type=refresh_token') {
      if (!live.delete(body.refresh_token)) return new Response('{}', { status: 400 });
      return ok(tokens());
    }
    if (path === '/auth/v1/logout') return new Response(null, { status: 204 });
    if (path === '/auth/v1/user') return ok({ factors: [{ id: 'factor-1', factor_type: 'totp', status: 'verified' }] });
    if (path === '/auth/v1/factors/factor-1/challenge') return ok({ id: 'challenge-1' });
    if (path === '/auth/v1/factors/factor-1/verify') return body.code === '123456' ? ok(tokens()) : new Response('{}', { status: 422 });
    if (path === '/rest/v1/rpc/nohut_register_device' || path === '/rest/v1/rpc/nohut_logout') return new Response(null, { status: 204 });
    if (path === '/rest/v1/rpc/nohut_whoami') return ok({ status: 'ok', username: 'deniz', role: 'Personel', has_pin: pin != null, grants: ['orders.create'] });
    if (path === '/rest/v1/rpc/nohut_set_pin') {
      if (!fresh.has(bearer)) return new Response('{"message":"password_required"}', { status: 403 });
      pin = body.p_pin; return new Response(null, { status: 204 });
    }
    if (path === '/rest/v1/rpc/nohut_verify_pin') {
      if (pin == null) return ok('no_pin');
      if (body.p_pin === pin) { pinFailed = 0; return ok('ok'); }
      if (++pinFailed >= 5) { pin = null; pinFailed = 0; return ok('locked'); }
      return ok('wrong');
    }
    return new Response('{}', { status: 404 });
  };
  return { fetcher, calls };
}

function req(action: string, body: Record<string, unknown>, opts: { cookie?: string; bearer?: string; origin?: string } = {}) {
  const headers: Record<string, string> = { 'Content-Type': 'application/json', Origin: opts.origin ?? ORIGIN, 'CF-Connecting-IP': '203.0.113.7' };
  if (opts.cookie) headers.Cookie = opts.cookie;
  if (opts.bearer) headers.Authorization = `Bearer ${opts.bearer}`;
  return new Request(`${ORIGIN}/api/auth/${action}`, { method: 'POST', headers, body: JSON.stringify({ deviceId: DEV, client: 'personel', ...body }) });
}
const cookieOf = (r: Response) => (r.headers.get('Set-Cookie') ?? '').split(';')[0] ?? '';

describe('Login BFF', () => {
  it('login sets only an HttpOnly refresh cookie and returns the session', async () => {
    const s = fakeSupabase();
    const bff = new LoginBff(env, s.fetcher);
    const r = await bff.handle(req('login', { username: 'Deniz', password: 'synthetic-pass-1' }), 'login');
    expect(r.status).toBe(200);
    const sc = r.headers.get('Set-Cookie') ?? '';
    expect(sc).toContain(`${COOKIE}=refresh-synthetic-1`);
    expect(sc).toMatch(/HttpOnly/);
    expect(sc).toMatch(/Secure/);
    expect(sc).toMatch(/SameSite=Strict/);
    expect(r.headers.get('Cache-Control')).toBe('no-store');
    const b = await r.json() as any;
    expect(b.session.username).toBe('deniz');
    expect(JSON.stringify(b)).not.toContain('refresh-synthetic');
    expect(s.calls).toContain('/rest/v1/rpc/nohut_register_device');
  });

  it('refuses another origin, bad input and wrong passwords; throttles after 5', async () => {
    const s = fakeSupabase();
    const bff = new LoginBff(env, s.fetcher, new Throttle(5));
    expect((await bff.handle(req('login', { username: 'deniz', password: 'x' }, { origin: 'https://evil.example' }), 'login')).status).toBe(403);
    expect((await bff.handle(req('login', { username: 'deniz', password: 'x', deviceId: 'not-a-uuid' }), 'login')).status).toBe(400);
    for (let i = 0; i < 5; i++) {
      const r = await bff.handle(req('login', { username: 'deniz', password: 'wrong' }), 'login');
      expect(((await r.json()) as any).error).toBe('invalid_credentials');
    }
    const blocked = await bff.handle(req('login', { username: 'deniz', password: 'synthetic-pass-1' }), 'login');
    expect(blocked.status).toBe(429);
  });

  it('unlock: the access token is released only after the PIN is verified', async () => {
    const s = fakeSupabase();
    const bff = new LoginBff(env, s.fetcher);
    const login = await bff.handle(req('login', { username: 'deniz', password: 'synthetic-pass-1' }), 'login');
    const access = ((await login.json()) as any).accessToken;
    expect((await bff.handle(req('pin', { pin: '58291' }, { bearer: access }), 'pin')).status).toBe(200);
    let cookie = cookieOf(login);
    const wrong = await bff.handle(req('unlock', { pin: '00001' }, { cookie }), 'unlock');
    expect(wrong.status).toBe(403);
    const wb = (await wrong.json()) as any;
    expect(wb.error).toBe('invalid_pin');
    expect(wb.accessToken).toBeUndefined();
    cookie = cookieOf(wrong); // rotated even when the PIN was wrong
    const right = await bff.handle(req('unlock', { pin: '58291' }, { cookie }), 'unlock');
    expect(right.status).toBe(200);
    expect(((await right.json()) as any).accessToken).toMatch(/^access-token-synthetic-/);
    // The old (already rotated) refresh token no longer works.
    const replay = await bff.handle(req('unlock', { pin: '58291' }, { cookie }), 'unlock');
    expect(replay.status).toBe(401);
  });

  it('five wrong PINs: password sign-in needed and the cookie is cleared', async () => {
    const s = fakeSupabase();
    const bff = new LoginBff(env, s.fetcher, new Throttle(50));
    const login = await bff.handle(req('login', { username: 'deniz', password: 'synthetic-pass-1' }), 'login');
    const access = ((await login.json()) as any).accessToken;
    await bff.handle(req('pin', { pin: '58291' }, { bearer: access }), 'pin');
    let cookie = cookieOf(login), last: Response | undefined;
    for (let i = 0; i < 5; i++) {
      last = await bff.handle(req('unlock', { pin: '00001' }, { cookie }), 'unlock');
      cookie = cookieOf(last);
    }
    expect(((await last!.json()) as any).error).toBe('password_required');
    expect(last!.headers.get('Set-Cookie')).toContain('Max-Age=0');
  });

  it('replacing a PIN needs the password (fresh sign-in), like Windows', async () => {
    const s = fakeSupabase();
    const bff = new LoginBff(env, s.fetcher);
    const login = await bff.handle(req('login', { username: 'deniz', password: 'synthetic-pass-1' }), 'login');
    const access = ((await login.json()) as any).accessToken;
    expect((await bff.handle(req('pin', { pin: '58291' }, { bearer: access }), 'pin')).status).toBe(200);
    // Later, with an access token from a refresh (no fresh password stamp):
    const unlock = await bff.handle(req('unlock', { pin: '58291' }, { cookie: cookieOf(login) }), 'unlock');
    const later = ((await unlock.json()) as any).accessToken;
    const bare = await bff.handle(req('pin', { pin: '47302' }, { bearer: later }), 'pin');
    expect(((await bare.json()) as any).error).toBe('password_required');
    const wrong = await bff.handle(req('pin', { pin: '47302', password: 'nope' }, { bearer: later }), 'pin');
    expect(wrong.status).toBe(403);
    expect(((await wrong.json()) as any).error).toBe('invalid_credentials');
    const ok = await bff.handle(req('pin', { pin: '47302', password: 'synthetic-pass-1' }, { bearer: later }), 'pin');
    expect(ok.status).toBe(200);
    expect(ok.headers.get('Set-Cookie')).toContain(COOKIE);
  });

  it('owner TOTP raises the session; a wrong code is refused', async () => {
    const s = fakeSupabase();
    const bff = new LoginBff(env, s.fetcher);
    const login = await bff.handle(req('login', { username: 'deniz', password: 'synthetic-pass-1' }), 'login');
    const access = ((await login.json()) as any).accessToken;
    expect(((await (await bff.handle(req('mfa', { code: '000000' }, { bearer: access }), 'mfa')).json()) as any).error).toBe('invalid_code');
    const ok = await bff.handle(req('mfa', { code: '123456' }, { bearer: access }), 'mfa');
    expect(ok.status).toBe(200);
  });

  it('logout revokes and clears the cookie; unconfigured deployments say so', async () => {
    const s = fakeSupabase();
    const out = await new LoginBff(env, s.fetcher).handle(req('logout', {}, { bearer: 'access-token-synthetic-9' }), 'logout');
    expect(out.headers.get('Set-Cookie')).toContain('Max-Age=0');
    expect(s.calls).toContain('/rest/v1/rpc/nohut_logout');
    const none = await new LoginBff({}, s.fetcher).handle(req('login', { username: 'deniz', password: 'x' }), 'login');
    expect(none.status).toBe(503);
    expect(readCookie(new Request(ORIGIN, { headers: { Cookie: `a=b; ${COOKIE}=abc` } }))).toBe('abc');
  });
});
