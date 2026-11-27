// Staleness badge (spec V5.1 §7.2, §20.2): never label stale data current.
export interface Freshness {
  level: 'none' | 'fresh' | 'stale' | 'offline';
  label: string;
}

const two = (n: number) => String(n).padStart(2, '0');

export function freshness(asOf: string | null, now: Date, posOnline: boolean): Freshness {
  if (!asOf) return { level: 'none', label: 'Henüz senkronize veri yok' };
  const at = new Date(asOf);
  if (Number.isNaN(at.getTime())) return { level: 'none', label: 'Tarih okunamadı' };
  const local = new Date(at.getTime() + 3 * 3600 * 1000); // Europe/Istanbul (UTC+3)
  const hhmm = `${two(local.getUTCHours())}:${two(local.getUTCMinutes())}`;
  if (!posOnline) return { level: 'offline', label: `Kasa Çevrimdışı — Son veri: ${hhmm}` };
  const minutes = Math.floor((now.getTime() - at.getTime()) / 60000);
  if (minutes < 2) return { level: 'fresh', label: 'Güncel' };
  if (minutes < 60) return { level: 'stale', label: `${minutes} dk önce · ${hhmm}` };
  return { level: 'stale', label: `Son veri: ${hhmm}` };
}
