import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'brand.dart';
import 'pos_logic.dart';
import 'order_reporting.dart';
import 'compact_review_card.dart';
import 'review_display.dart';
import 'review_repository.dart';
import 'review_sync_service.dart';
import 'tgo_review_api.dart';
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
    this.onReprint,
    this.onAction,
    this.canWrite = false,
    this.now,
  });
  final Json order;
  /// Clock for the waiting badge; defaults to DateTime.now().
  final DateTime? now;
  /// Re-queues a ticket whose earlier send needs checking.
  final VoidCallback? onReprint;
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
                          if (line['removed'] case final List removed
                              when removed.isNotEmpty)
                            Text(
                              'Çıkar: ${removed.join(', ')}',
                              style: const TextStyle(fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: Color(0xffB3261E)),
                            ),
                          if (line['extras'] case final List extras
                              when extras.isNotEmpty)
                            Text(
                              'Ekstra: ${extras.join(', ')}',
                              style: const TextStyle(fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: Color(0xff2E7D4F)),
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
                child: Row(
                  children: [
                    Icon(
                      printState == 'Kontrol gerekli'
                          ? Icons.warning_amber_rounded
                          : Icons.print_outlined,
                      size: 15,
                      color: printState == 'Kontrol gerekli'
                          ? const Color(0xffB3261E) : NohutBrand.muted,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'Sipariş fişi · $printState',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    if (printState == 'Kontrol gerekli' && onReprint != null)
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact),
                        onPressed: onReprint,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('Fişi Tekrar Yazdır'),
                      ),
                  ],
                ),
              )
            else if (tgoKitchenActive(order) && status == 'Created')
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Sipariş fişi Kabul Et ile otomatik yazdırılır.',
                  style: theme.textTheme.bodySmall,
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
            if (customer.isNotEmpty || contact.isNotEmpty || address.isNotEmpty)
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
    required this.reviewSync,
  });

  final TrendyolGoReadonly integration;
  final ReviewSyncService reviewSync;
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
            integration: widget.integration,
            reviewSync: widget.reviewSync,
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

/// Trendyol Go reviews from the persistent repository (spec §23.6).
/// Data comes from [ReviewSyncService], which runs in the background on
/// every screen; this widget only displays, filters and acts. No Store ID
/// entry: the store is verified automatically (selector only when the
/// supplier has several official stores).
class TgoReviewsPanel extends StatefulWidget {
  const TgoReviewsPanel({
    super.key,
    required this.integration,
    required this.reviewSync,
  });

  final TrendyolGoReadonly integration;
  final ReviewSyncService reviewSync;

  @override
  State<TgoReviewsPanel> createState() => _TgoReviewsPanelState();
}

class _TgoReviewsPanelState extends State<TgoReviewsPanel> {
  int ratingFilter = 0;
  bool newestFirst = true, unreadOnly = false;
  bool? withText;
  ReplyFilter replyFilter = ReplyFilter.any;
  String search = '';
  int visibleCount = 30;
  final Set<String> busy = {};

  @override
  void initState() {
    super.initState();
    widget.reviewSync.addListener(_changed);
  }

