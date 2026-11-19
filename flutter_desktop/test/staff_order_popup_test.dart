import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/staff_order_popup.dart';

void main() {
  final order = <String, dynamic>{
    'id': 17,
    'dailyNumber': 17,
    'numberDay': '2026-11-19',
    'source': 'Masa',
    'table': 3,
    'batches': [
      {
        'lines': [
          {'name': 'Falafel Dürüm', 'qty': 2, 'note': ''},
          {'name': 'Ayran', 'qty': 1, 'note': 'Soğuk'},
        ],
      },
    ],
  };
  final notice = <String, dynamic>{
    'id': 'phone-request-123',
    'staff': 'Ayşe',
    'action': 'Yeni sipariş',
    'orderId': 17,
    'table': 3,
  };

  testWidgets('phone order popup shows staff, table and new items only',
      (tester) async {
    bool opened = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StaffOrderPopup(
          notice: notice,
          order: order,
          onOpen: () => opened = true,
          onDismiss: () {},
        ),
      ),
    ));
    expect(find.text('PERSONELDEN YENİ SİPARİŞ'), findsOneWidget);
    expect(find.text('Masa 3'), findsOneWidget);
    expect(find.textContaining('Personel: Ayşe'), findsOneWidget);
    expect(find.text('2 × Falafel Dürüm'), findsOneWidget);
    expect(find.text('1 × Ayran · Soğuk'), findsOneWidget);
    expect(find.text('Hazır'), findsNothing);
    expect(find.text('İptal'), findsNothing);
    expect(find.text('Kabul Et'), findsNothing);
    await tester.tap(find.text('Siparişi Aç'));
    expect(opened, isTrue);
  });

  testWidgets('extra phone order popup can be acknowledged without actions',
      (tester) async {
    var dismissed = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StaffOrderPopup(
          notice: {...notice, 'action': 'Ek sipariş'},
          order: order,
          onOpen: () {},
          onDismiss: () => dismissed = true,
        ),
      ),
    ));
    expect(find.text('PERSONELDEN EK SİPARİŞ'), findsOneWidget);
    await tester.tap(find.text('Tamam'));
    expect(dismissed, isTrue);
  });

  testWidgets('staff notification MP3 is bundled as a Flutter asset',
      (tester) async {
    final file = await rootBundle.load('assets/notifications/staff-order.mp3');
    expect(file.lengthInBytes, greaterThan(4000));
  });
}
