import 'package:flutter/material.dart';

import 'qr_menu_sync.dart';

/// Visible, operator-controlled status for the background website sync.
/// Local orders and historical receipt line prices are never changed.
class QrMenuSyncPanel extends StatelessWidget {
  const QrMenuSyncPanel({
    super.key,
    required this.sync,
    required this.enabled,
    required this.onToggle,
  });

  final QrMenuAutoSync sync;
  final bool enabled;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: sync,
    builder: (context, _) {
      final result = sync.lastResult;
      final error = sync.lastError;
      final success = sync.lastSuccessAtUtc;
      final latest = sync.lastCheckedAtUtc;
      final status = !enabled
          ? 'Kapalı: yerel fiyatlar korunur'
          : sync.busy
              ? 'Web sitesi kontrol ediliyor...'
              : error != null
                  ? (error.startsWith('FormatException')
                      ? 'QR veri doğrulama hatası · yerel menü korunuyor'
                      : 'Bağlantı hatası · çevrimdışı menü korunuyor')
                  : success != null
                      ? 'Güncel · otomatik kontrol etkin'
                      : 'İlk kontrol bekleniyor';
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Resmî QR Menü · Otomatik Eşitleme',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              const Text(
                'Bu PC, resmî QR menü fiyatlarını ve kampanyaları '
                'açılışta ve her 10 dakikada bir kontrol eder. '
                'Yeni ürünler eklenir; var olan ürünlerin fiyatı '
                'web sitesine göre güncellenir. Sipariş geçmişi '
                've geçmiş ürün fiyatları değişmez.',
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('QR Menü otomatik eşitleme'),
                subtitle: const Text(
                  'Fiyatların tek kaynağı web sitesidir. '
                  'Kapatırsanız PC yerel fiyatları kullanır.',
                ),
                value: enabled,
                onChanged: onToggle,
              ),
              Row(
                children: [
                  Icon(
                    enabled && error == null
                        ? Icons.cloud_done_outlined
                        : Icons.cloud_off_outlined,
                    color: enabled && error == null
                        ? Colors.green.shade700
                        : Colors.orange.shade800,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(status)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Son başarılı kontrol: '
                '${success == null ? 'Henüz yok' : success.toLocal()}',
              ),
              if (latest != null)
                Text('Son deneme: ${latest.toLocal()}'),
              if (result != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Web: ${result.remoteCount} ürün · '
                  'Yeni eklenen: ${result.added} · '
                  'Fiyatı güncellenen: ${result.repriced} · '
                  'Webde listelenmeyen yerel ürün: ${result.unlisted}',
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: 8),
                SelectableText(
                  'Ayrıntı: $error',
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ],
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: sync.busy || !enabled
                    ? null
                    : () => sync.syncNow(),
                icon: sync.busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                label: const Text('Şimdi Eşitle'),
              ),
              const SizedBox(height: 6),
              const Text(
                'Güvenlik: Webden eksilen veya yeniden adlandırılan '
                'ürünler otomatik silinmez. İçecek/ürün fiyatlarını '
                'yalnızca yerelde değiştirmek istiyorsanız önce '
                'otomatik eşitlemeyi kapatın. Bu işlem Trendyol '
                've Yemeksepeti gerçek API bağlantısı kurmaz.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      );
    },
  );
}
