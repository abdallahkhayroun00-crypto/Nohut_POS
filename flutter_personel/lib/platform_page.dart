/// Platform Yönetimi on the native Yönetici app (Daha Fazla) and its Ana
/// Sayfa quick card. The cards come from Windows (`ownerPlatforms`), built
/// by the same [PlatformCard] model the Windows page uses, so labels and the
/// enabled/disabled decision are identical. One confirmed command per tap;
/// the answer is shown, never retried.
library;

import 'package:flutter/material.dart';
import 'package:nohut_core/platform_status.dart';

import 'style.dart';

typedef PlatformRequest = Future<Map<String, dynamic>> Function(Map<String, dynamic> payload);

class PlatformSnapshot {
  const PlatformSnapshot(this.cards, {required this.canToggle});
  final List<PlatformCard> cards;

  /// `platform.store.toggle` for the signed-in person, decided by Windows.
  final bool canToggle;
}

/// Where the phone reads and sends. Windows checks permission again.
abstract class PlatformSource {
  Future<PlatformSnapshot> load();

  /// Null on success, otherwise the reason shown.
  Future<String?> command(Map<String, dynamic> body);
}

/// The paired owner channel to Windows.
class OwnerPlatformSource implements PlatformSource {
  OwnerPlatformSource(this.request);
  final PlatformRequest request;

  @override
  Future<PlatformSnapshot> load() async {
    final r = await request({'operation': 'ownerPlatforms'});
    final raw = r['cards'] is List ? r['cards'] as List : const [];
    return PlatformSnapshot(
      PlatformCard.completeSet([for (final c in raw) if (c is Map) PlatformCard.fromJson(c)]),
      canToggle: r['canToggle'] == true,
    );
  }

  @override
  Future<String?> command(Map<String, dynamic> body) async {
    final r = await request({'operation': 'ownerPlatform', 'data': body});
    return r['ok'] == true ? null : '${r['message'] ?? 'İstek doğrulanamadı.'}';
  }
}

Color _tone(String label, BuildContext context) => switch (label) {
  'Açık' => context.nohut.success,
  'Kapalı' => context.nohut.danger,
  'İşleniyor' || 'Doğrulanıyor' => context.nohut.warning,
  _ => context.nohut.muted,
};

class PlatformStatusChip extends StatelessWidget {
  const PlatformStatusChip(this.label, {super.key});
  final String label;
  @override
  Widget build(BuildContext context) {
    final c = _tone(label, context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(99),
          border: Border.all(color: c.withValues(alpha: 0.35))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: c, fontWeight: FontWeight.w800, fontSize: 12.5)),
      ]),
    );
  }
}

String _toggleText(PlatformCard c) => switch (c.toggleTarget) {
  PlatformWorking.open => 'Aç',
  PlatformWorking.closed => 'Kapat',
  _ => 'Aç / Kapat',
};

mixin _Loader<T extends StatefulWidget> on State<T> {
  PlatformSource get source;
  bool get offline;
  PlatformSnapshot snap = PlatformSnapshot(PlatformCard.completeSet(const []), canToggle: false);
  bool loading = true;
  String message = '';

  Future<void> reload() async {
    setState(() => loading = true);
    try {
      final next = await source.load();
      if (mounted) setState(() => snap = next);
    } catch (_) {
      if (mounted) setState(() => message = 'Platform durumu Windows’tan okunamadı.');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  String? blocked(PlatformCard c, DateTime now) =>
      offline ? 'Windows bağlantısı yok.' : c.toggleBlockedReason(now, granted: snap.canToggle);

  Future<void> toggle(PlatformCard card) async {
    final target = card.toggleTarget;
    if (target == null) return;
    final open = target == PlatformWorking.open;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text('${card.displayName}: restoranı ${open ? 'aç' : 'kapat'}?'),
      content: Text(open
          ? 'Restoran ${card.displayName} üzerinde yeniden sipariş almaya başlar.'
          : 'Yeni sipariş gelmez. Mevcut ve hazırlanan siparişler etkilenmez, iptal edilmez.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
        FilledButton(key: const ValueKey('platform-confirm'), onPressed: () => Navigator.pop(ctx, true),
            child: Text(open ? 'Evet, aç' : 'Evet, kapat')),
      ]));
    if (ok != true || !mounted) return;
    String? error;
    try {
      error = await source.command({'action': 'store', 'provider': card.provider,
        'target': PlatformCard.workingWire(target), 'expected': PlatformCard.workingWire(card.working),
        'confirmed': true});
    } catch (_) {
      error = 'İstek doğrulanamadı. Durumu Yenile ile kontrol edin; tekrar göndermeyin.';
    }
    if (!mounted) return;
    setState(() => message = error ?? 'İstek gönderildi. Sonuç platformdan doğrulanınca görünecek.');
    await reload();
  }

  Future<void> refresh(PlatformCard c) async {
    try {
      final error = await source.command({'action': 'refresh', 'provider': c.provider});
      if (error != null && mounted) setState(() => message = error);
    } catch (_) {
      if (mounted) setState(() => message = 'Yenilenemedi.');
    }
    await reload();
  }
}

class PlatformPage extends StatefulWidget {
  const PlatformPage({super.key, required this.source, this.offline = false, DateTime Function()? now})
      : now = now ?? DateTime.now;
  final PlatformSource source;
  final bool offline;
  final DateTime Function() now;
  @override
  State<PlatformPage> createState() => _PlatformPageState();
}

