import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'brand.dart';
import 'pos_logic.dart';
import 'order_reporting.dart';
import 'compact_review_card.dart';
import 'review_display.dart';
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
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
              Text(
                s.canWrite
                    ? 'Sipariş işlemleri etkin · Kabul Et / Hazır / İptal Et işlemleri platform API yanıtı ile doğrulanır.'
                    : 'Sipariş senkronizasyonu etkin. Kabul Et / Hazır / İptal Et için restoran API yazma yetkisi ve doğrulanmış bağlantı gereklidir.',
              ),
              if (!TrendyolGoReadonly.liveSyncEnabled)
                const Text(
                  'Ayarları kaydedebilirsiniz. Canlı sipariş eşitlemesi bu sürümde geçici olarak kapalı.',
                ),
              if (!TrendyolGoReadonly.writeEnabled)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Güvenlik: Yazma işlemleri bu yapıda kapalıdır. Restoran API izinleri ve MEAL endpointleri doğrulandıktan sonra açılabilir.',
                    style: TextStyle(color: NohutBrand.muted, fontSize: 12),
                  ),
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
                    onPressed:
                        !TrendyolGoReadonly.liveSyncEnabled ||
                            s.syncing ||
                            s.credentials?.valid != true
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

/// Label, foreground and background for a platform package status.
(String, Color, Color) tgoStatusStyle(String status) => switch (status) {
  'Created' => ('Yeni', const Color(0xff325577), const Color(0xffe9f0f5)),
  'Picking' => ('Hazırlanıyor', const Color(0xff765720), const Color(0xfff7ecd4)),
  'Invoiced' => ('Hazırlandı', NohutBrand.green, const Color(0xffe5ebdf)),
  'Shipped' => ('Yolda', const Color(0xff325577), const Color(0xffe9f0f5)),
  'Delivered' => ('Teslim Edildi', NohutBrand.green, const Color(0xffe5ebdf)),
  'Cancelled' => ('İptal', const Color(0xff8d3930), const Color(0xfff6e6e3)),
  'UnSupplied' => ('Karşılanamadı', const Color(0xff8d3930), const Color(0xfff6e6e3)),
  _ => (status.isEmpty ? 'Durum bilinmiyor' : status, NohutBrand.muted,
      const Color(0xffeeeeea)),
};

/// Minutes an active order has been waiting, or null when not active.
int? tgoWaitingMinutes(Json order, DateTime now) {
  if (!const ['Created', 'Picking', 'Invoiced'].contains(order['status'])) {
    return null;
  }
  final created = DateTime.tryParse('${order['createdAt']}');
  if (created == null) return null;
  final minutes = now.toUtc().difference(created.toUtc()).inMinutes;
  return minutes < 0 ? 0 : minutes;
}

/// A new order should be accepted within 3 minutes; a picking order should
/// be ready within its platform preparation time (15 minutes by default).
bool tgoOrderLate(Json order, DateTime now) {
  final waiting = tgoWaitingMinutes(order, now);
  if (waiting == null) return false;
  final prep = order['preparationMinutes'];
  return switch (order['status']) {
    'Created' => waiting >= 3,
    'Picking' => waiting >= (prep is num && prep > 0 ? prep.toInt() : 15),
    _ => false,
  };
}

