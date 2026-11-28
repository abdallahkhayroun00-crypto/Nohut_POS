import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'brand.dart';
import 'pos_logic.dart';

const floorDefaults = <int, Rect>{
  1: Rect.fromLTWH(.456, .130, .143, .135),
  2: Rect.fromLTWH(.255, .165, .130, .113),
  3: Rect.fromLTWH(.265, .424, .343, .174),
  4: Rect.fromLTWH(.261, .710, .346, .178),
  5: Rect.fromLTWH(.032, .676, .076, .148),
};

Map<int, Rect> positionsFromJson(Object? value) {
  final parsed = <int, Rect>{...floorDefaults};
  if (value is! Map) return parsed;
  for (final number in floorDefaults.keys) {
    final p = value['$number'];
    if (p is Map && p['x'] is num && p['y'] is num) {
      final base = floorDefaults[number]!;
      final x = (p['x'] as num).toDouble();
      final y = (p['y'] as num).toDouble();
      if (x >= 0 && y >= 0 && x + base.width <= 1 && y + base.height <= 1) {
        parsed[number] = Rect.fromLTWH(x, y, base.width, base.height);
      }
    }
  }
  return parsed;
}

Map<String, dynamic> positionsToJson(Map<int, Rect> positions) => {
  for (final entry in positions.entries)
    '${entry.key}': {'x': entry.value.left, 'y': entry.value.top},
};

bool validFloorPlacement(Map<int, Rect> positions) {
  const entrance = Rect.fromLTWH(.118, .274, .103, .15);
  final entries = positions.entries.toList();
  for (var i = 0; i < entries.length; i++) {
    final r = entries[i].value;
    if (r.left < 0 ||
        r.top < 0 ||
        r.right > 1 ||
        r.bottom > 1 ||
        r.overlaps(entrance))
      return false;
    if (r.top < .338 && r.bottom > .328) return false;
    for (var j = i + 1; j < entries.length; j++) {
      if (r.inflate(.012).overlaps(entries[j].value)) return false;
    }
  }
  return true;
}

class RestaurantFloorPlan extends StatelessWidget {
  const RestaurantFloorPlan({
    super.key,
    required this.state,
    required this.onTable,
    required this.positions,
    required this.editing,
    required this.onMove,
    this.selected,
    this.now,
  });
  final Json state;
  /// Clock for "open for N minutes"; defaults to DateTime.now().
  final DateTime? now;
  final ValueChanged<int> onTable;
  final Map<int, Rect> positions;
  final bool editing;
  final void Function(int table, Offset normalizedDelta) onMove;
  final int? selected;

