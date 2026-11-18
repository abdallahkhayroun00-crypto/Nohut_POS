import 'dart:io';

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
  });
  final Json state;
  final EditState edit;
  final PosStore store;
  final QrMenuAutoSync qrSync;
  final TrendyolGoReadonly tgoIntegration;
  final VoidCallback onOpenGoogle;
  final ValueChanged<String>? onTestOnlineSound;
  final Widget? staffPanel, wifiPanel;
  @override
  State<SimpleSettings> createState() => _SimpleSettingsState();
}

class _SimpleSettingsState extends State<SimpleSettings> {
  String tab = 'Genel', search = '';
  Widget printerLayout(Map settings, Widget controls) {
    final preview = section(
      'Fiş Önizleme',
      'Örnek hesap · ${settings['paperWidthMm'] ?? 56} mm',
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
        panelTitle('Ayarlar'),
        const Text('Restoran yönetimi, platform bağlantıları, yazıcılar ve veri güvenliği.'),
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
        if (tab == 'Genel')
          section(
            'Bildirimler',
            'Personelden gelen siparişler yönetici ekranında görünür.',
            [
              SwitchListTile(
                title: const Text('Yeni sipariş sesi'),
                value: settings['soundAlerts'] != false,
                onChanged: (v) => widget.edit((s) {
                  (s.putIfAbsent('settings', () => <String, dynamic>{})
                          as Map)['soundAlerts'] =
                      v;
                }),
              ),
              const ListTile(
                leading: Icon(Icons.table_restaurant),
                title: Text('5 masa · Ortak hesaplar'),
                subtitle: Text('Telefon ve laptop aynı siparişleri kullanır.'),
              ),
            ],
          ),
        if (tab == 'Bildirimler') ...[
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
                title: Text('10 sn ses · 15 sn aralık'),
                subtitle: Text('10 saniyelik özgün melodi + 5 saniye sessizlik. '
                    '45 saniye sonra hızlanır; 90 saniyede kırmızı acil uyarı.'),
              ),
              const ListTile(
                leading: Icon(Icons.verified_outlined),
                title: Text('Platform onayı gerekli'),
                subtitle: Text('Ses yalnızca API tarafından doğrulanan kabul, '
                    'iptal veya kapanış durumundan sonra durur. '
                    'Siparişi açmak sesi durdurmaz.'),
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
          Card(
            child: Padding(
              padding: const EdgeInsets.all(17),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Entegrasyon Sağlığı',
                    style: TextStyle(color: NohutBrand.green,
                        fontWeight: FontWeight.w800, fontSize: 18)),
                  const SizedBox(height: 9),
                  ListTile(
                    leading: Icon(
                      widget.tgoIntegration.status.startsWith('Bağlı ·')
                        ? Icons.check_circle_outline : Icons.info_outline,
                      color: widget.tgoIntegration.status.startsWith('Bağlı ·')
                        ? NohutBrand.green : NohutBrand.gold,
                    ),
                    title: const Text('Trendyol Go by Uber Eats'),
                    subtitle: Text(
                      '${widget.tgoIntegration.status}'
                      '\\nSon başarılı eşitleme: '
                      '${widget.tgoIntegration.lastSync.isNotEmpty ? widget.tgoIntegration.lastSync : 'Henüz yok'}'
                      '${widget.tgoIntegration.error.isEmpty ? '' : '\\nHata: ${widget.tgoIntegration.error}'}',
                    ),
                  ),
                  const ListTile(
                    leading: Icon(Icons.link_off_outlined, color: NohutBrand.gold),
                    title: Text('Yemeksepeti · Migros Yemek'),
                    subtitle: Text('API bilgilerini kaydetmek entegrasyonu açmaz. '
                        'Canlı bağlantı ve Test Connection, resmi restoran API erişimi '
                        'sağlanana kadar kullanılamaz.'),
                  ),
                  const ListTile(
                    leading: Icon(Icons.info_outline, color: NohutBrand.muted),
                    title: Text('Google İşletme Profili'),
                    subtitle: Text('OAuth bağlantısı ve yetkiler Google '
                        'İşletme Profili sayfasından kontrol edilir.'),
                  ),
                ],
              ),
            ),
          ),
          TgoSettingsPanel(integration: widget.tgoIntegration),
          const SizedBox(height: 12),
          const SizedBox(height: 12),
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
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.storefront_outlined),
              title: const Text('Google İşletme Profili'),
              subtitle: const Text(
                'Google Cloud proje onayı ve hesap yetkilendirmesi',
              ),
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
          printerLayout(
            settings,
            section(
              'Ödemede sor, istenirse yazdır',
              'Sipariş ve ek ürünlerde otomatik çıktı alınmaz. Ödeme kaydında fiş isteği sorulur.',
              [
                ListTile(
                  leading: const Icon(Icons.print_outlined),
                  title: Text('${settings['printerName'] ?? 'XP-237B'}'),
                  subtitle: Text(
                    '${settings['paperWidthMm'] ?? 56} mm kağıt · ${settings['printableWidthMm'] ?? 48} mm baskı · Aynı fiş tasarımı',
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
                  label: const Text('Yazıcı Ayarı'),
                  onPressed: () async {
                    final v = await askFields(
                      context,
                      'Yazıcı Ayarı',
                      [
                        (
                          'Windows yazıcı adı',
                          '${settings['printerName'] ?? 'XP-237B'}',
                        ),
                        (
                          'Kağıt genişliği (mm)',
                          '${settings['paperWidthMm'] ?? 56}',
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
                      ],
                      validate: (v) {
                        final values = v
                            .skip(1)
                            .map((x) => double.tryParse(x.replaceAll(',', '.')))
                            .toList();
                        if (v[0].isEmpty ||
                            values.any((x) => x == null || !x.isFinite))
                          return 'Yazıcı adı ve sayısal ölçüler gerekli';
                        final p = values.cast<double>();
                        try {
                          ReceiptDimensions({
                            'paperWidthMm': p[0],
                            'printableWidthMm': p[1],
                            'receiptMarginMm': p[2],
                            'receiptOffsetMm': p[3],
                            'receiptLogoMm': p[4],
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
                            p[4] > 25)
                          return 'Ölçüler: kağıt 40–80, baskı 30–48, boşluk 2–10, kaydırma ±10, logo 10–25 mm';
                        return null;
                      },
                    );
                    if (v != null)
                      widget.edit((s) {
                        final cfg = s['settings'] as Map;
                        cfg['printerName'] = v[0];
                        for (var i = 0; i < 5; i++)
                          cfg[[
                            'paperWidthMm',
                            'printableWidthMm',
                            'receiptMarginMm',
                            'receiptOffsetMm',
                            'receiptLogoMm',
                          ][i]] = double.parse(
                            v[i + 1].replaceAll(',', '.'),
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
                        'HİZALAMA TESTİ\nSol |--------------------| Sağ\nOrtalanmış baskı alanı\nKağıt: ${settings['paperWidthMm'] ?? 56} mm\nBu bir sipariş değildir.',
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
          section(
            'Mutfak Fişi',
            'Uber Eats Trendyol Go siparişleri için otomatik baskı zamanını seçin.',
            [
              DropdownButtonFormField<String>(
                initialValue: tgoKitchenTiming(settings),
                decoration: const InputDecoration(
                  labelText: 'Mutfak fişi zamanı',
                ),
                items: const [
                  DropdownMenuItem(value: 'manual', child: Text('Elle yazdır')),
                  DropdownMenuItem(
                    value: 'arrival',
                    child: Text('Sipariş gelince'),
                  ),
                  DropdownMenuItem(
                    value: 'accepted',
                    child: Text('Kabul edildiği görülünce'),
                  ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  widget.edit((s) {
                    final cfg = s['settings'] as Map;
                    cfg['tgoKitchenTiming'] = value;
                    cfg['tgoAutoKitchen'] = value == 'arrival';
                  });
                },
              ),
            ],
          ),
        ],
        if (tab == 'Güvenlik')
          section(
            'Güvenlik ve erişim',
            'Bu panel mevcut bağlantı ve erişim durumunu gösterir; yeni bir oturum açma sistemi kurmaz.',
            [
              const ListTile(
                leading: Icon(Icons.admin_panel_settings_outlined),
                title: Text('Yönetici bilgisayarını koruyun'),
                subtitle: Text('Windows oturumunu yetkisiz kişilerden koruyun. Bu sürümde yönetici için ayrı POS şifresi bulunmuyor.'),
              ),
              const Divider(),
              const ListTile(
                leading: Icon(Icons.people_outline),
                title: Text('Personel erişimi'),
                subtitle: Text('Personel adı seçimi tek başına kimlik doğrulama değildir. Çalışan ağını misafir Wi-Fi ağından ayırın.'),
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
                subtitle: Text('Yedekleme sekmesinden SQLite yedeği oluşturun ve geri yükleme işlemini güvenli ortamda test edin.'),
              ),
            ],
          ),
        if (tab == 'Yedekleme')
          section(
            'Verilerini koru',
            'Sipariş geçmişi bu bilgisayarda saklanır.',
            [
              FilledButton.icon(
                icon: const Icon(Icons.save_alt),
                label: const Text('SQLite Yedeği Oluştur'),
                onPressed: () async {
                  final v = await askFields(context, 'SQLite Yedekle', [
                    (
                      'Yeni yedek dosya yolu',
                      '${Directory.current.path}/nohut-${DateTime.now().millisecondsSinceEpoch}.sqlite3',
                    ),
                  ]);
                  if (v != null) {
                    try {
                      widget.store.backup(v[0]);
                      if (context.mounted)
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Yedek kaydedildi')),
                        );
                    } catch (e) {
                      if (context.mounted)
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text('$e')));
                    }
                  }
                },
              ),
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
