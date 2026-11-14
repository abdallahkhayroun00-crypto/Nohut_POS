const { chromium } = require('playwright');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

(async () => {
  const original = {
    employees: [{ id: 1, name: 'Ömer', active: true }],
    localMenu: [
      { id: 0, name: 'Falafel Dürüm', category: 'wrap', price: 140 },
      { id: 1, name: 'Ayran', category: 'drink', price: 45 },
      { id: 32, name: 'Şambali', category: 'dessert', price: 100, active: false },
    ],
    orders: [{ id: 1200, dailyNumber: 1, numberDay: '2026-11-14', source: 'Masa', table: 3,
      serviceStatus: 'Hazırlanıyor', createdAt: '2026-11-14T10:00:00Z',
      batches: [{ lines: [{ name: 'Falafel Dürüm', qty: 2, note: 'Sos ayrı', removed: ['Domates'] }] }] }],
  };
  let state, revision, posts, mode;
  const html = fs.readFileSync(path.join(__dirname, '../assets/staff.html'));
  async function handleRoute(route) {
    const url = new URL(route.request().url());
    if (url.pathname === '/api/bootstrap') {
      return route.fulfill({ json: { state, revision } });
    }
    if (url.pathname === '/api/staff/orders') {
      posts.push(route.request().postDataJSON());
      if (mode === 'lost') return route.abort('failed');
      if (mode === 'conflict') return route.fulfill({ status: 409, json: { error: 'conflict' } });
      return route.fulfill({ json: { orderNumber: '0002', orderId: 1201, revision: ++revision } });
    }
    if (url.pathname === '/assets/nohut-logo.webp') {
      return route.fulfill({ contentType: 'image/webp', body: fs.readFileSync(path.join(__dirname, '../assets/brand/nohut-logo.webp')) });
    }
    return route.fulfill({ contentType: 'text/html; charset=utf-8', body: html });
  }
  const localChrome = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
  const executablePath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH ||
    (process.platform === 'win32' && fs.existsSync(localChrome) ? localChrome : undefined);
  const browser = await chromium.launch({ headless: true, executablePath });
  try {
    for (const width of [320, 390, 768]) {
      state = structuredClone(original); revision = 1; posts = []; mode = 'success';
      const context = await browser.newContext({ viewport: { width, height: 844 } });
      const page = await context.newPage(); const errors = [];
      await page.route('http://pos.test/**', handleRoute);
      page.on('pageerror', error => errors.push(error.message));
      await page.clock.install();
      await page.goto('http://pos.test/');
      await page.locator('#staff option[value="1"]').waitFor({ state: 'attached' });
      assert.equal(await page.locator('#staff').inputValue(), '', 'staff is deliberately selected each visit');
      assert.match(await page.locator('#orders').innerText(), /Sos ayrı/);
      assert.match(await page.locator('#orders').innerText(), /Domates/);
      assert.equal(await page.locator('#menu').getByText('Şambali', { exact: true }).count(), 0);
      assert.match(await page.locator('#table option[value="3"]').innerText(), /Dolu/);
      await page.locator('#staff').selectOption('1');
      await page.locator('[data-table="3"]').click();
      assert.match(await page.locator('#destination').innerText(), /Ek sipariş.*0001/);
      await page.locator('[data-add="0"]').click();
      await page.locator('[data-note]').fill('Sos ayrı');
      await page.locator('[data-note]').focus();
      await page.evaluate(() => { window.focusedNote = document.querySelector('[data-note]'); focusedNote.setSelectionRange(3, 3); });
      revision++;
      await page.clock.runFor(5100);
      await page.waitForFunction(() => document.getElementById('connection').textContent.includes('Laptop bağlı'));
      assert.equal(await page.evaluate(() => document.activeElement === window.focusedNote), true, 'polling preserves the focused input node');
      assert.equal(await page.locator('[data-note]').inputValue(), 'Sos ayrı');
      await page.locator('[data-custom="0"]').click();
      await page.locator('#custom-note').fill('Acılı');
      await page.locator('#custom-form button[type="submit"]').click();
      assert.equal(await page.locator('.cart-line').count(), 2);
      await page.locator('[data-category="drink"]').click();
      assert.equal(await page.locator('.cart-line').count(), 2, 'cart persists across categories');
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, 'no page overflow');
      if (width === 390 && process.env.NOHUT_UI_SCREENSHOT) {
        await page.screenshot({ path: process.env.NOHUT_UI_SCREENSHOT, fullPage: true });
      }
      await page.locator('#submit').click();
      await page.waitForFunction(() => document.getElementById('notice').textContent.includes('0002'));
      assert.deepEqual(posts[0].lines.map(l => l.note), ['Sos ayrı', 'Acılı']);
      assert.equal(posts[0].table, 3);
      const success = await page.locator('#notice').innerText();
      await page.clock.runFor(5100);
      assert.equal(await page.locator('#notice').innerText(), success, 'success survives polling');
      await page.locator('[data-category="wrap"]').click();
      await page.locator('[data-add="0"]').click(); mode = 'conflict';
      await page.locator('#submit').click();
      await page.waitForFunction(() => document.getElementById('notice').textContent.includes('Sepet korundu'));
      assert.equal(await page.locator('.cart-line').count(), 1);
      mode = 'lost'; await page.locator('#submit').click();
      await page.locator('#retry').waitFor({ state: 'visible' });
      const requestId = posts.at(-1).requestId;
      assert.equal(await page.locator('[data-add="0"]').isDisabled(), true, 'unconfirmed request freezes the cart');
      mode = 'success'; await page.locator('#retry').click();
      await page.waitForFunction(() => document.getElementById('notice').textContent.includes('kaydedildi'));
      assert.equal(posts.at(-1).requestId, requestId, 'lost response retry uses the same idempotency key');
      assert.deepEqual(errors, []);
      console.log(`PASS staff workflow at ${width}px`);
      await context.close();
    }
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
