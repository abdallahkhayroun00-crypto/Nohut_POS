import type { CloudConfig } from './cloud';
import { isPublishableKey } from './cloud';
import type { CommandChannel, CommandKind, CommandResult } from './commands';

/** Supplied by Phase 3. This module never owns login, refresh, PIN or storage. */
export interface CommandSession {
  accessToken: string;
  deviceId: string;
  permissionVersion: number;
  client: 'personel' | 'yonetici';
}

class RequestRefused extends Error {}

export function commandPayload(kind: CommandKind, input: object): { action: string; requestId: string; payload: Record<string, unknown> } {
  const p = { ...input } as Record<string, unknown>;
  const requestId = p.requestId;
  if (typeof requestId !== 'string' || !/^[0-9a-f-]{36}$/i.test(requestId)) throw new Error('İstek kimliği geçersiz');
  delete p.requestId;
  delete p.staffId; // Windows always uses command_actor(), never a UI selector.
  let action: string | undefined;
  if (kind === 'order') {
    action = p.orderId == null ? 'create_order' : 'add_order_items';
    if (p.customer && typeof p.customer === 'object') {
      const c = p.customer as Record<string, unknown>;
      if (c.name || c.phone) throw new Error('Müşteri iletişim bilgileri yalnız kasada tutulur');
      p.customer = { ...(c.time ? { time: c.time } : {}) };
    }
  } else if (kind === 'action') {
    const routes: Record<string, string> = {
      pay: 'record_payment', payMixed: 'record_payment', payProducts: 'record_payment',
      splitEqual: 'split_bill', addGuest: 'split_bill', allocate: 'split_bill', resetGuests: 'split_bill',
      move: 'move_order', close: 'close_order', status: 'mark_delivered',
      editLine: 'edit_order_line', delete: 'delete_order', printProductPayment: 'print_payment_receipt',
    };
    action = routes[String(p.action)];
  } else if (kind === 'shift') {
    action = 'clock_in_out';
    delete p.employeeId;
  } else if (kind === 'platform') {
    if (p.platform !== 'Trendyol Go' || typeof p.packageId !== 'string') throw new Error('Doğrulanmış platform sipariş kimliği gerekli');
    action = 'platform_action';
    p.action = p.operation;
    delete p.operation; delete p.platform; delete p.orderNumber;
  } else if (kind === 'menu' && p.type === 'stock_update') {
    action = 'set_product_sale';
    p.active = p.soldOut === false;
    delete p.type; delete p.soldOut; delete p.expectedRevision;
  } else if (kind === 'print' && p.checked === true && typeof p.target === 'string') {
    action = 'retry_print';
    delete p.action; delete p.expectedRevision;
  }
  if (!action) throw new Error('Bu uzaktan işlem henüz desteklenmiyor');
  return { action, requestId, payload: p };
}

export function authenticatedCommands(
  config: CloudConfig,
  session: () => Promise<CommandSession | null>,
  authorityAvailable: () => boolean,
  fetcher: typeof fetch = fetch,
): CommandChannel {
  if (!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(config.url) || !isPublishableKey(config.publishableKey)) {
    throw new Error('Bulut yapılandırması geçersiz');
  }
  const rpc = async (name: string, args: object): Promise<Record<string, unknown>> => {
    const current = await session();
    if (!current) throw new RequestRefused('Oturum açın');
    const response = await fetcher(`${config.url}/rest/v1/rpc/${name}`, {
      method: 'POST', cache: 'no-store', redirect: 'error', credentials: 'omit',
      headers: { apikey: config.publishableKey, Authorization: `Bearer ${current.accessToken}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_device_id: current.deviceId, p_client: current.client,
        p_permission_version: current.permissionVersion, ...args }),
      signal: AbortSignal.timeout(15000),
    });
    if (!response.ok) {
      if (response.status === 401 || response.status === 403 || response.status === 400) {
        throw new RequestRefused('Oturum, işlem yetkisi veya istek geçerli değil');
      }
      throw new Error('Bulut isteği doğrulanamadı');
    }
    return await response.json() as Record<string, unknown>;
  };
  return {
    async send(kind, input) {
      if (!authorityAvailable()) return { state: 'unavailable', message: 'Kasa Çevrimdışı' };
      let command: ReturnType<typeof commandPayload>;
      try { command = commandPayload(kind, input); }
      catch (error) { return { state: 'rejected', message: (error as Error).message }; }
      try {
        const result = await rpc('nohut_enqueue_command', { p_request_id: command.requestId,
          p_action: command.action, p_payload: command.payload });
        if (result.status === 'conflict') return { state: 'rejected', requestId: command.requestId, message: 'İstek kimliği başka içerikle kullanılmış' };
        if (result.status !== 'accepted' && result.status !== 'duplicate') throw new Error('Geçersiz komut yanıtı');
        return { state: 'pending', requestId: command.requestId, message: 'Kasadan işlem onayı bekleniyor' };
      } catch (error) {
        // Enqueue may have committed before the connection failed. Keep the
        // same request ID and query status; never invent success or a new ID.
        return { state: error instanceof RequestRefused ? 'rejected' : 'pending',
          requestId: command.requestId, message: (error as Error).message };
      }
    },
    async status(requestId): Promise<CommandResult> {
      const result = await rpc('nohut_command_status', { p_request_id: requestId });
      if (result.state === 'confirmed') return { state: 'confirmed', requestId, message: 'Kasada tamamlandı' };
      if (result.state === 'pending' || result.state === 'processing') return { state: 'pending', requestId, message: 'Kasadan işlem onayı bekleniyor' };
      return { state: 'rejected', requestId, message: result.state === 'reconciliation_required'
        ? 'Sonuç belirsiz; kasadan kontrol edin. Otomatik tekrar yapılmadı.' : 'İşlem tamamlanmadı; kasadan kontrol edin' };
    },
  };
}
