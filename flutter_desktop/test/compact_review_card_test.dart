import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/compact_review_card.dart';
import 'package:nohut_falafel_desktop/review_display.dart';

void main() {
  testWidgets('star-only review is a compact single row without fake text',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: CompactReviewCard(
            platform: 'Trendyol Go',
            score: 5,
            dateLabel: '19.11.2026',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('Yalnızca yıldız puanı'), findsOneWidget);
    expect(find.text('Detaylar'), findsNothing);
    expect(find.text('Yanıtla'), findsNothing);
    expect(tester.getSize(find.byType(CompactReviewCard)).height,
        lessThan(125));
  });

  testWidgets('review shows compact verified answer and expands order details',
      (tester) async {
    var replies = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: CompactReviewCard(
            platform: 'Trendyol Go',
            score: 4,
            dateLabel: '18.11.2026',
            comment: 'Yemek gayet güzeldi, sipariş çok hızlı geldi. '
                'Bütün ürünler özenle paketlenmişti ve hala sıcaktı. '
                'Gerçekten emeği geçen herkese teşekkürler.',
            orderNumber: '1234',
            orderDate: '18.11.2026',
            products: const ['Falafel Dürüm', 'Ayran'],
            answerText: 'Güzel yorumunuz için teşekkür ederiz.',
            answerStatus: 'APPROVED',
            onReply: () => replies++,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('Yanıt · Onaylandı:'), findsOneWidget);
    expect(find.text('Falafel Dürüm, Ayran'), findsNothing);
    await tester.tap(find.text('Detaylar'));
    await tester.pumpAndSettle();
    expect(find.text('Falafel Dürüm, Ayran'), findsOneWidget);
    await tester.tap(find.text('Yanıtla'));
    expect(replies, 1);
    await tester.tap(find.text('Daha Az'));
    await tester.pumpAndSettle();
    expect(find.text('Falafel Dürüm, Ayran'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('only a written Trendyol comment qualifies for reply control', () {
    expect(reviewHasWrittenComment({
      'comment': {'text': '  '},
      'rating': {'average': 5},
    }), isFalse);
    expect(reviewHasWrittenComment({
      'comment': {'text': 'Çok güzel'},
      'rating': {'average': 5},
    }), isTrue);
    expect(reviewHasWrittenComment({'rating': {'average': 4}}), isFalse);
  });
}
