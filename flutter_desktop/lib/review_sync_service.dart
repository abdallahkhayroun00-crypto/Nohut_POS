/// Background Trendyol Go review synchronization (spec §23.6.4).
///
/// Independent of any screen: started with the Windows POS, it keeps running
/// while the user is on Masalar, Siparişler, Finans or anywhere else.
///
/// * Store identity: [resolveStoreIdentity]; never a hard-coded store.
/// * Retrieval: documented `startDate`/`endDate` windows (epoch ms on
///   `createdDate`), every page, overlapping windows, newest first.
///   - first sync per store: bounded backfill of [backfillDays] in
///     30-day windows; notifications suppressed (no storm);
///   - every run: [checkpoint − overlap, now];
///   - every [moderationEvery] runs: the last 30 days again, to pick up
///     reply moderation changes.
/// * Single flight, exponential backoff on 429 / network / 5xx, and the
///   status says exactly what happened: a failed run is never "successful".
/// * Migrated (Uber Eats) stores: 403 not-available / plain 404 stop polling
///   reviews (rechecked every 6 h) and the UI explains it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'notification_center.dart';
import 'pos_logic.dart';
import 'pos_store.dart';
import 'review_repository.dart';
import 'tgo_review_api.dart';
import 'tgo_store_identity.dart';

const reviewSyncStateKey = 'tgoReviewSync';
const storeIdentityStateKey = 'tgoStoreIdentity';
const reviewRowsStateKey = 'platformReviews';
const notificationsStateKey = 'notifications';

class ReviewSyncService extends ChangeNotifier {
  ReviewSyncService(
    this.store, {
    required this.apiFactory,
    DateTime Function()? clock,
    this.interval = const Duration(minutes: 5),
    this.backfillDays = 1095,
    this.overlap = const Duration(days: 2),
    this.moderationEvery = 6,
    this.pageSize = 50,
    this.maxPagesPerWindow = 40,
    this.onNewReviews,
  }) : _clock = clock ?? DateTime.now;

  final PosStore store;
  /// Returns null when no valid credentials exist (integration disabled).
  final TgoReviewApi? Function() apiFactory;
  final DateTime Function() _clock;
  final Duration interval, overlap;
  final int backfillDays, moderationEvery, pageSize, maxPagesPerWindow;
  /// Called with notification events that were newly stored.
  final void Function(List<Json> events)? onNewReviews;

  Timer? _timer;
  Future<void>? _running;
  int _runs = 0, _failures = 0;
  DateTime? _nextAllowed;
  bool _disposed = false;
  StoreIdentityDecision? lastDecision;

  bool get running => _running != null;

