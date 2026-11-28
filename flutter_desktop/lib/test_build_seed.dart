/// Synthetic people and the fixture account for TEST builds only.
library;

import 'dart:convert';
import 'dart:math';

import 'local_accounts.dart';
import 'pos_store.dart';
import 'test_build.dart';

const testBuildEmployees = [
  {'id': 1, 'name': 'Test Yönetici', 'role': 'Yönetici', 'active': true},
  {'id': 2, 'name': 'Test Personel A', 'role': 'Personel', 'active': true},
  {'id': 3, 'name': 'Test Personel B', 'role': 'Personel', 'active': true},
];

/// Before the store opens: a fresh TEST database gets only synthetic staff.
void prepareTestBuildStore() {
  if (!nohutTestBuild) return;
  debugSeedEmployees = [for (final e in testBuildEmployees) {...e}];
}

/// The `test` account (owner, linked to "Test Yönetici"). Its password is
/// random and never shown; the TEST build accepts `test` / `00000` instead.
Future<void> seedTestAccount(LocalAuth auth) async {
  if (!nohutTestBuild || auth.hasUsers) return;
  final r = Random.secure();
  await auth.createUser(username: testFixtureUsername,
      password: base64Url.encode(List<int>.generate(24, (_) => r.nextInt(256))),
      role: 'Yönetici', employeeId: 1, isOwner: true, actor: 'test-build');
}
