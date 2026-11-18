import 'pos_logic.dart';

/// Trendyol MEAL review payloads provide epoch millisecond times, product
/// names, orderParentId and an answer-status map. Reviewer name is optional.
DateTime? reviewDate(Object? raw) {
  if (raw is num && raw >= 0 && raw <= 8640000000000000) {
    return DateTime.fromMillisecondsSinceEpoch(raw.toInt(), isUtc: true);
  }
  if (raw is String) {
    return DateTime.tryParse(raw)?.toUtc();
  }
  return null;
}

List<Json> sortReviewsByDate(Iterable<Json> reviews, {bool newestFirst = true}) {
  final rows = reviews.toList();
  rows.sort((a, b) {
    final left = reviewDate(a['createdDate'] ?? a['createTime']);
    final right = reviewDate(b['createdDate'] ?? b['createTime']);
    if (left == null) return right == null ? 0 : 1;
    if (right == null) return -1;
    final result = right.compareTo(left);
    return newestFirst ? result : -result;
  });
  return rows;
}

String? reviewCustomerName(Json review) {
  for (final field in ['reviewerName', 'customerName', 'userName']) {
    final value = review[field];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  final reviewer = review['reviewer'];
  if (reviewer is Map) {
    final name = reviewer['displayName'] ?? reviewer['name'];
    if (name is String && name.trim().isNotEmpty) return name.trim();
  }
  return null; // Official restaurant review sample has no customer identity.
}

List<String> reviewProductNames(Json review) {
  final products = asMaps(review['products']);
  return [
    for (final item in products)
      if ('${item['name'] ?? ''}'.trim().isNotEmpty)
        '${item['name']}'.trim(),
  ];
}

String reviewRelativeAge(Object? raw, {DateTime? now}) {
  final created = reviewDate(raw);
  if (created == null) return '';
  DateTime turkeyDay(DateTime utc) => DateTime.utc(
    utc.toUtc().add(const Duration(hours: 3)).year,
    utc.toUtc().add(const Duration(hours: 3)).month,
    utc.toUtc().add(const Duration(hours: 3)).day,
  );
  final days = turkeyDay((now ?? DateTime.now()).toUtc())
      .difference(turkeyDay(created)).inDays;
  if (days < 0) return '';
  if (days == 0) return 'Bugün';
  if (days == 1) return 'Dün';
  return '$days gün önce';
}

String reviewDateText(Object? raw) {
  final stamp = reviewDate(raw);
  if (stamp == null) return 'Tarih bilinmiyor';
  final turkey = stamp.add(const Duration(hours: 3));
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(turkey.day)}.${two(turkey.month)}.${turkey.year} '
      '${two(turkey.hour)}:${two(turkey.minute)}';
}

bool reviewHasWrittenComment(Json review) {
  final comment = review['comment'];
  return comment is Map &&
      (comment['text'] ?? '').toString().trim().isNotEmpty;
}
