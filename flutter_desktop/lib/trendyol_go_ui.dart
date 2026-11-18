import 'package:flutter/material.dart';

import 'pos_logic.dart';
import 'order_reporting.dart';
import 'trendyol_go_readonly.dart';

class TgoSettingsPanel extends StatefulWidget {
  const TgoSettingsPanel({super.key, required this.integration});
  final TrendyolGoReadonly integration;
  @override
  State<TgoSettingsPanel> createState() => _TgoSettingsPanelState();
}

class _TgoSettingsPanelState extends State<TgoSettingsPanel> {
  late final TextEditingController supplier, apiKey, apiSecret, email;
  bool visible = false, saving = false, prefilled = false;
  void _hydrateCredentials() {
    if (prefilled || !mounted) return;
    final c = widget.integration.credentials;
    if (c == null) return;
    if (supplier.text.isEmpty) supplier.text = c.supplierId;
    if (email.text.isEmpty) email.text = c.email;
    prefilled = true;
  }

  @override
  void initState() {
    super.initState();
    final c = widget.integration.credentials;
    supplier = TextEditingController(text: c?.supplierId ?? '');
    apiKey = TextEditingController();
    apiSecret = TextEditingController();
    email = TextEditingController(text: c?.email ?? '');
    prefilled = c != null;
    widget.integration.addListener(_hydrateCredentials);
  }

  @override
  void dispose() {
    widget.integration.removeListener(_hydrateCredentials);
    supplier.dispose();
    apiKey.dispose();
    apiSecret.dispose();
    email.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() => saving = true);
    try {
      final old = widget.integration.credentials;
      await widget.integration.save(
        TgoCredentials(
          supplier.text.trim(),
          apiKey.text.trim().isEmpty ? (old?.apiKey ?? '') : apiKey.text.trim(),
          apiSecret.text.trim().isEmpty
              ? (old?.apiSecret ?? '')
              : apiSecret.text.trim(),
          email.text.trim(),
        ),
      );
      apiKey.clear();
      apiSecret.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('API bilgileri güvenle kaydedildi.')),
        );
      }
    } on FormatException catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('API bilgileri kaydedilemedi.')),
        );
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.integration,
    builder: (context, _) {
      final s = widget.integration;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Uber Eats Trendyol Go',
                style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 7),
              const Text(
                'Salt okunur bağlantı · Siparişler alınır; platformda kabul, iptal, fiyat veya durum değişikliği yapılmaz.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: supplier,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Satıcı ID (Cari ID)',
                  prefixIcon: Icon(Icons.storefront_outlined),
                ),
              ),
              const SizedBox(height: 11),
              TextField(
                controller: apiKey,
                obscureText: !visible,
                decoration: const InputDecoration(
                  labelText: 'API Key',
                  helperText:
                      'Kayıtlı anahtarı korumak için boş bırakabilirsiniz.',
                ),
              ),
              const SizedBox(height: 11),
              TextField(
                controller: apiSecret,
                obscureText: !visible,
                decoration: const InputDecoration(
                  labelText: 'API Secret',
                  helperText:
                      'Kayıtlı anahtarı korumak için boş bırakabilirsiniz.',
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => visible = !visible),
                  icon: Icon(
                    visible
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  label: Text(visible ? 'Gizle' : 'Göster'),
                ),
              ),
              TextField(
                controller: email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Entegrasyon e-posta',
                  helperText:
                      'Zorunlu x-executor-user başlığı için hesabın e-postası.',
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: saving ? null : save,
                    icon: const Icon(Icons.save),
                    label: const Text('Güvenli Kaydet'),
                  ),
                  OutlinedButton.icon(
                    onPressed: s.syncing || s.credentials?.valid != true
                        ? null
                        : () => s.sync(),
                    icon: const Icon(Icons.sync),
                    label: const Text('Bağlantıyı Test Et / Güncelle'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                'Bağlantı: ' + s.status,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              if (s.lastSync.isNotEmpty)
                Text('Son senkronizasyon: ' + s.lastSync),
              if (s.error.isNotEmpty)
                Text(s.error, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 8),
              const Text(
                'Gizli anahtarlar Windows DPAPI ile şifrelenir ve güncellemelerden bağımsız olarak AppData klasöründe kalır.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class TgoOrdersPanel extends StatelessWidget {
  const TgoOrdersPanel({
    super.key,
    required this.orders,
    this.integration,
    this.limit,
  });
  final List<Json> orders;
  final TrendyolGoReadonly? integration;
  final int? limit;
  @override
  Widget build(BuildContext context) {
    final sorted = [...orders]
      ..sort((a, b) {
        final day = '${b['numberDay'] ?? ''}'.compareTo(
          '${a['numberDay'] ?? ''}',
        );
        if (day != 0) return day;
        return (b['dailyNumber'] as int? ?? 0).compareTo(
          a['dailyNumber'] as int? ?? 0,
        );
      });
    final shown = limit == null ? sorted : sorted.take(limit!).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (integration != null)
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Trendyol Go · ' + integration!.status,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              TextButton.icon(
                onPressed: integration!.syncing
                    ? null
                    : () => integration!.sync(),
                icon: const Icon(Icons.refresh),
                label: const Text('Yenile'),
              ),
            ],
          ),
        if (sorted.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'Trendyol Go siparişi yok. Ayarlar bölümünden bağlantı kurun.',
              ),
            ),
          ),
        for (final o in shown)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '#${displayOrderNumber(o)} · Trendyol Go',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      Chip(label: Text('${o['status']}')),
                      if (o['testPackage'] == true)
                        const Chip(label: Text('TEST')),
                    ],
                  ),
                  Text(
                    'Trendyol sipariş no: ${o['orderNumber']} · ${o['createdAt']} · ${o['pickup'] == true ? 'Platform Gel-Al' : 'Paket Servis'}',
                  ),
                  for (final line in asMaps(o['lines']))
                    ListTile(
                      dense: true,
                      title: Text('${line['qty']} × ${line['name']}'),
                      subtitle: Text(
                        (line['options'] as List? ?? []).join(', '),
                      ),
                      trailing: Text(
                        formatTry(line['unitPriceCents'] as int? ?? 0),
                      ),
                    ),
                  if ('${o['customerNote'] ?? ''}'.trim().isNotEmpty)
                    Text('Müşteri notu: ${o['customerNote']}'),
                  const SizedBox(height: 4),
                  Text(
                    'Platform toplamı: ' +
                        formatTry(o['totalCents'] as int? ?? 0) +
                        ' · ' +
                        '${o['paymentType'] ?? ''}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const Text(
                    'Salt okunur · Yönetim Trendyol Go Partner Panelinde',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