  @override
  Widget build(BuildContext context) {
    final occupied = List.generate(
      floorDefaults.length,
      (i) => activeTable(state, i + 1),
    ).where((o) => o != null).length;
    return Card(
      margin: EdgeInsets.zero,
      color: const Color(0xfffefefb),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.chair_outlined, color: Color(0xff285940)),
                    SizedBox(width: 8),
                    Text(
                      'Restoran Yerleşimi',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _legend('Boş ${floorDefaults.length - occupied}', TableTone.free),
                    _legend('Dolu $occupied', TableTone.busy),
                    _legend('Ödendi', TableTone.paid),
                  ],
                ),
              ],
            ),
            if (editing) ...[
              const SizedBox(height: 8),
              const Row(children: [
                Icon(Icons.open_with, size: 15, color: Color(0xff718275)),
                SizedBox(width: 6),
                Expanded(child: Text(
                  'Sürükle · Yeni konumları kaydet veya iptal et.',
                  style: TextStyle(color: Color(0xff718275), fontSize: 12),
                )),
              ]),
            ],
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                if (!editing && constraints.maxWidth < 740) {
                  return EvenGrid(
                    minTileWidth: 150,
                    spacing: 10,
                    children: [
                      for (var n = 1; n <= floorDefaults.length; n++)
                        TableStatusTile(
                          key: ValueKey('table-tile-$n'),
                          number: n,
                          order: activeTable(state, n),
                          minutes: activeTable(state, n) == null
                              ? 0 : _minutes(activeTable(state, n)!),
                          selected: selected == n,
                          onTap: () => onTable(n),
                        ),
                    ],
                  );
                }
                final width = math.max(740.0, constraints.maxWidth);
                final height = width * 640 / 1075;
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: width,
                    height: height,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(painter: _FloorPainter(positions)),
                        ),
                        Positioned(
                          left: width * .137,
                          top: height * .274,
                          child: const Text(
                            'KAPI',
                            style: TextStyle(
                              color: Color(0xffbd6b5c),
                              fontSize: 13,
                              letterSpacing: 2,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        Positioned(
                          right: 22,
                          top: height * .36,
                          child: const Text(
                            'OTURMA ALANI',
                            style: TextStyle(
                              color: Color(0xffa0b5a0),
                              fontSize: 10,
                              letterSpacing: 2,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        for (final n in [2, 1, 3, 4, 5])
                          _table(context, n, width, height),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _legend(String label, TableTone tone) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: tone.fill,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: tone.accent.withValues(alpha: .55)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(radius: 4, backgroundColor: tone.accent),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 11.5,
          fontWeight: FontWeight.w700, color: tone.ink)),
      ],
    ),
  );

  Widget _table(BuildContext context, int n, double width, double height) {
    final r = positions[n] ?? floorDefaults[n]!;
    final order = activeTable(state, n);
    final busy = order != null;
    final paid = busy && orderDueCents(order) == 0;
    final tone = TableTone.of(order);
    final (fill, accent, ink) = (tone.fill, tone.accent, tone.ink);
    final small = n == 5;
    // Only large tables have room for the status pill and item/staff line.
    final roomy = r.height * height >= 85 && r.width * width >= 200;
    final minutes = busy ? _minutes(order) : 0;
    final status = !busy ? 'Boş' : paid ? 'Ödendi · Masa açık' : 'Dolu';
    return Positioned(
      left: r.left * width,
      top: r.top * height,
      width: r.width * width,
      height: r.height * height,
      child: GestureDetector(
        onTap: editing ? null : () => onTable(n),
        onPanUpdate: editing
            ? (details) => onMove(
                n,
                Offset(details.delta.dx / width, details.delta.dy / height),
              )
            : null,
        child: Tooltip(
          message: busy
              ? 'Masa $n · $status · Kalan ${formatTry(orderDueCents(order))}'
              : 'Masa $n · Boş · Yeni sipariş',
          child: MouseRegion(
            cursor: editing ? SystemMouseCursors.move : SystemMouseCursors.click,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(small ? 10 : 16),
                border: Border.all(
                  color: selected == n && !editing ? NohutBrand.green : accent,
                  width: selected == n ? 3 : 1.6,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x1A0c4229),
                    blurRadius: 12,
                    offset: Offset(0, 5),
                  ),
                ],
              ),
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Masa $n',
                          style: TextStyle(
                            color: ink,
                            fontWeight: FontWeight.w900,
                            fontSize: small ? 14 : 18,
                          ),
                        ),
                        const SizedBox(height: 4),
                        if (!busy)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.add_circle_outline,
                                size: small ? 12 : 14, color: accent),
                              const SizedBox(width: 4),
                              Text('Boş · Yeni Sipariş', style: TextStyle(
                                fontSize: small ? 10 : 12,
                                fontWeight: FontWeight.w600, color: ink)),
                            ],
                          )
                        else ...[
                          if (roomy) Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(10)),
                            child: Text(status, style: TextStyle(
                              fontSize: small ? 9.5 : 11,
                              fontWeight: FontWeight.w700, color: ink)),
                          ),
                          SizedBox(height: roomy ? 5 : 0),
                          Text(
                            formatTry(orderDueCents(order)),
                            style: TextStyle(
                              fontSize: small ? 13 : 17,
                              fontWeight: FontWeight.w900,
                              color: ink,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.timer_outlined,
                                size: small ? 10 : 12,
                                color: minutes >= 90
                                    ? const Color(0xffB3261E) : ink),
                              const SizedBox(width: 3),
                              Text(
                                '${minutes < 60 ? '$minutes dk' : '${minutes ~/ 60} sa ${minutes % 60} dk'}'
                                '${roomy ? ' · ${_items(order)} ürün · ${orderOwnerName(order)}' : ''}',
                                style: TextStyle(
                                  fontSize: small ? 9.5 : 11.5,
                                  color: minutes >= 90
                                      ? const Color(0xffB3261E) : ink),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  int _minutes(Json order) {
    final created = DateTime.tryParse('${order['createdAt']}');
    if (created == null) return 0;
    final m = (now ?? DateTime.now()).toUtc()
        .difference(created.toUtc()).inMinutes;
    return m < 0 ? 0 : m;
  }

  int _items(Json order) => activeLines(order).fold<int>(
    0, (sum, l) => sum + (l['qty'] is num ? (l['qty'] as num).toInt() : 0));
}

class _FloorPainter extends CustomPainter {
  const _FloorPainter(this.tables);
  final Map<int, Rect> tables;

  @override
  void paint(Canvas canvas, Size size) {
    final wall = Paint()
      ..color = const Color(0xffdf968c)
      ..strokeWidth = 3;
    canvas.drawLine(
      Offset(0, size.height * .333),
      Offset(size.width * .118, size.height * .333),
      wall,
    );
    canvas.drawLine(
      Offset(size.width * .221, size.height * .333),
      Offset(size.width, size.height * .333),
      wall,
    );
    final chairOuter = Paint()..color = const Color(0xffddb25a);
    final chairInner = Paint()..color = const Color(0xffffe5a2);
    void chair(double x, double y) {
      final p = Offset(size.width * x, size.height * y);
      canvas.drawCircle(p, 10, chairOuter);
      canvas.drawCircle(p, 7, chairInner);
      canvas.drawCircle(p, 3.3, chairOuter);
    }

    for (final n in tables.keys) {
      final r = tables[n]!;
      if (n == 1 || n == 2) {
        chair(r.left - .016, r.center.dy);
        chair(r.right + .016, r.center.dy);
      } else if (n == 5) {
        chair(r.center.dx, r.top - .018);
        chair(r.center.dx, r.bottom + .024);
      } else {
        chair(r.left + r.width * .19, r.top - .018);
        chair(r.left + r.width * .76, r.top - .018);
        chair(r.right + .035, r.center.dy);
        chair(r.left + r.width * .19, r.bottom + .024);
        chair(r.left + r.width * .76, r.bottom + .024);
      }
    }
    final dash = Paint()
      ..color = const Color(0xffdbe4d8)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(13, 13, size.width - 26, size.height - 26),
        const Radius.circular(13),
      ),
      dash,
    );
  }

  @override
  bool shouldRepaint(covariant _FloorPainter old) => old.tables != tables;
}


