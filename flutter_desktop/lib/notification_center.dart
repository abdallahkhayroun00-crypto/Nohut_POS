/// Durable Windows notification history (spec §23.5, first slice).
///
/// Events live in the `notifications` state list with a stable `eventId`
/// (deduplication key): the same event can never be stored or shown twice,
/// whatever the polling, reconnect or restart pattern. Shape (contract draft,
/// to be published as docs/contracts/v1/notifications.json):
/// `{eventId, category, severity, createdAt, title, body, ref{kind,key},
///   permission, read, windows: pending|shown|dismissed|later}`.
/// Bodies never hold payroll or customer contact data; mobile lock-screen
/// previews will use `title` only.
library;

import 'pos_logic.dart';

const notificationHistoryLimit = 500;

/// Adds events whose `eventId` is not already present. Returns the new list
/// and the ids actually added. Oldest read events are trimmed first when the
/// history exceeds [notificationHistoryLimit]; unread events are kept.
(List<Json>, List<String>) addNotifications(List? existing, Iterable<Json> events) {
  final rows = [for (final r in existing ?? const []) if (r is Map) Json.from(r)];
  final ids = {for (final r in rows) '${r['eventId']}'};
  final added = <String>[];
  for (final e in events) {
    final id = '${e['eventId'] ?? ''}';
    if (id.isEmpty || ids.contains(id)) continue;
    ids.add(id);
    added.add(id);
    rows.add(Json.from(e)
      ..putIfAbsent('read', () => false)
      ..putIfAbsent('windows', () => 'pending'));
  }
  while (rows.length > notificationHistoryLimit) {
    final i = rows.indexWhere((r) => r['read'] == true);
    rows.removeAt(i >= 0 ? i : 0);
  }
  return (rows, added);
}

List<Json> updateNotifications(List? existing, bool Function(Json) where,
    void Function(Json) change) => [
  for (final r in existing ?? const [])
    if (r is Map) () {
      final row = Json.from(r);
      if (where(row)) change(row);
      return row;
    }(),
];

int unreadNotifications(List? rows, {String? category}) => [
  for (final r in rows ?? const [])
    if (r is Map && r['read'] != true &&
        (category == null || r['category'] == category)) r,
].length;