class TgoOrderCard extends StatelessWidget {
  const TgoOrderCard({
    super.key,
    required this.order,
    this.onKitchenPrint,
    this.onAction,
    this.canWrite = false,
    this.now,
  });
  final Json order;
  /// Clock for the waiting badge; defaults to DateTime.now().
  final DateTime? now;
  final VoidCallback? onKitchenPrint;
  final void Function(Json order, String action)? onAction;
  final bool canWrite;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = '${order['status'] ?? ''}';
    final (statusLabel, statusColor, statusBg) = tgoStatusStyle(status);
    final payment = '${order['paymentType'] ?? ''}';
    final paymentLabel = switch (payment) {
      'PAY_WITH_CARD' => 'Kart',
      'PAY_WITH_CASH' => 'Nakit',
      _ => payment.replaceAll('_', ' '),
    };
    final note = '${order['customerNote'] ?? ''}'.trim();
    final customer = '${order['customerName'] ?? ''}'.trim();
    final contact = '${order['customerPhone'] ?? ''}'.trim();
    final email = '${order['customerEmail'] ?? ''}'.trim();
    final address = '${order['deliveryAddress'] ?? ''}'.trim();
    final duration = order['preparationMinutes'];
    final deliveryEta = '${order['deliveryEta'] ?? ''}'.trim();
    final reason = '${order['cancelReason'] ?? ''}'.trim();
    final eta = {
      for (final key in ['courierEtaFrom', 'courierEtaTo'])
        if (order[key] is String) istanbulStamp(order[key]).split(' ').last,
    }.join('–');
    final printState = order['kitchenPrintState'] as String?;
    final showCourier =
        order['pickup'] != true &&
        const ['Created', 'Picking', 'Invoiced'].contains(status);
    final lines = asMaps(order['lines']);
    final courierTimeline = asMaps(order['courierTimeline']);
    String observedAt(String stage) {
      final entry = courierTimeline.where((e) => e['stage'] == stage).firstOrNull;
      final time = entry?['observedAt'];
      return time is String && DateTime.tryParse(time) != null
          ? istanbulStamp(time) + ' · POS\'da görüldü'
          : 'Saat bilgisi yok';
    }
    bool reached(String stage) =>
        courierTimeline.any((event) => event['stage'] == stage);
    final clock = now ?? DateTime.now();
    final waiting = tgoWaitingMinutes(order, clock);
    final late = tgoOrderLate(order, clock);
    return Card(
      margin: EdgeInsets.zero,
      elevation: status == 'Created' ? 2 : 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: status == 'Created'
              ? const Color(0xff6E93BC)
              : const Color(0xffE1E7E3),
          width: status == 'Created' ? 1.6 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    '#${displayOrderNumber(order)}',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                if (waiting != null) ...[
                  Tooltip(
                    message: late
                        ? (status == 'Created'
                            ? 'Kabul bekliyor · gecikti'
                            : 'Hazırlık süresi aşıldı')
                        : 'Sipariş geleli',
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: late
                            ? const Color(0xffFBE4E0) : const Color(0xffF1F4F2),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.timer_outlined, size: 14,
                            color: late
                                ? const Color(0xffB3261E) : NohutBrand.muted),
                          const SizedBox(width: 3),
                          Text('$waiting dk', style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w700,
                            color: late
                                ? const Color(0xffB3261E) : NohutBrand.muted)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                const SizedBox(width: 2),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: statusBg,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    child: Text(
                      statusLabel,
                      style: TextStyle(
                        color: statusColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            DefaultTextStyle.merge(
              style: const TextStyle(fontSize: 12.5, color: NohutBrand.muted),
              child: Wrap(
                spacing: 10,
                runSpacing: 2,
                children: [
                  Text(order['source'] is String &&
                          order['source'] != 'Trendyol Go'
                      ? '${order['source']}' : 'Trendyol Go',
                    style: const TextStyle(
                      color: NohutBrand.green, fontWeight: FontWeight.w700)),
                  Text(istanbulStamp(order['createdAt'])),
                  Text(order['pickup'] == true ? 'Gel-Al' : 'Paket Servis'),
                  if ('${order['orderCode'] ?? ''}'.isNotEmpty)
                    Text("Kod: ${order['orderCode']}"),
                  Text('Platform no: ${order['orderNumber']}'),
                  if (order['testPackage'] == true) const Text('Test siparişi'),
                ],
              ),
            ),
            const Divider(height: 18),
            // What the kitchen needs first: items, then the customer note.
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 30,
                      margin: const EdgeInsets.only(right: 10),
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xffEEF3EF),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '${line['qty']}×',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800, color: NohutBrand.green),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${line['name']}', style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                          if (line['options'] case final List options
                              when options.isNotEmpty)
                            Text(
                              options.join(', '),
                              style: theme.textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            if (note.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: const Color(0xffFFF6E0),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xffEED9A6)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.sticky_note_2_outlined,
                      size: 16, color: Color(0xff8A6516)),
                    const SizedBox(width: 6),
                    Expanded(child: Text('Müşteri notu: $note',
                      style: const TextStyle(color: Color(0xff6B4E10),
                        fontWeight: FontWeight.w600))),
                  ],
                ),
              ),
            if (reason.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('İptal nedeni: $reason',
                  style: const TextStyle(color: Color(0xff8d3930),
                    fontWeight: FontWeight.w600)),
              ),
            const Divider(height: 18),
            Row(
              children: [
                Expanded(
                  child: Text(
                    paymentLabel.isEmpty ? 'Platform toplamı' : paymentLabel,
                    style: const TextStyle(color: NohutBrand.muted),
                  ),
                ),
                Text(
                  formatTry(order['totalCents'] as int? ?? 0),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            if (onAction != null && tgoKitchenActive(order)) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  if (status == 'Created' || status == 'Picking')
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(44)),
                        onPressed: canWrite
                            ? () => onAction!(order,
                                status == 'Created' ? 'accept' : 'ready')
                            : null,
                        icon: Icon(status == 'Created'
                            ? Icons.check_circle_outline
                            : Icons.restaurant_outlined, size: 18),
                        label: Text(status == 'Created' ? 'Kabul Et' : 'Hazır'),
                      ),
                    ),
                  if (status == 'Created' || status == 'Picking')
                    const SizedBox(width: 6),
                  IconButton.outlined(
                    tooltip: 'Siparişi İptal Et',
                    onPressed: canWrite ? () => onAction!(order, 'cancel') : null,
                    icon: const Icon(Icons.cancel_outlined, size: 19),
                  ),
                  IconButton(
                    tooltip: 'Partner Paneli',
                    onPressed: () => openExternalPage(
                      context, 'https://partner.tgoyemek.com/'),
                    icon: const Icon(Icons.open_in_new, size: 18),
                  ),
                ],
              ),
              if (!canWrite)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('API işlem yetkisi etkin değil',
                    style: TextStyle(fontSize: 12, color: NohutBrand.muted)),
                ),
            ],
            if (printState != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Mutfak fişi · $printState',
                  style: theme.textTheme.bodySmall,
                ),
              )
            else if (onKitchenPrint != null && tgoKitchenActive(order))
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: onKitchenPrint,
                  icon: const Icon(Icons.print_outlined),
                  label: const Text('Mutfak Fişi Yazdır'),
                ),
              ),
            // Secondary information: timing, courier progress, customer.
            if ((duration is num && duration > 0) || deliveryEta.isNotEmpty ||
                (showCourier && (eta.isNotEmpty || order['courierNearby'] == true)))
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: DefaultTextStyle.merge(
                  style: const TextStyle(fontSize: 12.5),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    children: [
                      if (duration is num && duration > 0)
                        Text('Hazırlık süresi: ${duration.toInt()} dk'),
                      if (showCourier && eta.isNotEmpty)
                        Text('Tahmini kurye varışı: $eta'),
                      if (deliveryEta.isNotEmpty)
                        Text('Tahmini teslimat: $deliveryEta'),
                      if (showCourier && order['courierNearby'] == true)
                        const Text('🛵 Kurye restorana yaklaştı.',
                          style: TextStyle(color: NohutBrand.green,
                            fontWeight: FontWeight.w800)),
                    ],
                  ),
                ),
              ),
            if (order['pickup'] != true) ...[
              const SizedBox(height: 10),
              Tooltip(
                message: 'Kurye Takip · Saatler platformun gerçek olay zamanı '
                  'değil, POS tarafından ilk görüldüğü zamandır.',
                child: Row(
                  children: [
                    for (final (i, step) in const [
                      ('nearby', 'Yaklaşıyor'),
                      ('picked_up', 'Kuryede'),
                      ('delivered', 'Teslim'),
                    ].indexed) ...[
                      if (i > 0)
                        Expanded(
                          child: Container(
                            height: 2,
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            color: reached(step.$1)
                                ? NohutBrand.green : const Color(0xffDCE3DE),
                          ),
                        ),
                      Tooltip(
                        message: observedAt(step.$1),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              reached(step.$1)
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                              size: 15,
                              color: reached(step.$1)
                                  ? NohutBrand.green : const Color(0xffA9B3AD),
                            ),
                            const SizedBox(width: 4),
                            Text(step.$2, style: TextStyle(
                              fontSize: 12,
                              color: reached(step.$1)
                                  ? NohutBrand.green : NohutBrand.muted,
                              fontWeight: reached(step.$1)
                                  ? FontWeight.w700 : FontWeight.w400)),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            if (customer.isNotEmpty || contact.isNotEmpty || email.isNotEmpty || address.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(top: 10),
                decoration: BoxDecoration(
                  color: const Color(0xffF3F7F3),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: DefaultTextStyle.merge(
                  style: const TextStyle(fontSize: 12.5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Müşteri ve Teslimat', style: TextStyle(
                        color: NohutBrand.green, fontWeight: FontWeight.w800)),
                      if (customer.isNotEmpty) SelectableText('Müşteri: $customer'),
                      if (contact.isNotEmpty) SelectableText('Telefon: $contact'),
                      if (email.isNotEmpty) SelectableText('E-posta: $email'),
                      if (address.isNotEmpty) SelectableText('Adres: $address'),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class FeedbackPanel extends StatefulWidget {
  const FeedbackPanel({
    super.key,
    required this.integration,
    required this.orders,
    required this.onOpenGoogle,
  });

  final TrendyolGoReadonly integration;
  final List<Json> orders;
  final VoidCallback onOpenGoogle;

  @override
  State<FeedbackPanel> createState() => _FeedbackPanelState();
}

enum _FeedbackSource { trendyol, google, yemeksepeti }

class _FeedbackPanelState extends State<FeedbackPanel> {
  _FeedbackSource source = _FeedbackSource.trendyol;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final (value, label) in const [
              (_FeedbackSource.trendyol, 'Trendyol Go'),
              (_FeedbackSource.google, 'Google Maps'),
              (_FeedbackSource.yemeksepeti, 'Yemeksepeti'),
            ])
              ChoiceChip(
                label: Text(label),
                selected: source == value,
                onSelected: (_) => setState(() => source = value),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Offstage(
          offstage: source != _FeedbackSource.trendyol,
          child: TgoReviewsPanel(
            orders: widget.orders,
            integration: widget.integration,
          ),
        ),
        if (source == _FeedbackSource.google)
          Card(
            child: ListTile(
              leading: const Icon(Icons.place_outlined),
              title: const Text('Google İşletme Profili'),
              subtitle: const Text('Yorumlar, yanıtlar ve işletme performansı'),
              trailing: const Icon(Icons.arrow_forward),
              onTap: widget.onOpenGoogle,
            ),
          ),
        if (source == _FeedbackSource.yemeksepeti)
          const _ExternalReviewsCard(
            icon: Icons.restaurant_outlined,
            title: 'Yemeksepeti',
            description:
                'Yorumları görmek için restoran hesabınızla Partner Paneli’ne giriş yapın.',
            action: 'Partner Panelini Aç',
            url: 'https://partner-app.yemeksepeti.com/',
          ),
      ],
    );
  }
}

Future<bool> openExternalPage(BuildContext context, String url) async {
  try {
    final ProcessResult result;
    if (Platform.isWindows) {
      result = await Process.run('rundll32.exe', [
        'url.dll,FileProtocolHandler',
        url,
      ]);
    } else {
      result = await Process.run(Platform.isMacOS ? 'open' : 'xdg-open', [url]);
    }
    if (result.exitCode == 0) return true;
  } on ProcessException {
    // Offer the address for manual opening if the browser cannot be launched.
  }
  if (!context.mounted) return false;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: SelectableText('Tarayıcı açılamadı. $url')));
  return false;
}

class _ExternalReviewsCard extends StatelessWidget {
  const _ExternalReviewsCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.action,
    required this.url,
  });

  final IconData icon;
  final String title, description, action, url;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: NohutBrand.green),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(description),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => openExternalPage(context, url),
              icon: const Icon(Icons.open_in_new),
              label: Text(action),
            ),
          ],
        ),
      ),
    );
  }
}

