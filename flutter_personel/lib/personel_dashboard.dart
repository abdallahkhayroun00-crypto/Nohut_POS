// §24.3 Personel Ana Sayfa: the signed-in employee's own week (actual hours,
// plan, pay) from the server session, today's floor at a glance and the
// quick actions. Nothing here selects or shows another employee.
//
// Two layouts for the owner to choose from (relay 7226986975), both sans-serif,
// one-line greeting, the week near the top, the same actions and numbers:
//  * [PersonelHomeStyle.summary]: a week card first, then compact action tiles.
//  * [PersonelHomeStyle.agenda]: next shift first, a week strip, then grouped
//    action lists with live counts.
import 'package:flutter/material.dart';

import 'pos_api.dart';
import 'style.dart';
import 'work_page.dart' show WorkFormat;

enum PersonelHomeStyle { summary, agenda }

class PersonelDashboard extends StatefulWidget {
  const PersonelDashboard({
    super.key,
    required this.api,
    required this.name,
    required this.busyTables,
    required this.openPickups,
    required this.openOrders,
    required this.onTables,
    required this.onNewOrder,
    required this.onOrders,
    required this.onWork,
    required this.onLogin,
    this.online = true,
    this.style = PersonelHomeStyle.summary,
  });
  final NohutApi api;
  final bool online;
  final PersonelHomeStyle style;
  final String? name;
  final int busyTables, openPickups, openOrders;
  final VoidCallback onTables, onNewOrder, onOrders, onLogin;
  /// Opens Mesai ve Maaşım on a tab: 0 Mesai, 1 Vardiya, 2 Maaş.
  final ValueChanged<int> onWork;

  @override
  State<PersonelDashboard> createState() => _PersonelDashboardState();
}

class _PersonelDashboardState extends State<PersonelDashboard> {
  Json? week;
  String? today;
  String? error;
  bool loading = false;

