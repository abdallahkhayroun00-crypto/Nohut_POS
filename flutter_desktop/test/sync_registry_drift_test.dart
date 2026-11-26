// Schema drift guard (spec V5 §4.4): any new top-level persisted key must be
// declared in lib/sync_registry.dart before CI passes.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/sync_registry.dart';

/// Receivers that hold the whole POS state somewhere in lib/.
const _roots = r'(?:(?<![\w.])(?:s|state|data|next|migrated|db|current|'
    r'updated|finished)|widget\.state|widget\.db|\.data)';

Set<String> scanSourceKeys() {
  final index = RegExp(_roots + r"\[\s*'(\w+)'\s*\]");
  final putIfAbsent = RegExp(_roots + r"\.putIfAbsent\(\s*'(\w+)'");
  final keys = <String>{};
  for (final file in Directory('lib').listSync().whereType<File>()) {
    if (!file.path.endsWith('.dart')) continue;
    final text = file.readAsStringSync();
    for (final m in [...index.allMatches(text), ...putIfAbsent.allMatches(text)]) {
      keys.add(m.group(1)!);
    }
  }
  return keys;
}

void main() {
  test('every default state key is registered', () {
    for (final key in emptyPosState().keys) {
      expect(syncEntityRegistry, contains(key), reason: key);
    }
  });

  test('every top-level key written by the source is registered', () {
    final unknown = scanSourceKeys()
        .where((k) =>
            !syncEntityRegistry.containsKey(k) &&
            !syncRegistryScannerFalsePositives.containsKey(k))
        .toList()
      ..sort();
    expect(unknown, isEmpty,
        reason: 'Declare these in lib/sync_registry.dart (registry or '
            'scanner false positives) and in docs/cloud-sync/'
            'data-inventory.md: $unknown');
  });

  test('registry and false-positive list do not overlap or go stale', () {
    final overlap = syncEntityRegistry.keys
        .where(syncRegistryScannerFalsePositives.containsKey);
    expect(overlap, isEmpty);
    final seen = scanSourceKeys();
    final stale = syncRegistryScannerFalsePositives.keys
        .where((k) => !seen.contains(k))
        .toList();
    expect(stale, isEmpty, reason: 'remove stale false positives: $stale');
  });

  test('secret and device-local keys never get a cloud target', () {
    for (final entry in syncEntityRegistry.entries) {
      if (entry.value.classes.contains(DataClass.secret)) {
        expect(entry.value.cloudTarget, isNull, reason: entry.key);
      }
    }
  });

  test('inventory document lists every registered key', () {
    final doc = File('../docs/cloud-sync/data-inventory.md');
    expect(doc.existsSync(), true);
    final text = doc.readAsStringSync();
    for (final key in syncEntityRegistry.keys) {
      expect(text, contains('`$key`'), reason: key);
    }
  });
}