class TgoReviewsPanel extends StatefulWidget {
  const TgoReviewsPanel({
    super.key,
    required this.integration,
    required this.orders,
  });

  final TrendyolGoReadonly integration;
  final List<Json> orders;

  @override
  State<TgoReviewsPanel> createState() => _TgoReviewsPanelState();
}

class _TgoReviewsPanelState extends State<TgoReviewsPanel> {
  final storeId = TextEditingController();
  List<Json> reviews = [];
  String error = '';
  int page = 0;
  bool loading = false, loaded = false, hasNextPage = false;
  int ratingFilter = 0;
  bool newestFirst = true, answering = false;
  bool starsOnly = false;
  final Map<String, String> pendingReplies = {};
  Timer? _refreshTimer;
  DateTime? _lastSuccessful;
  bool _autoAttempted = false;

  void _integrationChanged() {
    if (!mounted || _autoAttempted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoLoad());
  }

  void _restoreCache() {
    final c = widget.integration.credentials;
    if (c == null || !c.valid) return;
    final cache = widget.integration.store.read().data['tgoReviewCache'];
    if (cache is! Map ||
        cache['supplierId'] != c.supplierId ||
        cache['storeId'] != storeId.text.trim() ||
        cache['reviews'] is! List) return;
    final cachedRows = (cache['reviews'] as List)
        .whereType<Map>().map((e) => Json.from(e)).toList();
    final pending = cache['pendingReplies'];
    if (pending is Map) {
      pendingReplies.addAll({
        for (final entry in pending.entries)
          if (entry.key is String && entry.value is String)
            (entry.key as String): (entry.value as String),
      });
    }
    setState(() {
      reviews = cachedRows;
      loaded = true;
      page = 0;
      hasNextPage = cache['hasNextPage'] == true;
      _lastSuccessful = DateTime.tryParse('${cache['updatedAt'] ?? ''}');
    });
  }

