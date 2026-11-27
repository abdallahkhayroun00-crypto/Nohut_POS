/// Phase 5: the Windows side of remote commands (spec §11.2, §20.3, §22).
///
/// Phones and web apps never write business state. They ask the server for
/// a command; the server authenticates the user and builds an immutable
/// envelope (actor, grants, permission version, expiry, payload hash). The
/// Windows POS — the single transactional authority — claims envelopes
/// through a [CommandTransport], re-checks everything and executes them with
/// the SAME handlers the LAN phones already use (`submitStaffOrder`,
/// `submitStaffAction`). Idempotency is the existing `command_receipts`
/// table, written in the same SQLite transaction as the business change.
///
/// Rules enforced here, independent of what the client or server claims:
/// * unknown action types are rejected (fail closed);
/// * Windows-only operations (`sync.*`, `backup.*`, §22.3) are rejected from
///   every remote client — including the verified owner;
/// * the grant must be present (owner-only operations require the owner);
/// * the payload hash must match the canonical payload;
/// * expired envelopes are never executed (time-sensitive actions have a
///   short TTL so nothing is replayed after a long outage);
/// * the acting employee comes from the envelope, never from the payload,
///   and must be an active employee;
/// * a result is reported to the server only after the local COMMIT, and a
///   re-claimed command returns the stored receipt instead of running twice.
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as hash;

import 'permission_catalogue.g.dart';
import 'pos_logic.dart';
import 'pos_store.dart';
import 'shifts.dart';
import 'staff_commands.dart';
import 'trendyol_go_readonly.dart';

/// Terminal states of the §11.2 state machine as decided on Windows.
enum CommandOutcome {
  confirmed,
  conflict,
  rejected,
  expired,

  /// An external side effect may or may not have happened (§11.2). Never
  /// retried automatically; staff check the platform panel.
  reconciliationRequired,
}

class RemoteCommandResult {
  const RemoteCommandResult(this.outcome, this.code, this.result);
  final CommandOutcome outcome;

  /// Stable machine code (`ok`, `forbidden`, `windows_only`, ...).
  final String code;
  final Map<String, dynamic> result;

  Map<String, dynamic> toJson() => {
        'state': outcome == CommandOutcome.reconciliationRequired ? 'reconciliation_required' : outcome.name,
        'code': code,
        ...result,
      };
}

/// How an action type maps onto a catalogue operation and a handler.
class _Route {
  const _Route(this.operation, this.kind, {this.actions, this.ttl = const Duration(minutes: 15)});
  final String operation;

  /// `order` → submitStaffOrder, `action` → submitStaffAction,
  /// `shift` → submitShiftAction, `shiftCorrect` → correctShift.
  final String kind;

  /// Allowed `payload.action` values for `kind == 'action'`.
  final Set<String>? actions;
  final Duration ttl;
}

const _routes = <String, _Route>{
  'create_order': _Route('orders.create', 'order', ttl: Duration(minutes: 15)),
  'add_order_items': _Route('orders.create', 'order', ttl: Duration(minutes: 15)),
  'record_payment': _Route('payments.take', 'action', actions: {'pay', 'payMixed', 'payProducts'}, ttl: Duration(minutes: 15)),
  'split_bill': _Route('payments.take', 'action', actions: {'splitEqual', 'addGuest', 'allocate', 'resetGuests'}),
  'move_order': _Route('orders.move', 'action', actions: {'move'}),
  'close_order': _Route('orders.release', 'action', actions: {'close'}),
  'mark_delivered': _Route('orders.release', 'action', actions: {'status'}),
  'edit_order_line': _Route('orders.edit', 'action', actions: {'editLine'}),
  'delete_order': _Route('orders.edit', 'action', actions: {'delete'}),
  'clock_in_out': _Route('shifts.self', 'shift', actions: {'clockIn', 'clockOut'}, ttl: Duration(minutes: 5)),
  'correct_shift': _Route('shifts.manage', 'shiftCorrect'),
  'retry_print': _Route('receipts.print', 'print', ttl: Duration(minutes: 5)),
  'set_product_sale': _Route('menu.stock.toggle', 'menuSale'),
  'platform_action': _Route('online.act', 'platform', actions: {'accept', 'ready'}, ttl: Duration(minutes: 5)),
  'print_payment_receipt': _Route('receipts.print', 'action', actions: {'printProductPayment'}, ttl: Duration(minutes: 5)),
};

/// Action types that name a Windows-only section are recognised only to be
/// refused with a clear code (never "unknown").
bool _windowsOnlyAction(String type) =>
    type.startsWith('sync_') || type.startsWith('backup_') || type.startsWith('restore_') ||
    type == 'first_sync' || type == 'full_resync';

