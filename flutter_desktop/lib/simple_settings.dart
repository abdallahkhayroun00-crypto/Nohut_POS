
import 'package:flutter/material.dart';

import 'brand.dart';
import 'pos_logic.dart';
import 'pos_store.dart';
import 'operations_ui.dart';
import 'online_orders.dart';
import 'qr_menu_sync.dart';
import 'qr_menu_preview.dart';
import 'trendyol_go_readonly.dart';
import 'trendyol_go_ui.dart';
import 'partner_credentials.dart';
import 'receipt_printer.dart';
import 'receipt_layout.dart';
import 'receipt_preview.dart';
import 'printer_management.dart';
import 'qr_publisher_settings.dart';

class SimpleSettings extends StatefulWidget {
  const SimpleSettings({
    super.key,
    required this.state,
    required this.edit,
    required this.store,
    required this.qrSync,
    required this.tgoIntegration,
    required this.onOpenGoogle,
    this.onTestOnlineSound,
    this.staffPanel,
    this.wifiPanel,
    this.backupPanel,
    this.accountsPanel,
  });
  final Json state;
  final EditState edit;
  final PosStore store;
  final QrMenuAutoSync qrSync;
  final TrendyolGoReadonly tgoIntegration;
  final VoidCallback onOpenGoogle;
  final ValueChanged<String>? onTestOnlineSound;
  final Widget? staffPanel, wifiPanel, backupPanel, accountsPanel;
  @override
  State<SimpleSettings> createState() => _SimpleSettingsState();
}

