import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nohut_personel/performance_page.dart';
import 'package:nohut_personel/pos_api.dart';
import 'package:nohut_personel/style.dart';

import 'visual/render_harness.dart';

NohutApi perfApi(List<String> asked, {int status = 200}) {
  final a = NohutApi(client: MockClient((r) async {
    asked.add(r.url.queryParameters['range'] ?? '');
    final range = r.url.queryParameters['range'];
    return http.Response(jsonEncode(status != 200 ? {'error': 'no_employee', 'message': 'Hesabınız bir personele bağlı değil.'} : {
      'today': '2026-11-27',
      'performance': {
        'range': range, 'from': range == 'day' ? '2026-11-27' : '2026-11-23', 'to': range == 'day' ? '2026-11-27' : '2026-11-29',
        'orders': range == 'day' ? 3 : 12, 'tables': 2, 'pickups': 1, 'additions': 4, 'cancelled': 1,
        'openOrders': 1, 'salesCents': range == 'day' ? 31000 : 148500, 'averageCents': 10333,
        'activeDays': 1, 'workedMinutes': 450, 'collectionsAttributed': false,
        'note': 'Tahsilatlar kasadan kaydedildiği için kişiye atanmaz.',
      },
    }), status, headers: {'content-type': 'application/json; charset=utf-8'});
  }));
  a..host = 'http://192.168.1.5:8787'..token = 'x' * 40..serverId = 'synthetic'..session = 'synthetic';
  return a;
}

void main() {
  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await loadNohutFonts();
  });

  for (final mode in [Brightness.light, Brightness.dark]) {
    testWidgets('own numbers by range (${mode.name})', (t) async {
      final asked = <String>[];
      await renderScreen(t, 'performance-${mode.name}', MaterialApp(debugShowCheckedModeBanner: false,
          theme: NohutStyle.theme, darkTheme: NohutStyle.darkTheme,
          home: PerformancePage(api: perfApi(asked))), brightness: mode);
      expect(find.text('310,00 ₺'), findsOneWidget);
      expect(find.textContaining('7 sa 30 dk'), findsOneWidget);
      expect(find.textContaining('kişiye atanmaz'), findsOneWidget);
      await t.tap(find.text('Bu Hafta'));
      await t.pumpAndSettle();
      expect(asked, ['day', 'week']);
      expect(find.text('1.485,00 ₺'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('an unlinked account sees the server message', (t) async {
    await t.pumpWidget(MaterialApp(home: PerformancePage(api: perfApi([], status: 409))));
    await t.pumpAndSettle();
    expect(find.textContaining('personele bağlı değil'), findsOneWidget);
    expect(find.text('Tekrar dene'), findsOneWidget);
  });
}
