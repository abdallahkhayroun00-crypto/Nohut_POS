/// Persistent platform review repository (spec §23.6.5).
///
/// Rows live in the `platformReviews` state list, stored one SQLite row per
/// review (`pos_platform_reviews`, entity_storage.dart). Identity is
/// `platform:supplierId:storeId:reviewId`, so reviews of different
/// restaurants never merge. Rows are never deleted by sync: pagination,
/// restarts, outages and configuration changes cannot make history vanish.
///
/// Only permitted fields are kept: no raw payloads, no reviewer identity,
/// no credentials.
library;

import 'pos_logic.dart';

const tgoPlatform = 'trendyol_go';

String reviewKey(Map r) =>
    '${r['platform']}:${r['supplierId']}:${r['storeId']}:${r['reviewId']}';

String? _iso(Object? ms) {
  final n = ms is num ? ms.toInt() : int.tryParse('${ms ?? ''}');
  if (n == null || n <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(n, isUtc: true).toIso8601String();
}

int? _score(Object? v) {
  final n = v is num ? v : num.tryParse('${v ?? ''}');
  if (n == null || n < 0 || n > 5) return null;
  return (n * 10).round(); // tenths of a star, integer
}

/// Normalizes one API row to the permitted shape, or null when it lacks a
/// stable identity or a creation date.
Json? normalizeTgoReview(Map raw, {required String supplierId,
    required String storeId}) {
  final id = '${raw['reviewId'] ?? ''}'.trim();
  final created = _iso(raw['createdDate']);
  if (id.isEmpty || id.length > 80 || created == null) return null;
  final rating = raw['rating'] is Map ? raw['rating'] as Map : const {};
  final comment = raw['comment'] is Map ? raw['comment'] as Map : const {};
  final answer = comment['restaurantAnswer'] is Map
      ? comment['restaurantAnswer'] as Map : null;
  final rejected = answer?['rejectedReason'] is Map
      ? answer!['rejectedReason'] as Map : null;
  final text = '${comment['text'] ?? ''}'.trim();
  return {
    'platform': tgoPlatform,
    'supplierId': supplierId,
    'storeId': storeId,
    'reviewId': id,
    if (raw['restaurantId'] != null) 'restaurantId': '${raw['restaurantId']}',
    'createdAt': created,
    if (_iso(raw['orderCreatedDate']) != null)
      'orderCreatedAt': _iso(raw['orderCreatedDate']),
    if (raw['orderParentId'] != null) 'orderNumber': '${raw['orderParentId']}',
    'rating': {
      if (_score(rating['average']) != null) 'average': _score(rating['average']),
      if (_score(rating['flavorScore']) != null) 'flavor': _score(rating['flavorScore']),
      if (_score(rating['serviceScore']) != null) 'service': _score(rating['serviceScore']),
      if (_score(rating['deliveryScore']) != null) 'delivery': _score(rating['deliveryScore']),
    },
    if (text.isNotEmpty) 'comment': text.length > 4000 ? text.substring(0, 4000) : text,
    'products': [
      for (final p in (raw['products'] is List ? raw['products'] as List : const []))
        if (p is Map && '${p['name'] ?? ''}'.trim().isNotEmpty) '${p['name']}'.trim(),
    ],
    if (answer != null)
      'reply': {
        'text': '${answer['text'] ?? ''}',
        'status': '${answer['status'] ?? ''}',
        if (rejected != null) 'rejectedReason': '${rejected['reason'] ?? ''}',
        if (rejected != null && rejected['reasonId'] is num)
          'rejectedReasonId': (rejected['reasonId'] as num).toInt(),
      },
  };
}

class ReviewMergeResult {
  ReviewMergeResult(this.rows, this.newKeys, this.updatedKeys);
  final List<Json> rows;
  final List<String> newKeys, updatedKeys;
}

/// Platform fields that a sync may refresh; everything else (read state,
/// first detection, notification state, local reply workflow) is local.
const _platformFields = [
  'restaurantId', 'createdAt', 'orderCreatedAt', 'orderNumber', 'rating',
  'comment', 'products', 'reply',
];

/// Upserts [incoming] (already normalized) into [existing]. New rows get
/// `firstSeenAt`, `read: false` and `notification` = `pending` or, for a
/// historical import, `suppressed`. Nothing is ever removed.
ReviewMergeResult mergeReviews(List existing, Iterable<Json> incoming, {
  required DateTime now,
  required bool suppressNotifications,
}) {
  final rows = [for (final r in existing) if (r is Map) Json.from(r)];
  final index = {for (var i = 0; i < rows.length; i++) reviewKey(rows[i]): i};
  final nowIso = now.toUtc().toIso8601String();
  final added = <String>[], updated = <String>[];
  for (final r in incoming) {
    final key = reviewKey(r);
    final at = index[key];
    if (at == null) {
      final row = Json.from(r)
        ..['firstSeenAt'] = nowIso
        ..['lastVerifiedAt'] = nowIso
        ..['read'] = false
        ..['notification'] = suppressNotifications ? 'suppressed' : 'pending';
      index[key] = rows.length;
      rows.add(row);
      added.add(key);
      continue;
    }
    final row = rows[at];
    var changed = false;
    for (final f in _platformFields) {
      final next = r[f];
      if (next == null) continue;
      if (!jsonEqualsLoose(row[f], next)) {
        row[f] = next;
        changed = true;
      }
    }
    // A platform-confirmed answer settles the local reply workflow.
    final reply = row['reply'];
    if (reply is Map && row['replyDraft'] is Map) {
      final status = '${reply['status']}';
      final draft = Json.from(row['replyDraft'] as Map);
      final mapped = status == 'APPROVED' ? 'approved'
          : status == 'REJECTED' ? 'rejected' : 'waitingModeration';
      if (draft['state'] != mapped) {
        draft['state'] = mapped;
        row['replyDraft'] = draft;
        changed = true;
      }
    }
    row['lastVerifiedAt'] = nowIso;
    if (changed) updated.add(key);
  }
  return ReviewMergeResult(rows, added, updated);
}

bool jsonEqualsLoose(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (!b.containsKey(e.key) || !jsonEqualsLoose(e.value, b[e.key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonEqualsLoose(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// Average in tenths of a star (null when no rating).
int? reviewStars10(Map r) {
  final rating = r['rating'];
  return rating is Map && rating['average'] is num
      ? (rating['average'] as num).toInt() : null;
}

enum ReplyFilter { any, waiting, answered, pendingApproval, rejected }

class ReviewQuery {
  const ReviewQuery({
    this.platform, this.storeId, this.from, this.to, this.stars,
    this.unreadOnly = false, this.reply = ReplyFilter.any,
    this.withText, this.search = '', this.newestFirst = true,
  });
  final String? platform, storeId;
  final DateTime? from, to;
  /// Whole-star bucket 1..5 (rounded average).
  final int? stars;
  final bool unreadOnly;
  final ReplyFilter reply;
  /// true = written reviews only, false = ratings without comment.
  final bool? withText;
  final String search;
  final bool newestFirst;
}

String replyStatusOf(Map r) {
  final reply = r['reply'];
  if (reply is Map) {
    switch ('${reply['status']}') {
      case 'APPROVED': return 'answered';
      case 'REJECTED': return 'rejected';
      default: return 'pendingApproval';
    }
  }
  final draft = r['replyDraft'];
  if (draft is Map && const ['submitted', 'unknown', 'waitingModeration']
      .contains(draft['state'])) {
    return 'pendingApproval';
  }
  return 'waiting';
}

/// Filters and sorts the WHOLE local dataset (not one API page).
List<Json> queryReviews(Iterable rows, ReviewQuery q) {
  final needle = q.search.trim().toLowerCase();
  final out = <Json>[];
  for (final raw in rows) {
    if (raw is! Map) continue;
    final r = Json.from(raw);
    if (q.platform != null && r['platform'] != q.platform) continue;
    if (q.storeId != null && r['storeId'] != q.storeId) continue;
    final at = DateTime.tryParse('${r['createdAt'] ?? ''}');
    if (q.from != null && (at == null || at.isBefore(q.from!))) continue;
    if (q.to != null && (at == null || !at.isBefore(q.to!))) continue;
    if (q.stars != null) {
      final s = reviewStars10(r);
      if (s == null || ((s + 5) ~/ 10) != q.stars) continue;
    }
    if (q.unreadOnly && r['read'] == true) continue;
    final hasText = '${r['comment'] ?? ''}'.isNotEmpty;
    if (q.withText != null && hasText != q.withText) continue;
    if (q.reply != ReplyFilter.any && replyStatusOf(r) != q.reply.name) continue;
    if (needle.isNotEmpty) {
      final hay = [r['comment'], ...(r['products'] is List ? r['products'] as List : const []),
          (r['reply'] is Map ? (r['reply'] as Map)['text'] : null)]
          .whereType<Object>().join(' ').toLowerCase();
      if (!hay.contains(needle)) continue;
    }
    out.add(r);
  }
  out.sort((a, b) {
    final c = '${a['createdAt']}'.compareTo('${b['createdAt']}');
    final byDate = q.newestFirst ? -c : c;
    return byDate != 0 ? byDate : reviewKey(a).compareTo(reviewKey(b));
  });
  return out;
}

/// Locally computed statistics (labelled as such in the UI: they are not
/// the platform's official figures).
class ReviewStats {
  ReviewStats(this.total, this.average10, this.distribution, this.unread,
      this.waiting, this.answered, this.pendingApproval, this.rejected,
      this.newSince, this.positive, this.negative);
  final int total, unread, waiting, answered, pendingApproval, rejected,
      newSince, positive, negative;
  final int? average10;
  /// Count per whole star 1..5.
  final Map<int, int> distribution;
}

ReviewStats reviewStats(Iterable<Json> rows, {DateTime? newSince}) {
  var total = 0, sum = 0, rated = 0, unread = 0, waiting = 0, answered = 0,
      pending = 0, rejected = 0, fresh = 0, positive = 0, negative = 0;
  final dist = {for (var i = 1; i <= 5; i++) i: 0};
  for (final r in rows) {
    total++;
    final s = reviewStars10(r);
    if (s != null) {
      sum += s;
      rated++;
      final bucket = ((s + 5) ~/ 10).clamp(1, 5);
      dist[bucket] = dist[bucket]! + 1;
      if (s >= 40) positive++;
      if (s <= 25) negative++;
    }
    if (r['read'] != true) unread++;
    switch (replyStatusOf(r)) {
      case 'waiting': waiting++;
      case 'answered': answered++;
      case 'pendingApproval': pending++;
      case 'rejected': rejected++;
    }
    final seen = DateTime.tryParse('${r['firstSeenAt'] ?? ''}');
    if (newSince != null && seen != null && seen.isAfter(newSince)) fresh++;
  }
  return ReviewStats(total, rated == 0 ? null : (sum / rated).round(), dist,
      unread, waiting, answered, pending, rejected, fresh, positive, negative);
}

/// Marks reviews read (by key); returns the updated list.
List<Json> markReviewsRead(List rows, Set<String> keys) => [
  for (final r in rows)
    if (r is Map)
      keys.contains(reviewKey(r)) ? (Json.from(r)..['read'] = true) : Json.from(r),
];
