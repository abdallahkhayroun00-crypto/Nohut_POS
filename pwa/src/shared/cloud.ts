// Honest cloud status (spec V5.1 §6.3): configured / reachable / gated.
// Only the PUBLISHABLE key may ever reach the browser (it is public by
// design); privileged keys never do. Business data needs Phase 3 login and
// the owner's verified first sync, so until then the app says so.
export type CloudState = 'unconfigured' | 'reachable' | 'unreachable';

export interface CloudConfig {
  url: string;
  publishableKey: string;
}

export function readConfig(env: Record<string, string | undefined>): CloudConfig | null {
  const url = (env.VITE_SUPABASE_URL ?? '').trim();
  const publishableKey = (env.VITE_SUPABASE_PUBLISHABLE_KEY ?? '').trim();
  if (!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(url) || publishableKey.length < 20) return null;
  return { url, publishableKey };
}

export async function probe(
  config: CloudConfig | null,
  fetcher: typeof fetch = fetch,
): Promise<CloudState> {
  if (!config) return 'unconfigured';
  try {
    const res = await fetcher(`${config.url}/auth/v1/health`, {
      headers: { apikey: config.publishableKey },
      cache: 'no-store',
    });
    return res.ok ? 'reachable' : 'unreachable';
  } catch {
    return 'unreachable';
  }
}

export const cloudLabels: Record<CloudState, string> = {
  unconfigured: 'Yapılandırılmadı',
  reachable: 'Bağlı (giriş ve ilk senkronizasyon bekleniyor)',
  unreachable: 'Çevrimdışı',
};