class _SimpleSettingsState extends State<SimpleSettings> {
  String tab = 'Genel', search = '';
  Widget _quickTile(String name, IconData icon, String description) =>
      Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(13),
        child: InkWell(
          onTap: () => setState(() => tab = name),
          borderRadius: BorderRadius.circular(13),
          child: Container(
            height: 104,
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xffDCE8DE)),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(icon, size: 21, color: NohutBrand.green),
                  const Spacer(),
                  const Icon(Icons.arrow_forward_rounded,
                    color: NohutBrand.muted, size: 17),
                ]),
                const Spacer(),
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: NohutBrand.green,
                    fontSize: 14, fontWeight: FontWeight.w800)),
                Text(description, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: NohutBrand.muted, fontSize: 11)),
              ]),
          ),
        ),
      );

  Widget _quickGrid(Map settings) => LayoutBuilder(
    builder: (context, constraints) {
      final cols = constraints.maxWidth >= 900 ? 4 :
        constraints.maxWidth >= 510 ? 2 : 1;
      final tileWidth = (constraints.maxWidth - 12 * (cols - 1)) / cols;
      final entries = <(String, IconData, String)>[
        ('Bildirimler', Icons.notifications_active_outlined, 'Masa ve online sesleri'),
        ('Entegrasyonlar', Icons.hub_outlined, 'Platform bağlantıları'),
        ('Yazıcı', Icons.print_outlined,
          (settings['printerName'] ?? 'XP-237B').toString()),
        ('Menü', Icons.menu_book_outlined,
          settings['qrAutoSync'] != false ? 'QR eşitleme açık' : 'QR eşitleme kapalı'),
        ('Güvenlik', Icons.shield_outlined, 'Kullanıcılar & Yetkiler'),
        ('Yedekleme', Icons.backup_outlined, 'Şifreli yedek ve geri yükleme'),
      ];
      return Wrap(spacing: 12, runSpacing: 12, children: [
        for (final entry in entries)
          SizedBox(width: tileWidth,
            child: _quickTile(entry.$1, entry.$2, entry.$3)),
      ]);
    },
  );

  Widget printerLayout(Map settings, Widget controls) {
    final preview = section(
      'Fiş Önizleme',
      'Örnek hesap · ${settings['paperWidthMm'] ?? 57} mm',
      [
        ReceiptPreview(
          settings: settings,
          order: {
            'id': 1,
            'dailyNumber': 1,
            'source': 'Masa',
            'table': 3,
            'createdAt': '2026-11-18T09:00:00Z',
            'batches': [
              {
                'id': 1,
                'lines': [
                  {'name': 'Falafel Dürüm', 'qty': 1, 'price': 140},
                  {'name': 'Ek Lavaş', 'qty': 1, 'price': 10},
                ],
              },
            ],
            'payments': [
              {'method': 'Nakit', 'amount': 150},
            ],
          },
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 790) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [controls, const SizedBox(height: 12), preview],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: controls),
            const SizedBox(width: 16),
            SizedBox(width: 270, child: preview),
          ],
        );
      },
    );
  }

  Widget section(String title, String description, List<Widget> children) =>
      Card(
        child: Padding(
          padding: const EdgeInsets.all(19),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xffEAF2EC),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.tune_outlined,
                        color: NohutBrand.green, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: const TextStyle(
                          color: NohutBrand.green,
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                        )),
                        const SizedBox(height: 4),
                        Text(description, style: const TextStyle(
                          color: NohutBrand.muted, fontSize: 12,
                        )),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Divider(),
              const SizedBox(height: 10),
              ...children,
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final settings = widget.state['settings'] as Map? ?? {};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('İşletme Ayarları · Yönetim ve Bağlantılar',
          style: TextStyle(color: NohutBrand.green,
            fontSize: 19, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        const Text('Her bölümü ayrı yönetin. Değişiklikler bu bilgisayarda saklanır.',
          style: TextStyle(color: NohutBrand.muted, fontSize: 12)),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          children: [
            for (final name in [
              'Genel',
              'Bildirimler',
              'Menü',
              'Yazıcı',
              'Entegrasyonlar',
              if (widget.staffPanel != null) 'Personel',
              if (widget.wifiPanel != null) 'Bağlantı',
              'Güvenlik',
              'Yedekleme',
            ])
              ChoiceChip(
                avatar: Icon(
                  switch (name) {
                    'Genel' => Icons.dashboard_customize_outlined,
                    'Bildirimler' => Icons.notifications_active_outlined,
                    'Menü' => Icons.menu_book_outlined,
                    'Yazıcı' => Icons.print_outlined,
                    'Entegrasyonlar' => Icons.hub_outlined,
                    'Personel' => Icons.people_outline,
                    'Bağlantı' => Icons.wifi_outlined,
                    'Güvenlik' => Icons.shield_outlined,
                    _ => Icons.backup_outlined,
                  },
                  size: 17,
                  color: tab == name ? Colors.white : NohutBrand.green,
                ),
                label: Text(name),
                selected: tab == name,
                onSelected: (_) => setState(() => tab = name),
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (tab == 'Personel' && widget.staffPanel != null) widget.staffPanel!,
        if (tab == 'Bağlantı' && widget.wifiPanel != null) widget.wifiPanel!,
        if (tab == 'Genel') ...[
          section('Hızlı Ayarlar', 'Doğrudan ilgili bölüme gidin.',
            [_quickGrid(settings)]),
          const SizedBox(height: 10),
          section('Bağlantı Durumu',
            'API bilgisi kaydetmek canlı entegrasyon başlatmaz.', [
            ListTile(
              leading: Icon(widget.tgoIntegration.status.startsWith('Bağlı ·')
                ? Icons.check_circle_outline : Icons.info_outline,
                color: widget.tgoIntegration.status.startsWith('Bağlı ·')
                  ? NohutBrand.green : NohutBrand.gold),
              title: const Text('Trendyol Go'),
              subtitle: Text(widget.tgoIntegration.status),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => setState(() => tab = 'Entegrasyonlar'),
            ),
            const ListTile(
              leading: Icon(Icons.link_off_outlined,
                color: NohutBrand.gold),
              title: Text('Migros Yemek · Yemeksepeti'),
              subtitle: Text('Canlı sipariş API bağlantısı henüz yok.'),
            ),
            ListTile(
              leading: const Icon(Icons.print_outlined),
              title: const Text('Fiş Yazıcısı'),
              subtitle: Text((settings['printerName'] ?? 'XP-237B')
                .toString()),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => setState(() => tab = 'Yazıcı'),
            ),
          ]),
        ],
        if (tab == 'Bildirimler') ...[
          section('Masa / Gel-Al Sesleri',
            'Personel siparişleri online platformlardan bağımsızdır.', [
            SwitchListTile.adaptive(
              secondary: const Icon(Icons.table_restaurant_outlined,
                color: NohutBrand.green),
              title: const Text('Yeni sipariş sesi'),
              value: settings['soundAlerts'] != false,
              onChanged: (v) => widget.edit((db) {
                (db.putIfAbsent('settings', () => <String, dynamic>{})
                    as Map)['soundAlerts'] = v;
              }),
            ),
          ]),
          section(
            'Online Sipariş Alarm 2.0',
            'Trendyol Go, Yemeksepeti ve Migros Yemek için ortak kuyruk. '
            'Canlı ses sadece doğrulanmış online siparişle başlar.',
            [
              SwitchListTile.adaptive(
                title: const Text('Online sipariş sesi'),
                subtitle: const Text(
                  'Personel (masa) siparişi sesinden bağımsızdır. '
                  'Kapalıyken bekleyen online sipariş uyarısı ekranda kalır.',
                ),
                value: settings['onlineOrderSound'] != false,
                onChanged: (value) => widget.edit((s) =>
                    (s.putIfAbsent('settings', () => <String, dynamic>{})
                        as Map)['onlineOrderSound'] = value),
              ),
              const ListTile(
                leading: Icon(Icons.timer_outlined),
                title: Text('Tek seferlik ses · 3 saniye'),
                subtitle: Text('Her yeni online sipariş için yalnızca bir kez '
                    '3 saniyelik ses çalar. Kabul edilmese bile tekrarlamaz. '
                    'Görsel aciliyet 45 ve 90 saniyede artar.'),
              ),
              const ListTile(
                leading: Icon(Icons.verified_outlined),
                title: Text('Görsel uyarı onaya kadar kalır'),
                subtitle: Text('Siparişi açmak onay sayılmaz. Bekleyen sipariş '
                    'sadece platformdan doğrulanan durum değişikliğiyle '
                    'uyarı listesinden çıkar. Ses tekrar başlamaz.'),
              ),
              const SizedBox(height: 8),
              const Text('Sesleri dene',
                  style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final provider in const [
                    'Trendyol Go', 'Yemeksepeti', 'Migros Yemek',
                  ])
                    OutlinedButton.icon(
                      onPressed: widget.onTestOnlineSound == null
                          ? null
                          : () => widget.onTestOnlineSound!(provider),
                      icon: const Icon(Icons.volume_up_outlined, size: 18),
                      label: Text('$provider · Test Sesi'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Ses düzeyi Windows mikserinden ayarlanır. '
                'Yemeksepeti ve Migros Yemek canlı sipariş bildirimleri '
                'yetkili API bağlantısı kurulana kadar çalışmaz.',
                style: TextStyle(fontSize: 12, color: NohutBrand.muted),
              ),
            ],
          ),
        ],
        if (tab == 'Entegrasyonlar') ...[
          section(
            'Platform Bağlantıları',
            'Bağlantı durumları ayrı tutulur. Kayıtlı API anahtarı '
            'canlı sipariş veya yetki onayı değildir.',
            [
              ListTile(
                leading: Icon(
                  widget.tgoIntegration.status.startsWith('Bağlı ·')
                    ? Icons.check_circle_outline
                    : Icons.info_outline,
                  color: widget.tgoIntegration.status.startsWith('Bağlı ·')
                    ? NohutBrand.green : NohutBrand.gold),
                title: const Text('Trendyol Go by Uber Eats'),
                subtitle: Text(
                  widget.tgoIntegration.status +
                  '\nSon başarılı eşitleme: ' +
                  (widget.tgoIntegration.lastSync.isNotEmpty
                    ? widget.tgoIntegration.lastSync : 'Henüz yok') +
                  (widget.tgoIntegration.error.isEmpty ? '' :
                    '\nHata: ' + widget.tgoIntegration.error)),
              ),
              const Divider(height: 8),
              const ListTile(
                leading: Icon(Icons.link_off_outlined,
                  color: NohutBrand.gold),
                title: Text('Yemeksepeti'),
                subtitle: Text('Canlı sipariş API bağlantısı yok. '
                  'Yetki ve sipariş endpoints doğrulanmalı.'),
              ),
              const ListTile(
                leading: Icon(Icons.link_off_outlined,
                  color: NohutBrand.gold),
                title: Text('Migros Yemek'),
                subtitle: Text('Canlı sipariş API bağlantısı yok. '
                  'Restoran / şube onayı ve gerçek API erişimi gerekli.'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          section(
            'Platform API Bilgileri',
            'Şifreli Windows saklama · API bilgilerini paylaşmayın. '
            'Partner sözleşmesi ve izinler ayrıca doğrulanır.',
            [
              LayoutBuilder(builder: (context, constraints) {
                final wide = constraints.maxWidth >= 700;
                final cards = [
                  PartnerCredentialsCard(
                    partner: 'Yemeksepeti',
                    databasePath: widget.store.filePath,
                    portalUrl: onlinePartners['Yemeksepeti']!.url,
                    documentationUrl: 'https://integration.yemeksepeti.com/en/',
                  ),
                  PartnerCredentialsCard(
                    partner: 'Migros Yemek',
                    databasePath: widget.store.filePath,
                    portalUrl: onlinePartners['Migros Yemek']!.url,
                  ),
                ];
                return wide
                  ? Row(crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: cards[0]),
                      const SizedBox(width: 12),
                      Expanded(child: cards[1]),
                    ])
                  : Column(children: [
                      cards[0], const SizedBox(height: 8), cards[1],
                    ]);
              }),
              const SizedBox(height: 10),
              ExpansionTile(
                leading: const Icon(Icons.fact_check_outlined,
                  color: NohutBrand.green),
                title: const Text('Migros API Kurulum Kontrol Listesi'),
                subtitle: const Text('Paneldeki bilgileri doğrulamadan '
                  'canlı bağlantı başlatılamaz.'),
                children: const [
                  ListTile(dense: true,
                    title: Text('1 · Restoran / şube kimliğini doğrulayın')),
                  ListTile(dense: true,
                    title: Text('2 · Yetkili POS entegrasyonu iznini alın')),
                  ListTile(dense: true,
                    title: Text('3 · Resmi API kimlik bilgileri ve dökümana '
                      'erişimi teyit edin')),
                  ListTile(dense: true,
                    title: Text('4 · Test siparişi, iptal, ödeme tipi ve '
                      'mükerrer sipariş senaryolarını doğrulayın')),
                  ListTile(dense: true,
                    title: Text('5 · Canlı bağlantı henüz bu sürümde yok'),
                    subtitle: Text('Kaydetmek, Migros siparişlerini '
                      'otomatik çekmez.')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          TgoSettingsPanel(integration: widget.tgoIntegration),
          if (asMaps(widget.state['tgoOperationAudit']).isNotEmpty)
            Card(
              child: ExpansionTile(
                leading: const Icon(Icons.history_outlined),
                title: const Text('Trendyol · İşlem Günlüğü'),
                subtitle: const Text('Platform işlemlerinin yerel denetim kaydı'),
                children: [
                  for (final record in asMaps(widget.state['tgoOperationAudit'])
                      .reversed.take(20))
                    ListTile(
                      dense: true,
                      title: Text('${record['action']} · #${record['orderNumber']}'),
                      subtitle: Text('${record['at']} · ${record['result']}'),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          QrPublisherSettingsPanel(
            state: widget.state,
            edit: widget.edit,
            databasePath: widget.store.filePath,
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.storefront_outlined,
                color: NohutBrand.green),
              title: const Text('Google İşletme Profili'),
              subtitle: const Text(
                'Google Cloud proje onayı ve hesap yetkilendirmesi'),
              trailing: const Icon(Icons.arrow_forward),
              onTap: widget.onOpenGoogle,
            ),
          ),
        ],
        if (tab == 'Menü')
          section(
            'Menü ve fiyatlar',
            'Eşitleme eski siparişlerin fiyatlarını değiştirmez.',
            [
              QrMenuSyncPanel(
                sync: widget.qrSync,
                enabled: settings['qrAutoSync'] != false,
                onToggle: (v) {
                  if (widget.edit((s) {
                        (s.putIfAbsent('settings', () => <String, dynamic>{})
                                as Map)['qrAutoSync'] =
                            v;
                      }) &&
                      v)
                    widget.qrSync.syncNow();
                },
              ),
              TextField(
                decoration: const InputDecoration(
                  labelText: 'Ürün ara',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (v) => setState(() => search = v),
              ),
              for (final p in asMaps(widget.state['localMenu']).where(
                (p) =>
                    '${p['name']}'.toLowerCase().contains(search.toLowerCase()),
              ))
                ListTile(
                  title: Text('${p['name']}'),
                  subtitle: Text(
                    p['price'] == null
                        ? 'Satış dışı'
                        : formatTry(cents(p['price'])),
                  ),
                  trailing: IconButton(
                    tooltip: 'Fiyat Düzenle',
                    onPressed: settings['qrAutoSync'] != false
                        ? null
                        : () async {
                            final v = await askFields(
                              context,
                              'Yerel Ürün Fiyatı',
                              [
                                (
                                  'Fiyat ₺ (boş = satış dışı)',
                                  '${p['price'] ?? ''}',
                                ),
                              ],
                            );
                            if (v != null)
                              widget.edit((s) {
                                final row = (s['localMenu'] as List)
                                    .cast<Map>()
                                    .firstWhere((x) => x['id'] == p['id']);
                                row['price'] = v[0].isEmpty
                                    ? null
                                    : fromCents(parseMoney(v[0]));
                              });
                          },
                    icon: const Icon(Icons.edit_outlined),
                  ),
                ),
            ],
          ),
        if (tab == 'Yazıcı') ...[
          PrinterManagementPanel(state:widget.state,edit:widget.edit),
          const SizedBox(height:12),
          printerLayout(
            settings,
            section(
              'Müşteri Hesap Fişi',
              'Masa/Gel-Al hesap özeti ödeme öncesi elle yazdırılabilir. Ödeme sonrası tekrar sorulur; mali fiş değildir.',
              [
                ListTile(
                  leading: const Icon(Icons.print_outlined),
                  title: Text('${settings['printerName'] ?? 'XP-237B'}'),
                  subtitle: Text(
                    '${settings['paperWidthMm'] ?? 57} mm kağıt (Mevax termal rulo) · ${settings['printableWidthMm'] ?? 48} mm baskı · sol/sağ ${settings['receiptSidePaddingMm'] ?? 3} mm boşluk',
                  ),
                ),
                DropdownButtonFormField<String>(
                  key: ValueKey(
                    'receipt-transport-${settings['receiptTransport'] ?? 'windows'}',
                  ),
                  initialValue: '${settings['receiptTransport'] ?? 'windows'}',
                  decoration: const InputDecoration(
                    labelText: 'Yazdırma yöntemi',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'windows',
                      child: Text('Windows · Fiş görseli'),
                    ),
                    DropdownMenuItem(
                      value: 'escpos',
                      child: Text('ESC/POS · Fiş modu'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null)
                      widget.edit((s) {
                        final cfg = s['settings'] as Map;
                        cfg['receiptTransport'] = v;
                        if (v == 'escpos') cfg['receiptOffsetMm'] = 0;
                      });
                  },
                ),
                const SizedBox(height: 12),
                const Text(
                  'XP-237B: Önce yazıcının fiş modunda olduğunu doğrulayın. ESC/POS, sayfa uzunluğu sınırını kullanmaz. Etiket modunda seçmeyin.',
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('Gelişmiş Kağıt / Logo / Hizalama Ayarı'),
                  onPressed: () async {
                    final v = await askFields(
                      context,
                      'Yazıcı Ayarı',
                      [
                        (
                          'Kağıt genişliği (mm)',
                          '${settings['paperWidthMm'] ?? 57}',
                        ),
                        (
                          'Baskı genişliği (mm)',
                          '${settings['printableWidthMm'] ?? 48}',
                        ),
                        (
                          'Üst / alt güvenli boşluk (mm)',
                          '${settings['receiptMarginMm'] ?? 4}',
                        ),
                        (
                          'Yatay kaydırma (mm, + sağa)',
                          '${settings['receiptOffsetMm'] ?? 0}',
                        ),
                        (
                          'Logo boyutu (mm)',
                          '${settings['receiptLogoMm'] ?? 18}',
                        ),
                        (
                          'Sol / sağ boşluk (mm)',
                          '${settings['receiptSidePaddingMm'] ?? 3}',
                        ),
                      ],
                      validate: (v) {
                        final values = v
                            .map((x) => double.tryParse(x.replaceAll(',', '.')))
                            .toList();
                        if (values.any((x) => x == null || !x.isFinite))
                          return 'Sayısal ölçüler gerekli';
                        final p = values.cast<double>();
                        try {
                          ReceiptDimensions({
                            'paperWidthMm': p[0],
                            'printableWidthMm': p[1],
                            'receiptMarginMm': p[2],
                            'receiptOffsetMm': p[3],
                            'receiptLogoMm': p[4],
                            'receiptSidePaddingMm': p[5],
                          });
                        } on FormatException catch (e) {
                          return e.message;
                        }
                        if (settings['receiptTransport'] == 'escpos' &&
                            p[3] != 0)
                          return 'ESC/POS için yatay kaydırma 0 olmalı';

                        if (p[0] < 40 ||
                            p[0] > 80 ||
                            p[1] < 30 ||
                            p[1] > 48 ||
                            p[1] > p[0] ||
                            p[2] < 2 ||
                            p[2] > 10 ||
                            p[3].abs() > 10 ||
                            p[4] < 10 ||
                            p[4] > 25 ||
                            p[5] < 0 ||
                            p[5] > 8)
                          return 'Ölçüler: kağıt 40–80, baskı 30–48, boşluk 2–10, kaydırma ±10, logo 10–25, sol/sağ 0–8 mm';
                        return null;
                      },
                    );
                    if (v != null)
                      widget.edit((s) {
                        final cfg = s['settings'] as Map;
                        for (var i = 0; i < 6; i++)
                          cfg[[
                            'paperWidthMm',
                            'printableWidthMm',
                            'receiptMarginMm',
                            'receiptOffsetMm',
                            'receiptLogoMm',
                            'receiptSidePaddingMm',
                          ][i]] = double.parse(
                            v[i].replaceAll(',', '.'),
                          );
                        cfg['receiptScale'] = 'actual';
                      });
                  },
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.print_outlined),
                  label: const Text('Hizalama Testi Yazdır'),
                  onPressed: () async {
                    try {
                      await windowsPrint(
                        'HİZALAMA TESTİ\nSol |--------------------| Sağ\nOrtalanmış baskı alanı\nKağıt: ${settings['paperWidthMm'] ?? 57} mm\nBu bir sipariş değildir.',
                        '${settings['printerName'] ?? 'XP-237B'}',
                        settings: settings,
                      );
                      if (context.mounted)
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Test yazıcı kuyruğuna gönderildi'),
                          ),
                        );
                    } catch (e) {
                      if (context.mounted)
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text('$e')));
                    }
                  },
                ),
                for (final j in asMaps(widget.state['printJobs']).where(
                  (j) =>
                      j['kind'] == 'paymentReceipt' &&
                      j['state'] == 'Kontrol gerekli',
                ))
                  ListTile(
                    title: const Text('Fiş çıktısını kontrol edin'),
                    subtitle: Text('${j['error']}'),
                    trailing: TextButton(
                      child: const Text('Kontrol Ettim · Yeniden Dene'),
                      onPressed: () async {
                        if (await confirmAction(
                          context,
                          'Tekrar yazdır?',
                          'Aynı çıktı iki kez basılabilir. Önce yazıcıyı kontrol edin.',
                        ))
                          widget.edit((s) {
                            final job = (s['printJobs'] as List)
                                .cast<Map>()
                                .firstWhere(
                                  (x) =>
                                      x['receiptRequestId'] ==
                                      j['receiptRequestId'],
                                );
                            if (job['state'] != 'Kontrol gerekli')
                              throw const FormatException('Durum değişti');
                            job['state'] = 'Bekliyor';
                          });
                      },
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const SizedBox(height: 4),
          const ListTile(
            leading: Icon(Icons.receipt_long_outlined),
            title: Text('Trendyol Go sipariş fişi'),
            subtitle: Text('Sipariş kabul edildiğinde, Masa / Gel-Al fişiyle aynı yazıcıdan ve aynı formatta otomatik yazdırılır (Otomatik Masa / Gel-Al Fişi açıkken).'),
          ),
        ],
        if (tab == 'Güvenlik' && widget.accountsPanel != null)
          section(
            'Kullanıcılar & Yetkiler',
            'Bireysel hesaplar, kişiye özel yetkiler, güvenilen cihazlar ve sahip için iki adımlı doğrulama.',
            [widget.accountsPanel!],
          ),
        if (tab == 'Güvenlik')
          section(
            'Güvenlik ve erişim',
            'Genel öneriler.',
            [
              const ListTile(
                leading: Icon(Icons.admin_panel_settings_outlined),
                title: Text('Yönetici bilgisayarını koruyun'),
                subtitle: Text('Windows oturumunu yetkisiz kişilerden koruyun. Kullanıcı hesapları ve yedekler bu bilgisayardadır.'),
              ),
              const Divider(),
              const ListTile(
                leading: Icon(Icons.people_outline),
                title: Text('Personel erişimi'),
                subtitle: Text('“Bireysel giriş zorunlu” kapalıyken ad seçimi kimlik doğrulama değildir. Çalışan ağını misafir Wi-Fi ağından ayırın.'),
              ),
              const Divider(),
              const ListTile(
                leading: Icon(Icons.key_off_outlined),
                title: Text('API bilgileri'),
                subtitle: Text('Entegrasyon anahtarlarını sadece yetkili yönetici cihazında saklayın; ekran görüntülerinde veya GitHub üzerinde paylaşmayın.'),
              ),
              const Divider(),
              const ListTile(
                leading: Icon(Icons.backup_outlined),
                title: Text('Veri yedekleri'),
                subtitle: Text('Yedekleme sekmesinden şifreli yedek alın, doğrulayın ve gerekirse geri yükleyin.'),
              ),
            ],
          ),
        if (tab == 'Yedekleme')
          section(
            'Yedekleme ve Geri Yükleme',
            'Şifreli yedek (AES-256) · kurtarma anahtarı sizde · hiçbir yedek otomatik silinmez.',
            [
              if (widget.backupPanel != null) widget.backupPanel!
              else const Text('Yedekleme bu ekranda kullanılamıyor.'),
              ExpansionTile(
                title: const Text('Veritabanı konumu'),
                children: [SelectableText(widget.store.filePath)],
              ),
            ],
          ),
      ],
    );
  }
}
