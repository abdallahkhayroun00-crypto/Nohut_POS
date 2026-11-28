// Drives the real local Yönetici page served by PosLanServer. Brand fonts
// and logo come from the Flutter asset bundle, absent in a unit test run.
const { chromium } = require('playwright');
const [,, base, out] = process.argv;
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  const errors = [];
  p.setDefaultTimeout(10000);
  p.on('response', r => { if (r.status() >= 500 && !new URL(r.url()).pathname.startsWith('/assets/')) errors.push(r.status() + ' ' + new URL(r.url()).pathname); });
  p.on('pageerror', e => errors.push(String(e)));
  await p.goto(base + '/yonetici');
  await p.fill('#auth-username', 'sahip');
  await p.fill('#auth-password', 'owner-pass-1');
  await p.click('#auth-submit');
  await p.waitForSelector('#auth-skip:visible');
  await p.click('#auth-skip');
  await p.waitForSelector('#pl-quick:not([hidden]) .pl-row');
  await p.screenshot({ path: out + '/web-ozet.png' });
  const quick = await p.$$eval('#pl-quick .pl-row', rows => rows.map(r => r.innerText.replace(/\s+/g, ' ')));
  await p.click('#nav-daha');
  await p.screenshot({ path: out + '/web-daha.png' });
  await p.click('#more-platform');
  await p.waitForSelector('#pl-cards .pl-card');
  await p.screenshot({ path: out + '/web-platform.png', fullPage: true });
  await p.click('#pl-cards [data-pl-toggle="trendyol_go"]');
  await p.waitForSelector('#pl-confirm[open]');
  await p.screenshot({ path: out + '/web-confirm.png' });
  await p.click('#pl-confirm button[value=cancel]');
  await p.click('#pl-cards [data-pl-toggle="trendyol_go"]');
  await p.click('#pl-confirm-ok');
  await p.waitForSelector('#pl-msg:not([hidden])');
  const msg = await p.textContent('#pl-msg');
  const disabled = await p.$eval('#pl-cards [data-pl-toggle="yemeksepeti"]', e => e.disabled);
  console.log(JSON.stringify({ quick, msg, disabled, errors }));
  await b.close();
})().catch(e => { console.error(e); process.exit(1); });
