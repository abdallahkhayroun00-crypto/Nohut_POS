// Phone edits of the shared QR menu draft (relay 7226917068): server-side
// grants, draft-bound writes, audit, idempotency, publish stays on Windows.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/lan_auth_gate.dart';
import 'package:nohut_falafel_desktop/local_accounts.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/qr_menu_lan_api.dart';
import 'package:nohut_falafel_desktop/qr_menu_remote.dart';

Json catalog() => {
      'schemaVersion': 1,
      'categories': [
        {'id': 'durum', 'name': {'tr': 'Dürümler', 'en': 'Wraps', 'ar': 'لفائف'}, 'order': 0, 'active': true},
      ],
      'products': [
        {'id': 1, 'legacyKey': 'Falafel Dürüm', 'category': 'durum',
          'name': {'tr': 'Falafel Dürüm', 'en': 'Falafel Wrap', 'ar': 'لفافة فلافل'},
          'price': 140, 'available': true, 'active': true, 'order': 0},
      ],
      'campaigns': <Object?>[],
    };

void main() {
  late Directory dir;
  late PosStore store;
  late LocalAuth auth;
  late QrMenuLanApi api;
  late String owner, staff, cashier;
  var n = 0;
  String rid() => 'req-qr-${(n++).toString().padLeft(4, '0')}';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('nohut-qr-remote');
    store = PosStore(databaseFile: '${dir.path}/db');
    auth = LocalAuth(store.authDatabase, iterations: 1000);
    await auth.createUser(username: 'sahip', password: 'owner-pass-1', role: 'Yönetici', isOwner: true);
    await auth.createUser(username: 'ayse', password: 'staff-pass-1', role: 'Personel', employeeId: 2);
    final mudur = await auth.createUser(username: 'mert', password: 'staff-pass-2', role: 'Personel', employeeId: 3);
    auth.setGrant(mudur, 'menu.price.edit', true);
    auth.setGrant(mudur, 'menu.product.edit', true);
    Future<String> login(String u, String p, String client, String dev) async =>
        (await auth.login(username: u, password: p, deviceId: dev, client: client)).token;
    owner = await login('sahip', 'owner-pass-1', 'yonetici', 'device-owner-000000001');
    staff = await login('ayse', 'staff-pass-1', 'personel', 'device-staff-000000001');
    cashier = await login('mert', 'staff-pass-2', 'personel', 'device-staff-000000002');
    api = QrMenuLanApi(store, LanAuthGate(auth), clock: () => DateTime.utc(2026, 11, 27, 21));
  });
  tearDown(() {
    store.dispose();
    dir.deleteSync(recursive: true);
  });

  void seed({bool pending = false}) {
    final s = store.read();
    final data = copyJson(s.data)
      ..['qrPublisherDraftSourceSnapshot'] = catalog()
      ..['qrPublisherDraftRevision'] = 'sha-1';
    if (pending) data['qrPublisherPendingPublish'] = {'revision': 'sha-1', 'at': '2026-11-27T20:00:00Z', 'changes': 1};
    store.replace(data, s.revision);
  }

  Future<(int, Json)> view(String token, [String client = 'personel']) async {
    final r = await api.handle('GET', 'view', {'client': client}, {}, token: token);
    return (r.status, r.body);
  }

  Future<(int, Json)> write(String token, Json body, [String client = 'personel']) async {
    final r = await api.handle('POST', 'write', {}, {'client': client, 'requestId': rid(), ...body}, token: token);
    return (r.status, r.body);
  }

  test('no login, no menu: refused or told to load it on Windows', () async {
    expect((await view('nope')).$1, 401);
    final (code, body) = await view(staff);
    expect(code, 200);
    expect(body['available'], false);
    expect('${body['message']}', contains('Windows'));
  });

  test('Personel: stock yes, price no; the phone never sees a key and publish stays on Windows', () async {
    seed();
    final (_, v) = await view(staff);
    expect(v['available'], true);
    expect(v['publish'], 'windows');
    expect(v['can'], {'menu.product.edit': false, 'menu.price.edit': false, 'menu.category.edit': false,
      'menu.campaign.edit': false, 'menu.stock.toggle': true});
    expect('$v', isNot(contains('token')));
    final stamp = v['stamp'];
    final (no, nb) = await write(staff, {'action': 'set_price', 'id': 1, 'priceCents': 15000, 'expectedStamp': stamp});
    expect(no, 403);
    expect(nb['error'], 'forbidden');
    final (ok, ob) = await write(staff, {'action': 'set_stock', 'id': 1, 'available': false, 'expectedStamp': stamp});
    expect(ok, 200, reason: '$ob');
    final data = store.read().data;
    expect(data['qrPublisherDraft']['products'][0]['available'], false);
    expect(data['qrPublisherDraftSourceSnapshot']['products'][0]['available'], true, reason: 'published base untouched');
    final audit = asMaps(data[qrMenuAuditKey]).single;
    expect(audit['by'], 'ayse');
    expect(audit['action'], 'set_stock');
    final (_, after) = await view(staff);
    expect(after['changes'], [{'list': 'products', 'id': 1, 'label': 'Falafel Dürüm', 'detail': 'Tükendi'}]);
  });

  test('a stale draft is refused, never merged blindly', () async {
    seed();
    final (_, v) = await view(cashier);
    final stamp = v['stamp'];
    expect((await write(cashier, {'action': 'set_price', 'id': 1, 'priceCents': 15000, 'expectedStamp': stamp})).$1, 200);
    final (code, body) = await write(staff, {'action': 'set_stock', 'id': 1, 'available': false, 'expectedStamp': stamp});
    expect(code, 409);
    expect(body['error'], 'conflict');
    expect(store.read().data['qrPublisherDraft']['products'][0]['price'], 150);
  });

  test('granted manager: new product with TR/EN/AR and price; back to base clears the draft', () async {
    seed();
    var (_, v) = await view(cashier);
    final (code, body) = await write(cashier, {
      'action': 'save_product', 'expectedStamp': v['stamp'], 'category': 'durum', 'priceCents': 8550,
      'name': {'tr': 'Mercimek Çorbası', 'en': 'Lentil Soup', 'ar': 'شوربة عدس'},
    });
    expect(code, 200, reason: '$body');
    expect(body['id'], 2);
    final p = asMaps(store.read().data['qrPublisherDraft']['products']).last;
    expect(p['price'], 85.5);
    expect(p['legacyKey'], 'pos-id-2');
    expect((await write(cashier, {'action': 'save_product', 'expectedStamp': body['stamp'], 'category': 'durum',
      'priceCents': 100, 'name': {'tr': 'Falafel Dürüm', 'en': 'x', 'ar': 'y'}})).$2['message'], contains('zaten'));
    // Missing translations are refused.
    (_, v) = await view(cashier);
    expect((await write(cashier, {'action': 'save_product', 'expectedStamp': v['stamp'], 'category': 'durum',
      'priceCents': 100, 'name': {'tr': 'Yeni', 'en': '', 'ar': ''}})).$1, 422);
    // Owner hides then shows: equal to base again for that field.
    (_, v) = await view(owner, 'yonetici');
    final (h, hb) = await write(owner, {'action': 'set_visible', 'list': 'products', 'id': 1, 'active': false,
      'expectedStamp': v['stamp']}, 'yonetici');
    expect(h, 200);
    expect((await write(owner, {'action': 'set_visible', 'list': 'products', 'id': 1, 'active': true,
      'expectedStamp': hb['stamp']}, 'yonetici')).$1, 200);
    expect(asMaps(store.read().data['qrPublisherDraft']['products']).length, 2);
  });

  test('a phone edit that returns to the published menu removes the draft', () async {
    seed();
    var (_, v) = await view(staff);
    final (_, a) = await write(staff, {'action': 'set_stock', 'id': 1, 'available': false, 'expectedStamp': v['stamp']});
    expect(store.read().data['qrPublisherDraft'], isNotNull);
    await write(staff, {'action': 'set_stock', 'id': 1, 'available': true, 'expectedStamp': a['stamp']});
    expect(store.read().data['qrPublisherDraft'], isNull);
    (_, v) = await view(staff);
    expect(v['changes'], isEmpty);
  });

  test('while Windows verifies a publish, phones cannot edit', () async {
    seed(pending: true);
    final (_, v) = await view(owner, 'yonetici');
    expect(v['pendingPublish'], true);
    final (code, _) = await write(owner, {'action': 'set_stock', 'id': 1, 'available': false,
      'expectedStamp': v['stamp']}, 'yonetici');
    expect(code, 409);
  });

  test('same request id twice is applied once', () async {
    seed();
    final (_, v) = await view(staff);
    final body = {'client': 'personel', 'requestId': 'req-qr-same-0001', 'action': 'set_stock', 'id': 1,
      'available': false, 'expectedStamp': v['stamp']};
    final a = await api.handle('POST', 'write', {}, body, token: staff);
    final b = await api.handle('POST', 'write', {}, body, token: staff);
    expect(a.status, 200);
    expect(b.status, 200);
    expect(asMaps(store.read().data[qrMenuAuditKey]).length, 1);
  });

  test('categories and campaigns need their own grants', () async {
    seed();
    final (_, v) = await view(cashier);
    expect((await write(cashier, {'action': 'save_category', 'isNew': true, 'id': 'icecek',
      'name': {'tr': 'İçecekler', 'en': 'Drinks', 'ar': 'مشروبات'}, 'expectedStamp': v['stamp']})).$1, 403);
    final (_, o) = await view(owner, 'yonetici');
    final (c, cb) = await write(owner, {'action': 'save_category', 'isNew': true, 'id': 'icecek',
      'name': {'tr': 'İçecekler', 'en': 'Drinks', 'ar': 'مشروبات'}, 'expectedStamp': o['stamp']}, 'yonetici');
    expect(c, 200, reason: '$cb');
    final (k, kb) = await write(owner, {'action': 'save_campaign', 'isNew': true, 'id': 'aksam',
      'title': {'tr': 'Akşam', 'en': 'Evening', 'ar': 'مساء'}, 'priceCents': 19900,
      'poster': 'assets/campaigns/aksam.webp', 'thumbnail': 'assets/campaigns/aksam-k.webp',
      'expectedStamp': cb['stamp']}, 'yonetici');
    expect(k, 200, reason: '$kb');
    final draft = store.read().data['qrPublisherDraft'];
    expect(asMaps(draft['campaigns']).single['active'], false, reason: 'new campaigns start passive');
  });
}
