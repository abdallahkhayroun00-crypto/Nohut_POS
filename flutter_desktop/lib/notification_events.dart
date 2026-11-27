/// Operational notification events (spec §23.5, tasks N1/N2/N3-LAN).
///
/// Mirrors docs/contracts/v1/notifications.json (checked by
/// test/notification_events_test.dart). Events are *derived* from committed
/// Windows state with stable `eventId`s, so deriving again after a restart,
/// reconnect or duplicate poll never adds a duplicate ([addNotifications]).
/// Notifications are never confirmation of an order or payment.
library;

import 'daily_report.dart' show dailyReportEvent;
import 'local_accounts.dart';
import 'notification_center.dart';
import 'pos_logic.dart';
import 'pos_store.dart';
import 'review_sync_service.dart' show notificationsStateKey;

typedef NotificationCategory = ({
  String label, String severity, String? permission, List<String> clients, bool windowsOnly});

const Map<String, NotificationCategory> notificationCategories = {
  'order.table': (label: 'Yeni masa siparişi', severity: 'normal', permission: 'tables.view', clients: ['windows', 'personel', 'yonetici'], windowsOnly: false),
  'order.pickup': (label: 'Yeni Gel-Al siparişi', severity: 'normal', permission: 'tables.view', clients: ['windows', 'personel', 'yonetici'], windowsOnly: false),
  'order.platform': (label: 'Yeni online sipariş (Trendyol Go / Yemeksepeti / Migros)', severity: 'high', permission: 'online.view', clients: ['windows', 'personel', 'yonetici'], windowsOnly: false),
  'order.status': (label: 'Sipariş durumu değişti', severity: 'low', permission: 'tables.view', clients: ['windows', 'personel', 'yonetici'], windowsOnly: false),
  'payment.error': (label: 'Ödeme sonucu belirsiz / hata', severity: 'high', permission: 'payments.take', clients: ['windows', 'personel', 'yonetici'], windowsOnly: false),
  'print.error': (label: 'Yazdırma hatası', severity: 'high', permission: 'receipts.print', clients: ['windows', 'personel', 'yonetici'], windowsOnly: false),
  'menu.availability': (label: 'Ürün stok durumu değişti', severity: 'low', permission: 'menu.view', clients: ['windows', 'personel', 'yonetici'], windowsOnly: false),
  'shift': (label: 'Vardiya başladı/bitti, düzeltme', severity: 'normal', permission: 'shifts.manage', clients: ['windows', 'yonetici'], windowsOnly: false),
  'payroll': (label: 'Maaş, prim, avans, ödeme', severity: 'normal', permission: 'payroll.view', clients: ['windows', 'yonetici'], windowsOnly: false),
  'report.daily': (label: 'Gün sonu raporu hazır', severity: 'normal', permission: 'sales.view', clients: ['windows', 'yonetici'], windowsOnly: false),
  'review': (label: 'Yeni platform / Google yorumu', severity: 'normal', permission: 'reviews.reply', clients: ['windows', 'yonetici'], windowsOnly: false),
  'pos.unavailable': (label: 'Windows POS erişilemiyor', severity: 'high', permission: null, clients: ['personel', 'yonetici'], windowsOnly: false),
  'command.failed': (label: 'Uzak komut başarısız / bekliyor', severity: 'high', permission: 'online.act', clients: ['windows', 'yonetici'], windowsOnly: false),
  'security': (label: 'Güvenlik ve hesap olayı', severity: 'high', permission: 'users.manage', clients: ['windows', 'yonetici'], windowsOnly: false),
  'sync': (label: 'Bulut senkronizasyon uyarısı', severity: 'normal', permission: 'sync.view', clients: ['windows'], windowsOnly: true),
  'backup': (label: 'Yedekleme uyarısı', severity: 'high', permission: 'backup.view', clients: ['windows'], windowsOnly: true),
};

/// Events older than this are recorded as already read (first import, long
/// downtime): history without a burst of stale alerts.
const notificationFreshness = Duration(hours: 6);

Json _event(String id, String category, String createdAt, String title,
        {String body = '', required Json ref}) => {
  'eventId': id,
  'category': category,
  'severity': notificationCategories[category]!.severity,
  'createdAt': createdAt,
  'title': title,
  if (body.isNotEmpty) 'body': body,
  'ref': ref,
  'permission': notificationCategories[category]!.permission,
};

