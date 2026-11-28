import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/operations_ui.dart';

void main() {
  Future<(int, int)> pump(WidgetTester t, Map<String, dynamic> order,
      {double width = 1000}) async {
    var cancels = 0, deletes = 0;
    await t.pumpWidget(MaterialApp(home: Scaffold(body: Center(
      child: SizedBox(width: width, child: OrderDangerZone(
        order: order,
        onCancel: () => cancels++,
        onDelete: () => deletes++,
      )),
    ))));
    await t.tap(find.byKey(const ValueKey('order-cancel')));
    await t.tap(find.byKey(const ValueKey('order-delete')));
    return (cancels, deletes);
  }

  testWidgets('open unpaid order can be cancelled or deleted', (t) async {
    final r = await pump(t, {'source': 'Masa', 'payments': []});
    expect(r, (1, 1));
    expect(find.textContaining('Raporlarda "İptal"'), findsOneWidget);
  });

  testWidgets('a paid order cannot be cancelled until refunded', (t) async {
    final r = await pump(t, {'source': 'Masa', 'payments': [
      {'amount': 5000, 'method': 'Nakit'},
    ]}, width: 500);
    expect(r, (0, 1));
    expect(find.text('Önce tüm ödemeleri iade edin.'), findsOneWidget);
  });

  testWidgets('a closed order can only be archived', (t) async {
    final r = await pump(t, {'source': 'Gel-Al', 'closed': true, 'payments': []});
    expect(r, (0, 1));
    expect(find.textContaining('yeniden iptal edilemez'), findsOneWidget);
  });
}
