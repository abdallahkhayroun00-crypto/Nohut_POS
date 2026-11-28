import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nohut_personel/pos_api.dart';
import 'package:nohut_personel/staff_expense_page.dart';
import 'package:nohut_personel/style.dart';

import 'visual/render_harness.dart';

class Server {
  final rows = <Map<String, dynamic>>[];
  final seen = <String>{};
  bool dropNext = false, forbidden = false;
  int posts = 0;
  NohutApi api({List<String> grants = const ['expenses.quick_add']}) {
    final a = NohutApi(client: MockClient((r) async {
      json(Object b, [int s = 200]) => http.Response(jsonEncode(b), s,
          headers: {'content-type': 'application/json; charset=utf-8'});
      if (forbidden) return json({'error': 'forbidden'}, 403);
      if (r.method == 'GET') return json({'expenses': rows.reversed.toList()});
      posts++;
      final b = jsonDecode(r.body) as Map;
      if (!seen.contains(b['requestId'])) {
        seen.add(b['requestId'] as String);
        final total = (b['amountsCents'] as List).fold<int>(0, (n, x) => n + (x as int));
        rows.add({'id': rows.length + 1, 'date': b['date'], 'storeBrand': b['storeBrand'],
          'market': b['storeBrand'], 'totalCents': total, 'paymentMethod': b['paymentMethod'],
          'note': b['note'], 'voided': false});
      }
      if (dropNext) { dropNext = false; throw http.ClientException('lost'); }
      return json({'ok': true, 'totalCents': rows.last['totalCents']});
    }));
    a..host = 'http://192.168.1.5:8787'..token = 'x' * 40..serverId = 'synthetic'..session = 'synthetic'
      ..sessionInfo = {'session': {'status': 'ok', 'employeeId': 1, 'username': 'personela', 'grants': grants}};
    return a;
  }
}

Future<void> fillAndSend(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('staff-expense-add')));
  await t.pumpAndSettle();
  await t.enterText(find.byType(TextField).first, '125,50');
  await t.tap(find.text('Gönder'));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await loadNohutFonts();
  });

  test('only the explicit grant shows the page', () {
    final s = Server();
    expect(canSubmitExpenses(s.api()), isTrue);
    expect(canSubmitExpenses(s.api(grants: const ['shifts.self'])), isFalse);
  });

  testWidgets('add a purchase; a lost answer is retried with the same request', (t) async {
    final s = Server();
    await t.pumpWidget(MaterialApp(theme: NohutStyle.theme, home: StaffExpensePage(api: s.api())));
    await t.pumpAndSettle();
    expect(find.text('Henüz gider girmediniz.'), findsOneWidget);
    s.dropNext = true;
    await fillAndSend(t);
    expect(find.byKey(const ValueKey('staff-expense-retry')), findsOneWidget);
    await t.tap(find.text('Tekrar Gönder'));
    await t.pumpAndSettle();
    expect(s.posts, 2);
    expect(s.rows, hasLength(1), reason: 'same requestId: no duplicate');
    expect(find.byKey(const ValueKey('staff-expense-retry')), findsNothing);
    expect(find.textContaining('125,50'), findsWidgets);
  });

  testWidgets('without the grant the server refusal is explained', (t) async {
    final s = Server()..forbidden = true;
    await t.pumpWidget(MaterialApp(home: StaffExpensePage(api: s.api())));
    await t.pumpAndSettle();
    expect(find.textContaining('yetkiniz yok'), findsOneWidget);
    expect(find.byKey(const ValueKey('staff-expense-add')), findsNothing);
  });
}