  void _autoLoad() {
    if (!mounted || _autoAttempted || loading) return;
    final credentials = widget.integration.credentials;
    if (credentials?.valid != true ||
        !RegExp(r'^[0-9]+$').hasMatch(storeId.text.trim())) return;
    _autoAttempted = true;
    _restoreCache();
    unawaited(loadPage(0));
  }

  void _saveCache() {
    final c = widget.integration.credentials;
    if (c == null) return;
    for (var i = 0; i < 3; i++) {
      final snapshot = widget.integration.store.read();
      final next = copyJson(snapshot.data);
      next['tgoReviewStoreId'] = storeId.text.trim();
      next['tgoReviewCache'] = {
        'supplierId': c.supplierId,
        'storeId': storeId.text.trim(),
        'updatedAt': _lastSuccessful?.toUtc().toIso8601String(),
        'reviews': reviews,
        'hasNextPage': hasNextPage,
        'pendingReplies': pendingReplies,
      };
      if (widget.integration.store.replace(next, snapshot.revision).ok) return;
    }
  }

  void _saveStoreId(String id) {
    if (!RegExp(r'^[0-9]{3,12}$').hasMatch(id)) return;
    for (var i = 0; i < 3; i++) {
      final snapshot = widget.integration.store.read();
      if (snapshot.data['tgoReviewStoreId'] == id) return;
      final next = copyJson(snapshot.data);
      next['tgoReviewStoreId'] = id;
      if (widget.integration.store.replace(next, snapshot.revision).ok) return;
    }
  }

