/// Platform Yönetimi (owner decision #7236316817): a standalone page, apart
/// from Online Siparişler, plus the compact Ana Sayfa quick widget
/// (#7236345438). Both read the same [PlatformControl] and use the same
/// confirmation and the same enable rule from `PlatformCard`.
library;

import 'package:flutter/material.dart';
import 'package:nohut_core/platform_status.dart';

import 'brand.dart';
import 'operations_ui.dart' show confirmAction;
import 'platform_management.dart';

Color _pillColor(String label, ColorScheme s) => switch (label) {
  'Açık' => const Color(0xff2E7D4F),
  'Kapalı' => const Color(0xffB3261E),
  'İşleniyor' || 'Doğrulanıyor' => const Color(0xffA66A00),
  _ => s.outline,
};

class PlatformStatusPill extends StatelessWidget {
  const PlatformStatusPill(this.label, {super.key});
  final String label;
  @override
  Widget build(BuildContext context) {
    final c = _pillColor(label, Theme.of(context).colorScheme);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(99), border: Border.all(color: c.withValues(alpha: 0.35))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: c, fontWeight: FontWeight.w800, fontSize: 12.5)),
      ]),
    );
  }
}

/// Shared confirm + command for both surfaces.
Future<String?> confirmStoreToggle(BuildContext context, PlatformControl control, PlatformCard card) async {
  final target = card.toggleTarget;
  if (target == null) return null;
  final open = target == PlatformWorking.open;
  final ok = await confirmAction(context,
      '${card.displayName}: restoranı ${open ? 'aç' : 'kapat'}?',
      open
          ? 'Restoran ${card.displayName} üzerinde yeniden sipariş almaya başlar.'
          : 'Yeni sipariş gelmez. Mevcut ve hazırlanan siparişler etkilenmez, iptal edilmez.',
      confirm: open ? 'Evet, aç' : 'Evet, kapat');
  if (!ok) return null;
  try {
    await control.setStoreStatus(card.provider, target, expected: card.working);
    return 'İstek gönderildi. Sonuç platformdan doğrulanınca görünecek.';
  } on PlatformUnavailable catch (e) {
    return e.message;
  }
}

mixin _PlatformLoader<T extends StatefulWidget> on State<T> {
  PlatformControl get control;
  List<PlatformCard> cards = PlatformCard.completeSet(const []);
  bool loading = true;
  String message = '';

  Future<void> reload() async {
    setState(() => loading = true);
    try {
      final next = await control.load();
      if (mounted) setState(() => cards = PlatformCard.completeSet(next));
    } catch (_) {
      if (mounted) setState(() => message = 'Platform durumu okunamadı.');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> toggle(PlatformCard card) async {
    final result = await confirmStoreToggle(context, control, card);
    if (result == null || !mounted) return;
    setState(() => message = result);
    await reload();
  }
}

class PlatformManagementPage extends StatefulWidget {
  const PlatformManagementPage({super.key, required this.control, this.granted = true, DateTime Function()? now})
      : now = now ?? DateTime.now;
  final PlatformControl control;

  /// `platform.store.toggle` for the signed-in person (Windows: owner).
  final bool granted;
  final DateTime Function() now;
  @override
  State<PlatformManagementPage> createState() => _PlatformManagementPageState();
}

class _PlatformManagementPageState extends State<PlatformManagementPage>
    with _PlatformLoader<PlatformManagementPage> {
  @override
  PlatformControl get control => widget.control;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Widget _section(String title, IconData icon, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, size: 17, color: NohutBrand.muted),
        const SizedBox(width: 6),
        Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
      ]),
      const SizedBox(height: 6),
      ...children,
    ]),
  );

  Widget _muted(String text) => Text(text, style: const TextStyle(color: NohutBrand.muted, fontSize: 12.5));

  Widget _card(PlatformCard c) {
    final now = widget.now();
    final label = c.statusLabel(now);
    final blocked = c.toggleBlockedReason(now, granted: widget.granted);
    final target = c.toggleTarget;
    return Card(
      key: ValueKey('platform-card-${c.provider}'),
      child: Padding(padding: const EdgeInsets.all(16), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(c.displayName, style: const TextStyle(
              fontFamily: NohutBrand.headingFont, fontSize: 19, color: NohutBrand.ink))),
          Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight,
              child: PlatformStatusPill(label, key: ValueKey('platform-status-${c.provider}')))),
        ]),
        const SizedBox(height: 6),
        _muted(c.verifiedStoreName == null
            ? 'Mağaza doğrulanmadı'
            : '${c.verifiedStoreName} · ${c.verifiedStoreId}'),
        _muted(c.connection == PlatformConnection.connected ? platformVerifiedText(c.lastVerifiedAt) : (c.note ?? '')),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            key: ValueKey('platform-toggle-${c.provider}'),
            onPressed: blocked == null ? () => toggle(c) : null,
            icon: Icon(target == PlatformWorking.open ? Icons.storefront : Icons.store_mall_directory_outlined),
            label: Text(target == PlatformWorking.open ? 'Aç' : target == PlatformWorking.closed ? 'Kapat' : 'Aç / Kapat')),
          OutlinedButton.icon(
            key: ValueKey('platform-refresh-${c.provider}'),
            onPressed: c.connection == PlatformConnection.connected && !loading
                ? () async { await control.refresh(c.provider); await reload(); } : null,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Yenile')),
        ]),
        if (blocked != null && c.connection == PlatformConnection.connected)
          Padding(padding: const EdgeInsets.only(top: 6), child: _muted(blocked)),
        _section('Çalışma Saatleri', Icons.schedule_outlined, [
          if (c.workingHours.isEmpty) _muted('Platformdan doğrulanmış çalışma saati yok.')
          else for (final h in c.workingHours)
            _muted('${platformDayName(h.dayOfWeek)}  ${h.opening} – ${h.closing}'),
        ]),
        _section('Ürün/Kategori Durumu', Icons.inventory_2_outlined, [
          _muted(c.canToggleCatalog
              ? 'Ürün ve kategori açma/kapatma ayrı yetkiyle yapılır.'
              : 'Henüz bağlı değil. POS ve QR menü bundan etkilenmez.'),
        ]),
        _section('İşlem Geçmişi', Icons.history, [
          if (c.audit.isEmpty) _muted('Henüz işlem yok.')
          else for (final a in c.audit.take(5))
            _muted('${a.at} · ${a.actor} · ${platformStatusWord(a.oldStatus)} › ${platformStatusWord(a.newStatus)} · ${platformOutcomeWord(a.outcome)}'),
        ]),
      ])),
    );
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    // The window header already names this page.
    Row(children: [
      const Expanded(child: Text('Restoranın online platformlardaki açık/kapalı durumu, çalışma saatleri ve işlem geçmişi. '
          'Siparişler Online Siparişler sayfasında kalır.', style: TextStyle(color: NohutBrand.muted))),
      if (loading) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
    ]),
    if (message.isNotEmpty)
      Padding(padding: const EdgeInsets.only(top: 10), child: Text(message,
          key: const ValueKey('platform-message'), style: const TextStyle(fontWeight: FontWeight.w700))),
    const SizedBox(height: 14),
    LayoutBuilder(builder: (context, box) {
      final cols = box.maxWidth >= 1050 ? 3 : box.maxWidth >= 680 ? 2 : 1;
      final w = (box.maxWidth - 12 * (cols - 1)) / cols;
      return Wrap(spacing: 12, runSpacing: 12, children: [
        for (final c in cards) SizedBox(width: w, child: _card(c)),
      ]);
    }),
  ]);
}

