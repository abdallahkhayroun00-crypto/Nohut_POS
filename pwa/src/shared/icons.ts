// Inline SVG icons (24×24, Material-style outlines) — no icon font, no
// external requests, CSP-friendly.
const paths: Record<string, string> = {
  table: 'M4 7h16v3H4zM6 10v8M18 10v8M9 13h6',
  order: 'M7 4h10l1 4H6zM6 8h12l-1 12H7zM10 12h4',
  pickup: 'M6 8h12l-1 11H7zM9 8a3 3 0 0 1 6 0',
  online: 'M3 12a9 9 0 1 0 18 0 9 9 0 0 0-18 0M3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18',
  payment: 'M3 7h18v10H3zM3 10h18M7 14h3',
  clock: 'M12 7v5l3 2M3 12a9 9 0 1 0 18 0 9 9 0 0 0-18 0',
  chart: 'M4 20V10M10 20V4M16 20v-7M22 20H2',
  finance: 'M12 3v18M16 7c0-2-2-3-4-3s-4 1-4 3 2 3 4 3 4 1 4 3-2 3-4 3-4-1-4-3',
  report: 'M7 3h7l4 4v14H7zM14 3v4h4M10 12h5M10 16h5',
  people: 'M9 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6M3 20c0-3 3-5 6-5s6 2 6 5M17 11a2.5 2.5 0 1 0 0-5M18 15c2 .5 3 2 3 5',
  shield: 'M12 3l7 3v6c0 4-3 7-7 9-4-2-7-5-7-9V6z',
  menu: 'M5 4h14v16H5zM8 8h8M8 12h8M8 16h5',
  price: 'M3 12l9-9h8v8l-9 9zM15 8h.01',
  category: 'M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z',
  campaign: 'M4 13v-2l12-5v12l-12-5M16 9h3v4h-3M7 14l1 5h3l-1-4',
  stock: 'M4 7l8-4 8 4v10l-8 4-8-4zM4 7l8 4 8-4M12 11v10',
  qr: 'M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h2v2h-2zM18 18h2v2h-2zM14 18h2M18 14h2',
  cloud: 'M7 18h10a4 4 0 0 0 .5-7.97A6 6 0 0 0 6 9a4.5 4.5 0 0 0 1 9',
  sync: 'M20 12a8 8 0 0 0-14-5.3L4 9M4 4v5h5M4 12a8 8 0 0 0 14 5.3L20 15M20 20v-5h-5',
  auto: 'M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M5.6 18.4l2.1-2.1M16.3 7.7l2.1-2.1M9 12a3 3 0 1 0 6 0 3 3 0 0 0-6 0',
  check: 'M5 12l5 5 9-10',
  queue: 'M4 6h16M4 12h16M4 18h10',
  history: 'M3 12a9 9 0 1 0 3-6.7L3 8M3 3v5h5M12 7v5l3 2',
  storage: 'M4 6c0-1.7 3.6-3 8-3s8 1.3 8 3-3.6 3-8 3-8-1.3-8-3M4 6v12c0 1.7 3.6 3 8 3s8-1.3 8-3V6M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3',
  alert: 'M12 3l10 18H2zM12 10v5M12 18h.01',
  backup: 'M12 16V4M8 8l4-4 4 4M4 16v4h16v-4',
  verify: 'M12 3l7 3v6c0 4-3 7-7 9-4-2-7-5-7-9V6zM9 12l2 2 4-4',
  restore: 'M3 12a9 9 0 1 0 3-6.7L3 8M3 3v5h5',
  lock: 'M7 11V8a5 5 0 0 1 10 0v3M5 11h14v10H5zM12 15v2',
  home: 'M3 11l9-8 9 8v10h-6v-6H9v6H3z',
  dashboard: 'M4 4h7v9H4zM13 4h7v5h-7zM13 11h7v9h-7zM4 15h7v5H4z',
  back: 'M15 5l-7 7 7 7',
  close: 'M6 6l12 12M18 6L6 18',
  plus: 'M12 5v14M5 12h14',
  minus: 'M5 12h14',
  search: 'M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14M20 20l-4-4',
  more: 'M5 12h.01M12 12h.01M19 12h.01',
  user: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8M4 21c0-4 4-6 8-6s8 2 8 6',
  bell: 'M6 16V11a6 6 0 0 1 12 0v5l2 2H4zM10 21h4',
  receipt: 'M6 3h12v18l-3-2-3 2-3-2-3 2zM9 8h6M9 12h6M9 16h3',
  move: 'M4 12h16M14 6l6 6-6 6',
  edit: 'M4 20h4L19 9l-4-4L4 16zM13 7l4 4',
  wallet: 'M4 7h15v12H4zM4 7l11-3v3M15 13h2',
  star: 'M12 3l2.7 5.6 6.3.9-4.5 4.4 1 6.1L12 17l-5.5 3 1-6.1L3 9.5l6.3-.9z',
  link: 'M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1',
  play: 'M7 4l12 8-12 8z',
  stop: 'M6 6h12v12H6z',
  phone: 'M5 4h4l2 5-3 2a11 11 0 0 0 5 5l2-3 5 2v4a2 2 0 0 1-2 2A16 16 0 0 1 3 6a2 2 0 0 1 2-2',
};

export function icon(name: string, size = 24): SVGSVGElement {
  const ns = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(ns, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('width', String(size));
  svg.setAttribute('height', String(size));
  svg.setAttribute('aria-hidden', 'true');
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '1.8');
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');
  const p = document.createElementNS(ns, 'path');
  p.setAttribute('d', paths[name] ?? paths.check!);
  svg.append(p);
  return svg;
}

export const iconNames = Object.keys(paths);
