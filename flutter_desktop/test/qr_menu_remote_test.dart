// Phone edits and publishing of the shared QR menu draft (relays 7226917068,
// 7226936601 / QA-18): Personel and Yönetici hold every menu.* operation by
// default, publishing included, always with Windows' own key; server-side
// grants, draft-bound writes, audit, idempotency, no key on any phone.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/lan_auth_gate.dart';
import 'package:nohut_falafel_desktop/local_accounts.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/qr_menu_lan_api.dart';
import 'package:nohut_falafel_desktop/qr_menu_remote.dart';
import 'package:nohut_falafel_desktop/qr_publisher_client.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;

const secret = 'ghp_FAKEPUBLISHERKEYNEVERONAPHONE0000000';

/// Windows' local publisher, faked: GitHub revision moves on each publish.
class FakePublisher extends QrPublisherClient {
  FakePublisher() : super('/nonexistent/db.sqlite3', testToken: secret);
  bool token = true, up = true;
  String revision = 'sha-1';
  Json remote = menuCatalog();
  String? failNext; // lost | lostAfterWrite | refuse
  int publishes = 0, uploads = 0;
  @override
  Future<bool> hasToken() async => token;
  @override
  Future<bool> health(String endpoint) async => up;
  @override
  Future<Map<String, dynamic>> catalog(String endpoint) async => {'revision': revision, 'catalog': copyJson(remote)};
  @override
  Future<Map<String, dynamic>> publish(String endpoint, String revision, Json menu) async {
    publishes++;
    final mode = failNext;
    failNext = null;
    if (mode == 'lost') throw const QrPublisherNoAnswer('zaman aşımı');
    if (mode == 'refuse' || revision != this.revision) throw const QrPublisherRefused('Web menüsü değişti.', 409);
    remote = copyJson(menu);
    this.revision = 'sha-p$publishes';
    if (mode == 'lostAfterWrite') throw const QrPublisherNoAnswer('bağlantı kesildi');
    return {'published': true, 'revision': this.revision, 'commit': 'c0ffee$publishes'};
  }
  @override
  Future<Map<String, dynamic>> uploadImage(String endpoint, String mime, List<int> bytes) async {
    uploads++;
    return {'path': 'assets/products/upload-$uploads.webp'};
  }
}