/// Ana Sayfa: three compact rows, same rule and command as the page.
class PlatformQuickPanel extends StatefulWidget {
  const PlatformQuickPanel({super.key, required this.control, required this.onOpenPage,
      this.granted = true, DateTime Function()? now})
      : now = now ?? DateTime.now;
  final PlatformControl control;
  final VoidCallback onOpenPage;
  final bool granted;
  final DateTime Function() now;
  @override
  State<PlatformQuickPanel> createState() => _PlatformQuickPanelState();
}

class _PlatformQuickPanelState extends State<PlatformQuickPanel> with _PlatformLoader<PlatformQuickPanel> {
  @override
  PlatformControl get control => widget.control;

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.now();
    return Card(
      key: const ValueKey('platform-quick'),
      child: Padding(padding: const EdgeInsets.fromLTRB(14, 12, 8, 8), child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Expanded(child: Text('Platformlar', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
          Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: TextButton(key: const ValueKey('platform-quick-open'), onPressed: widget.onOpenPage,
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Text('Platform Yönetimi'), SizedBox(width: 2), Icon(Icons.chevron_right, size: 18)])))),
        ]),
        for (final c in cards)
          Padding(
            key: ValueKey('platform-quick-${c.provider}'),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Expanded(flex: 2, child: Text(c.displayName, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600))),
              Flexible(flex: 2, child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight,
                  child: PlatformStatusPill(c.statusLabel(now)))),
              const SizedBox(width: 8),
              SizedBox(width: 96, child: Tooltip(
                message: c.toggleBlockedReason(now, granted: widget.granted) ?? '',
                child: TextButton(
                  key: ValueKey('platform-quick-toggle-${c.provider}'),
                  onPressed: c.toggleBlockedReason(now, granted: widget.granted) == null ? () => toggle(c) : null,
                  child: Text(c.toggleTarget == PlatformWorking.open ? 'Aç'
                      : c.toggleTarget == PlatformWorking.closed ? 'Kapat' : 'Aç/Kapat')),
              )),
            ]),
          ),
        if (message.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 4, right: 6), child: Text(message,
              style: const TextStyle(fontSize: 12.5, color: NohutBrand.muted))),
      ])),
    );
  }
}