/// Colours shared by the floor plan, the compact tiles and the legend.
class TableTone {
  const TableTone._(this.fill, this.accent, this.ink);
  final Color fill, accent, ink;

  static const free = TableTone._(
    Color(0xffF1F7F2), Color(0xff7FB08F), Color(0xff23553a));
  static const busy = TableTone._(
    Color(0xffFFF1D6), Color(0xffD9A24E), Color(0xff6E4614));
  static const paid = TableTone._(
    Color(0xffE3F1F5), Color(0xff5E9CB0), Color(0xff1F5566));

  static TableTone of(Json? order) => order == null
      ? free
      : orderDueCents(order) == 0 ? paid : busy;
}

/// One table as a compact card, used when the window is too narrow for the
/// drawn floor plan. Same colours, same tap behaviour as the plan.
class TableStatusTile extends StatelessWidget {
  const TableStatusTile({
    super.key,
    required this.number,
    required this.order,
    required this.minutes,
    required this.onTap,
    this.selected = false,
  });
  final int number;
  final Json? order;
  final int minutes;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final o = order;
    final tone = TableTone.of(o);
    final long = minutes >= 90;
    final status = o == null
        ? 'Boş'
        : orderDueCents(o) == 0 ? 'Ödendi · Masa açık' : 'Dolu';
    return Material(
      color: tone.fill,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 96),
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? NohutBrand.green : tone.accent,
              width: selected ? 2.4 : 1.4),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(child: Text('Masa $number', maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900,
                    color: tone.ink))),
                const SizedBox(width: 6),
                if (o == null)
                  Icon(Icons.add_circle_outline, size: 18, color: tone.accent)
                else
                  Flexible(child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.timer_outlined, size: 13,
                      color: long ? const Color(0xffB3261E) : tone.ink),
                    const SizedBox(width: 2),
                    Flexible(
                      child: Text(minutes < 60 ? '$minutes dk'
                          : '${minutes ~/ 60} sa ${minutes % 60} dk',
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: long ? const Color(0xffB3261E) : tone.ink)),
                    ),
                  ])),
              ]),
              const SizedBox(height: 4),
              Text(status, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: tone.ink,
                  fontWeight: FontWeight.w600)),
              // Every tile has the same three lines, so rows stay level.
              const SizedBox(height: 6),
              if (o == null)
                Text('Yeni sipariş', maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900,
                    color: tone.ink))
              else ...[
                Text(orderDueCents(o) == 0
                    ? 'Ödenen ${formatTry(orderPaidCents(o))}'
                    : 'Kalan ${formatTry(orderDueCents(o))}', maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900,
                    color: tone.ink)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
