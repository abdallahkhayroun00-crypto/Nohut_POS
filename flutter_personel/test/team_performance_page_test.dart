import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_personel/pos_api.dart';
import 'package:nohut_personel/style.dart';
import 'package:nohut_personel/team_performance_page.dart';

import 'visual/render_harness.dart';

Future<Json> Function(Json) teamRequest(List<Json> asked, {bool fail = false}) => (p) async {
  asked.add(p);
  if (fail) throw const FormatException('Yönetim eşleştirmesi gerekli.');
  final week = p['range'] == 'week';
  Json person(int id, String name, int orders, int cents, int minutes) => {
    'employeeId': id, 'name': name, 'active': true, 'orders': orders, 'tables': orders - 1,
    'pickups': orders == 0 ? 0 : 1, 'additions': orders ~/ 2, 'cancelled': 0, 'openOrders': 1,
    'salesCents': cents, 'averageCents': orders == 0 ? null : cents ~/ orders,
    'activeDays': orders == 0 ? 0 : 1, 'workedMinutes': minutes,
  };
  return {'ok': true, 'team': {
    'range': p['range'], 'from': week ? '2026-11-23' : '2026-11-27', 'to': week ? '2026-11-29' : '2026-11-27',
    'people': [
      person(1, 'Ayşe', week ? 30 : 6, week ? 420000 : 84000, 450),
      person(2, 'Mehmet', 4, 52000, 300),
      person(3, 'Zeynep', 0, 0, 0),
    ],
    'unassigned': {'orders': 2, 'salesCents': 9000},
    'totals': {'orders': week ? 36 : 12, 'salesCents': week ? 481000 : 145000, 'workedMinutes': 750},
    'note': 'Tahsilatlar kasadan kaydedildiği için kişiye atanmaz.',
  }};
};

void main() {
  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await loadNohutFonts();
  });

  for (final mode in [Brightness.light, Brightness.dark]) {
    testWidgets('team by range, detail on tap (${mode.name})', (t) async {
      final asked = <Json>[];
      await renderScreen(t, 'team-performance-${mode.name}', MaterialApp(debugShowCheckedModeBanner: false,
          theme: NohutStyle.theme, darkTheme: NohutStyle.darkTheme,
          home: TeamPerformancePage(request: teamRequest(asked))), brightness: mode);
      expect(asked.single['operation'], 'ownerTeamPerformance');
      expect(find.text('1.450,00 ₺'), findsOneWidget);
      expect(find.text('Bu dönemde kayıt yok'), findsOneWidget);
      expect(find.byKey(const ValueKey('team-unassigned')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('team-person-1')));
      await t.pumpAndSettle();
      expect(find.text('Çalıştığı gün'), findsOneWidget);
      await t.tap(find.text('Bu Hafta'));
      await t.pumpAndSettle();
      expect(asked.map((a) => a['range']), ['day', 'week']);
      expect(find.text('4.810,00 ₺'), findsOneWidget);
      expect(find.text('Çalıştığı gün'), findsNothing);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('no pairing shows the reason and a retry', (t) async {
    await t.pumpWidget(MaterialApp(home: TeamPerformancePage(request: teamRequest([], fail: true))));
    await t.pumpAndSettle();
    expect(find.textContaining('eşleştirmesi gerekli'), findsOneWidget);
    expect(find.text('Tekrar dene'), findsOneWidget);
  });
}
