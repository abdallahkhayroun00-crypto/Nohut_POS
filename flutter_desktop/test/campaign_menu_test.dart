import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/campaign_menu.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/product_customization.dart';
import 'package:nohut_falafel_desktop/operations.dart';
import 'package:nohut_falafel_desktop/order_actions.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/staff_commands.dart';

Json fixture() => {
  ...emptyPosState(),
  'localMenu': (jsonDecode(
    File('assets/menu.json').readAsStringSync(),
  ) as Map)['products'],
  'qrCampaigns': [
    {
      'id': 'two',
      'active': true,
      'price': 300,
      'title': {'tr': '2’li Menü'},
      'items': [
        {'tr': '2 Falafel Dürüm'},
        {'tr': '2 Eker Ayran'},
      ],
    },
    {
      'id': 'four',
      'active': true,
      'price': 250,
      'title': {'tr': 'Falafel Menü'},
      'items': [
        {'tr': 'Falafel Dürüm'},
        {'tr': 'Tahinli Muhallebi'},
        {'tr': 'Şişe Cola Turka'},
        {'tr': 'Çay'},
      ],
    },
    {
      'id': 'dessert',
      'active': true,
      'price': 150,
      'title': {'tr': 'Layali Lübnan'},
      'items': [
        {'tr': 'Geleneksel Lübnan tatlısı'},
      ],
    },
  ],
};
Json draft(Json state) {
  final p = campaignProducts(state).first;
  return {
    ...p,
    'productId': p['id'],
    'basePrice': p['price'],
    'qty': 1,
    'note': '',
    'removed': <String>[],
    'adjustmentCents': 0,
  };
}

void main() {
  test('source prices and recipes become orderable virtual products without duplicate charges', () {
    final s = fixture(), campaigns = campaignProducts(s);
    expect(campaigns.map((p) => p['price']), [300, 250, 150]);
    expect(asMaps(campaigns.first['components']).map((c) => c['name']), [
      'Falafel Dürüm',
      'Falafel Dürüm',
      'Küçük Ayran',
      'Küçük Ayran',
    ]);
    expect(asMaps(campaigns[1]['components']).length, 4);
    expect(asMaps(campaigns[2]['components']).single['name'], 'Layali Lübnan');
    final line = draft(s);
    validateCashierDraft(s, [line]);
    final o = newLocalOrder(
      state: s,
      source: 'Masa',
      table: 1,
      productLines: [line],
    );
    expect(orderTotalCents(o), 30000);
    expect(billText(o), contains('Küçük Ayran'));
    expect(orderingProducts(s).first['category'], 'campaign');
  });
  test(
    'each wrap has separate notes and component extras multiply once per combo',
    () {
      final s = fixture(),
          line = draft(s),
          children = asMaps(line['components']);
      applyLineCustomization(children[0], 1000, 'Ek falafel', ['Domates']);
      children[1]['note'] = 'Sos ayrı';
      line['components'] = children;
      line['qty'] = 2;
      applyLineCustomization(line, 0, '', []);
      validateCashierDraft(s, [line]);
      expect(line['price'], 310);
      final o = newLocalOrder(
        state: s,
        source: 'Masa',
        table: 1,
        productLines: [line],
      );
      expect(orderTotalCents(o), 62000);
      expect(asMaps(line['components'])[1]['removed'], isEmpty);
      expect(billText(o), contains('Ek falafel'));
      splitEqually(o, 2);
      expect(guestBalance(o, 1), 31000);
      recordPayment(o, 31000, 'Nakit', guestId: 1);
      expect(orderDueCents(o), 31000);
    },
  );
  test('dates, missing products, disabled ingredients and malformed recipes cannot be sold', () {
    final s = fixture(), c = asMaps(s['qrCampaigns']).first;
    c['startsAt'] = '2026-11-01T00:00:00Z';
    c['endsAt'] = '2026-12-01T00:00:00Z';
    s['qrCampaigns'] = [c];
    expect(campaignProducts(s, now: DateTime.utc(2026, 10, 31)), isEmpty);
    expect(campaignProducts(s, now: DateTime.utc(2026, 11, 1)), hasLength(1));
    expect(campaignProducts(s, now: DateTime.utc(2026, 12, 1)), isEmpty);
    c.remove('startsAt');
    c.remove('endsAt');
    s['qrCampaigns'] = [c];
    (s['localMenu'] as List).firstWhere(
      (p) => p['name'] == 'Küçük Ayran',
    )['active'] = false;
    expect(campaignProducts(s), isEmpty);
  });
  test('stale draft refuses new prices; existing order edits keep the sold snapshot after expiry', () {
    final s = fixture(), line = draft(s);
    final o = newLocalOrder(
      state: s,
      source: 'Masa',
      table: 1,
      productLines: [line],
    );
    (s['qrCampaigns'] as List).first['price'] = 350;
    expect(
      () => validateCashierDraft(s, [copyJson(line)]),
      throwsFormatException,
    );
    expect(campaignProducts(s).first['price'], 350);
    expect(orderTotalCents(o), 30000);
    (s['qrCampaigns'] as List).first['active'] = false;
    expect(
      () => validateCashierDraft(s, [copyJson(line)]),
      throwsFormatException,
    );
    final children = asMaps(line['components']);
    applyLineCustomization(children.first, 500, 'Ek sos', []);
    editLocalLine(o, '1:0', 1, '', [], 'Kasa', components: children);
    expect(orderTotalCents(o), 30500);
  });
  test('forged component price, name and base are ignored; changed slots or quantity rejected', () {
    final s = fixture(), line = draft(s), children = asMaps(line['components']);
    children.first.addAll({'price': 0, 'basePrice': 0, 'name': 'Forged'});
    line['components'] = children;
    final resolved = prepareCampaignLine(s, line);
    expect(resolved['price'], 300);
    expect(asMaps(resolved['components']).first['basePrice'], 140);
    children.first['qty'] = 2;
    expect(() => prepareCampaignLine(s, line), throwsFormatException);
    children.first['qty'] = 1;
    children.first['slot'] = 99;
    expect(() => prepareCampaignLine(s, line), throwsFormatException);
  });
  test('phone submits campaign, edits and retries atomically using authoritative source prices', () {
    final dir = Directory.systemTemp.createTempSync('campaign_test_');
    final store = PosStore(databaseFile: '${dir.path}/db');
    try {
      final s = fixture();
      expect(store.replace(s, store.read().revision).ok, true);
      final line = draft(s);
      line['price'] = 1;
      final payload = {
        'requestId': 'campaign_order_1',
        'staffId': 1,
        'expectedRevision': store.read().revision,
        'source': 'Masa',
        'table': 1,
        'lines': [line],
      };
      final result = submitStaffOrder(store, payload);
      final again = submitStaffOrder(store, payload);
      expect(result, again);
      expect(store.read().data['orders'], hasLength(1));
      final o = asMaps(store.read().data['orders']).single;
      expect(orderTotalCents(o), 30000);
      expect(
        asMaps(asMaps(o['batches']).single['lines']).single['campaignId'],
        'two',
      );
    } finally {
      store.dispose();
      dir.deleteSync(recursive: true);
    }
  });
}
