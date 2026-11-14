import 'package:flutter/material.dart';

import 'qr_menu_reader.dart';

/// Operator-controlled preview of the public website's JSON data.
/// Never writes prices, products, campaigns, or orders into SQLite.
class QrMenuPreviewPanel extends StatefulWidget {
  const QrMenuPreviewPanel({
    super.key,
    required this.localMenu,
    this.reader,
  });

  final List<Map<String, dynamic>> localMenu;
  final QrMenuReader? reader;

  @override
  State<QrMenuPreviewPanel> createState() => _QrMenuPreviewPanelState();
}

class _QrMenuPreviewPanelState extends State<QrMenuPreviewPanel> {
  bool loading = false;
  String? error;
  PublishedQrMenu? published;

  Future<void> checkWebsite() async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result =
          await (widget.reader ?? QrMenuReader()).readPublishedMenu();
      if (!mounted) return;
      setState(() => published = result);
    } catch (e) {
      if (!mounted) return;
      setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final remote = published;
    final local = <String, Map<String, dynamic>>{
      for (final p in widget.localMenu)
        if (p['name'] is String) p['name'] as String: p,
    };
    final remoteNames = remote?.products.map((p) => p.name).toSet() ??
        <String>{};
    final missingLocally = remote?.products
            .where((p) => !local.containsKey(p.name))
            .toList() ??
        <PublishedProductPrice>[];
    final missingRemotely = local.keys
        .where((name) => !remoteNames.contains(name))
        .toList();
    final differentPrices = remote?.products
            .where((p) =>
                local.containsKey(p.name) &&
                local[p.name]!['price'] is num &&
                ((local[p.name]!['price'] as num) * 100).round() !=
                    (p.priceTl * 100).round())
            .toList() ??
        <PublishedProductPrice>[];
    final visibleCampaigns = remote?.campaigns
            .where((c) => c.isVisibleAt(DateTime.now()))
            .toList() ??
        <PublishedCampaign>[];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Resmî QR Menü — Web Verilerini Oku',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            const Text(
              'Sadece okuma: web sitesinin ürün fiyatları ve kampanyaları '
              'kontrol edilir. Yerel menü, eski siparişler ve SQLite '
              'kesinlikle değiştirilmez.',
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: loading ? null : checkWebsite,
              icon: loading
                  ? const SizedBox(
                      width: 17,
                      height: 17,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_download_outlined),
              label: Text(loading
                  ? 'Web bilgileri okunuyor...'
                  : 'QR Menü Bilgilerini Kontrol Et'),
            ),
            if (error != null) ...[
              const SizedBox(height: 10),
              SelectableText(
                'Web verileri okunamadı: ' + error!,
                style: const TextStyle(color: Colors.redAccent),
              ),
            ],
            if (remote != null) ...[
              const SizedBox(height: 14),
              Text(
                'Son kontrol: ' +
                    remote.retrievedAtUtc.toLocal().toString() +
                    ' · ' +
                    remote.products.length.toString() +
                    ' ürün · ' +
                    visibleCampaigns.length.toString() +
                    ' güncel kampanya',
              ),
              const SizedBox(height: 6),
              Text(
                'Yerelde olmayan: ' +
                    missingLocally.length.toString() +
                    ' · Webde olmayan: ' +
                    missingRemotely.length.toString() +
                    ' · Fiyatı farklı: ' +
                    differentPrices.length.toString(),
              ),
              if (missingLocally.isNotEmpty) ...[
                const SizedBox(height: 6),
                SelectableText(
                  'Yerelde eksik: ' +
                      missingLocally.map((p) => p.name).join(', '),
                ),
              ],
              if (missingRemotely.isNotEmpty) ...[
                const SizedBox(height: 6),
                SelectableText(
                  'Webde bulunmayan yerel ürünler: ' +
                      missingRemotely.join(', '),
                ),
              ],
              if (differentPrices.isNotEmpty) ...[
                const SizedBox(height: 6),
                SelectableText(
                  'Fiyat farkları (Web TL): ' +
                      differentPrices
                          .map((p) => p.name + ' ' + p.priceTl.toStringAsFixed(2))
                          .join(', '),
                ),
              ],
              if (visibleCampaigns.isNotEmpty) ...[
                const SizedBox(height: 6),
                SelectableText(
                  'Yayındaki kampanyalar: ' +
                      visibleCampaigns
                          .map((c) => c.title['tr']! + ' ' +
                              c.priceTl.toStringAsFixed(2) + ' TL')
                          .join(' · '),
                ),
              ],
              const SizedBox(height: 6),
              const Text(
                'Bu önizleme senkronizasyon değildir. '
                'Fiyatları değiştirmek için daha sonra açık onaylı '
                'bir eşleştirme adımı gerekir.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
