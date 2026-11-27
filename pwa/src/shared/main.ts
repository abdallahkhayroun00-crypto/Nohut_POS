import './style.css';
import { type AppId, type Section, apps, sectionsFor, setupSteps } from './apps';
import { type CloudState, cloudLabels, probe, readConfig } from './cloud';
import { freshness } from './freshness';
import { icon } from './icons';
import { operationsFor } from './permissions';

declare const __APP__: AppId;

const app = __APP__;
const sections = sectionsFor(app);
let current: Section['id'] = sections[0]!.id;
let cloud: CloudState = 'unconfigured';
const root = document.getElementById('app')!;
document.documentElement.dataset.app = app;

function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  opts: { text?: string; cls?: string; children?: (Node | null)[] } = {},
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  if (opts.text !== undefined) node.textContent = opts.text;
  if (opts.cls) node.className = opts.cls;
  for (const c of opts.children ?? []) if (c) node.append(c);
  return node;
}

function appBar(): HTMLElement {
  const logo = el('img', { cls: 'logo' });
  logo.src = '/icons/icon-192.png';
  logo.alt = 'Nohut Falafel';
  const reachable = cloud === 'reachable';
  const chip = el('span', {
    cls: `chip ${reachable ? 'ok' : 'off'}`,
    children: [el('span', { cls: 'dot' }), document.createTextNode(reachable ? 'Bulut bağlı' : cloud === 'unconfigured' ? 'Bulut yok' : 'Çevrimdışı')],
  });
  chip.setAttribute('role', 'status');
  return el('header', {
    cls: 'appbar',
    children: [
      logo,
      el('div', {
        cls: 'titles',
        children: [el('h1', { text: apps[app].name }), el('span', { cls: 'role', text: apps[app].role })],
      }),
      chip,
    ],
  });
}

function setupCard(): HTMLElement {
  const list = el('ol', { cls: 'steps' });
  setupSteps(cloud === 'reachable').forEach((s, i) => {
    const label = s.state === 'done' ? 'Tamam' : s.state === 'waiting' ? 'Bekliyor' : 'Sırada';
    list.append(el('li', {
      cls: `step ${s.state}`,
      children: [
        el('span', { cls: 'badge', text: s.state === 'done' ? '✓' : String(i + 1) }),
        el('div', {
          children: [
            el('strong', { children: [document.createTextNode(s.title), el('span', { cls: `state ${s.state}`, text: label })] }),
            el('span', { text: s.detail }),
          ],
        }),
      ],
    }));
  });
  return el('section', {
    cls: 'card hero',
    children: [
      el('h3', { text: 'Kurulum durumu' }),
      el('p', { cls: 'lead', text: 'Restoran verileri bu adımlar tamamlanınca burada görünür. Örnek veya tahmini veri gösterilmez.' }),
      list,
    ],
  });
}

function tiles(section: Section): HTMLElement {
  const grid = el('div', { cls: 'tiles' });
  for (const item of section.items) {
    const isConnection = item.label === 'Bağlantı Durumu';
    const tile = el('div', {
      cls: `tile${isConnection && cloud === 'reachable' ? ' live' : ''}`,
      children: [
        el('span', { cls: 'ic', children: [icon(item.icon)] }),
        el('strong', { text: item.label }),
        isConnection
          ? el('span', { cls: `value${cloud === 'reachable' ? '' : ' off'}`, text: cloudLabels[cloud] })
          : el('small', { text: item.hint }),
      ],
    });
    if (!isConnection) {
      const lock = el('span', { cls: 'lock', children: [icon('lock', 16)] });
      lock.title = 'Giriş gerekli';
      tile.append(lock);
    }
    tile.setAttribute('aria-label', `${item.label}${isConnection ? `: ${cloudLabels[cloud]}` : ' — giriş gerekli'}`);
    grid.append(tile);
  }
  return grid;
}

const opNames: Record<string, string> = {
  'menu.view': 'Menüyü görüntüle', 'menu.product.edit': 'Ürün düzenle', 'menu.price.edit': 'Fiyat değiştir',
  'menu.category.edit': 'Kategori düzenle', 'menu.campaign.edit': 'Kampanya düzenle', 'menu.stock.toggle': 'Stok durumu',
  'menu.qr.publish': 'QR menüyü yayınla', 'sync.view': 'Durumu görüntüle', 'sync.manual': 'Şimdi senkronize et',
  'sync.retry': 'Hataları yeniden dene', 'sync.auto.configure': 'Otomatik ayarlar', 'sync.initial.start': 'İlk senkronizasyonu başlat',
  'sync.cloud.configure': 'Bulut yapılandırması', 'sync.full_resync': 'Tam yeniden senkronizasyon', 'backup.view': 'Yedekleri görüntüle',
  'backup.manual': 'Şimdi yedekle', 'backup.auto.configure': 'Otomatik yedek ayarı', 'backup.verify': 'Yedeği doğrula',
  'backup.restore': 'Verileri geri yükle', 'backup.delete': 'Yedek sil',
};

function operations(section: Section): HTMLElement | null {
  const ops = operationsFor(section.id);
  if (!ops.length) return null;
  const card = el('div', { cls: 'card ops' });
  for (const op of ops) {
    const pill = op.sensitivity === 'ownerOnly'
      ? el('span', { cls: 'pill owner', text: 'Yalnız sahip' })
      : op.sensitivity === 'elevated'
        ? el('span', { cls: 'pill elevated', text: 'Onaylı yetki' })
        : el('span', { cls: 'pill', text: 'Yetki gerekir' });
    card.append(el('div', {
      cls: 'op',
      children: [
        el('div', { cls: 'name', children: [el('strong', { text: opNames[op.id] ?? op.id }), el('small', { text: op.id })] }),
        pill,
      ],
    }));
  }
  return el('div', { children: [el('div', { cls: 'section-label', text: 'İşlemler ve yetkiler' }), card] });
}

function tabBar(): HTMLElement {
  const inner = el('div', { cls: 'inner' });
  for (const s of sections) {
    const b = el('button', { children: [icon(s.icon, 22), el('span', { text: s.tab })] });
    b.type = 'button';
    b.setAttribute('aria-label', s.title);
    if (s.id === current) b.setAttribute('aria-current', 'page');
    b.onclick = () => {
      current = s.id;
      render();
      window.scrollTo({ top: 0 });
    };
    inner.append(b);
  }
  const nav = el('nav', { cls: 'tabbar', children: [inner] });
  nav.setAttribute('aria-label', 'Bölümler');
  return nav;
}

function render() {
  const section = sections.find((s) => s.id === current)!;
  const main = el('main');
  if (!navigator.onLine) main.append(el('div', { cls: 'offline-banner', text: 'Çevrimdışı — bağlantı gelince yenilenir.' }));
  main.append(el('div', {
    cls: 'screen-head',
    children: [el('h2', { text: section.title }), el('p', { text: section.subtitle })],
  }));
  if (section.id === 'home') main.append(setupCard());
  main.append(el('div', { cls: 'section-label', text: section.id === 'home' ? 'Yakında bu ekranda' : 'Bölüm' }), tiles(section));
  const ops = operations(section);
  if (ops) main.append(ops);
  main.append(el('p', { cls: 'note', text: `${freshness(null, new Date(), false).label} · Sürüm 2.0.0` }));
  root.replaceChildren(appBar(), main, tabBar());
}

async function start() {
  render();
  cloud = await probe(readConfig(import.meta.env as Record<string, string | undefined>));
  render();
  window.addEventListener('online', render);
  window.addEventListener('offline', render);
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(() => undefined);
}

void start();
