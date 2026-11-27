// Owner identity comes from the owner account's linked profile, never from
// a hardcoded name. Legacy installs keep working until an owner is linked.
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_core/management_sections.dart';
import 'package:nohut_falafel_desktop/finance_sync_server.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';

void main() {
  Json state(List<Json> people) => {'employees': people};

  test('linked owner account decides; display name comes from the profile', () {
    final s = state([
      {'id': 4, 'name': 'Test Sahip', 'active': true},
      {'id': 5, 'name': 'Test Personel', 'active': true},
    ]);
    expect(FinanceSyncServer.owner(s, ownerIds: [4])['name'], 'Test Sahip');
  });

  test('legacy pairing keeps working on upgrade, only while no owner is linked', () {
    final s = state([
      {'id': 1, 'name': legacyManagementOwnerName, 'active': true},
      {'id': 2, 'name': 'Test Personel', 'active': true},
    ]);
    expect(FinanceSyncServer.owner(s)['id'], 1);
    // Once an owner account is linked, the name no longer grants anything.
    expect(FinanceSyncServer.owner(s, ownerIds: [2])['id'], 2);
  });

  test('no owner link and no legacy profile fails closed with guidance', () {
    final s = state([{'id': 2, 'name': 'Test Personel', 'active': true}]);
    expect(() => FinanceSyncServer.owner(s), throwsA(isA<FormatException>()
        .having((e) => e.message, 'message', contains('Kullanıcılar'))));
    // A deactivated owner profile is not an owner.
    final off = state([{'id': 4, 'name': 'Test Sahip', 'active': false}]);
    expect(() => FinanceSyncServer.owner(off, ownerIds: [4]), throwsFormatException);
  });
}