  Json get status {
    final raw = store.read().data[reviewSyncStateKey];
    return raw is Map ? Json.from(raw) : <String, dynamic>{};
  }

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(syncNow()));
    unawaited(syncNow());
  }

  /// Single flight: a call while a run is active joins that run.
  Future<void> syncNow({bool manual = false}) {
    if (_disposed) return Future.value();
    final active = _running;
    if (active != null) return active;
    final now = _clock();
    if (!manual && _nextAllowed != null && now.isBefore(_nextAllowed!)) {
      return Future.value();
    }
    final run = _run(manual).whenComplete(() {
      _running = null;
      if (!_disposed) notifyListeners();
    });
    _running = run;
    notifyListeners();
    return run;
  }

  /// Owner picked one of several official stores.
  Future<void> selectStore(TgoStore s) async {
    final api = apiFactory();
    if (api == null) return;
    final record = {
      'supplierId': api.supplierId, 'storeId': s.id, 'name': s.name,
      'source': 'selection', 'verifiedAt': _clock().toUtc().toIso8601String(),
    };
    _write((state) => state[storeIdentityStateKey] = record);
    await syncNow(manual: true);
  }

  Future<void> _run(bool manual) async {
    final api = apiFactory();
    final startedAt = _clock();
    _runs++;
    if (api == null) {
      _setStatus({'state': 'disabled', 'lastAttemptAt': _iso(startedAt)});
      return;
    }
    final data = store.read().data;
    final saved = data[storeIdentityStateKey] is Map
        ? data[storeIdentityStateKey] as Map : null;
    final previous = data[reviewSyncStateKey] is Map
        ? Json.from(data[reviewSyncStateKey] as Map) : <String, dynamic>{};

    // 1. Identity (official discovery every run is cheap: one GET).
    final discovery = await api.stores();
    final decision = resolveStoreIdentity(
      supplierId: api.supplierId,
      discovery: discovery,
      ordersStores: orderStoreIds(
          [for (final o in (data['trendyolGoOrders'] as List? ?? const []))
            if (o is Map) Json.from(o)],
          api.supplierId),
      saved: saved,
    );
    lastDecision = decision;
    final base = <String, dynamic>{
      ...previous,
      'lastAttemptAt': _iso(startedAt),
      'supplierId': api.supplierId,
      'identityState': decision.state.name,
      'identityWarnings': decision.warnings,
      'candidates': [for (final c in decision.candidates) {'id': c.id, 'name': c.name}],
      if (decision.suggestedStoreId != null) 'suggestedStoreId': decision.suggestedStoreId,
      'discovery': discovery.ok ? 'ok' : discovery.failure!.outcome.name,
    };
    if (!decision.usable) {
      _backoff(discovery.failure);
      _setStatus({...base, 'state': 'identity', 'error': discovery.failure?.toString() ?? ''});
      return;
    }
    final storeId = decision.storeId!;
    if (saved == null || saved['storeId'] != storeId ||
        saved['supplierId'] != api.supplierId || discovery.ok) {
      _write((s) => s[storeIdentityStateKey] =
          storeIdentityRecord(api.supplierId, decision, startedAt));
    }

    // Migrated stores: recheck only every 6 h.
    if (!manual && previous['state'] == 'migrated' && previous['storeId'] == storeId) {
      final last = DateTime.tryParse('${previous['lastAttemptAt'] ?? ''}');
      if (last != null && startedAt.difference(last) < const Duration(hours: 6)) return;
    }

    // 2. Windows.
    final checkpoints = previous['checkpoints'] is Map
        ? Json.from(previous['checkpoints'] as Map) : <String, dynamic>{};
    final cpKey = '${api.supplierId}:$storeId';
    final checkpoint = DateTime.tryParse('${checkpoints[cpKey] ?? ''}');
    final firstSync = checkpoint == null;
    final windows = <(DateTime, DateTime)>[];
    final end = startedAt.add(const Duration(minutes: 5));
    if (firstSync) {
      var to = end;
      final floor = startedAt.subtract(Duration(days: backfillDays));
      while (to.isAfter(floor)) {
        final from = to.subtract(const Duration(days: 30));
        windows.add((from.isBefore(floor) ? floor : from, to));
        to = from;
      }
    } else {
      windows.add((checkpoint.subtract(overlap), end));
      if (manual || _runs % moderationEvery == 0) {
        windows.add((startedAt.subtract(const Duration(days: 30)), end));
      }
    }

    // 3. Fetch every page of every window.
    final fetched = <Json>[];
    var pagesComplete = true, pages = 0;
    TgoApiFailure? failure;
    outer:
    for (final (from, to) in windows) {
      for (var page = 0;; page++) {
        if (page >= maxPagesPerWindow) {
          pagesComplete = false;
          break;
        }
        final res = await api.reviews(storeId, page: page, size: pageSize,
            startMs: from.millisecondsSinceEpoch, endMs: to.millisecondsSinceEpoch);
        if (!res.ok) {
          failure = res.failure;
          break outer;
        }
        pages++;
        for (final raw in res.rows) {
          final row = normalizeTgoReview(raw, supplierId: api.supplierId, storeId: storeId);
          if (row != null) fetched.add(row);
        }
        final total = res.totalPages;
        if (total != null ? page + 1 >= total : res.rows.length < pageSize) break;
      }
    }

    if (failure != null) {
      _backoff(failure);
      _setStatus({
        ...base,
        'storeId': storeId,
        'storeName': decision.name,
        'state': failure.migrated ? 'migrated' : 'error',
        'apiAvailability': failure.migrated ? 'migrated' : failure.outcome.name,
        'error': failure.toString(),
      });
      return; // nothing partial is committed, checkpoint unchanged
    }

    // 4. Commit rows, checkpoint, status and notifications in ONE write.
    _failures = 0;
    _nextAllowed = null;
    var newEvents = <Json>[];
    _write((state) {
      final merge = mergeReviews(
        state[reviewRowsStateKey] as List? ?? const [], fetched,
        now: startedAt, suppressNotifications: firstSync);
      final recentFloor = startedAt.subtract(const Duration(days: 7));
      final events = <Json>[];
      final rows = merge.rows;
      for (final key in merge.newKeys) {
        final i = rows.indexWhere((r) => reviewKey(r) == key);
        final r = rows[i];
        final created = DateTime.tryParse('${r['createdAt']}');
        if (r['notification'] != 'pending') continue;
        if (created == null || created.isBefore(recentFloor)) {
          rows[i] = Json.from(r)..['notification'] = 'suppressed';
          continue;
        }
        final stars = reviewStars10(r);
        events.add({
          'eventId': 'review:$key',
          'category': 'review',
          'severity': stars != null && stars <= 25 ? 'high' : 'normal',
          'createdAt': _iso(startedAt),
          'title': 'Yeni Yorum · Trendyol Go',
          'body': '${stars == null ? '' : '${(stars / 10).toStringAsFixed(1)} ★ '}'
              '${_preview('${r['comment'] ?? ''}')}'.trim(),
          'ref': {'kind': 'review', 'key': key},
          'permission': 'reviews.reply',
        });
        rows[i] = Json.from(r)..['notification'] = 'created';
      }
      state[reviewRowsStateKey] = rows;
      final (notes, added) = addNotifications(state[notificationsStateKey] as List?, events);
      state[notificationsStateKey] = notes;
      newEvents = [for (final e in events) if (added.contains(e['eventId'])) e];
      final storeRows = rows.where((r) =>
          r['supplierId'] == api.supplierId && r['storeId'] == storeId);
      String? latest;
      for (final r in storeRows) {
        final c = '${r['createdAt']}';
        if (latest == null || c.compareTo(latest) > 0) latest = c;
      }
      // Windows are on review createdDate; the next run re-reads from
      // (this run's start - overlap), so late-indexed reviews are caught.
      checkpoints[cpKey] = _iso(startedAt);
      state[reviewSyncStateKey] = {
        ...base,
        'state': 'ok',
        'storeId': storeId,
        'storeName': decision.name,
        'apiAvailability': 'ok',
        'error': '',
        'lastSuccessAt': _iso(startedAt),
        'latestReviewAt': latest,
        'retrieved': fetched.length,
        'pages': pages,
        'pagesComplete': pagesComplete,
        'newReviews': merge.newKeys.length,
        'updatedReviews': merge.updatedKeys.length,
        'firstSync': firstSync,
        'checkpoints': checkpoints,
      };
    });
    if (newEvents.isNotEmpty) onNewReviews?.call(newEvents);
  }

  static String _preview(String text) =>
      text.length <= 80 ? text : '${text.substring(0, 77)}…';

  void _backoff(TgoApiFailure? f) {
    if (f == null || !f.retryable) return;
    _failures++;
    final minutes = (interval.inMinutes * (1 << (_failures - 1).clamp(0, 4)))
        .clamp(interval.inMinutes, 60);
    _nextAllowed = _clock().add(Duration(minutes: minutes));
  }

  void _setStatus(Json value) => _write((s) => s[reviewSyncStateKey] = value);

  void _write(void Function(Json state) change) {
    for (var attempt = 0; attempt < 5; attempt++) {
      final snap = store.read();
      final next = copyJson(snap.data);
      change(next);
      if (store.replace(next, snap.revision).ok) return;
    }
    throw StateError('review sync could not commit after 5 attempts');
  }

  static String _iso(DateTime t) => t.toUtc().toIso8601String();

  /// Marks reviews read and their notifications read.
  void markRead(Set<String> keys) {
    if (keys.isEmpty) return;
    _write((s) {
      s[reviewRowsStateKey] = markReviewsRead(s[reviewRowsStateKey] as List? ?? const [], keys);
      s[notificationsStateKey] = updateNotifications(s[notificationsStateKey] as List?,
          (e) => e['ref'] is Map && keys.contains((e['ref'] as Map)['key']),
          (e) => e['read'] = true);
    });
    notifyListeners();
  }

  /// Local change to one review row (reply workflow).
  void updateReview(String key, void Function(Json row) change) {
    _write((s) {
      s[reviewRowsStateKey] = [
        for (final r in (s[reviewRowsStateKey] as List? ?? const []))
          if (r is Map)
            reviewKey(r) == key ? (Json.from(r)..also(change)) : Json.from(r),
      ];
    });
    notifyListeners();
  }

  /// Marks Windows popup delivery for notification events.
  void markDelivered(Set<String> eventIds, String state) {
    if (eventIds.isEmpty) return;
    _write((s) => s[notificationsStateKey] = updateNotifications(
        s[notificationsStateKey] as List?,
        (e) => eventIds.contains(e['eventId']), (e) => e['windows'] = state));
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

extension _Also on Json {
  void also(void Function(Json) f) => f(this);
}