  @override
  void initState() {
    super.initState();
    final stores = widget.orders
        .where(
          (order) =>
              order['supplierId'] == widget.integration.credentials?.supplierId,
        )
        .map((order) => '${order['storeId'] ?? ''}')
        .where((id) => id.isNotEmpty)
        .toSet();
    final saved = '${widget.integration.store.read().data['tgoReviewStoreId'] ?? ''}';
    storeId.text = RegExp(r'^[0-9]+$').hasMatch(saved)
        ? saved
        : stores.length == 1 ? stores.single : '316490';
    widget.integration.addListener(_integrationChanged);
    _refreshTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (mounted && _autoAttempted && !loading &&
          widget.integration.credentials?.valid == true) {
        unawaited(loadPage(page));
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoLoad());
  }

  @override
  void dispose() {
    widget.integration.removeListener(_integrationChanged);
    _refreshTimer?.cancel();
    storeId.dispose();
    super.dispose();
  }

  Future<void> loadPage(int index) async {
    if (loading) return;
    setState(() {
      loading = true;
      error = '';
    });
    try {
      final result = await widget.integration.readReviews(
        storeId.text.trim(),
        index,
      );
      if (!mounted) return;
      setState(() {
        reviews = result.reviews;
        hasNextPage = result.hasNextPage;
        page = index;
        loaded = true;
        _lastSuccessful = DateTime.now().toUtc();
        // Only clear a local unverified submission after the platform GET
        // actually includes an answer for that review.
        for (final row in result.reviews) {
          final comment = row['comment'];
          if (comment is Map && comment['restaurantAnswer'] is Map) {
            pendingReplies.remove(row['reviewId'].toString());
          }
        }
      });
      if (index == 0) {
        try { _saveCache(); } catch (_) {
          // Display the last fetched data even when local persistence fails.
        }
      }
    } on FormatException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted)
        setState(() => error = 'Yorumlar alınamadı. Bağlantıyı kontrol edin.');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  /// Real names are shown only when returned by the review API.
  /// An order customer is not necessarily the reviewer, so label separately.
  String? _orderCustomer(Json review) {
    final orderNumber = '${review['orderParentId'] ?? ''}'.trim();
    if (orderNumber.isEmpty) return null;
    final matches = widget.orders.where((order) =>
      order['testPackage'] != true &&
      '${order['orderNumber'] ?? ''}' == orderNumber &&
      '${order['storeId'] ?? ''}' == storeId.text.trim()).toList();
    if (matches.length != 1) return null;
    final name = '${matches.single['customerName'] ?? ''}'.trim();
    return name.isEmpty ? null : name;
  }

