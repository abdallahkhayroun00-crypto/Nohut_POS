// Phase 1B step 1: decoded-state cache and structural copy must keep the
// exact old semantics (isolation, cross-connection visibility, JSON rules).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('nohut-cache'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('copyJson equals a JSON round trip and rejects what JSON rejects', () {
    final value = <String, dynamic>{
      'a': 1, 'b': 2.5, 'c': 'ğüşİ', 'd': null, 'e': true,
      'f': [1, {'g': [2.0, 'x']}], 'h': <String, dynamic>{},
    };
    final copy = copyJson(value);
    expect(jsonEncode(copy), jsonEncode(value));
    expect(copy, jsonDecode(jsonEncode(value)));
    (copy['f'] as List)[0] = 9;
    expect((value['f'] as List)[0], 1, reason: 'deep, not shallow');
    expect(() => copyJson({'n': double.nan}), throwsA(isA<JsonUnsupportedObjectError>()));
    expect(() => copyJson({'m': {1: 'x'}}), throwsA(isA<JsonUnsupportedObjectError>()));
    expect(() => copyJson({'o': Object()}), throwsA(isA<JsonUnsupportedObjectError>()));
  });

  test('a second connection always sees the latest committed state', () {
    final file = '${dir.path}/db';
    final a = PosStore(databaseFile: file), b = PosStore(databaseFile: file);
    try {
      expect(b.read().data['nextId'], 1200); // fills b's cache
      final s = a.read().data..['nextId'] = 1300;
      expect(a.replace(s, a.read().revision).ok, true);
      expect(b.read().data['nextId'], 1300);
      expect(b.read().revision, a.read().revision);
      // b writes; a sees it.
      final t = b.read().data..['nextId'] = 1400;
      expect(b.replace(t, b.read().revision).ok, true);
      expect(a.read().data['nextId'], 1400);
      // Stale revision is still refused.
      expect(a.replace(s, 1).ok, false);
    } finally {
      a.dispose();
      b.dispose();
    }
  });

  test('callers never share the cached state', () {
    final store = PosStore(databaseFile: '${dir.path}/db');
    try {
      final first = store.read().data;
      (first['employees'] as List).clear();
      expect((store.read().data['employees'] as List), isNotEmpty);
      final next = store.read().data..['nextId'] = 1500;
      store.replace(next, store.read().revision);
      next['nextId'] = 1; // mutate after commit
      expect(store.read().data['nextId'], 1500);
      final result = store.command('request_cache_1', {'x': 1}, (s) {
        s['nextId'] = 1600;
        return {'ok': true};
      });
      expect(result['ok'], true);
      expect(store.read().data['nextId'], 1600);
      // A failing command leaves the cache untouched.
      expect(() => store.command('request_cache_2', {'x': 2}, (s) {
        s['nextId'] = 1;
        throw const FormatException('stop');
      }), throwsFormatException);
      expect(store.read().data['nextId'], 1600);
    } finally {
      store.dispose();
    }
  });

  test('no history ceiling: more than 50 000 orders and 100 000 jobs validate',
      () {
    final state = emptyPosState();
    final orders = state['orders'] as List, jobs = state['printJobs'] as List;
    for (var i = 0; i < 50001; i++) {
      orders.add({
        'id': 1200 + i, 'source': 'Gel-Al', 'table': null, 'closed': true,
        'batches': [
          {'id': 1, 'lines': [
            {'name': 'Ayran', 'qty': 1, 'price': 35},
          ]},
        ],
        'payments': <dynamic>[],
      });
      jobs..add({'orderId': 1200 + i, 'batchId': 1, 'state': 'Kuyruğa gönderildi'})
        ..add({'orderId': 1200 + i, 'batchId': -1, 'state': 'Kuyruğa gönderildi'});
    }
    state['nextId'] = 1200 + 50001;
    expect(() => PosStore.validate(state), returnsNormally);
  });
}