  @override
  void dispose() {
    widget.reviewSync.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  static const partnerPanel = 'https://partner.tgoyemek.com';

  Future<void> _reply(Json review) async {
    final key = reviewKey(review);
    if (busy.contains(key)) return;
    final draft = await showDialog<String>(
      context: context,
      builder: (_) => const _TgoReplyDialog(),
    );
    if (!mounted || draft == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Yanıt önizleme'),
        content: SizedBox(width: 460, child: Text(draft)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Düzenle / Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('Herkese açık gönder')),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    String nowIso() => DateTime.now().toUtc().toIso8601String();
    setState(() => busy.add(key));
    // Persist BEFORE the request: a crash mid-request leaves "sending",
    // which is shown as an uncertain outcome and never re-sent automatically.
    widget.reviewSync.updateReview(key, (row) => row['replyDraft'] = {
      'text': draft, 'state': 'sending', 'updatedAt': nowIso()});
    String state, message;
    String? errorText;
    try {
      await widget.integration.answerReview(
        storeId: '${review['storeId']}',
        reviewId: '${review['reviewId']}',
        text: draft,
      );
      state = 'submitted';
      message = 'Yanıt gönderildi. Yayın, platform onayından sonra görünecek.';
    } on FormatException catch (e) {
      // The platform answered with a definite refusal.
      state = 'failed';
      errorText = e.message;
      message = e.message;
    } catch (_) {
      // Timeout / connection loss: outcome unknown. Never auto-resend.
      state = 'unknown';
      message = 'Yanıtın sonucu belirsiz. Tekrar göndermeden önce '
          'Partner Paneli’nden kontrol edin; otomatik eşitleme de doğrulayacak.';
    }
    widget.reviewSync.updateReview(key, (row) => row['replyDraft'] = {
      'text': draft, 'state': state, 'updatedAt': nowIso(),
      if (errorText != null) 'error': errorText});
    if (!mounted) return;
    setState(() => busy.remove(key));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    if (state == 'submitted') unawaited(widget.reviewSync.syncNow(manual: true));
  }

  Widget _diagnostics(Json st) {
    final theme = Theme.of(context);
    final state = '${st['state'] ?? ''}';
    final latest = DateTime.tryParse('${st['latestReviewAt'] ?? ''}');
    final lastOk = DateTime.tryParse('${st['lastSuccessAt'] ?? ''}');
    final stale = latest != null &&
        DateTime.now().toUtc().difference(latest) > const Duration(days: 21);
    String label(String k) => switch (k) {
      'ok' => 'Çalışıyor',
      'migrated' => 'Uber Eats geçişi: yorum servisi kapalı',
      'identity' => 'Şube doğrulanamadı',
      'error' => 'Son eşitleme başarısız',
      'disabled' => 'API bilgileri yok',
      _ => 'Bekleniyor',
    };
    Widget row(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 190, child: Text(k, style: const TextStyle(color: NohutBrand.muted))),
        Expanded(child: SelectableText(v)),
      ]),
    );
    final supplier = '${st['supplierId'] ?? ''}';
    final masked = supplier.length > 2
        ? '${'•' * (supplier.length - 2)}${supplier.substring(supplier.length - 2)}'
        : supplier;
    final warnings = (st['identityWarnings'] as List? ?? const []).map((e) => '$e');
    final candidates = [
      for (final c in (st['candidates'] as List? ?? const []))
        if (c is Map) TgoStore(id: '${c['id']}', name: '${c['name'] ?? ''}'),
    ];
    return Card(
      child: ExpansionTile(
        initiallyExpanded: state != 'ok' || stale,
        leading: Icon(state == 'ok' && !stale ? Icons.verified_outlined : Icons.warning_amber,
            color: state == 'ok' && !stale ? NohutBrand.green : theme.colorScheme.error),
        title: Text('Entegrasyon durumu · ${label(state)}'),
        subtitle: Text(lastOk == null ? 'Henüz başarılı eşitleme yok'
            : 'Son başarılı eşitleme: ${reviewDateText(lastOk.toIso8601String())}'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        children: [
          row('Satıcı ID', masked.isEmpty ? '—' : masked),
          row('Doğrulanmış şube', '${st['storeId'] ?? '—'}'
              '${'${st['storeName'] ?? ''}'.isEmpty ? '' : ' · ${st['storeName']}'}'),
          row('Şube doğrulama', '${st['identityState'] ?? '—'} (liste: ${st['discovery'] ?? '—'})'),
          row('Yorum API', '${st['apiAvailability'] ?? '—'}'),
          row('Son deneme', reviewDateText(st['lastAttemptAt'])),
          row('En yeni yorum', latest == null ? '—' : reviewDateText(st['latestReviewAt'])),
          row('Alınan kayıt / sayfa', '${st['retrieved'] ?? 0} / ${st['pages'] ?? 0}'
              '${st['pagesComplete'] == false ? ' (eksik: sayfa sınırı)' : ''}'),
          row('Yeni / güncellenen', '${st['newReviews'] ?? 0} / ${st['updatedReviews'] ?? 0}'),
          if ('${st['error'] ?? ''}'.isNotEmpty) row('Hata', '${st['error']}'),
          for (final w in warnings) row('Uyarı', w),
          if (stale)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Dikkat: en yeni yorum ${reviewRelativeAge(st['latestReviewAt'])} '
                  'tarihli. Yeni yorum yoksa normaldir; şube veya API sorununu da gösterebilir.',
                  style: TextStyle(color: theme.colorScheme.error)),
            ),
          if (state == 'migrated')
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: SelectableText('Restoranınız Uber Eats altyapısına geçtiği için Trendyol '
                  'yorum servisi bu şube için kapatılmış (resmi doküman: 403 / 404). Yorumları '
                  'Partner Paneli’nden görüntüleyin: $partnerPanel'),
            ),
          if (st['identityState'] == 'needsSelection' && candidates.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('Birden fazla resmi şube var. Yorumları alınacak şubeyi seçin:'),
            Wrap(spacing: 8, children: [
              for (final c in candidates)
                OutlinedButton(
                  onPressed: () => unawaited(widget.reviewSync.selectStore(c)),
                  child: Text('${c.id}${c.name.isEmpty ? '' : ' · ${c.name}'}'
                      '${st['suggestedStoreId'] == c.id ? ' (siparişlerle eşleşiyor)' : ''}'),
                ),
            ]),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: widget.reviewSync.running ? null
                  : () => unawaited(widget.reviewSync.syncNow(manual: true)),
              icon: const Icon(Icons.refresh),
              label: const Text('Şimdi yenile'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.reviewSync.store.read().data;
    final st = data[reviewSyncStateKey] is Map
        ? Json.from(data[reviewSyncStateKey] as Map) : <String, dynamic>{};
    final storeId = st['storeId'] == null ? null : '${st['storeId']}';
    final all = [
      for (final r in (data[reviewRowsStateKey] as List? ?? const []))
        if (r is Map && r['platform'] == tgoPlatform &&
            (storeId == null || r['storeId'] == storeId)) Json.from(r),
    ];
    final stats = reviewStats(all);
    final visible = queryReviews(all, ReviewQuery(
      stars: ratingFilter == 0 ? null : ratingFilter,
      newestFirst: newestFirst, unreadOnly: unreadOnly, withText: withText,
      reply: replyFilter, search: search,
    ));
    final shown = visible.take(visibleCount).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.star_outline, color: NohutBrand.green),
                const SizedBox(width: 10),
                Expanded(child: Text('Trendyol Go · Değerlendirmeler',
                    style: Theme.of(context).textTheme.titleLarge)),
                if (widget.reviewSync.running)
                  const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2)),
              ]),
              const SizedBox(height: 6),
              const Text('Yorumlar arka planda otomatik eşitlenir ve bu bilgisayarda saklanır. '
                  'Yanıtlar yalnızca sizin onayınızla gönderilir.'),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        _diagnostics(st),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(spacing: 28, runSpacing: 18,
                crossAxisAlignment: WrapCrossAlignment.center, children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(stats.average10 == null ? '—' : (stats.average10! / 10).toStringAsFixed(1),
                    style: const TextStyle(color: NohutBrand.green,
                        fontWeight: FontWeight.w800, fontSize: 35)),
                const Text('★ ★ ★ ★ ★', style: TextStyle(color: NohutBrand.gold)),
                Text('${stats.total} yorum · ${stats.unread} okunmamış',
                    style: const TextStyle(fontSize: 12, color: NohutBrand.muted)),
              ]),
              SizedBox(width: 240, child: Column(children: [
                for (var star = 5; star >= 1; star--)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      SizedBox(width: 35, child: Text('$star ★')),
                      Expanded(child: LinearProgressIndicator(
                        value: stats.total == 0 ? 0 : stats.distribution[star]! / stats.total,
                        minHeight: 7, borderRadius: BorderRadius.circular(8),
                        color: NohutBrand.gold, backgroundColor: const Color(0xffECEFE9))),
                      SizedBox(width: 30, child: Text('${stats.distribution[star]}',
                          textAlign: TextAlign.end)),
                    ]),
                  ),
              ])),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Yanıt bekleyen: ${stats.waiting}'),
                Text('Onay bekleyen: ${stats.pendingApproval}'),
                Text('Yanıtlanan: ${stats.answered}'),
                Text('Reddedilen yanıt: ${stats.rejected}'),
              ]),
              const Text('Özet bu bilgisayarda eşitlenmiş yorumlardan hesaplanır;\n'
                  'platformun resmi genel puanı değildir.',
                  style: TextStyle(color: NohutBrand.muted, fontSize: 12)),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final star in [0, 5, 4, 3, 2, 1])
            ChoiceChip(
              showCheckmark: false,
              label: Text(star == 0 ? 'Tüm Yorumlar' : '$star ★'),
              selected: ratingFilter == star,
              onSelected: (_) => setState(() => ratingFilter = star),
            ),
          FilterChip(label: const Text('Okunmamış'), selected: unreadOnly,
              onSelected: (v) => setState(() => unreadOnly = v)),
          FilterChip(label: const Text('Yazılı yorum'), selected: withText == true,
              onSelected: (v) => setState(() => withText = v ? true : null)),
          FilterChip(label: const Text('Sadece puan'), selected: withText == false,
              onSelected: (v) => setState(() => withText = v ? false : null)),
          DropdownButton<ReplyFilter>(
            value: replyFilter,
            items: const [
              DropdownMenuItem(value: ReplyFilter.any, child: Text('Tüm yanıt durumları')),
              DropdownMenuItem(value: ReplyFilter.waiting, child: Text('Yanıt bekleyen')),
              DropdownMenuItem(value: ReplyFilter.pendingApproval, child: Text('Onay bekleyen')),
              DropdownMenuItem(value: ReplyFilter.answered, child: Text('Yanıtlanan')),
              DropdownMenuItem(value: ReplyFilter.rejected, child: Text('Reddedilen')),
            ],
            onChanged: (v) => setState(() => replyFilter = v ?? ReplyFilter.any),
          ),
          DropdownButton<bool>(
            value: newestFirst,
            items: const [
              DropdownMenuItem(value: true, child: Text('Yeni → Eski')),
              DropdownMenuItem(value: false, child: Text('Eski → Yeni')),
            ],
            onChanged: (v) => setState(() => newestFirst = v ?? true),
          ),
          SizedBox(width: 220, child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Yorumlarda ara'),
            onChanged: (v) => setState(() => search = v),
          )),
          if (stats.unread > 0)
            TextButton(
              onPressed: () => widget.reviewSync.markRead({for (final r in all) reviewKey(r)}),
              child: const Text('Tümünü okundu işaretle'),
            ),
        ]),
        const SizedBox(height: 10),
        if (shown.isEmpty)
          Card(child: ListTile(leading: const Icon(Icons.inbox_outlined),
              title: Text(all.isEmpty ? 'Henüz eşitlenmiş yorum yok.' : 'Bu filtrede değerlendirme yok.'))),
        for (final review in shown) _reviewTile(review),
        if (visible.length > shown.length)
          TextButton(
            onPressed: () => setState(() => visibleCount += 30),
            child: Text('Daha fazla göster (${visible.length - shown.length})'),
          ),
      ],
    );
  }

  Widget _reviewTile(Json review) {
    final key = reviewKey(review);
    final reply = review['reply'] is Map ? review['reply'] as Map : null;
    final draft = review['replyDraft'] is Map ? review['replyDraft'] as Map : null;
    final draftState = '${draft?['state'] ?? ''}';
    final stars = reviewStars10(review);
    final text = '${review['comment'] ?? ''}';
    final uncertain = draftState == 'unknown' || draftState == 'sending';
    final canReply = reply == null && text.trim().isNotEmpty &&
        (draft == null || draftState == 'failed') && !busy.contains(key);
    final card = CompactReviewCard(
      key: ValueKey('tgo-review-$key'),
      platform: 'Trendyol Go',
      score: stars == null ? null : stars / 10,
      dateLabel: '${reviewDateText(review['createdAt'])} · ${reviewRelativeAge(review['createdAt'])}',
      comment: text.isEmpty ? null : text,
      orderNumber: review['orderNumber'] == null ? null : '${review['orderNumber']}',
      orderDate: review['orderCreatedAt'] == null ? null : reviewDateText(review['orderCreatedAt']),
      products: [for (final p in (review['products'] as List? ?? const [])) '$p'],
      answerText: reply?['text'] is String ? reply!['text'] as String
          : draft?['text'] is String && draftState != 'failed' ? draft!['text'] as String : null,
      answerStatus: reply?['status']?.toString(),
      rejectedReason: reply?['rejectedReason']?.toString(),
      awaitingVerification: reply == null && (draftState == 'submitted' || uncertain),
      replyBusy: busy.contains(key),
      onReply: canReply ? () => _reply(review) : null,
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      card,
      Row(children: [
        if (review['read'] != true)
          TextButton.icon(
            onPressed: () => widget.reviewSync.markRead({key}),
            icon: const Icon(Icons.mark_email_read_outlined, size: 18),
            label: const Text('Okundu İşaretle'),
          ),
        if (uncertain)
          const Expanded(child: Text('Yanıt sonucu belirsiz: otomatik tekrar gönderilmez. '
              'Partner Paneli’nden kontrol edin.', style: TextStyle(color: NohutBrand.muted, fontSize: 12))),
        if (draftState == 'failed')
          Expanded(child: Text('Yanıt reddedildi: ${draft?['error'] ?? ''}',
              style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12))),
      ]),
    ]);
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