/// Derives operational events from committed state. Pure and idempotent.
List<Json> deriveOperationalEvents(Json state) {
  final events = <Json>[];
  for (final n in asMaps(state['staffNotices'])) {
    final action = '${n['action'] ?? ''}';
    if (action != 'Yeni sipariş' && action != 'Ek sipariş') continue;
    final table = n['table'];
    final isTable = table is int && table > 0;
    events.add(_event('staff:${n['id']}', isTable ? 'order.table' : 'order.pickup',
        '${n['at'] ?? ''}',
        isTable ? '$action · Masa $table' : '$action · Gel-Al',
        body: '${n['staff'] ?? ''}', ref: {'kind': 'order', 'key': '${n['orderId']}'}));
  }
  for (final o in asMaps(state['trendyolGoOrders'])) {
    if (o['testPackage'] == true || o['packageId'] == null) continue;
    events.add(_event('tgo:${o['packageId']}:new', 'order.platform', '${o['createdAt'] ?? ''}',
        'Trendyol Go · Yeni sipariş ${o['orderNumber'] ?? ''}'.trim(),
        ref: {'kind': 'package', 'key': '${o['packageId']}'}));
  }
  for (final j in asMaps(state['printJobs'])) {
    if (j['state'] != 'Kontrol gerekli') continue;
    final key = '${j['orderId']}:${j['batchId']}:${j['kind'] ?? ''}';
    events.add(_event('print:$key:${j['spooledAt'] ?? j['createdAt'] ?? ''}', 'print.error',
        '${j['spooledAt'] ?? j['createdAt'] ?? ''}', 'Yazdırma kontrol gerekli · Sipariş ${j['orderId']}',
        body: 'Yazıcıyı kontrol edin; fişi gerekirse elle yeniden yazdırın.',
        ref: {'kind': 'printJob', 'key': key}));
  }
  for (final a in asMaps(state['terminalAttempts'])) {
    if (a['status'] != 'unknown') continue;
    events.add(_event('terminal:${a['reference']}:unknown', 'payment.error', '',
        'Kart ödemesi sonucu belirsiz · Sipariş ${a['orderId']}',
        body: 'Terminalden sorgulayın; ödeme yeniden başlatılmaz.',
        ref: {'kind': 'terminalAttempt', 'key': '${a['reference']}'}));
  }
  return events;
}

/// Adds new derived events to the history in one guarded write. Returns the
/// ids added; writes nothing (no revision change) when nothing is new.
List<String> recordOperationalNotifications(PosStore store, {DateTime Function()? clock}) {
  final now = (clock ?? DateTime.now)().toUtc();
  final snap = store.read();
  final known = {for (final r in asMaps(snap.data[notificationsStateKey])) '${r['eventId']}'};
  final daily = dailyReportEvent(snap.data, now);
  final fresh = [
    for (final e in [
      ...deriveOperationalEvents(snap.data),
      if (daily != null) {...daily, 'severity': notificationCategories['report.daily']!.severity,
        'permission': notificationCategories['report.daily']!.permission},
    ])
      if (!known.contains(e['eventId'])) () {
        final at = DateTime.tryParse('${e['createdAt']}');
        final stale = at == null ? false : now.difference(at) > notificationFreshness;
        return {
          ...e,
          if ('${e['createdAt']}'.isEmpty) 'createdAt': now.toIso8601String(),
          if (stale) 'read': true,
          if (stale) 'windows': 'dismissed',
        };
      }(),
  ];
  if (fresh.isEmpty) return const [];
  final next = copyJson(snap.data);
  final (rows, added) = addNotifications(next[notificationsStateKey] as List?, fresh);
  next[notificationsStateKey] = rows;
  if (!store.replace(next, snap.revision).ok) return const [];
  return added;
}

/// What a LAN client may see: category allowed for that client, recipient
/// permission held, newest first. Windows-only categories never leave Windows.
List<Json> visibleNotifications(List? rows, LocalAuth auth, AuthContext ctx, {int limit = 100}) {
  final client = ctx.client ?? '';
  final out = <Json>[];
  for (final r in asMaps(rows).reversed) {
    final cat = notificationCategories['${r['category']}'];
    if (cat == null || cat.windowsOnly || !cat.clients.contains(client)) continue;
    final perm = r['permission'] as String? ?? cat.permission;
    if (perm != null && auth.authorize(ctx, perm) != 'ok') continue;
    out.add({
      for (final k in ['eventId', 'category', 'severity', 'createdAt', 'title', 'body', 'ref']) k: r[k],
    });
    if (out.length >= limit) break;
  }
  return out;
}

/// `/api/notifications` for the LAN apps: per-user read state lives in the
/// local auth database (never in the synced state JSON).
class LanNotificationsApi {
  LanNotificationsApi(this.store, this.auth) {
    auth.db.execute('''CREATE TABLE IF NOT EXISTS auth_notification_reads(
      user_id TEXT NOT NULL, event_id TEXT NOT NULL, read_at TEXT NOT NULL,
      PRIMARY KEY(user_id, event_id))''');
  }
  final PosStore store;
  final LocalAuth auth;

  Set<String> _read(String userId) => {
    for (final r in auth.db.select('SELECT event_id FROM auth_notification_reads WHERE user_id=?', [userId]))
      r['event_id'] as String,
  };

  Json list(AuthContext ctx) {
    final read = _read(ctx.userId!);
    final rows = [
      for (final e in visibleNotifications(store.read().data[notificationsStateKey] as List?, auth, ctx))
        {...e, 'read': read.contains(e['eventId'])},
    ];
    return {'notifications': rows, 'unread': rows.where((r) => r['read'] != true).length};
  }

  Json markRead(AuthContext ctx, Json body) {
    final visible = {
      for (final e in visibleNotifications(store.read().data[notificationsStateKey] as List?, auth, ctx, limit: 500))
        '${e['eventId']}',
    };
    final ids = body['all'] == true
        ? visible
        : {for (final id in (body['eventIds'] is List ? body['eventIds'] as List : const [])) '$id'}
            .intersection(visible);
    final now = DateTime.now().toUtc().toIso8601String();
    for (final id in ids) {
      auth.db.execute('INSERT OR IGNORE INTO auth_notification_reads(user_id,event_id,read_at) VALUES(?,?,?)',
          [ctx.userId, id, now]);
    }
    return {'ok': true, 'marked': ids.length};
  }
}
