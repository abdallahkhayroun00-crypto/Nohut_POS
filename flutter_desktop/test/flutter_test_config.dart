// Runtime persistence validation for the whole test suite (spec V5.1 §4.4,
// owner decision 6): every state committed through PosStore during any test
// must contain only declared field paths (lib/sync_field_registry.dart).
// NOHUT_FIELD_DUMP=<file> instead records every observed path (discovery).
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/sync_field_registry.dart';

/// Fixture-only fields that tests inject on purpose, with the reason.
const _testOnlyPaths = <String, String>{
  'trendyolGoOrders[].apiSecret':
      'staff_platform_action_test proves the LAN projection drops it',
};

void _walk(Object? v, String path, Set<String> out) {
  if (v is Map) {
    for (final e in v.entries) {
      final p = path.isEmpty ? '${e.key}' : '$path.${e.key}';
      out.add(p);
      _walk(e.value, p, out);
    }
  } else if (v is List) {
    for (final x in v) {
      _walk(x, '$path[]', out);
    }
  }
}

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final out = Platform.environment['NOHUT_FIELD_DUMP'];
  if (out != null) {
    final seen = <String>{};
    PosStore.debugWriteObserver = (state) => _walk(state, '', seen);
    tearDownAll(() => File(out)
        .writeAsStringSync('${seen.join('\n')}\n', mode: FileMode.append));
  } else {
    PosStore.debugWriteObserver = (state) {
      final unknown = unregisteredFieldPaths(state)
          .where((p) => !_testOnlyPaths.containsKey(p))
          .toList();
      if (unknown.isNotEmpty) {
        throw StateError(
          'Unregistered persisted field(s): $unknown. Declare them in '
          'lib/sync_field_paths.g.dart and docs/cloud-sync/data-inventory.md.',
        );
      }
    };
  }
  await testMain();
}
