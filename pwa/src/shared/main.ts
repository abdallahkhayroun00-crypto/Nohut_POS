import './style.css';
import { type AppId, apps, sectionsFor } from './apps';
import { cloudLabels, probe, readConfig } from './cloud';
import { freshness } from './freshness';
import { canPerform, operationsFor } from './permissions';

declare const __APP__: AppId;

const app = __APP__;
const sections = sectionsFor(app);
let current = sections[0]!.id;
const root = document.getElementById('app')!;

function el<K extends keyof HTMLElementTagNameMap>(tag: K, text?: string, cls?: string) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (cls) node.className = cls;
  return node;
}

function render(cloudLabel: string, reachable: boolean) {
  root.replaceChildren();
  const header = el('header');
  const logo = el('img');
  logo.src = '/icons/icon-192.png';
  logo.alt = '';
  const title = el('div');
  title.append(el('h1', apps[app].name), el('small', 'Nohut Falafel'));
  header.append(logo, title);

  const main = el('main');
  const fresh = freshness(null, new Date(), false);
  const banner = el('div', 'İlk kurulum bekleniyor: restoran verileri, sahibin '
    + '“İlk Senkronizasyonu Başlat” işlemi ve hesabınızla giriş tamamlanınca '
    + 'burada görünür. Bu ekranda örnek veya tahmini veri gösterilmez.', 'banner');
  if (!navigator.onLine) {
    banner.className = 'banner offline';
    banner.textContent = 'Çevrimdışı — bağlantı gelince yenilenir.';
  }
  const nav = el('nav');
  for (const s of sections) {
    const b = el('button', s.title);
    if (s.id === current) b.setAttribute('aria-current', 'page');
    b.onclick = () => { current = s.id; render(cloudLabel, reachable); };
    nav.append(b);
  }
  const section = sections.find((s) => s.id === current)!;
  const card = el('section', undefined, 'card');
  card.append(el('h2', section.title));
  for (const item of section.items) {
    const row = el('div', undefined, 'row');
    const status = el('span', 'Giriş gerekli', 'pill');
    if (item === 'Bağlantı Durumu') {
      status.textContent = cloudLabel;
      status.className = reachable ? 'pill ok' : 'pill off';
    }
    row.append(el('span', item), status);
    card.append(row);
  }
  // Operations of this section are visible but locked until login (§20.3).
  const ops = operationsFor(current);
  if (ops.length) {
    const opsCard = el('section', undefined, 'card');
    opsCard.append(el('h2', 'İşlemler'));
    for (const op of ops) {
      const allowed = canPerform(op.id, new Set(), { isOwner: false });
      const row = el('div', undefined, 'row');
      const label = op.sensitivity === 'ownerOnly' ? 'Yalnız sahip' : allowed ? 'Yetkili' : 'Yetki yok';
      row.append(el('span', op.id, 'muted'), el('span', label, 'pill'));
      opsCard.append(row);
    }
    main.append(banner, nav, card, opsCard);
  } else {
    main.append(banner, nav, card);
  }
  const foot = el('footer', `Veri durumu: ${fresh.label} · Sürüm 2.0.0`);
  root.append(header, main, foot);
}

async function start() {
  render('Kontrol ediliyor…', false);
  const state = await probe(readConfig(import.meta.env as Record<string, string | undefined>));
  render(cloudLabels[state], state === 'reachable');
  window.addEventListener('online', () => render(cloudLabels[state], state === 'reachable'));
  window.addEventListener('offline', () => render(cloudLabels[state], false));
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('/sw.js').catch(() => undefined);
  }
}

void start();
