import { describe, expect, it } from 'vitest';
import { apps, sectionsFor, setupSteps, sharedSections } from '../src/shared/apps';
import { iconNames } from '../src/shared/icons';
import { canPerform, findOperation, operations, operationsFor } from '../src/shared/permissions';
import { freshness } from '../src/shared/freshness';
import { probe, readConfig } from '../src/shared/cloud';

describe('two apps, three shared sections (spec §20.1–20.2)', () => {
  it('both apps contain Menü, Bulut and Yedekleme sections', () => {
    for (const app of ['personel', 'yonetici'] as const) {
      const ids = sectionsFor(app).map((s) => s.id);
      expect(ids).toEqual(['home', 'menu', 'sync', 'backup']);
    }
    expect(apps.personel.home.title).toBe('Masalar');
    expect(apps.yonetici.home.title).toBe('Genel Bakış');
    expect(sharedSections.find((s) => s.id === 'sync')!.items.map((i) => i.label)).toContain('Şimdi Senkronize Et');
    for (const s of [...sectionsFor('personel'), ...sectionsFor('yonetici')]) {
      for (const item of s.items) expect(iconNames).toContain(item.icon);
      expect(iconNames).toContain(s.icon);
    }
  });
});

describe('per-operation permissions from the shared contract (§20.3)', () => {
  it('loads the same catalogue the POS and server use', () => {
    expect(operations.length).toBeGreaterThan(15);
    expect(findOperation('backup.restore')!.sensitivity).toBe('ownerOnly');
    expect(operationsFor('menu').map((o) => o.id)).toContain('menu.price.edit');
  });
  it('unknown operations deny', () => {
    expect(canPerform('menu.delete_everything', new Set(['menu.delete_everything']), { isOwner: true })).toBe(false);
  });
  it('owner-only operations ignore stored grants for non-owners', () => {
    for (const id of ['backup.restore', 'sync.initial.start', 'sync.cloud.configure', 'sync.full_resync', 'permissions.update']) {
      expect(canPerform(id, new Set([id]), { isOwner: false })).toBe(false);
      expect(canPerform(id, new Set(), { isOwner: true })).toBe(true);
    }
  });
  it('delegable operations follow the grant', () => {
    expect(canPerform('sync.manual', new Set(), { isOwner: false })).toBe(false);
    expect(canPerform('sync.manual', new Set(['sync.manual']), { isOwner: false })).toBe(true);
  });
});

describe('freshness badge never calls stale data current (§7.2)', () => {
  const now = new Date('2026-11-27T12:00:00Z');
  it('no data', () => expect(freshness(null, now, true).level).toBe('none'));
  it('fresh within 2 minutes', () => expect(freshness('2026-11-27T11:59:00Z', now, true).label).toBe('Güncel'));
  it('stale shows age and Istanbul time', () => expect(freshness('2026-11-27T11:30:00Z', now, true).label).toBe('30 dk önce · 14:30'));
  it('POS offline banner', () => expect(freshness('2026-11-27T09:05:00Z', now, false).label).toBe('Kasa Çevrimdışı — Son veri: 12:05'));
});

describe('cloud configuration (publishable key only)', () => {
  it('rejects anything that is not a Supabase https project URL', () => {
    expect(readConfig({})).toBeNull();
    expect(readConfig({ VITE_SUPABASE_URL: 'http://x.supabase.co', VITE_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_abcdefghijklmnop' })).toBeNull();
    expect(readConfig({ VITE_SUPABASE_URL: 'https://abc.supabase.co', VITE_SUPABASE_PUBLISHABLE_KEY: 'short' })).toBeNull();
  });
  it('probes the health endpoint and reports honestly', async () => {
    const cfg = readConfig({ VITE_SUPABASE_URL: 'https://abc.supabase.co', VITE_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_abcdefghijklmnop' });
    expect(await probe(null)).toBe('unconfigured');
    expect(await probe(cfg, (async () => new Response('{}', { status: 200 })) as typeof fetch)).toBe('reachable');
    expect(await probe(cfg, (async () => new Response('', { status: 503 })) as typeof fetch)).toBe('unreachable');
    expect(await probe(cfg, (async () => { throw new Error('offline'); }) as typeof fetch)).toBe('unreachable');
  });
});

describe('setup steps are honest', () => {
  it('only the cloud step can be done today; first sync waits; login later', () => {
    expect(setupSteps(true).map((s) => s.state)).toEqual(['done', 'waiting', 'later']);
    expect(setupSteps(false).map((s) => s.state)).toEqual(['waiting', 'waiting', 'later']);
  });
});
