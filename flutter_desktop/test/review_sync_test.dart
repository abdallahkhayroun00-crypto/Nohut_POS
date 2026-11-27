// Spec §23.6.12: Trendyol review rework with synthetic data only.
// Store identity, date-windowed paging, persistence, dedup, notifications,
// migration errors, rate limiting and statistics.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/notification_center.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/review_repository.dart';
import 'package:nohut_falafel_desktop/review_sync_service.dart';
import 'package:nohut_falafel_desktop/tgo_review_api.dart';
import 'package:nohut_falafel_desktop/tgo_store_identity.dart';

const supplier = '900001';
const store = '700001';
const otherStore = '700002';
const legacyStore = '316490';

/// Synthetic Trendyol API. Reviews are returned OLDEST FIRST without a date
/// filter, which reproduces the field symptom (page 0 = oldest reviews).
class FakeTgo {
  FakeTgo(this.now);
  DateTime now;
  List<Map<String, Object?>> stores = [
    {'id': int.parse(store), 'name': 'Nohut Falafel (sentetik)', 'supplierId': int.parse(supplier)},
  ];
  final Map<String, List<Map<String, Object?>>> reviews = {store: []};
  final calls = <Uri>[];
  int? forceStatus;
  String forceBody = '';
  bool network = false;

  void addReview(String storeId, String id, DateTime created,
      {num avg = 5, String? text, Map<String, Object?>? answer}) {
    reviews.putIfAbsent(storeId, () => []).add({
      'reviewId': id,
      'restaurantId': int.parse(storeId),
      'createdDate': created.millisecondsSinceEpoch,
      'orderCreatedDate': created.subtract(const Duration(hours: 2)).millisecondsSinceEpoch,
      'orderParentId': 1000 + reviews[storeId]!.length,
      'rating': {'flavorScore': avg, 'serviceScore': avg, 'deliveryScore': avg, 'average': avg},
      'deliveryType': 'GO',
      'products': [
        {'productId': '1', 'name': 'Falafel Dürüm', 'modifierProducts': []},
      ],
      'comment': {
        if (text != null) 'text': text,
        if (answer != null) 'restaurantAnswer': answer,
      },
    });
  }

  Future<({int status, String body})> get(Uri uri) async {
    calls.add(uri);
    if (network) throw const SocketException('offline (synthetic)');
    if (forceStatus != null) return (status: forceStatus!, body: forceBody);
    if (uri.path.endsWith('/stores')) {
      return (status: 200, body: jsonEncode({
        'restaurants': stores, 'totalPages': 1, 'totalElements': stores.length}));
    }
    final m = RegExp(r'/stores/(\d+)/reviews/filter$').firstMatch(uri.path);
    if (m == null) return (status: 404, body: '{"error":"no"}');
    final rows = reviews[m[1]];
    if (rows == null) return (status: 404, body: '{"error":"unknown store"}');
    final q = uri.queryParameters;
    final start = int.tryParse(q['startDate'] ?? ''), end = int.tryParse(q['endDate'] ?? '');
    final filtered = [
      for (final r in rows)
        if ((start == null || (r['createdDate'] as int) >= start) &&
            (end == null || (r['createdDate'] as int) <= end)) r,
    ]..sort((a, b) => (a['createdDate'] as int).compareTo(b['createdDate'] as int));
    final page = int.parse(q['page']!), size = int.parse(q['size']!);
    final slice = filtered.skip(page * size).take(size).toList();
    return (status: 200, body: jsonEncode({
      'content': slice,
      'totalPages': (filtered.length / size).ceil(),
      'totalElements': filtered.length,
    }));
  }
}