class _PlatformPageState extends State<PlatformPage> with _Loader<PlatformPage> {
  @override
  PlatformSource get source => widget.source;
  @override
  bool get offline => widget.offline;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Widget _muted(String t) => Text(t, style: TextStyle(color: context.nohut.muted, fontSize: 13));

  Widget _section(String title, IconData icon, List<Widget> rows) => Theme(
    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
    child: ExpansionTile(
      tilePadding: EdgeInsets.zero, childrenPadding: const EdgeInsets.only(bottom: 8),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      leading: Icon(icon, size: 19, color: context.nohut.muted),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
      children: rows),
  );

  Widget _card(PlatformCard c) {
    final now = widget.now().toUtc();
    final reason = blocked(c, now);
    final connected = c.connection == PlatformConnection.connected;
    return Card(
      key: ValueKey('platform-card-${c.provider}'),
      child: Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 6), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(c.displayName, style: const TextStyle(fontFamily: 'Bree', fontSize: 19))),
          PlatformStatusChip(c.statusLabel(now), key: ValueKey('platform-status-${c.provider}')),
        ]),
        const SizedBox(height: 6),
        if (connected) ...[
          _muted(c.verifiedStoreName == null ? 'Mağaza doğrulanmadı' : '${c.verifiedStoreName} · ${c.verifiedStoreId}'),
          _muted(platformVerifiedText(c.lastVerifiedAt)),
        ] else _muted(c.note ?? 'Bu platformun resmî entegrasyonu henüz bağlı değil.'),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: FilledButton(
            key: ValueKey('platform-toggle-${c.provider}'),
            onPressed: reason == null && !loading ? () => toggle(c) : null,
            child: Text(_toggleText(c)))),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            key: ValueKey('platform-refresh-${c.provider}'),
            onPressed: connected && !loading && !offline ? () => refresh(c) : null,
            icon: const Icon(Icons.refresh, size: 18), label: const Text('Yenile')),
        ]),
        if (reason != null && connected)
          Padding(padding: const EdgeInsets.only(top: 6), child: _muted(reason)),
        _section('Çalışma Saatleri', Icons.schedule_outlined, [
          if (c.workingHours.isEmpty) _muted('Platformdan doğrulanmış çalışma saati yok.')
          else for (final h in c.workingHours) _muted('${platformDayName(h.dayOfWeek)}  ${h.opening} – ${h.closing}'),
        ]),
        _section('Ürün/Kategori Durumu', Icons.inventory_2_outlined, [
          _muted(c.canToggleCatalog
              ? 'Ürün ve kategori açma/kapatma ayrı yetkiyle yapılır.'
              : 'Henüz bağlı değil. POS ve QR menü bundan etkilenmez.'),
        ]),
        _section('İşlem Geçmişi', Icons.history, [
          if (c.audit.isEmpty) _muted('Henüz işlem yok.')
          else for (final a in c.audit.take(5))
            _muted('${a.at} · ${a.actor} · ${platformStatusWord(a.oldStatus)} › '
                '${platformStatusWord(a.newStatus)} · ${platformOutcomeWord(a.outcome)}'),
        ]),
      ])),
    );
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    if (loading) const LinearProgressIndicator(),
    Padding(padding: const EdgeInsets.fromLTRB(4, 8, 4, 8), child: _muted(
        'Restoranın online platformlardaki açık/kapalı durumu. Siparişler Online Siparişler bölümünde kalır.')),
    if (message.isNotEmpty)
      Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 8), child: Text(message,
          key: const ValueKey('platform-message'), style: const TextStyle(fontWeight: FontWeight.w700))),
    for (final c in snap.cards) _card(c),
  ]);
}

/// Ana Sayfa: three rows, same rule, same confirmation, same command.
class PlatformQuickCard extends StatefulWidget {
  const PlatformQuickCard({super.key, required this.source, required this.onOpen,
      this.offline = false, DateTime Function()? now})
      : now = now ?? DateTime.now;
  final PlatformSource source;
  final VoidCallback onOpen;
  final bool offline;
  final DateTime Function() now;
  @override
  State<PlatformQuickCard> createState() => _PlatformQuickCardState();
}

class _PlatformQuickCardState extends State<PlatformQuickCard> with _Loader<PlatformQuickCard> {
  @override
  PlatformSource get source => widget.source;
  @override
  bool get offline => widget.offline;

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.now().toUtc();
    return Card(
      key: const ValueKey('platform-quick'),
      child: Padding(padding: const EdgeInsets.fromLTRB(14, 6, 6, 8), child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Expanded(child: Text('Platformlar', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
          TextButton(key: const ValueKey('platform-quick-open'), onPressed: widget.onOpen,
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Text('Tümü'), Icon(Icons.chevron_right, size: 18)])),
        ]),
        for (final c in snap.cards)
          Padding(
            key: ValueKey('platform-quick-${c.provider}'),
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              Expanded(child: Text(c.displayName, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600))),
              Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: FittedBox(
                  fit: BoxFit.scaleDown, child: PlatformStatusChip(c.statusLabel(now))))),
              SizedBox(width: 86, child: TextButton(
                key: ValueKey('platform-quick-toggle-${c.provider}'),
                onPressed: blocked(c, now) == null && !loading ? () => toggle(c) : null,
                child: Text(_toggleText(c) == 'Aç / Kapat' ? 'Aç/Kapat' : _toggleText(c)))),
            ]),
          ),
        if (message.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 4, right: 8), child: Text(message,
              style: TextStyle(fontSize: 12.5, color: context.nohut.muted))),
      ])),
    );
  }
}