/// Canonical JSON: object keys sorted recursively, no whitespace.
String canonicalJson(Object? value) {
  Object? norm(Object? v) {
    if (v is Map) {
      final keys = v.keys.map((k) => '$k').toList()..sort();
      return {for (final k in keys) k: norm(v[k])};
    }
    if (v is List) return v.map(norm).toList();
    return v;
  }

  return jsonEncode(norm(value));
}

String payloadSha256(Object? payload) => hash.sha256.convert(utf8.encode(canonicalJson(payload))).toString();

RemoteCommandResult _reject(String code, String message) =>
    RemoteCommandResult(CommandOutcome.rejected, code, {'message': message});

class _Checked {
  const _Checked(this.type, this.route, this.body, this.employee);
  final String type;
  final _Route route;
  final Map<String, dynamic> body;
  final Json employee;
}

/// All envelope checks. Returns a rejection/expiry, or the checked command.
Object _check(PosStore store, Map<String, dynamic> envelope, DateTime? now) {
  RemoteCommandResult reject(String code, String message) => _reject(code, message);

  final requestId = envelope['request_id'];
  final type = envelope['action_type'];
  final payload = envelope['payload'];
  final actor = envelope['actor'];
  if (requestId is! String || type is! String || payload is! Map || actor is! Map) {
    return reject('invalid_envelope', 'Komut zarfı geçersiz');
  }
  if (_windowsOnlyAction(type)) {
    return reject('windows_only', 'Bu işlem yalnız Windows kasada yapılır');
  }
  final route = _routes[type];
  if (route == null) return reject('unknown_action', 'Desteklenmeyen işlem');
  final op = permissionCatalogue[route.operation];
  final client = envelope['client'];
  if (op == null) return reject('unknown_operation', 'Yetki tanımı yok');
  if (client is! String || client == 'windows' || !op.clients.contains(client)) {
    // Remote envelopes come from the apps; an operation must be allowed for
    // that client. Windows-only operations therefore never pass (§22.3).
    return reject(op.clients.length == 1 && op.clients.single == 'windows' ? 'windows_only' : 'client_not_allowed',
        'Bu işlem bu uygulamadan yapılamaz');
  }

  // Integrity: the server hashes the canonical payload it accepted.
  if (envelope['payload_sha256'] != payloadSha256(payload)) {
    return reject('payload_hash_mismatch', 'Komut içeriği doğrulanamadı');
  }

  // Expiry: both the server's expires_at and our own TTL per action type.
  final clock = (now ?? DateTime.now()).toUtc();
  final expires = DateTime.tryParse('${envelope['expires_at']}');
  final issued = DateTime.tryParse('${envelope['issued_at']}');
  if (expires == null || issued == null) return reject('invalid_envelope', 'Komut zamanı eksik');
  if (!clock.isBefore(expires) || clock.isAfter(issued.add(route.ttl))) {
    return RemoteCommandResult(CommandOutcome.expired, 'expired', {'message': 'Komutun süresi doldu; yeniden deneyin'});
  }

  // Authorization (server already checked; Windows re-checks, §20.3 rule 4).
  final isOwner = actor['is_owner'] == true;
  final grants = {for (final g in (actor['grants'] as List? ?? const [])) '$g'};
  final allowed = op.sensitivity == 'ownerOnly' ? isOwner : isOwner || grants.contains(route.operation);
  if (!allowed) return reject('forbidden', 'Bu işlem için yetkiniz yok');

  // Identity comes from the envelope, never from the client payload.
  final employeeId = actor['employee_id'];
  final state = store.read().data;
  final employee = asMaps(state['employees']).where((e) => e['id'] == employeeId && e['active'] == true).firstOrNull;
  if (employeeId is! int || employee == null) return reject('actor_inactive', 'Personel hesabı aktif değil');

  final body = Map<String, dynamic>.from(payload)
    ..['requestId'] = requestId
    ..['staffId'] = employeeId;
  if (route.actions != null) {
    if (!route.actions!.contains(body['action'])) {
      return reject('action_mismatch', 'İşlem türü ile içerik uyuşmuyor');
    }
  } else if (route.kind == 'order') {
    final hasOrder = body['orderId'] != null;
    if ((type == 'add_order_items') != hasOrder) {
      return reject('action_mismatch', 'İşlem türü ile içerik uyuşmuyor');
    }
  }
  return _Checked(type, route, body, employee);
}

