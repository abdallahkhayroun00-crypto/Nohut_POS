import { describe, expect, it, vi } from 'vitest';
import { authenticatedCommands, commandPayload } from '../src/shared/cloud-commands';
import { isPublishableKey } from '../src/shared/cloud';

const config = { url: 'https://synthetic.supabase.co', publishableKey: 'sb_publishable_synthetic_test_key' };
const id = '10000000-0000-4000-8000-000000000001';
const session = async () => ({ accessToken: 'synthetic-jwt', deviceId: id, permissionVersion: 1, client: 'personel' as const });
const order = { requestId: id, expectedRevision: 1, staffId: 99, source: 'Masa', table: 1,
  lines: [{ productId: 0, qty: 1, expectedPriceCents: 100 }] };

describe('authenticated cloud commands', () => {
  it('keeps the request identity and leaves actor selection to the backend', () => {
    const parsed = commandPayload('order', order);
    expect(parsed.action).toBe('create_order');
    expect(parsed.requestId).toBe(id);
    expect(parsed.payload.staffId).toBeUndefined();
    expect(parsed.payload.requestId).toBeUndefined();
  });
  it('never sends local customer contact data or guessed external identities', () => {
    expect(() => commandPayload('order', { ...order, source: 'Gel-Al', customer: { phone: 'synthetic' } })).toThrow();
    expect(() => commandPayload('platform', { requestId: id, platform: 'Trendyol Go', orderNumber: 'display-only', operation: 'accept' })).toThrow();
    expect(commandPayload('shift', { requestId: id, action: 'clockIn', employeeId: 99 }).payload).toEqual({ action: 'clockIn' });
  });
  it('requires explicit printer checks and preserves the QR publishing boundary', () => {
    expect(() => commandPayload('print', { requestId: id, action: 'reprint', orderId: 1 })).toThrow();
    expect(() => commandPayload('menu', { requestId: id, type: 'qr_publish' })).toThrow();
  });
  it('denies privileged keys including legacy service-role JWTs', () => {
    expect(isPublishableKey(`header.${btoa('{"role":"service_role"}')}.signature`)).toBe(false);
    expect(isPublishableKey(`header.${btoa('{"role":"anon"}')}.signature`)).toBe(true);
    expect(() => authenticatedCommands({ ...config, publishableKey: 'sb_secret_synthetic' }, session, () => true)).toThrow();
  });
  it('does not enqueue while Windows is unavailable', async () => {
    const fetcher = vi.fn();
    const channel = authenticatedCommands(config, session, () => false, fetcher);
    expect((await channel.send('order', order)).state).toBe('unavailable');
    expect(fetcher).not.toHaveBeenCalled();
  });
  it('enqueue success remains pending until authoritative confirmation', async () => {
    const fetcher = vi.fn<typeof fetch>()
      .mockResolvedValueOnce(new Response(JSON.stringify({ status: 'accepted', request_id: id })))
      .mockResolvedValueOnce(new Response(JSON.stringify({ state: 'confirmed', result: { ok: true } })));
    const channel = authenticatedCommands(config, session, () => true, fetcher);
    expect((await channel.send('order', order)).state).toBe('pending');
    const args = JSON.parse(fetcher.mock.calls[0]![1]!.body as string);
    expect(args.p_request_id).toBe(id);
    expect(args.p_payload.staffId).toBeUndefined();
    expect((await channel.status!(id)).state).toBe('confirmed');
  });
  it('lost enqueue acknowledgement retains the same request ID without replay', async () => {
    const fetcher = vi.fn<typeof fetch>().mockRejectedValue(new TypeError('synthetic connection lost'));
    const result = await authenticatedCommands(config, session, () => true, fetcher).send('order', order);
    expect(result).toMatchObject({ state: 'pending', requestId: id });
    expect(fetcher).toHaveBeenCalledTimes(1);
  });
  it('revocation rejects and uncertain external results never report confirmation', async () => {
    const fetcher = vi.fn<typeof fetch>()
      .mockResolvedValueOnce(new Response('{}', { status: 403 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ state: 'reconciliation_required' })));
    const channel = authenticatedCommands(config, session, () => true, fetcher);
    expect((await channel.send('order', order)).state).toBe('rejected');
    expect((await channel.status!(id)).state).toBe('rejected');
  });
});
