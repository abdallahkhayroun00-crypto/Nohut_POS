import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/dashboard_sales.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/review_display.dart';

void main() {
  testWidgets('daily weekly monthly history works, next cannot pass current',
      (t) async {
    t.view.physicalSize = const Size(1540, 1040);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: DashboardSales(
            state: emptyPosState(),
            businessDay: '2026-11-19',
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.textContaining('19.11.2026'), findsWidgets);
    final next = find.byKey(const ValueKey('chart-next-period'));
    final previous = find.byKey(const ValueKey('chart-previous-period'));
    expect(t.widget<IconButton>(next).onPressed, isNull);
    await t.tap(previous);
    await t.pumpAndSettle();
    expect(find.textContaining('18.11.2026'), findsWidgets);
    expect(t.widget<IconButton>(next).onPressed, isNotNull);
    await t.tap(next);
    await t.pumpAndSettle();
    await t.tap(find.text('Haftalık').last);
    await t.pumpAndSettle();
    expect(find.textContaining('16.11 – 22.11'), findsWidgets);
    await t.tap(previous);
    await t.pumpAndSettle();
    expect(find.textContaining('09.11 – 15.11'), findsWidgets);
    await t.tap(find.text('Aylık').last);
    await t.pumpAndSettle();
    expect(find.textContaining('Kasım 2026'), findsWidgets);
    await t.tap(previous);
    await t.pumpAndSettle();
    expect(find.textContaining('Ekim 2026'), findsWidgets);
  });

  test('Trendyol review payload only reveals identity when supplied', () {
    final known = <String, dynamic>{
      'reviewId': 'r-1',
      'createdDate': 1795057200000,
      'orderParentId': 1581566890,
      'products': [
        {'name': 'Falafel Dürüm'},
        {'name': 'Ayran'},
      ],
    };
    expect(reviewCustomerName(known), isNull);
    expect(reviewProductNames(known), ['Falafel Dürüm', 'Ayran']);
    expect(reviewCustomerName({...known, 'reviewerName': 'Ayşe'}),
        'Ayşe');
    expect(reviewDate(known['createdDate']), isNotNull);
  });

  test('reviews sort newest first using numeric or ISO dates', () {
    final rows = sortReviewsByDate([
      {'reviewId': 'old', 'createdDate': 1600000000000},
      {'reviewId': 'new', 'createdDate': '2026-11-18T12:00:00Z'},
      {'reviewId': 'unknown'},
    ]);
    expect(rows.map((e) => e['reviewId']), ['new', 'old', 'unknown']);
    final reversed = sortReviewsByDate(rows, newestFirst: false);
    expect(reversed.map((e) => e['reviewId']), ['old', 'new', 'unknown']);
  });
}
