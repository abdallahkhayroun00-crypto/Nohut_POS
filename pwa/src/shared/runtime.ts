// App runtime: hash routing, data loading, sign-in gate, rendering.
import type { CloudState } from './cloud';
import { cloudLabels } from './cloud';
import type { Snapshot } from './model';
import type { Client } from './permissions';
import { applyTheme, readTheme } from './profile';
import { type DataSource, createSource } from './source';
import { type Ctx, type NavItem, type Screen, closeSheet, h, ic, makeCan, shell } from './ui';

export interface AppDef {
  name: string;
  client: Client;
  home: string;
  nav(ctx: Ctx): NavItem[];
  /** Which primary tab a sub-route belongs to. */
  navOf(route: string): string;
  screen(route: string, params: URLSearchParams, ctx: Ctx): Screen | null;
}

export function parseRoute(hash: string, home: string): { route: string; params: URLSearchParams } {
  const raw = hash.replace(/^#\/?/, '');
  const [route, query] = raw.split('?');
  return { route: route || home, params: new URLSearchParams(query ?? '') };
}

function signIn(app: AppDef, cloud: CloudState): HTMLElement {
  return h(
    'div',
    { class: 'gate' },
    h(
      'div',
      { class: 'gate-card' },
      h('img', { class: 'gate-logo', src: '/icons/icon-192.png', alt: 'Nohut Falafel' }),
      h('h1', {}, app.name),
      h(
        'form',
        { class: 'form', onsubmit: (e: Event) => e.preventDefault() },
        h('input', { autocomplete: 'username', placeholder: 'Kullanıcı adı', disabled: true, 'aria-label': 'Kullanıcı adı' }),
        h('input', { type: 'password', autocomplete: 'current-password', placeholder: 'Şifre', disabled: true, 'aria-label': 'Şifre' }),
        h('button', { class: 'btn primary wide', type: 'submit', disabled: true }, 'Giriş Yap'),
      ),
      h(
        'p',
        { class: 'muted small' },
        'Hesapla giriş, restoranın bulut bağlantısı ve hesap sistemi kasadan etkinleştirildiğinde açılır.',
      ),
      h('p', { class: `chip ${cloud === 'reachable' ? 'ok' : 'off'} inline` }, h('span', { class: 'dot' }), `Bulut: ${cloudLabels[cloud]}`),
    ),
  );
}

export async function run(app: AppDef) {
  const root = document.getElementById('app')!;
  document.documentElement.dataset.app = app.client;
  applyTheme(readTheme());
  root.replaceChildren(h('div', { class: 'loading' }, ic('sync', 28)));

  const source: DataSource = await createSource(app.client === 'yonetici' ? 'yonetici' : 'personel');
  let snapshot: Snapshot | null = null;
  let fixtures = false;

  const render = () => {
    if (!snapshot) return;
    const { route, params } = parseRoute(location.hash, app.home);
    const ctx: Ctx = {
      snap: snapshot,
      client: app.client,
      now: new Date(),
      fixtures,
      can: makeCan(snapshot, app.client),
      go: (r) => {
        closeSheet();
        if (`#/${r}` === location.hash) render();
        else location.hash = `#/${r}`;
      },
      rerender: render,
      send: (kind, payload) => source.commands.send(kind, payload),
    };
    const screen = app.screen(route, params, ctx) ?? app.screen(app.home, new URLSearchParams(), ctx)!;
    const y = window.scrollY;
    root.replaceChildren(...shell(ctx, app.name, app.nav(ctx), app.navOf(route), screen));
    window.scrollTo({ top: y });
  };

  const load = async () => {
    const state = await source.load();
    if (state.kind === 'signedOut') {
      snapshot = null;
      root.replaceChildren(signIn(app, state.cloud));
      return;
    }
    snapshot = state.snapshot;
    fixtures = state.fixtures;
    render();
  };

  window.addEventListener('hashchange', () => {
    window.scrollTo({ top: 0 });
    render();
  });
  window.addEventListener('online', load);
  window.addEventListener('offline', render);
  document.addEventListener('visibilitychange', () => document.visibilityState === 'visible' && load());
  await load();
  if ('serviceWorker' in navigator && import.meta.env.PROD) navigator.serviceWorker.register('/sw.js').catch(() => undefined);
}
