import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/cloud_finance_serializer.dart';
import 'package:nohut_falafel_desktop/cloud_platform_serializer.dart';
import 'package:nohut_falafel_desktop/sync_outbox.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/synthetic_platform_order.dart';

void main() {
  test(
    'platform commercial projection keeps cancelled facts, source total and privacy',
    () {
      final db = sqlite3.openInMemory();
      try {
        final source = syntheticPlatformOrder();
        expect(source['lines'], hasLength(2));
        expect(source['lineFacts'], hasLength(3));
        final raw = Map<String, dynamic>.from(
          projectRow('trendyolGoOrders', source) as Map,
        );
        final json = jsonEncode(raw);
        for (final private in [
          'Private PlatformCustomer',
          '0850 000 0000',
          'Synthetic private address',
          'private@example.invalid',
        ]) {
          expect(json, isNot(contains(private)));
        }
        expect(raw['customerNote'], contains('Sos ayrı olsun'));
        expect(source['customerName'], 'Private PlatformCustomer');
        final projection = serializeTgoOrder(
          raw,
          CloudIdentityMap(db),
          '2026-11-27T12:00:00Z',
        );
      final fixturePath=Platform.environment['NOHUT_EXPORT_SYNTHETIC_PLATFORM'];
      if(fixturePath!=null)File(fixturePath).writeAsStringSync(jsonEncode(projection));
        final rows = (projection['rows'] as List).cast<Map>();
        final items = rows
            .where((r) => r['table'] == 'platform_line_versions')
            .map((r) => r['data'] as Map)
            .toList();
        expect(items, hasLength(3));
        expect(items.map((i) => i['line_version_id']).toSet(), hasLength(3));
        expect(items.last['original_qty'], 1);
        expect(items.last['qty'], 0);
        expect(items.last['cancelled_item_ids'], ['item-c']);
        final header =
            rows.singleWhere(
                  (r) => r['table'] == 'platform_order_versions',
                )['data']
                as Map;
        expect(
          header['total_kurus'],
          2000,
          reason:
              'platform total can differ from line sum; do not guess discount',
        );
        expect(header['sales_eligible'], false);
        expect(header['source_complete'], true);
        final record =
            rows.singleWhere(
                  (r) => r['table'] == 'platform_order_records',
                )['data']
                as Map;
        expect(record['net_kurus'], null);
        expect(record['commission_kurus'], null);
        expect(record['gross_kurus'], null);
        final retry = serializeTgoOrder(
          raw,
          CloudIdentityMap(db),
          '2026-11-27T12:01:00Z',
        );
        expect(retry['record_id'], projection['record_id']);
        expect(retry['platform_version_id'], projection['platform_version_id']);
        raw['status'] = 'Delivered';
        final changed = serializeTgoOrder(
          raw,
          CloudIdentityMap(db),
          '2026-11-27T12:02:00Z',
        );
        expect(changed['record_id'], projection['record_id']);
        expect(changed['order_id'], projection['order_id']);
        expect(
          changed['platform_version_id'],
          isNot(projection['platform_version_id']),
        );
      } finally {
        db.close();
      }
    },
  );
  test(
    'legacy duplicated lines remain separate facts without guessed original quantity',
    () {
      final db = sqlite3.openInMemory();
      try {
        final raw =
            Map<String, dynamic>.from(
                projectRow('trendyolGoOrders', syntheticPlatformOrder()) as Map,
              )
              ..remove('lineFacts')
              ..remove('totalKnown');
        final first = (raw['lines'] as List).first;
        raw['lines'] = [first, first];
        final p = serializeTgoOrder(
          raw,
          CloudIdentityMap(db),
          '2026-11-27T12:00:00Z',
        );
        final items = (p['rows'] as List)
            .cast<Map>()
            .where((r) => r['table'] == 'platform_line_versions')
            .map((r) => r['data'] as Map)
            .toList();
        expect(items.map((r) => r['line_version_id']).toSet(), hasLength(2));
        expect(
          items.every(
            (r) => r['original_qty'] == null && r['quantity_known'] == false,
          ),
          true,
        );
        final foreign = Map<String, dynamic>.from(raw)..['supplierId'] = '999';
        expect(
          serializeTgoOrder(
            foreign,
            CloudIdentityMap(db),
            '2026-11-27T12:00:00Z',
          )['order_id'],
          isNot(p['order_id']),
        );
        raw['totalCents'] = 1.5;
        expect(
          () => serializeTgoOrder(
            raw,
            CloudIdentityMap(db),
            '2026-11-27T12:00:00Z',
          ),
          throwsFormatException,
        );
      } finally {
        db.close();
      }
    },
  );
}
