// The Dart catalogue is generated from the shared contract used by the
// server, both PWAs and the Android apps; it must never drift.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/permission_catalogue.g.dart';

void main() {
  test('permission_catalogue.g.dart matches docs/contracts/v1/permissions.json', () {
    final contract = jsonDecode(File('../docs/contracts/v1/permissions.json').readAsStringSync()) as Map;
    expect(permissionCatalogueVersion, contract['schemaVersion']);
    final ops = {for (final o in contract['operations'] as List) (o as Map)['id'] as String: o};
    expect(permissionCatalogue.keys.toSet(), ops.keys.toSet());
    for (final MapEntry(:key, :value) in permissionCatalogue.entries) {
      final o = ops[key]!;
      expect(value.section, o['section'], reason: key);
      expect(value.sensitivity, o['sensitivity'], reason: key);
      expect(value.clients, List<String>.from(o['clients'] as List), reason: key);
    }
  });

  test('Bulut and Yedek operations are Windows-only (§22.3)', () {
    for (final MapEntry(:key, :value) in permissionCatalogue.entries) {
      if (value.section == 'sync' || value.section == 'backup') {
        expect(value.clients, ['windows'], reason: key);
      }
    }
  });
}
