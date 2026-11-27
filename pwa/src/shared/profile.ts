// Profil: account, password/PIN, trusted devices, theme, logout.
// Account operations run against the Phase 3 auth service; until it exists
// they are shown disabled with the reason, never simulated.
import { type Ctx, h, ic, section, segmented } from './ui';

export type Theme = 'auto' | 'light' | 'dark';

export function readTheme(): Theme {
  try {
    const t = localStorage.getItem('nohut-theme');
    return t === 'light' || t === 'dark' ? t : 'auto';
  } catch {
    return 'auto';
  }
}

export function applyTheme(t: Theme) {
  if (t === 'auto') delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = t;
  try {
    localStorage.setItem('nohut-theme', t);
  } catch {
    /* private mode: theme just isn't remembered */
  }
}

export function profileScreen(ctx: Ctx): HTMLElement {
  const s = ctx.snap.session;
  const authReady = false; // Phase 3
  const row = (icon: string, label: string, detail: string) =>
    h(
      'button',
      { type: 'button', class: 'list-row', disabled: !authReady, title: authReady ? undefined : 'Hesap sistemiyle açılır' },
      h('span', { class: 'row-ic' }, ic(icon, 20)),
      h('span', { class: 'grow' }, h('strong', {}, label), h('small', {}, detail)),
    );
  return h(
    'div',
    {},
    h(
      'div',
      { class: 'card profile' },
      h('span', { class: 'avatar' }, s.name.slice(0, 1).toLocaleUpperCase('tr-TR')),
      h('div', {}, h('strong', {}, s.name), h('small', {}, s.isOwner ? 'Sahip' : `${s.grants.length} yetki`)),
    ),
    section(
      'Hesap',
      h(
        'div',
        { class: 'list' },
        row('lock', 'Şifre Değiştir', 'Kullanıcı adı ve şifre'),
        row('shield', 'PIN Sıfırla', 'Bu cihaz için 6 haneli PIN'),
        row('phone', 'Güvenilir Cihazlar', 'Bağlı cihazları gör ve kaldır'),
      ),
      authReady ? null : h('p', { class: 'muted small' }, 'Hesap işlemleri giriş sistemi etkinleşince açılır.'),
    ),
    section(
      'Görünüm',
      segmented(
        [
          { id: 'auto', label: 'Otomatik' },
          { id: 'light', label: 'Açık' },
          { id: 'dark', label: 'Koyu' },
        ],
        readTheme(),
        (t) => {
          applyTheme(t);
          ctx.rerender();
        },
      ),
    ),
    h('button', { type: 'button', class: 'btn wide danger', disabled: !authReady }, ic('back', 18), 'Çıkış Yap'),
  );
}