  bool get _canWork => widget.api.signedIn && widget.api.sessionEmployeeId != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_canWork) return;
    setState(() { loading = true; error = null; });
    try {
      final (status, body) = await widget.api.work('GET', 'week');
      if (!mounted) return;
      if (status == 200 && body['week'] is Map) {
        setState(() { week = Map<String, dynamic>.from(body['week'] as Map); today = '${body['today'] ?? ''}'; });
      } else {
        setState(() => error = 'Haftalık bilgiler alınamadı.');
      }
    } catch (_) {
      if (mounted) setState(() => error = 'Haftalık bilgiler için Windows bağlantısı gerekli.');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Json? get _nextPlan {
    final t = today ?? '';
    final plans = rows(week?['plans']).where((p) => p['dayOff'] != true && p['cancelled'] != true &&
        '${p['date']}'.compareTo(t) >= 0).toList()
      ..sort((a, b) => '${a['date']} ${a['start']}'.compareTo('${b['date']} ${b['start']}'));
    return plans.firstOrNull;
  }

  // ------------------------------------------------------------ shared bits
  Map get _status => week?['status'] is Map ? week!['status'] as Map : const {};
  Map? get _pay {
    final pay = week?['pay'] is Map ? week!['pay'] as Map : null;
    return pay != null && pay['payrollEligible'] != false ? pay : null;
  }
  String? get _name {
    final emp = week?['employee'] is Map ? week!['employee'] as Map : const {};
    return emp['name'] is String ? '${emp['name']}' : widget.name;
  }
  String _m(Object? v) => v is int ? money(v) : '—';
  String get _dateLabel => today == null ? 'Ana Sayfa' : WorkFormat.day(today!);
  String? get _nextLabel {
    final n = _nextPlan;
    return n == null ? null : '${WorkFormat.day('${n['date']}')} · ${n['start']}–${n['end']}';
  }

  TextStyle _label(BuildContext context) => TextStyle(fontFamily: 'Barlow', fontSize: 12.5,
      fontWeight: FontWeight.w700, letterSpacing: .4, color: context.nohut.muted);

  /// The week card's body when there is nothing to show yet.
  Widget? _weekPlaceholder(BuildContext context) {
    if (!_canWork) {
      return NohutEmpty(icon: Icons.badge_outlined,
          message: 'Mesai, vardiya ve maaşınızı görmek için kendi hesabınızla giriş yapın.',
          action: 'Giriş Yap', onAction: widget.onLogin);
    }
    if (loading && week == null) return const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator());
    if (error != null && week == null) {
      return NohutEmpty(icon: Icons.cloud_off_outlined, message: error!, action: 'Tekrar dene', onAction: _load);
    }
    return null;
  }

  List<(IconData, String, VoidCallback, String?)> get _service => [
    (Icons.table_restaurant_outlined, 'Masalar', widget.onTables, '${widget.busyTables}/5 dolu'),
    (Icons.add_shopping_cart, 'Sipariş Al', widget.onNewOrder, null),
    (Icons.receipt_long_outlined, 'Siparişler', widget.onOrders,
        widget.openOrders == 0 ? null : '${widget.openOrders} açık'),
  ];
  List<(IconData, String, VoidCallback, String?)> get _work => [
    (Icons.more_time, 'Mesai Ekle', () => widget.onWork(0), null),
    (Icons.edit_calendar_outlined, 'Vardiya Ekle', () => widget.onWork(1), null),
    (Icons.payments_outlined, 'Maaş & Avans', () => widget.onWork(2), null),
  ];

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: _load,
    child: LayoutBuilder(builder: (context, c) {
      // Tablets: a readable column, centred.
      final side = c.maxWidth > 720 ? (c.maxWidth - 680) / 2 : 16.0;
      final children = widget.style == PersonelHomeStyle.summary ? _summary(context, c.maxWidth) : _agenda(context);
      return ListView(key: ValueKey('home-${widget.style.name}'),
          padding: EdgeInsets.fromLTRB(side, 10, side, 24), children: children);
    }),
  );

  // ------------------------------------------------------- A: Özet kartı
  List<Widget> _summary(BuildContext context, double width) {
    final nc = context.nohut;
    final name = _name;
    return [
      Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name == null ? 'Hoş geldiniz' : 'Merhaba, $name', key: const ValueKey('home-greeting'),
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: 'Barlow', fontSize: 22, fontWeight: FontWeight.w700, color: nc.heading)),
          Text(_dateLabel, style: TextStyle(fontFamily: 'Barlow', fontSize: 14, color: nc.muted)),
        ])),
      ]),
      const SizedBox(height: 12),
      _weekCard(context),
      const SizedBox(height: 16),
      Text('HIZLI İŞLEMLER', style: _label(context)),
      const SizedBox(height: 8),
      _tiles(context, width, [..._service, if (_canWork) ..._work]),
      const SizedBox(height: 16),
      Text('RESTORAN', style: _label(context)),
      const SizedBox(height: 8),
      Card(child: Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Row(children: [
        _inline(context, 'Dolu masa', '${widget.busyTables} / 5'),
        _divider(context),
        _inline(context, 'Açık sipariş', '${widget.openOrders}'),
        _divider(context),
        _inline(context, 'Gel-Al', '${widget.openPickups}'),
      ]))),
    ];
  }

  Widget _weekCard(BuildContext context) {
    final placeholder = _weekPlaceholder(context);
    if (placeholder != null) return Card(child: placeholder);
    const on = Colors.white;
    final soft = Colors.white.withValues(alpha: .72);
    final pay = _pay;
    final next = _nextLabel;
    Widget stat(String label, String value) => Expanded(child: Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontFamily: 'Barlow', fontSize: 13, color: soft, fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value,
            style: const TextStyle(fontFamily: 'Barlow', fontSize: 22, color: on, fontWeight: FontWeight.w700))),
      ]));
    return Material(
      key: const ValueKey('home-week'),
      color: context.nohut.brandPanel,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 12), child: Column(children: [
          Row(children: [
            const Expanded(child: Text('Bu hafta', style: TextStyle(fontFamily: 'Barlow', fontSize: 16,
                fontWeight: FontWeight.w700, color: on))),
            if (_status['status'] is String)
              Flexible(child: Text('${_status['status']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontFamily: 'Barlow', fontSize: 13, color: soft))),
          ]),
          const SizedBox(height: 10),
          LayoutBuilder(builder: (context, c) {
            final hours = [stat('Çalışılan', WorkFormat.hours(_status['minutes'])),
              stat('Plan', WorkFormat.hours(week?['plannedMinutes']))];
            final money = pay == null ? <Widget>[]
                : [stat('Kazanılan', _m(pay['earnedCents'])), stat('Kalan', _m(pay['remainingCents']))];
            // Two money values side by side only when they fit at full size.
            if (money.isEmpty || c.maxWidth >= 520) return Row(children: [...hours, ...money]);
            return Column(children: [Row(children: hours), const SizedBox(height: 10), Row(children: money)]);
          }),
        ])),
        InkWell(
          key: const ValueKey('home-next-shift'),
          onTap: () => widget.onWork(1),
          child: Container(
            color: Colors.black.withValues(alpha: .18),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            child: Row(children: [
              Icon(Icons.event_outlined, size: 19, color: soft),
              const SizedBox(width: 10),
              Expanded(child: Text(next == null ? 'Planlı vardiya yok' : 'Sıradaki vardiya · $next',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'Barlow', fontSize: 14.5, fontWeight: FontWeight.w700, color: on))),
              Icon(Icons.chevron_right, color: soft),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _tiles(BuildContext context, double width, List<(IconData, String, VoidCallback, String?)> items) {
    final nc = context.nohut;
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth >= 560 ? 3 : 2;
      final w = (c.maxWidth - 8 * (cols - 1)) / cols;
      return Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (icon, label, onTap, _) in items)
          SizedBox(width: w, child: Material(
            color: nc.card,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: nc.outline)),
            clipBehavior: Clip.antiAlias,
            child: InkWell(onTap: onTap, child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: Row(children: [
                Container(width: 32, height: 32, decoration: BoxDecoration(color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(9)),
                  child: Icon(icon, size: 19, color: scheme.onSecondaryContainer)),
                const SizedBox(width: 10),
                Expanded(child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: 'Barlow', fontSize: 15, fontWeight: FontWeight.w700, color: nc.ink, height: 1.15))),
              ])),
            )),
          )),
      ]);
    });
  }

  Widget _inline(BuildContext context, String label, String value) => Expanded(child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6), child: Column(children: [
    FittedBox(fit: BoxFit.scaleDown, child: Text(value, style: TextStyle(fontFamily: 'Barlow', fontSize: 19,
        fontWeight: FontWeight.w700, color: context.nohut.heading))),
    Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(fontFamily: 'Barlow', fontSize: 12.5, color: context.nohut.muted)),
  ])));
  Widget _divider(BuildContext context) => Container(width: 1, height: 30, color: context.nohut.outline);

  // ------------------------------------------------------- B: Gündem
  List<Widget> _agenda(BuildContext context) {
    final nc = context.nohut;
    final name = _name;
    final initials = (name ?? '?').trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(2)
        .map((w) => w.characters.first.toUpperCase()).join();
    final placeholder = _weekPlaceholder(context);
    final pay = _pay;
    final n = _nextPlan;
    return [
      Row(children: [
        CircleAvatar(radius: 21, backgroundColor: nc.brandPanel, foregroundColor: Colors.white,
            child: Text(initials.isEmpty ? '?' : initials, style: const TextStyle(fontFamily: 'Barlow',
                fontWeight: FontWeight.w700, fontSize: 16))),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name ?? 'Hoş geldiniz', key: const ValueKey('home-greeting'), maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: 'Barlow', fontSize: 19, fontWeight: FontWeight.w700, color: nc.heading)),
          Text(_dateLabel, maxLines: 1, style: TextStyle(fontFamily: 'Barlow', fontSize: 13.5, color: nc.muted)),
        ])),
      ]),
      const SizedBox(height: 14),
      if (placeholder != null) Card(child: placeholder)
      else ...[
        Card(key: const ValueKey('home-next-shift'), child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => widget.onWork(1),
          child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [
            Container(width: 54, padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(color: nc.warningSoft, borderRadius: BorderRadius.circular(12)),
              child: Column(children: [
                Text(n == null ? '—' : '${DateTime.tryParse('${n['date']}')?.day ?? ''}',
                    style: TextStyle(fontFamily: 'Barlow', fontSize: 21, fontWeight: FontWeight.w700, color: nc.warning)),
                Text(n == null ? '' : WorkFormat.day('${n['date']}').split(' ').last,
                    style: TextStyle(fontFamily: 'Barlow', fontSize: 12, fontWeight: FontWeight.w700, color: nc.warning)),
              ])),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('SIRADAKİ VARDİYA', style: _label(context)),
              const SizedBox(height: 2),
              Text(n == null ? 'Planlı vardiya yok' : '${WorkFormat.day('${n['date']}').split(' ').first} · ${n['start']}–${n['end']}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontFamily: 'Barlow', fontSize: 18, fontWeight: FontWeight.w700, color: nc.heading)),
            ])),
            Icon(Icons.chevron_right, color: nc.muted),
          ])),
        )),
        const SizedBox(height: 8),
        Card(key: const ValueKey('home-week'), child: Padding(padding: const EdgeInsets.symmetric(vertical: 12),
          child: LayoutBuilder(builder: (context, c) {
            final hours = [_inline(context, 'Çalışılan', WorkFormat.hours(_status['minutes'])), _divider(context),
              _inline(context, 'Plan', WorkFormat.hours(week?['plannedMinutes']))];
            final money = pay == null ? <Widget>[] : [_inline(context, 'Kazanılan', _m(pay['earnedCents'])),
              _divider(context), _inline(context, 'Kalan', _m(pay['remainingCents']))];
            if (money.isEmpty || c.maxWidth >= 480) {
              return Row(children: [...hours, if (money.isNotEmpty) _divider(context), ...money]);
            }
            return Column(children: [Row(children: hours), Divider(height: 20, color: nc.outline), Row(children: money)]);
          }))),
      ],
      const SizedBox(height: 14),
      Text('SERVİS', style: _label(context)),
      const SizedBox(height: 6),
      _group(context, _service),
      if (_canWork) ...[
        const SizedBox(height: 14),
        Text('MESAİ VE MAAŞ', style: _label(context)),
        const SizedBox(height: 6),
        _group(context, _work),
      ],
    ];
  }

  Widget _group(BuildContext context, List<(IconData, String, VoidCallback, String?)> items) {
    final nc = context.nohut;
    final scheme = Theme.of(context).colorScheme;
    return Card(child: Column(children: [
      for (var i = 0; i < items.length; i++) ...[
        if (i > 0) Divider(height: 1, indent: 56, color: nc.outline),
        ListTile(
          minVerticalPadding: 10,
          leading: Container(width: 34, height: 34, decoration: BoxDecoration(color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(10)),
            child: Icon(items[i].$1, size: 19, color: scheme.onSecondaryContainer)),
          title: Text(items[i].$2, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: 'Barlow', fontSize: 16, fontWeight: FontWeight.w700, color: nc.ink)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (items[i].$4 != null) NohutPill(items[i].$4!),
            Icon(Icons.chevron_right, color: nc.muted),
          ]),
          onTap: items[i].$3,
        ),
      ],
    ]));
  }
}