void main() {
  late Directory dir;
  late PosStore pos;
  late FakeTgo api;
  late DateTime now;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('nohut-reviews');
    pos = PosStore(databaseFile: '${dir.path}/nohut-pos.sqlite3');
    now = DateTime.utc(2026, 11, 27, 12);
    api = FakeTgo(now);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  ReviewSyncService service({int pageSize = 50}) => ReviewSyncService(
        pos,
        apiFactory: () => TgoReviewApi(supplier, api.get),
        clock: () => now,
        pageSize: pageSize,
      );

  List rows() => pos.read().data[reviewRowsStateKey] as List? ?? const [];
  Json status() => Json.from(pos.read().data[reviewSyncStateKey] as Map);

  group('store identity', () {
    TgoStoresResult ok(List<TgoStore> s) => TgoStoresResult.ok(s);
    const fail = TgoStoresResult.failed(TgoApiFailure(TgoApiOutcome.network, -1, 'x'));

    test('single official store is selected automatically', () {
      final d = resolveStoreIdentity(supplierId: supplier,
          discovery: ok([const TgoStore(id: store, name: 'A', supplierId: supplier)]),
          ordersStores: {store});
      expect(d.state, StoreIdentityState.verified);
      expect(d.storeId, store);
      expect(d.source, 'discovery');
    });

    test('outdated saved store is replaced and reported, never silently kept', () {
      final d = resolveStoreIdentity(supplierId: supplier,
          discovery: ok([const TgoStore(id: store, name: 'A', supplierId: supplier)]),
          ordersStores: {store},
          saved: {'supplierId': supplier, 'storeId': legacyStore, 'source': 'discovery'});
      expect(d.storeId, store);
      expect(d.warnings.join(), contains(legacyStore));
    });

    test('multiple stores need an explicit selection, with a suggestion', () {
      final d = resolveStoreIdentity(supplierId: supplier,
          discovery: ok(const [
            TgoStore(id: store, name: 'A', supplierId: supplier),
            TgoStore(id: otherStore, name: 'B', supplierId: supplier)]),
          ordersStores: {otherStore});
      expect(d.state, StoreIdentityState.needsSelection);
      expect(d.usable, isFalse);
      expect(d.suggestedStoreId, otherStore);
    });

    test('store of another supplier is never used', () {
      final d = resolveStoreIdentity(supplierId: supplier,
          discovery: ok(const [TgoStore(id: store, name: 'X', supplierId: '123')]),
          ordersStores: const {});
      expect(d.state, StoreIdentityState.noStores);
      expect(d.warnings.join(), contains('farklı Satıcı'));
    });

    test('single official store that differs from the orders is a mismatch', () {
      final d = resolveStoreIdentity(supplierId: supplier,
          discovery: ok(const [TgoStore(id: store, name: 'A', supplierId: supplier)]),
          ordersStores: {otherStore});
      expect(d.state, StoreIdentityState.mismatch);
      expect(d.usable, isFalse);
    });

    test('saved identity of another supplier is ignored; no hard-coded fallback', () {
      final d = resolveStoreIdentity(supplierId: supplier, discovery: fail,
          ordersStores: const {},
          saved: {'supplierId': '42', 'storeId': legacyStore});
      expect(d.state, StoreIdentityState.unverified);
      expect(d.storeId, isNull);
    });

    test('discovery down: previously verified store kept; orders give one store', () {
      expect(resolveStoreIdentity(supplierId: supplier, discovery: fail,
          ordersStores: const {},
          saved: {'supplierId': supplier, 'storeId': store}).storeId, store);
      final d = resolveStoreIdentity(supplierId: supplier, discovery: fail,
          ordersStores: {store});
      expect((d.state, d.storeId, d.source), (StoreIdentityState.verified, store, 'orders'));
    });

    test('order store ids ignore other suppliers and test packages', () {
      expect(orderStoreIds([
        {'supplierId': supplier, 'storeId': store},
        {'supplierId': '1', 'storeId': otherStore},
        {'supplierId': supplier, 'storeId': legacyStore, 'testPackage': true},
      ], supplier), {store});
    });
  });

  test('recent reviews on later pages are found via date windows; history '
      'persists; first import creates no notification storm', () async {
    for (var i = 0; i < 120; i++) {
      api.addReview(store, 'old-$i', now.subtract(Duration(days: 300 - i)), avg: 4);
    }
    api.addReview(store, 'recent-1', now.subtract(const Duration(days: 1)), avg: 2, text: 'soğuktu');
    final s = service(pageSize: 20);
    await s.syncNow();
    expect(status()['state'], 'ok');
    expect(status()['latestReviewAt'],
        now.subtract(const Duration(days: 1)).toIso8601String());
    expect(rows(), hasLength(121));
    expect(api.calls.every((u) => !u.path.endsWith('/reviews/filter') ||
        u.queryParameters.containsKey('startDate')), isTrue,
        reason: 'every review request is date-bounded');
    expect(pos.read().data[notificationsStateKey] ?? const [], isEmpty);
    expect(rows().every((r) => r['notification'] == 'suppressed'), isTrue);

    // Restart: a new service instance and store reload keep everything.
    s.dispose();
    pos = PosStore(databaseFile: '${dir.path}/nohut-pos.sqlite3');
    expect(rows(), hasLength(121));
  });

  test('exactly one notification per genuinely new review across polls and '
      'restarts; low rating is high severity', () async {
    api.addReview(store, 'a', now.subtract(const Duration(days: 3)));
    final events = <Json>[];
    final s = ReviewSyncService(pos, apiFactory: () => TgoReviewApi(supplier, api.get),
        clock: () => now, onNewReviews: events.addAll);
    await s.syncNow(); // first import
    now = now.add(const Duration(minutes: 5));
    api.addReview(store, 'b', now.subtract(const Duration(minutes: 1)), avg: 1, text: 'kötü');
    await s.syncNow();
    await s.syncNow(manual: true);
    final restarted = ReviewSyncService(pos,
        apiFactory: () => TgoReviewApi(supplier, api.get), clock: () => now,
        onNewReviews: events.addAll);
    await restarted.syncNow(manual: true);
    final notes = pos.read().data[notificationsStateKey] as List;
    expect(notes, hasLength(1));
    expect(events, hasLength(1));
    expect(notes.single['eventId'], 'review:$tgoPlatform:$supplier:$store:b');
    expect(notes.single['severity'], 'high');
    expect('${notes.single['body']}', contains('kötü'));
    expect(unreadNotifications(notes), 1);
    s.markRead({'$tgoPlatform:$supplier:$store:b'});
    expect(unreadNotifications(pos.read().data[notificationsStateKey] as List), 0);
    expect(rows().firstWhere((r) => r['reviewId'] == 'b')['read'], isTrue);
  });

  test('reply moderation status is synchronized and settles the local reply',
      () async {
    api.addReview(store, 'r', now.subtract(const Duration(days: 2)), text: 'iyi');
    final s = service();
    await s.syncNow();
    // Local workflow: reply submitted, outcome waiting.
    final next = copyJson(pos.read().data);
    (next[reviewRowsStateKey] as List).first['replyDraft'] = {'text': 'Teşekkürler', 'state': 'submitted'};
    expect(pos.replace(next, pos.read().revision).ok, isTrue);
    api.reviews[store]!.first['comment'] = {'text': 'iyi',
      'restaurantAnswer': {'text': '***', 'status': 'REJECTED',
        'rejectedReason': {'reason': 'Uygunsuz Cevap', 'reasonId': 1}}};
    now = now.add(const Duration(minutes: 5));
    await s.syncNow(manual: true);
    final row = rows().single;
    expect(row['reply']['status'], 'REJECTED');
    expect(row['reply']['rejectedReason'], 'Uygunsuz Cevap');
    expect(row['replyDraft']['state'], 'rejected');
    expect(replyStatusOf(row), 'rejected');
  });

  test('403 not-available and plain 404 are reported as migration; nothing '
      'is lost and the run is not successful', () async {
    api.addReview(store, 'x', now.subtract(const Duration(days: 1)));
    final s = service();
    await s.syncNow();
    expect(rows(), hasLength(1));
    final success = status()['lastSuccessAt'];
    // The store list still works; only reviews are migrated.
    final realGet = api.get;
    var calls = 0;
    final s2 = ReviewSyncService(pos, clock: () => now, apiFactory: () =>
        TgoReviewApi(supplier, (u) async {
          calls++;
          if (u.path.endsWith('/reviews/filter')) {
            return (status: 403, body: '{"errorCode":"endpoint.not-available.error"}');
          }
          return realGet(u);
        }));
    now = now.add(const Duration(minutes: 5));
    await s2.syncNow(manual: true);
    expect(status()['state'], 'migrated');
    expect(status()['lastSuccessAt'], success);
    expect(rows(), hasLength(1));
    expect(classifyTgoResponse(404, '404 page not found')?.outcome, TgoApiOutcome.removed);
    expect(classifyTgoResponse(404, '{"error":"x"}')?.outcome, TgoApiOutcome.notFound);
    // Migrated: automatic runs within 6 h do not call the API again.
    final before = calls;
    now = now.add(const Duration(minutes: 10));
    await s2.syncNow();
    expect(calls, before + 1, reason: 'only the store list is checked');
  });

  test('rate limiting and network failures back off and keep the checkpoint',
      () async {
    api.addReview(store, 'x', now.subtract(const Duration(days: 1)));
    final s = service();
    await s.syncNow();
    final cp = status()['checkpoints'];
    api.forceStatus = 429;
    now = now.add(const Duration(minutes: 5));
    await s.syncNow();
    // Store list limited -> saved identity kept; reviews limited -> error.
    expect(status()['state'], 'error');
    expect(status()['apiAvailability'], 'rateLimited');
    final n = api.calls.length;
    now = now.add(const Duration(minutes: 1));
    await s.syncNow();
    expect(api.calls.length, n, reason: 'backoff: no request before next slot');
    api.forceStatus = null;
    api.network = true;
    now = now.add(const Duration(minutes: 30));
    await s.syncNow();
    expect(status()['checkpoints'], cp);
    api.network = false;
    now = now.add(const Duration(hours: 2));
    await s.syncNow();
    expect(status()['state'], 'ok');
  });

  test('overlapping manual and timer runs share one flight', () async {
    api.addReview(store, 'x', now.subtract(const Duration(days: 1)));
    final s = service();
    await Future.wait([s.syncNow(), s.syncNow(), s.syncNow(manual: true)]);
    expect(api.calls.where((u) => u.path.endsWith('/stores')), hasLength(1));
  });

  test('reviews of different stores are never merged', () {
    final a = normalizeTgoReview({'reviewId': 'same', 'createdDate': 1700000000000},
        supplierId: supplier, storeId: store)!;
    final b = normalizeTgoReview({'reviewId': 'same', 'createdDate': 1700000000000},
        supplierId: supplier, storeId: otherStore)!;
    final merged = mergeReviews([], [a, b, a], now: now, suppressNotifications: true);
    expect(merged.rows, hasLength(2));
  });

  test('only permitted fields are stored', () {
    final r = normalizeTgoReview({
      'reviewId': 'p', 'createdDate': 1700000000000, 'customerName': 'X Y',
      'customerPhone': '555', 'rating': {'average': 4.5},
      'comment': {'text': 'ok'}, 'products': [{'name': 'Humus', 'productId': '9'}],
    }, supplierId: supplier, storeId: store)!;
    expect(r.keys, isNot(contains('customerName')));
    expect(r.keys, isNot(contains('customerPhone')));
    expect(r['rating'], {'average': 45});
    expect(r['products'], ['Humus']);
  });

  test('filters and statistics cover the whole local dataset', () {
    final base = DateTime.utc(2026, 11, 1);
    final rows = [
      for (var i = 0; i < 10; i++)
        normalizeTgoReview({
          'reviewId': 'q$i', 'createdDate': base.add(Duration(days: i)).millisecondsSinceEpoch,
          'rating': {'average': (i % 5) + 1},
          if (i.isEven) 'comment': {'text': 'yorum $i',
            if (i == 2) 'restaurantAnswer': {'text': 't', 'status': 'APPROVED'},
            if (i == 4) 'restaurantAnswer': {'text': 't', 'status': 'WAITING_FOR_APPROVE'}},
        }, supplierId: supplier, storeId: store)!..['read'] = i < 3,
    ];
    final newest = queryReviews(rows, const ReviewQuery());
    expect(newest.first['reviewId'], 'q9');
    expect(queryReviews(rows, const ReviewQuery(newestFirst: false)).first['reviewId'], 'q0');
    expect(queryReviews(rows, const ReviewQuery(stars: 5)).map((r) => r['reviewId']), ['q9', 'q4']);
    expect(queryReviews(rows, const ReviewQuery(withText: false)), hasLength(5));
    expect(queryReviews(rows, const ReviewQuery(unreadOnly: true)), hasLength(7));
    expect(queryReviews(rows, const ReviewQuery(reply: ReplyFilter.answered)).single['reviewId'], 'q2');
    expect(queryReviews(rows, const ReviewQuery(search: 'YORUM 6')).single['reviewId'], 'q6');
    final st = reviewStats(rows);
    expect(st.total, 10);
    expect(st.average10, 30);
    expect(st.distribution, {1: 2, 2: 2, 3: 2, 4: 2, 5: 2});
    expect((st.answered, st.pendingApproval, st.waiting, st.unread), (1, 1, 8, 7));
  });

  test('notification history dedups by event id', () {
    final (a, added) = addNotifications(null, [
      {'eventId': 'e1', 'title': 't'}, {'eventId': 'e1', 'title': 't'}]);
    expect(added, ['e1']);
    final (b, again) = addNotifications(a, [{'eventId': 'e1'}]);
    expect(again, isEmpty);
    expect(b, hasLength(1));
  });
}
