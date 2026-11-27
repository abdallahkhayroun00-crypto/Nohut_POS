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

/// Terminal states of the §11.2 state machine as decided on Windows.
enum CommandOutcome { confirmed, conflict, rejected, expired }

class RemoteCommandResult {
  const RemoteCommandResult(this.outcome, this.code, this.result);
  final CommandOutcome outcome;

  /// Stable machine code (`ok`, `forbidden`, `windows_only`, ...).
  final String code;
  final Map<String, dynamic> result;

  Map<String, dynamic> toJson() => {'state': outcome.name, 'code': code, ...result};
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

/// Pure decision + execution for one envelope. Never throws for bad input:
/// every problem becomes a `rejected`/`expired`/`conflict` result.
RemoteCommandResult executeRemoteCommand(PosStore store, Map<String, dynamic> envelope, {DateTime? now}) {
  RemoteCommandResult reject(String code, String message) =>
      RemoteCommandResult(CommandOutcome.rejected, code, {'message': message});

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
  final active = asMaps(state['employees']).any((e) => e['id'] == employeeId && e['active'] == true);
  if (employeeId is! int || !active) return reject('actor_inactive', 'Personel hesabı aktif değil');

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

  try {
    final result = switch (route.kind) {
      'order' => submitStaffOrder(store, body),
      'shift' => submitShiftAction(store, body..['source'] = 'remote', now: now),
      'shiftCorrect' => correctShift(store, body),
      _ => submitStaffAction(store, body),
    };
    return RemoteCommandResult(CommandOutcome.confirmed, 'ok', Map<String, dynamic>.from(result));
  } on StaffConflict {
    return RemoteCommandResult(CommandOutcome.conflict, 'conflict', {'message': 'Veriler değişti; yenileyip tekrar deneyin', 'revision': store.read().revision});
  } on FormatException catch (e) {
    final mismatch = e.message == 'Request ID reused with different payload';
    return reject(mismatch ? 'idempotency_payload_mismatch' : 'invalid_request', mismatch ? 'İstek kimliği farklı içerikle tekrar kullanıldı' : e.message);
  }
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
  RemoteCommandWorker(this.store, this.transport, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final PosStore store;
  final CommandTransport transport;
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
        final result = executeRemoteCommand(store, envelope, now: _clock());
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