  Future<void> _reply(Json review) async {
    final reviewId = '${review['reviewId'] ?? ''}';
    if (reviewId.isEmpty || answering || loading ||
        pendingReplies.containsKey(reviewId)) return;
    final answer = await showDialog<String>(
      context: context,
      builder: (_) => const _TgoReplyDialog(),
    );
    if (!mounted || answer == null) return;
    setState(() { answering = true; error = ''; });
    try {
      await widget.integration.answerReview(
        storeId: storeId.text.trim(),
        reviewId: reviewId,
        text: answer,
      );
      if (!mounted) return;
      // API accepted the submission, but the reply is NOT claimed approved
      // until the subsequent review GET supplies restaurantAnswer.
      setState(() => pendingReplies[reviewId] = answer);
      try { _saveCache(); } catch (_) {}
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(
          'Yanıt isteği gönderildi. Platform onayı kontrol ediliyor.',
        )),
      );
      await loadPage(page);
    } on FormatException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Yanıt gönderilemedi. Partner Paneli’nden kontrol edin.');
      }
    } finally {
      if (mounted) setState(() => answering = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    int scoreOf(Json review) {
      final raw = review['rating'];
      final score = raw is Map ? raw['average'] : null;
      return score is num ? score.round().clamp(1, 5).toInt() : 0;
    }
    final ratings = [for (var score = 5; score >= 1; score--)
      reviews.where((review) => scoreOf(review) == score).length];
    final rated = reviews.where((review) => scoreOf(review) > 0).toList();
    final average = rated.isEmpty
        ? null
        : rated.fold<int>(0, (sum, review) => sum + scoreOf(review)) / rated.length;
    final visible = sortReviewsByDate(
      reviews.where((review) =>
          (ratingFilter == 0 || scoreOf(review) == ratingFilter) &&
          (!starsOnly || !reviewHasWrittenComment(review))),
      newestFirst: newestFirst,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.star_outline, color: NohutBrand.green),
                    const SizedBox(width: 10),
                    Expanded(child: Text('Trendyol Go · Değerlendirmeler',
                        style: Theme.of(context).textTheme.titleLarge)),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Müşteri adları yalnızca API sağlarsa görünür. '
                  'Yanıtlar desteklenen restoranlarda, sizin onayınızla gönderilir.',
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 210,
                      child: TextField(
                        controller: storeId,
                        enabled: !loading,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Şube ID (Store ID)',
                          prefixIcon: Icon(Icons.storefront_outlined),
                        ),
                        onChanged: (value) {
                          setState(() {
                            reviews = []; loaded = false; error = '';
                            ratingFilter = 0; starsOnly = false;
                          });
                          _saveStoreId(value.trim());
                        },
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: 'Yenile',
                      onPressed: loading ? null : () => loadPage(0),
                      icon: const Icon(Icons.refresh),
                    ),
                    if (_lastSuccessful != null)
                      Text(
                        'Son güncelleme: ${_lastSuccessful!.toLocal().toString().split('.').first}',
                        style: const TextStyle(color: NohutBrand.muted, fontSize: 11),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (loading) const LinearProgressIndicator(),
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(10),
            child: Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        if (loaded) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                alignment: WrapAlignment.start,
                spacing: 28,
                runSpacing: 18,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(average == null ? '—' : average.toStringAsFixed(1),
                          style: const TextStyle(color: NohutBrand.green,
                              fontWeight: FontWeight.w800, fontSize: 35)),
                      const Text('★ ★ ★ ★ ★', style: TextStyle(color: NohutBrand.gold)),
                      Text('${reviews.length} yorum · Sayfa ${page + 1}',
                          style: const TextStyle(fontSize: 12, color: NohutBrand.muted)),
                    ],
                  ),
                  SizedBox(
                    width: 240,
                    child: Column(
                      children: [
                        for (var i = 0; i < 5; i++)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              children: [
                                SizedBox(width: 35, child: Text('${5-i} ★')),
                                Expanded(
                                  child: LinearProgressIndicator(
                                    value: reviews.isEmpty ? 0 : ratings[i] / reviews.length,
                                    minHeight: 7,
                                    borderRadius: BorderRadius.circular(8),
                                    color: NohutBrand.gold,
                                    backgroundColor: const Color(0xffECEFE9),
                                  ),
                                ),
                                SizedBox(width: 30,
                                    child: Text('${ratings[i]}', textAlign: TextAlign.end)),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  const Text('Özet yalnızca yüklenen sayfaya aittir.',
                    style: TextStyle(color: NohutBrand.muted, fontSize: 12)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final star in [0, 5, 4, 3, 2, 1])
                ChoiceChip(
                  showCheckmark: false,
                  label: Text(
                    star == 0 ? 'Tüm Yorumlar' : '$star ★',
                    style: TextStyle(
                      color: ratingFilter == star
                          ? Colors.white : NohutBrand.ink,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  selectedColor: NohutBrand.green,
                  backgroundColor: Colors.white,
                  selected: ratingFilter == star,
                  onSelected: (_) => setState(() => ratingFilter = star),
                ),
              FilterChip(
                label: const Text('Sadece puan'),
                selected: starsOnly,
                showCheckmark: false,
                selectedColor: NohutBrand.green,
                labelStyle: TextStyle(
                  color: starsOnly ? Colors.white : NohutBrand.ink,
                  fontWeight: FontWeight.w600,
                ),
                onSelected: (v) => setState(() => starsOnly = v),
              ),
              const SizedBox(width: 8),
              DropdownButton<bool>(
                value: newestFirst,
                items: const [
                  DropdownMenuItem(
                    value: true, child: Text('Yeni → Eski')),
                  DropdownMenuItem(
                    value: false, child: Text('Eski → Yeni')),
                ],
                onChanged: loading ? null : (value) =>
                    setState(() => newestFirst = value ?? true),
              ),
              const Text('Sıralama: yüklenen sayfa',
                style: TextStyle(color: NohutBrand.muted, fontSize: 11)),
            ],
          ),
          const SizedBox(height: 10),
          if (visible.isEmpty)
            const Card(child: ListTile(leading: Icon(Icons.inbox_outlined),
                title: Text('Bu filtrede değerlendirme yok.'))),
          for (final review in visible) _reviewTile(review),
          if (page > 0 || hasNextPage)
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: loading || page == 0 ? null : () => loadPage(page - 1),
                  child: const Text('Önceki'),
                ),
                TextButton(
                  onPressed: loading || !hasNextPage
                      ? null : () => loadPage(page + 1),
                  child: const Text('Sonraki'),
                ),
              ],
            ),
        ],
      ],
    );
  }

  Widget _reviewTile(Json review) {
    final rating = review['rating'];
    final comment = review['comment'];
    final score = rating is Map ? rating['average'] : null;
    final text = comment is Map ? comment['text'] : null;
    final answer = comment is Map && comment['restaurantAnswer'] is Map
        ? comment['restaurantAnswer'] as Map : null;
    final reviewId = (review['reviewId'] ?? '').toString();
    final pending = pendingReplies[reviewId];
    final customer = reviewCustomerName(review);
    final orderCustomer = customer == null ? _orderCustomer(review) : null;
    final orderNumber = (review['orderParentId'] ?? '').toString();
    final rejected = answer?['rejectedReason'];
    final reason = rejected is Map
        ? (rejected['reason'] ?? '').toString() : null;
    return CompactReviewCard(
      key: ValueKey('tgo-review-' + reviewId),
      platform: 'Trendyol Go',
      score: score is num ? score : null,
      customerName: customer,
      dateLabel: reviewDateText(review['createdDate']) + ' · ' +
          reviewRelativeAge(review['createdDate']),
      comment: text is String ? text : null,
      orderNumber: orderNumber.isEmpty ? null : orderNumber,
      orderDate: review['orderCreatedDate'] == null
          ? null : reviewDateText(review['orderCreatedDate']),
      orderCustomer: orderCustomer,
      products: reviewProductNames(review),
      answerText: answer?['text'] is String
          ? answer!['text'] as String : pending,
      answerStatus: answer?['status']?.toString(),
      rejectedReason: reason,
      awaitingVerification: pending != null && answer == null,
      replyBusy: answering || loading,
      onReply: reviewId.isNotEmpty && answer == null && pending == null &&
              text is String && text.trim().isNotEmpty
          ? () => _reply(review) : null,
    );
  }

}


class _TgoReplyDialog extends StatefulWidget {
  const _TgoReplyDialog();

  @override
  State<_TgoReplyDialog> createState() => _TgoReplyDialogState();
}

class _TgoReplyDialogState extends State<_TgoReplyDialog> {
  final controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    controller.addListener(_refresh);
  }

  void _refresh() => setState(() {});

  @override
  void dispose() {
    controller.removeListener(_refresh);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Trendyol Go · Yoruma Yanıt Ver'),
    content: SizedBox(
      width: 470,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Bu yanıt platformda herkese açık olur. '
            'Uber Eats’e geçmiş restoranlarda API yanıtı reddedebilir.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            autofocus: true,
            maxLength: 500,
            maxLines: 5,
            decoration: const InputDecoration(
              hintText: 'Müşteriye yanıtınızı yazın…',
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Vazgeç'),
      ),
      FilledButton(
        onPressed: controller.text.trim().isEmpty
            ? null : () => Navigator.pop(context, controller.text.trim()),
        child: const Text('Yanıtı Gönder'),
      ),
    ],
  );
}