Json catalog() => menuCatalog();
Json menuCatalog() => {
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
  late FakePublisher pub;
  late String owner, staff, cashier, manager;
  late String staffId;
  var syncs = 0;
  var n = 0;
  String rid() => 'req-qr-${(n++).toString().padLeft(4, '0')}';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('nohut-qr-remote');
    store = PosStore(databaseFile: '${dir.path}/db');
    auth = LocalAuth(store.authDatabase, iterations: 1000);
    await auth.createUser(username: 'sahip', password: 'owner-pass-1', role: 'Yönetici', isOwner: true);
    staffId = await auth.createUser(username: 'ayse', password: 'staff-pass-1', role: 'Personel', employeeId: 2);
    // 'mert' is a Personel whose menu grants the owner narrowed to price/product.
    final narrowed = await auth.createUser(username: 'mert', password: 'staff-pass-2', role: 'Personel', employeeId: 3);
    for (final op in ['menu.category.edit', 'menu.campaign.edit', 'menu.stock.toggle', 'menu.qr.publish']) {
      auth.setGrant(narrowed, op, false);
    }
    await auth.createUser(username: 'selin', password: 'staff-pass-3', role: 'Yönetici', employeeId: 4);
    Future<String> login(String u, String p, String client, String dev) async =>
        (await auth.login(username: u, password: p, deviceId: dev, client: client)).token;
    owner = await login('sahip', 'owner-pass-1', 'yonetici', 'device-owner-000000001');
    staff = await login('ayse', 'staff-pass-1', 'personel', 'device-staff-000000001');
    cashier = await login('mert', 'staff-pass-2', 'personel', 'device-staff-000000002');
    manager = await login('selin', 'staff-pass-3', 'yonetici', 'device-yonet-000000001');
    pub = FakePublisher();
    syncs = 0;
    final clock = () => DateTime.utc(2026, 11, 27, 21);
    api = QrMenuLanApi(store, LanAuthGate(auth), clock: clock, remote: QrMenuRemoteService(store,
        publisher: () => pub, endpoint: () => 'http://127.0.0.1:18787/', clock: clock,
        syncPos: () async => syncs++));
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

  Future<(int, Json)> post(String token, String path, Json body, [String client = 'personel']) async {
    final r = await api.handle('POST', path, {}, {'client': client, 'requestId': rid(), ...body}, token: token);
    return (r.status, r.body);
  }

  const allMenu = {'menu.product.edit': true, 'menu.price.edit': true, 'menu.category.edit': true,
    'menu.campaign.edit': true, 'menu.stock.toggle': true, 'menu.qr.publish': true};

  test('Personel and Yönetici hold every menu.* by default; nothing else widened', () async {
    seed();
    for (final (token, client) in [(staff, 'personel'), (manager, 'yonetici')]) {
      final (code, v) = await view(token, client);
      expect(code, 200, reason: '$client $v');
      expect(v['can'], allMenu, reason: client);
      expect(v['publish'], 'here');
      expect(v['link'], 'ready');
    }
    for (final op in ['users.manage', 'sync.cloud.configure', 'sync.full_resync', 'backup.view', 'audit.view']) {
      expect(LocalAuth.defaultGrants('Personel'), isNot(contains(op)), reason: op);
    }
    for (final role in ['Personel', 'Müdür', 'Yönetici']) {
      expect(LocalAuth.defaultGrants(role), containsAll(allMenu.keys), reason: role);
    }
    expect(LocalAuth.defaultGrants('Muhasebe').where((op) => op.startsWith('menu.')), ['menu.view']);
  });

  test('both roles: stock, price, visibility, product, category, campaign, photo, publish, sync', () async {
    for (final (token, client, who) in [(staff, 'personel', 'ayse'), (manager, 'yonetici', 'selin')]) {
      seed();
      store.replace(copyJson(store.read().data)..remove('qrPublisherDraft')..remove(qrMenuAuditKey), store.read().revision);
      pub.revision = 'sha-1';
      pub.remote = menuCatalog();
      var (_, v) = await view(token, client);
      Future<Json> ok(String path, Json body) async {
        final (code, b) = await post(token, path, {'expectedStamp': v['stamp'], ...body}, client);
        expect(code, 200, reason: '$who $path $body → $b');
        (_, v) = await view(token, client);
        return b;
      }
      await ok('write', {'action': 'set_stock', 'id': 1, 'available': false});
      await ok('write', {'action': 'set_price', 'id': 1, 'priceCents': 15000});
      await ok('write', {'action': 'set_visible', 'list': 'products', 'id': 1, 'active': true});
      await ok('write', {'action': 'save_product', 'category': 'durum', 'priceCents': 8550,
        'name': {'tr': 'Mercimek', 'en': 'Lentil', 'ar': 'عدس'}});
      await ok('write', {'action': 'save_category', 'isNew': true, 'id': 'icecek',
        'name': {'tr': 'İçecekler', 'en': 'Drinks', 'ar': 'مشروبات'}});
      await ok('write', {'action': 'save_campaign', 'isNew': true, 'id': 'aksam',
        'title': {'tr': 'Akşam', 'en': 'Evening', 'ar': 'مساء'}, 'priceCents': 19900,
        'poster': 'assets/campaigns/aksam.webp', 'thumbnail': 'assets/campaigns/aksam-k.webp'});
      await ok('image', {'id': 1, 'mime': 'image/webp', 'base64': base64Encode([1, 2, 3, 4])});
      expect(asMaps(v['catalog']['products']).first['image'], startsWith('assets/products/upload-'));
      expect(v['changes'], isNotEmpty);
      final published = await ok('publish', {});
      expect(published['outcome'], 'published', reason: '$published');
      expect(asMaps(pub.remote['products']).first['price'], 150);
      expect(v['changes'], isEmpty, reason: 'base is now what was published');
      expect(v['revision'], pub.revision);
      final data = store.read().data;
      expect(data['qrPublisherDraft'], isNull);
      expect(data['qrPublisherPendingPublish'], isNull);
      final audit = asMaps(data[qrMenuAuditKey]);
      expect(audit.map((a) => a['by']).toSet(), {who});
      expect(audit.map((a) => a['action']), containsAll(['publish_requested', 'publish', 'set_image']));
      await ok('sync', {});
    }
    expect(syncs, 2);
    expect(pub.publishes, 2);
  });

  test('publish needs a reviewed, current, valid draft and a working Windows link', () async {
    seed();
    var (_, v) = await view(staff);
    expect((await post(staff, 'publish', {'expectedStamp': v['stamp']})).$1, 422, reason: 'nothing to publish');
    final (_, a) = await write(staff, {'action': 'set_stock', 'id': 1, 'available': false, 'expectedStamp': v['stamp']});
    expect((await post(staff, 'publish', {'expectedStamp': v['stamp']})).$1, 409, reason: 'reviewed an older draft');
    pub.token = false;
    final (k, kb) = await post(staff, 'publish', {'expectedStamp': a['stamp']});
    expect(k, 422);
    expect('${kb['message']}', contains('anahtar'));
    pub.token = true;
    pub.up = false;
    expect('${(await post(staff, 'publish', {'expectedStamp': a['stamp']})).$2['message']}', contains('çalışmıyor'));
    pub.up = true;
    (_, v) = await view(staff);
    expect(v['link'], 'ready');
    expect(pub.publishes, 0);
    // GitHub refuses (it moved on): pending cleared, draft kept, nothing published.
    pub.failNext = 'refuse';
    final (_, r) = await post(staff, 'publish', {'expectedStamp': a['stamp']});
    expect(r['outcome'], 'refused');
    expect(store.read().data['qrPublisherPendingPublish'], isNull);
    expect(store.read().data['qrPublisherDraft'], isNotNull);
  });

  test('a lost answer blocks edits and publishes until verified; verify never republishes', () async {
    seed();
    final (_, v) = await view(manager, 'yonetici');
    final (_, a) = await write(manager, {'action': 'set_stock', 'id': 1, 'available': false, 'expectedStamp': v['stamp']}, 'yonetici');
    pub.failNext = 'lostAfterWrite';
    final (_, p) = await post(manager, 'publish', {'expectedStamp': a['stamp']}, 'yonetici');
    expect(p['outcome'], 'unknown');
    final (_, mid) = await view(staff);
    expect(mid['pendingPublish'], true);
    expect((await post(staff, 'publish', {'expectedStamp': mid['stamp']})).$1, 409);
    expect((await write(staff, {'action': 'set_stock', 'id': 1, 'available': true, 'expectedStamp': mid['stamp']})).$1, 409);
    final (_, rc) = await post(staff, 'reconcile', {});
    expect(rc['outcome'], 'confirmed');
    expect(pub.publishes, 1);
    final (_, after) = await view(staff);
    expect(after['pendingPublish'], false);
    expect(after['changes'], isEmpty);
    expect(after['revision'], pub.revision);
    // Not applied: the draft stays and can be published again.
    final (_, b) = await write(staff, {'action': 'set_stock', 'id': 1, 'available': true, 'expectedStamp': after['stamp']});
    pub.failNext = 'lost';
    expect((await post(staff, 'publish', {'expectedStamp': b['stamp']})).$2['outcome'], 'unknown');
    expect((await post(staff, 'reconcile', {})).$2['outcome'], 'not_applied');
    expect((await post(staff, 'publish', {'expectedStamp': b['stamp']})).$2['outcome'], 'published');
  });

  test('anonymous, revoked, deactivated and narrowed accounts are refused; no key ever leaves Windows', () async {
    seed();
    final (_, v) = await view(staff);
    final stamp = v['stamp'];
    final (_, ed) = await write(staff, {'action': 'set_stock', 'id': 1, 'available': false, 'expectedStamp': stamp});
    for (final path in ['view', 'write', 'publish', 'reconcile', 'image', 'sync']) {
      final r = await api.handle(path == 'view' ? 'GET' : 'POST', path, {}, {'client': 'personel'}, token: null);
      expect(r.status, 401, reason: 'anonymous $path');
      expect((await api.handle('POST', path, {}, {'client': 'personel'}, token: 'forged-token')).status, 401);
    }
    // Narrowed by the owner: no publish, no stock, no category.
    expect((await post(cashier, 'publish', {'expectedStamp': ed['stamp']})).$2['error'], 'forbidden');
    expect((await post(cashier, 'reconcile', {})).$1, 403);
    // A Personel phone cannot widen its own grants by claiming the Yönetici client.
    final (cc, _) = await view(cashier, 'yonetici');
    expect(cc, anyOf(401, 403));
    // Revoked session and deactivated user.
    auth.revokeSessions(staffId);
    expect((await post(staff, 'publish', {'expectedStamp': ed['stamp']})).$1, 401);
    auth.setActive(staffId, false);
    await expectLater(auth.login(username: 'ayse', password: 'staff-pass-1', deviceId: 'device-staff-000000001',
        client: 'personel'), throwsA(isA<LocalAuthException>()));
    expect(pub.publishes, 0);
    // Nothing any phone can read carries the publisher key or token fields.
    final (_, mv) = await view(manager, 'yonetici');
    final everything = jsonEncode([mv, store.read().data[qrMenuAuditKey]]);
    expect(everything, isNot(contains(secret)));
    expect(everything.toLowerCase(), isNot(contains('token')));
  });

  test('one-time upgrade gives existing staff the menu.* grants, keeps owner removals afterwards', () async {
    final db = sqlite3.openInMemory();
    var a = LocalAuth(db, iterations: 1000);
    await a.createUser(username: 'sahip', password: 'owner-pass-1', role: 'Yönetici', isOwner: true);
    final old = await a.createUser(username: 'eski', password: 'staff-pass-1', role: 'Personel');
    final acc = await a.createUser(username: 'muhasebe', password: 'staff-pass-2', role: 'Muhasebe');
    // Simulate a database from before the decision: old Personel template, flag absent.
    db.execute('UPDATE auth_users SET grants=? WHERE user_id=?', [jsonEncode(['menu.stock.toggle', 'menu.view', 'shifts.self']), old]);
    db.execute("DELETE FROM auth_settings WHERE key='upgrade.menu_parity_2026_11_27'");
    a = LocalAuth(db, iterations: 1000);
    List<String> grants(String id) => (jsonDecode(db.select('SELECT grants FROM auth_users WHERE user_id=?', [id])
        .single['grants'] as String) as List).cast<String>();
    expect(grants(old), containsAll(allMenu.keys));
    expect(grants(old), contains('shifts.self'));
    expect(grants(old).where((g) => !g.startsWith('menu.') && g != 'shifts.self'), isEmpty, reason: 'nothing else added');
    expect(grants(acc).where((g) => g.startsWith('menu.')), ['menu.view']);
    expect(db.select("SELECT 1 FROM auth_audit WHERE action='grant.add' AND target=?", [old]), isNotEmpty);
    a.setGrant(old, 'menu.qr.publish', false);
    a = LocalAuth(db, iterations: 1000);
    expect(grants(old), isNot(contains('menu.qr.publish')), reason: 'runs once');
    db.dispose();
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