/// Pure decision + execution for one envelope. Never throws for bad input:
/// every problem becomes a `rejected`/`expired`/`conflict` result. Commands
/// with external side effects need [executeRemoteCommandAsync].
RemoteCommandResult executeRemoteCommand(PosStore store, Map<String, dynamic> envelope, {DateTime? now}) {
  final checked = _check(store, envelope, now);
  if (checked is RemoteCommandResult) return checked;
  final c = checked as _Checked;
  if (c.route.kind == 'platform') return _reject('async_required', 'Platform işlemi ayrı yürütülür');
  final body = c.body;
  try {
    final result = switch (c.route.kind) {
      'order' => submitStaffOrder(store, body),
      'shift' => submitShiftAction(store, body..['source'] = 'remote', now: now),
      'shiftCorrect' => correctShift(store, body),
      'print' => retryAmbiguousPrint(store, body),
      'menuSale' => setProductSale(store, body),
      _ => submitStaffAction(store, body),
    };
    return RemoteCommandResult(CommandOutcome.confirmed, 'ok', Map<String, dynamic>.from(result));
  } on StaffConflict {
    return RemoteCommandResult(CommandOutcome.conflict, 'conflict', {'message': 'Veriler değişti; yenileyip tekrar deneyin', 'revision': store.read().revision});
  } on FormatException catch (e) {
    final mismatch = e.message == 'Request ID reused with different payload';
    return _reject(mismatch ? 'idempotency_payload_mismatch' : 'invalid_request', mismatch ? 'İstek kimliği farklı içerikle tekrar kullanıldı' : e.message);
  }
}

/// Calls the delivery platform (Trendyol Go today). Returns whether the
/// platform confirmed the new status. Throws [FormatException] for checks
/// that fail BEFORE any network call; any other error means the outcome is
/// unknown.
typedef PlatformCall = Future<bool> Function(Json order, String action, {int? preparationMinutes});

/// Like [executeRemoteCommand], plus platform actions. The attempt is stored
/// before the external call; a repeat of an interrupted attempt returns
/// `reconciliation_required` instead of calling the platform again.
Future<RemoteCommandResult> executeRemoteCommandAsync(
  PosStore store,
  Map<String, dynamic> envelope, {
  PlatformCall? platform,
  DateTime? now,
}) async {
  final checked = _check(store, envelope, now);
  if (checked is RemoteCommandResult) return checked;
  final c = checked as _Checked;
  if (c.route.kind != 'platform') return executeRemoteCommand(store, envelope, now: now);

  final requestId = '${envelope['request_id']}';
  final sha = '${envelope['payload_sha256']}';
  final previous = store.platformAttempt(requestId);
  if (previous != null) {
    if (previous['payload_sha256'] != sha) {
      return _reject('idempotency_payload_mismatch', 'İstek kimliği farklı içerikle tekrar kullanıldı');
    }
    final stored = Map<String, dynamic>.from(previous['result'] as Map);
    return switch (previous['state']) {
      'confirmed' => RemoteCommandResult(CommandOutcome.confirmed, 'ok', stored),
      'rejected' => RemoteCommandResult(CommandOutcome.rejected, '${stored['code'] ?? 'invalid_request'}', stored),
      _ => const RemoteCommandResult(CommandOutcome.reconciliationRequired, 'reconciliation_required',
          {'message': 'Önceki deneme yarıda kaldı; platform panelinden durumu kontrol edin'}),
    };
  }
  if (platform == null) return _reject('platform_unavailable', 'Platform bağlantısı etkin değil');
  final packageId = '${c.body['packageId'] ?? ''}';
  final order = asMaps(store.read().data['trendyolGoOrders'])
      .where((o) => packageId.isNotEmpty && '${o['packageId']}' == packageId)
      .firstOrNull;
  if (order == null) return _reject('invalid_request', 'Sipariş bulunamadı');
  if (!store.beginPlatformAttempt(requestId, sha)) {
    return const RemoteCommandResult(CommandOutcome.reconciliationRequired, 'reconciliation_required',
        {'message': 'Aynı işlem zaten yürütülüyor'});
  }
  final minutes = c.body['preparationMinutes'];
  try {
    final verified = await platform(order, '${c.body['action']}', preparationMinutes: minutes is int ? minutes : null);
    final result = <String, dynamic>{'ok': true, 'verified': verified, 'by': c.employee['name']};
    store.finishPlatformAttempt(requestId, 'confirmed', result);
    return RemoteCommandResult(CommandOutcome.confirmed, 'ok', result);
  } on FormatException catch (e) {
    final result = <String, dynamic>{'code': 'invalid_request', 'message': e.message};
    store.finishPlatformAttempt(requestId, 'rejected', result);
    return RemoteCommandResult(CommandOutcome.rejected, 'invalid_request', result);
  } catch (_) {
    final result = <String, dynamic>{'message': 'Platform yanıtı alınamadı; platform panelinden durumu kontrol edin'};
    store.finishPlatformAttempt(requestId, 'reconciliation_required', result);
    return RemoteCommandResult(CommandOutcome.reconciliationRequired, 'reconciliation_required', result);
  }
}

