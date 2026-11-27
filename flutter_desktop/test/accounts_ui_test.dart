import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/accounts_ui.dart';
import 'package:nohut_falafel_desktop/local_accounts.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  Widget host(LocalAuth auth) => MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: AccountsPanel(auth: auth, employees: const [{'id': 7, 'name': 'Ayşe', 'active': true}]))));

  testWidgets('without an owner only the owner setup is offered', (tester) async {
    final auth = LocalAuth(sqlite3.openInMemory(), iterations: 1000);
    await tester.pumpWidget(host(auth));
    expect(find.byKey(const ValueKey('create-owner')), findsOneWidget);
    expect(find.byKey(const ValueKey('lan-login-required')), findsNothing);
  });

  testWidgets('owner sees users, enables individual login, revokes a device', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final auth = LocalAuth(sqlite3.openInMemory(), iterations: 1000);
    await tester.runAsync(() async {
      await auth.createUser(username: 'sahip', password: 'owner-pass-1', role: 'Yönetici', isOwner: true);
      await auth.createUser(username: 'ayse', password: 'staff-pass-1', role: 'Personel', employeeId: 7);
      await auth.login(username: 'ayse', password: 'staff-pass-1',
          deviceId: 'phone-device-0001-abcdef', client: 'personel', label: 'iPhone');
    });
    await tester.pumpWidget(host(auth));
    expect(find.byKey(const ValueKey('user-ayse')), findsOneWidget);
    expect(find.textContaining('Personel · Ayşe · 1 cihaz'), findsOneWidget);
    expect(auth.lanLoginRequired, false);
    await tester.tap(find.byKey(const ValueKey('lan-login-required')));
    await tester.pump();
    expect(auth.lanLoginRequired, true);

    await tester.tap(find.text('Kaldır'));
    await tester.pumpAndSettle();
    expect(auth.devices().single['revoked'], true);
    expect(find.text('Kaldırıldı'), findsOneWidget);
  });
}