/// Re-queues ONE print whose outcome is uncertain ("Kontrol gerekli"), only
/// after the requester confirms the printer was checked — the same rule as
/// the Windows screens. Never creates a print for a job that printed fine.
Json retryAmbiguousPrint(PosStore store, Json payload) {
  if (payload['checked'] != true) throw const FormatException('Önce yazıcıyı kontrol edin');
  return store.command('${payload['requestId']}', payload, (s) {
    switch (payload['target']) {
      case 'kitchen':
      case 'payment':
        final job = (s['printJobs'] as List).cast<Map>().where((j) => payload['target'] == 'payment'
            ? j['kind'] == 'paymentReceipt' && j['receiptRequestId'] == payload['receiptRequestId']
            : j['kind'] != 'paymentReceipt' && j['orderId'] == payload['orderId'] && j['batchId'] == payload['batchId']).firstOrNull;
        if (job == null) throw const FormatException('Fiş bulunamadı');
        if (job['state'] != 'Kontrol gerekli') throw const FormatException('Bu fiş için tekrar yazdırma gerekmiyor');
        job['state'] = 'Bekliyor';
        return {'ok': true, 'target': payload['target']};
      case 'platform':
        final order = mutableTgoOrders(s).where((o) => tgoOrderKey(o) == payload['orderKey']).firstOrNull;
        if (order == null) throw const FormatException('Sipariş bulunamadı');
        if (order['kitchenPrintState'] != 'Kontrol gerekli' || !tgoKitchenActive(order)) {
          throw const FormatException('Bu fiş için tekrar yazdırma gerekmiyor');
        }
        order['kitchenPrintState'] = 'Bekliyor';
        order['kitchenQueuedAt'] = DateTime.now().toUtc().toIso8601String();
        return {'ok': true, 'target': 'platform'};
      default:
        throw const FormatException('Yazdırma hedefi geçersiz');
    }
  });
}

/// Satıştan kaldır / satışa aç for a POS menu product (`localMenu`). Old
/// orders are untouched (they store their own name and price). Campaigns,
/// internal products and the public QR menu are not changed here.
Json setProductSale(PosStore store, Json payload) {
  final active = payload['active'];
  if (active is! bool) throw const FormatException('Satış durumu geçersiz');
  return store.command('${payload['requestId']}', payload, (s) {
    final product = ((s['localMenu'] ?? const []) as List).cast<Map>().where((p) => p['id'] == payload['productId']).firstOrNull;
    if (product == null) throw const FormatException('Ürün bulunamadı');
    final staff = asMaps(s['employees']).firstWhere((e) => e['id'] == payload['staffId']);
    product['active'] = active;
    final notices = s.putIfAbsent('staffNotices', () => <dynamic>[]) as List;
    notices.add({
      'id': payload['requestId'],
      'staff': staff['name'],
      'action': '${product['name']}: ${active ? 'satışa açıldı' : 'satıştan kaldırıldı'}',
      'at': DateTime.now().toUtc().toIso8601String(),
    });
    return {'ok': true, 'productId': product['id'], 'active': active};
  });
}

/// Server side of the command queue (Supabase RPCs in production; a fake in
/// tests). Claims are leased: an unacknowledged claim becomes claimable
/// again, which is safe because execution is idempotent.
abstract class CommandTransport {
  Future<List<Map<String, dynamic>>> claim({required int max});
  Future<void> complete(String requestId, Map<String, dynamic> result);
}

/// Polls the transport, executes on Windows, reports after COMMIT.
/// Single-flight; network calls never happen inside a SQLite transaction.
class RemoteCommandWorker {
  RemoteCommandWorker(this.store, this.transport, {DateTime Function()? clock, this.platform}) : _clock = clock ?? DateTime.now;

  final PosStore store;
  final CommandTransport transport;

  /// Delivery-platform caller; null while no integration can write.
  final PlatformCall? platform;
  final DateTime Function() _clock;
  Future<int>? _running;

  /// Last error from the transport (shown as "Bekleyen işlemler" status).
  Object? lastError;

  Future<int> runOnce({int max = 20}) => _running ??= _run(max).whenComplete(() => _running = null);

  Future<int> _run(int max) async {
    var done = 0;
    try {
      final batch = await transport.claim(max: max);
      for (final envelope in batch) {
        final result = await executeRemoteCommandAsync(store, envelope, platform: platform, now: _clock());
        // Local state is committed (or nothing changed) before reporting.
        await transport.complete('${envelope['request_id']}', result.toJson());
        done++;
      }
      lastError = null;
    } catch (e) {
      lastError = e;
    }
    return done;
  }
}
