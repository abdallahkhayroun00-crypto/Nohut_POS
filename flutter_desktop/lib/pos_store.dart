import 'order_reporting.dart';

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as paths;
import 'package:sqlite3/sqlite3.dart';

import 'entity_storage.dart';
import 'sync_outbox.dart';
import 'pos_logic.dart';
import 'operations.dart';
import 'order_sync_identity.dart';

/// Compatible with the Python LAN prototype's state_snapshot schema.
/// All order data lives on the restaurant laptop, not in GitHub Pages.
class PosSnapshot {
  const PosSnapshot(this.revision, this.data, this.updatedAt);
  final int revision;
  final Map<String, dynamic> data;
  final String updatedAt;
}

class WriteResult {
  WriteResult(this.ok, this._load);
  final bool ok;
  final PosSnapshot Function() _load;

  /// Read on demand (a full copy is costly on large histories).
  PosSnapshot get snapshot => _load();
}

Map<String, dynamic> emptyPosState() => {
  'employees': [
    {'id': 1, 'name': 'Ömer', 'role': 'Yönetici', 'active': true},
    {'id': 2, 'name': 'Mehmet', 'role': 'Personel', 'active': true},
    {'id': 3, 'name': 'Abdallah', 'role': 'Personel', 'active': true},
  ],
  'orders': <dynamic>[],
  'nextId': 1200,
  'printJobs': <dynamic>[],
};

class PosStore extends ChangeNotifier {
  /// Test/diagnostic hook: sees every state about to be committed (after
  /// validation). `null` in production. Used by the persistence field audit
  /// (spec V5.1 §4.4 runtime validation); it must never mutate the state.
  @visibleForTesting
  static void Function(Map<String, dynamic> state)? debugWriteObserver;

  /// The database path the store will open (used to apply a staged
  /// restore before the database is opened).
  static String resolvePath(String? databaseFile) {
    if (databaseFile != null) return databaseFile;
    final env = Platform.environment['NOHUT_POS_DATABASE'];
    if (env != null) return env;
    final defaultFolder =
        Platform.environment['APPDATA'] ??
        paths.join(Directory.current.path, 'local-data');
    final folder = Directory(paths.join(defaultFolder, 'NohutFalafel'));
    folder.createSync(recursive: true);
    return paths.join(folder.path, 'nohut-pos.sqlite3');
  }

  PosStore({String? databaseFile}) {
    filePath = resolvePath(databaseFile);
    final target = Directory(paths.dirname(filePath));
    target.createSync(recursive: true);
    _db = sqlite3.open(filePath);
    _db.execute('PRAGMA journal_mode=WAL');
    _db.execute('PRAGMA busy_timeout=15000');
    _db.execute('PRAGMA synchronous=FULL');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS state_snapshot(
        id INTEGER PRIMARY KEY CHECK(id=1),
        revision INTEGER NOT NULL,
        payload TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    _db.execute(
      'INSERT OR IGNORE INTO state_snapshot(id,revision,payload,updated_at) VALUES(1,0,?,?)',
      [jsonEncode(emptyPosState()), DateTime.now().toUtc().toIso8601String()],
    );
    _db.execute(
      'CREATE TABLE IF NOT EXISTS command_receipts (request_id TEXT PRIMARY KEY, payload TEXT NOT NULL, result TEXT NOT NULL)',
    );
    _db.execute('''
      CREATE TABLE IF NOT EXISTS remote_command_receipts(
        request_id TEXT PRIMARY KEY, envelope_sha256 TEXT NOT NULL,
        result TEXT NOT NULL
      )
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS remote_command_report_acks(
        request_id TEXT PRIMARY KEY, envelope_sha256 TEXT NOT NULL
      )
    ''');
    _db.execute(
      'CREATE TABLE IF NOT EXISTS deleted_requests (request_id TEXT PRIMARY KEY)',
    );
    // Phase 5D: remote actions with external side effects (delivery
    // platforms). The attempt is recorded BEFORE the external call, so an
    // interrupted call is never blindly repeated (spec §11.2).
    _db.execute(
      'CREATE TABLE IF NOT EXISTS platform_command_attempts ('
      'request_id TEXT PRIMARY KEY, payload_sha256 TEXT NOT NULL, '
      'state TEXT NOT NULL, result TEXT NOT NULL, updated_at TEXT NOT NULL)',
    );
    // Spec V5.1 §4.4: local backup history (additive; never pruned).
    _db.execute('''
      CREATE TABLE IF NOT EXISTS backup_history(
        backup_id TEXT PRIMARY KEY,
        created_at TEXT NOT NULL,
        revision INTEGER NOT NULL,
        file_size_bytes INTEGER NOT NULL,
        compressed_bytes INTEGER NOT NULL,
        sha256 TEXT NOT NULL,
        destination TEXT NOT NULL,
        status TEXT NOT NULL,
        verified_at TEXT,
        reason TEXT,
        error_message TEXT
      )
    ''');
    createSyncTables(_db);
    _normalized = isNormalized(_db);
    if (!_normalized) _normalize();
    final old = read();
    final migrated = copyJson(old.data);
    assignDailyNumbers(migrated);
    if (jsonEncode(migrated) != jsonEncode(old.data)) {
      replace(migrated, old.revision);
    }
  }

  late final String filePath;
  late final Database _db;

  /// Phase 1B: true when the database uses per-entity tables.
  bool _normalized = false;
  bool get normalized => _normalized;

  /// Set when the one-time migration could not be verified; the database
  /// then stays in the legacy format, fully usable, and the UI says so.
  String? migrationError;

  /// Path of the plain safety copy taken just before migrating a database
  /// that already held orders (kept; never deleted automatically).
  String? preMigrationCopy;

  /// One-time, verified, transactional move of a legacy database to the
  /// per-entity tables. A database that already holds business data gets a
  /// consistent safety copy first. Any failure rolls back completely.
  void _normalize() {
    try {
      final legacy = jsonDecode(
        _db.select('SELECT payload FROM state_snapshot WHERE id=1')
            .single['payload'] as String,
      ) as Map;
      final hasHistory = (legacy['orders'] as List? ?? const []).isNotEmpty ||
          (legacy['trendyolGoOrders'] as List? ?? const []).isNotEmpty;
      if (hasHistory) {
        final stamp = DateTime.now().toUtc().toIso8601String()
            .substring(0, 19).replaceAll(':', '');
        final copy = '$filePath.pre-normalization-$stamp.sqlite3';
        if (!File(copy).existsSync()) backup(copy);
        preMigrationCopy = copy;
      }
      _db.execute('BEGIN IMMEDIATE');
      try {
        migrateLegacyToNormalized(_db);
        _db.execute('COMMIT');
        _normalized = true;
      } catch (_) {
        _db.execute('ROLLBACK');
        rethrow;
      }
    } catch (e) {
      migrationError = '$e';
      _normalized = false;
    }
  }

  Map<String, dynamic> _loadState() => _normalized
      ? loadNormalizedState(_db)
      : Map<String, dynamic>.from(
          jsonDecode(
            _db.select('SELECT payload FROM state_snapshot WHERE id=1')
                .single['payload'] as String,
          ) as Map,
        );

  /// Writes [next] as revision [revision] inside the caller's transaction
  /// and returns the state to cache after COMMIT.
  Map<String, dynamic> _commitState(
    Map<String, dynamic> next,
    int revision,
    String stamp,
  ) {
    if (!_normalized) {
      _writeSnapshot(next, revision, stamp);
      return copyJson(next);
    }
    // The diff needs the exact previous committed state.
    if (_cache == null || _cacheRevision != revision - 1) {
      _cache = _loadState();
      _cacheRevision = revision - 1;
    }
    // The same SQLite transaction covers domain rows and local events.
    // Recording remains disabled until the future owner-authorized wizard.
    if(outboxEnabled(_db)){
      prepareOrderSyncIdentities(_cache!,next);
      debugWriteObserver?.call(next);
    }
    final changes = outboxEnabled(_db)
        ? collectOutboxChanges(_cache!, next)
        : const <OutboxChange>[];
    final (cached, _) = writeNormalizedState(
      _db, _cache, next, revision: revision, updatedAt: stamp);
    if (changes.isNotEmpty) {
      writeOutboxEvents(_db, revision: revision, createdAt: stamp, changes: changes);
    }
    return cached;
  }

  // Phase 1B step 1: the last committed state stays decoded in memory and
  // is reused while (revision, updated_at) in SQLite is unchanged, so other
  // connections' writes are always seen. Callers still get their own copy.
  int? _cacheRevision;
  String? _cacheUpdatedAt;
  Map<String, dynamic>? _cache;

  PosSnapshot read() {
    final head = _db
        .select('SELECT revision,updated_at FROM state_snapshot WHERE id=1')
        .single;
    final revision = head['revision'] as int;
    final updatedAt = head['updated_at'] as String;
    if (_cache == null ||
        _cacheRevision != revision ||
        _cacheUpdatedAt != updatedAt) {
      _cache = _loadState();
      _cacheRevision = revision;
      _cacheUpdatedAt = updatedAt;
    }
    return PosSnapshot(revision, copyJson(_cache!), updatedAt);
  }

  int _headRevision() =>
      _db.select('SELECT revision FROM state_snapshot WHERE id=1').single['revision']
          as int;

  /// Owner-controlled first-sync preparation, before taking its pinned
  /// snapshot. Only additive IDs change; business facts remain untouched.
  void prepareCloudOrderIdentities(){
    final snapshot=read(),next=snapshot.data;
    prepareOrderSyncIdentities(next,next,force:true);
    if(!replace(next,snapshot.revision).ok)throw const FormatException('POS changed during identity preparation');
  }

  /// Writes the snapshot row; the caller holds the transaction.
  void _writeSnapshot(Map<String, dynamic> next, int revision, String stamp) {
    _db.execute(
      'UPDATE state_snapshot SET revision=?,payload=?,updated_at=? WHERE id=1',
      [revision, jsonEncode(next), stamp],
    );
  }

  void _remember(Map<String, dynamic> next, int revision, String stamp) {
    _cache = next;
    _cacheRevision = revision;
    _cacheUpdatedAt = stamp;
  }

  static void validate(Map<String, dynamic> data) {
    if (data['employees'] is! List ||
        data['orders'] is! List ||
        data['printJobs'] is! List ||
        data['nextId'] is! int) {
      throw const FormatException('Invalid POS structure');
    }
    final orders = data['orders'] as List;
    final employeeIds = <int>{};
    for (final e in asMaps(data['employees'])) {
      if (e['id'] is! int ||
          !employeeIds.add(e['id'] as int) ||
          e['name'] is! String ||
          '${e['name']}'.trim().isEmpty ||
          e['active'] is! bool) {
        throw const FormatException('Invalid employee');
      }
    }
    // No ceiling on history (owner decision 2026-11-27, spec §21.1): the old
    // 50 000-order / 100 000-print-job limit would have refused every write
    // once the restaurant's history grew past it. Size is handled by the
    // storage design and measured in docs/cloud-sync/storage-benchmark.md.
    final ids = <int>{};
    final tables = <int>{};
    final packages = <String>{};
    for (final item in orders) {
      if (item is! Map ||
          item['id'] is! int ||
          item['batches'] is! List ||
          item['payments'] is! List ||
          !ids.add(item['id'] as int)) {
        throw const FormatException('Invalid or duplicate order');
      }
      final order = item.cast<String, dynamic>();
      if (![
        'Masa',
        'Gel-Al',
        'Yemeksepeti',
        'Trendyol Go',
      ].contains(order['source'])) {
        throw const FormatException('Invalid order source');
      }
      if (order['source'] == 'Masa') {
        final table = order['table'];
        if (table is! int || table < 1 || table > 5) {
          throw const FormatException('Masa 1–5');
        }
        if (order['closed'] != true &&
            order['cancelled'] != true &&
            order['tableReleased'] != true &&
            !tables.add(table)) {
          throw const FormatException('Duplicate active table');
        }
      } else if (order['table'] != null) {
        throw const FormatException('Non-table order has table');
      }
      if (isPlatform(order) &&
          order['platformPackageId'] != null &&
          !packages.add('${order['source']}:${order['platformPackageId']}')) {
        throw const FormatException('Duplicate platform package');
      }
      final batches = <int>{};
      for (final b in asMaps(order['batches'])) {
        if (b['id'] is! int ||
            !batches.add(b['id'] as int) ||
            b['lines'] is! List) {
          throw const FormatException('Invalid batch');
        }
        for (final l in asMaps(b['lines'])) {
          if (l['qty'] is! int ||
              (l['qty'] as int) < 0 ||
              ((l['qty'] as int) == 0 && l['voided'] != true) ||
              l['price'] is! num ||
              !(l['price'] as num).isFinite ||
              cents(l['price']) < 0) {
            throw const FormatException('Invalid product quantity / price');
          }
        }
      }
      for (final p in asMaps(order['payments'])) {
        if (!['Nakit', 'Kart', 'Platform'].contains(p['method']) ||
            p['amount'] is! num ||
            !(p['amount'] as num).isFinite ||
            cents(p['amount']) <= 0 ||
            (isPlatform(order) != (p['method'] == 'Platform')) ||
            paymentNetCents(p) < 0) {
          throw const FormatException('Invalid payment');
        }
        for (final r in asMaps(p['refunds'])) {
          if (r['amount'] is! num ||
              !(r['amount'] as num).isFinite ||
              cents(r['amount']) <= 0 ||
              DateTime.tryParse('${r['createdAt']}') == null) {
            throw const FormatException('Invalid refund');
          }
        }
      }
      if (!isPlatform(order) &&
          orderPaidCents(order) > orderTotalCents(order)) {
        throw const FormatException('Overpayment');
      }
      final guests = <int>{};
      for (final g in asMaps(order['guestChecks'])) {
        if (g['id'] is! int || !guests.add(g['id'] as int)) {
          throw const FormatException('Invalid guest');
        }
        final keys = <String>{};
        for (final a in asMaps(g['allocations'])) {
          final l = checkLines(
            order,
          ).where((l) => l.key == a['key']).firstOrNull;
          if (a['key'] is! String ||
              !keys.add(a['key'] as String) ||
              a['cents'] is! int ||
              (a['cents'] as int) < 0 ||
              l == null ||
              allocatedTo(order, l.key) > l.total) {
            throw const FormatException('Invalid allocation');
          }
        }
        if (guestBalance(order, g['id'] as int) < 0) {
          throw const FormatException('Guest overpayment');
        }
      }
      for (final p in asMaps(order['payments'])) {
        final mapped = asMaps(p['guestAllocations']), mappedIds = <int>{};
        if (mapped.fold<int>(0, (n, a) => n + cents(a['amount'])) >
                paymentNetCents(p) ||
            p['guestCheckId'] != null && mapped.isNotEmpty) {
          throw const FormatException('Invalid payment allocation');
        }
        for (final a in mapped) {
          if (a['guestCheckId'] is! int ||
              !guests.contains(a['guestCheckId']) ||
              !mappedIds.add(a['guestCheckId'] as int) ||
              a['amount'] is! num ||
              cents(a['amount']) <= 0) {
            throw const FormatException('Invalid payment guest');
          }
        }
      }
    }
    for (final archived in asMaps(data['deletedOrders'])) {
      final id = archived['orderId'];
      if (id is! int || archived['order'] is! Map ||
          (archived['order'] as Map)['id'] != id || !ids.add(id)) {
        throw const FormatException('Invalid deleted order archive');
      }
    }
    if (ids.isNotEmpty &&
        (data['nextId'] as int) <= ids.reduce((a, b) => a > b ? a : b)) {
      throw const FormatException('Invalid nextId');
    }
  }

  (String, String)? _remoteContext;
  bool Function()? _remoteExecutionGuard;

  bool get remoteExecutionAllowed => syncStateValue(_db, 'remote_execution_blocked') == null;

  /// Bind a cloud envelope to the receipt written by the existing handler.
  /// Synchronous only: no network call or await may enter this context.
  T withRemoteCommand<T>(String requestId, String envelopeSha256, T Function() run, {bool Function()? guard}) {
    if (_remoteContext != null) throw StateError('Remote command already running');
    _remoteContext = (requestId, envelopeSha256);
    _remoteExecutionGuard = guard;
    try {
      return run();
    } finally {
      _remoteContext = null;
      _remoteExecutionGuard = null;
    }
  }

  Map<String, dynamic>? remoteCommandReceipt(String requestId, String envelopeSha256) {
    final rows = _db.select(
      'SELECT envelope_sha256,result FROM remote_command_receipts WHERE request_id=?',
      [requestId],
    );
    if (rows.isEmpty) return null;
    if (rows.single['envelope_sha256'] != envelopeSha256) {
      throw const FormatException('Request ID reused with different payload');
    }
    return Map<String, dynamic>.from(jsonDecode(rows.single['result'] as String) as Map);
  }

  void _recordRemoteReceipt(String requestId, Map<String, dynamic> result) {
    final context = _remoteContext;
    if (context == null) return;
    if (context.$1 != requestId) throw StateError('Remote request identity mismatch');
    _db.execute(
      'INSERT INTO remote_command_receipts(request_id,envelope_sha256,result) VALUES(?,?,?)',
      [requestId, context.$2, jsonEncode(result)],
    );
  }

  /// Durable business receipts/attempts not yet acknowledged by the cloud.
  /// An interrupted provider call is reported as uncertain, never repeated.
  List<Map<String, dynamic>> pendingRemoteReports({int limit = 100}) => [
    for (final row in _db.select('''
      SELECT r.request_id,r.envelope_sha256,r.result,'confirmed' AS state
      FROM remote_command_receipts r
      WHERE NOT EXISTS(SELECT 1 FROM remote_command_report_acks a
        WHERE a.request_id=r.request_id AND a.envelope_sha256=r.envelope_sha256)
      UNION ALL
      SELECT p.request_id,p.payload_sha256 AS envelope_sha256,p.result,p.state
      FROM platform_command_attempts p
      WHERE NOT EXISTS(SELECT 1 FROM remote_command_report_acks a
        WHERE a.request_id=p.request_id AND a.envelope_sha256=p.payload_sha256)
      LIMIT ?
    ''', [limit]))
      {
        'request_id': row['request_id'],
        'envelope_sha256': row['envelope_sha256'],
        'result': {
          ...Map<String, dynamic>.from(jsonDecode(row['result'] as String) as Map),
          'state': row['state'] == 'processing' ? 'reconciliation_required' : row['state'],
          'code': row['state'] == 'confirmed' ? 'ok' : row['state'] == 'rejected' ? 'invalid_request' : 'reconciliation_required',
        },
      },
  ];

  void acknowledgeRemoteReport(String requestId, String envelopeSha256) => _db.execute(
    'INSERT OR REPLACE INTO remote_command_report_acks(request_id,envelope_sha256) VALUES(?,?)',
    [requestId, envelopeSha256],
  );

  /// Executes a synchronous domain command while holding the SQLite writer lock.
  /// Retries reuse a persisted receipt; the same ID with another payload fails.
  Map<String, dynamic> command(
    String requestId,
    Map<String, dynamic> payload,
    Map<String, dynamic> Function(Map<String, dynamic>) change,
  ) {
    if (!RegExp(r'^[A-Za-z0-9_-]{8,100}$').hasMatch(requestId)) {
      throw const FormatException('Invalid request ID');
    }
    _db.execute('BEGIN IMMEDIATE');
    Map<String, dynamic> result;
    try {
      _checkRemoteFence();
      final receipt = _db.select(
        'SELECT payload,result FROM command_receipts WHERE request_id=?',
        [requestId],
      );
      if (_db.select(
        'SELECT request_id FROM deleted_requests WHERE request_id=?',
        [requestId],
      ).isNotEmpty)
        throw const FormatException(
          'Bu istek silinmiş bir siparişe ait; tekrar oluşturulamaz',
        );
      final encoded = jsonEncode(payload);
      if (receipt.isNotEmpty) {
        if (receipt.single['payload'] != encoded) {
          throw const FormatException(
            'Request ID reused with different payload',
          );
        }
        result = Map<String, dynamic>.from(
          jsonDecode(receipt.single['result'] as String) as Map,
        );
        _recordRemoteReceipt(requestId, result);
        _db.execute('COMMIT');
        return result;
      }
      final current = read(), next = current.data;
      result = change(next);
      validate(next);
      debugWriteObserver?.call(next);
      final revision = current.revision + 1;
      result['revision'] = revision;
      final stamp = DateTime.now().toUtc().toIso8601String();
      final cached = _commitState(next, revision, stamp);
      _db.execute(
        'INSERT INTO command_receipts(request_id,payload,result) VALUES(?,?,?)',
        [requestId, encoded, jsonEncode(result)],
      );
      _recordRemoteReceipt(requestId, result);
      _db.execute('COMMIT');
      _remember(cached, revision, stamp);
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    notifyListeners();
    return result;
  }

  /// Audited SOFT deletion (owner decision 2026-11-27, spec §21.2).
  ///
  /// The order is not erased: it moves, unchanged, into `deletedOrders`
  /// together with its print jobs, staff notices and terminal attempts and
  /// an audit block (who, when, why, request ID). Every existing report and
  /// screen reads `orders`, so totals behave exactly as before, while the
  /// full record, its payments and its command receipts are preserved and
  /// the archive entry is the sync tombstone. Command receipts are kept;
  /// their request IDs are also listed in `deleted_requests` so a replay
  /// returns a clear message and can never re-create the order.
  Json deleteOrder(
    int orderId,
    int revision,
    String requestId, {
    int? staffId,
    String? reason,
    String? actor,
  }) {
    if (!RegExp(r'^[A-Za-z0-9_-]{8,100}$').hasMatch(requestId))
      throw const FormatException('İstek kimliği geçersiz');
    _db.execute('BEGIN IMMEDIATE');
    try {
      _checkRemoteFence();
      if (_db.select(
        'SELECT request_id FROM deleted_requests WHERE request_id=?',
        [requestId],
      ).isNotEmpty) {
        _db.execute('COMMIT');
        return {'ok': true, 'revision': read().revision};
      }
      final snap = read();
      if (snap.revision != revision)
        throw const FormatException('Kayıtlar değişti; yenileyin');
      final state = snap.data, order = mutableOrder(state, orderId);
      if (order == null) throw const FormatException('Sipariş yok');
      requireLocal(order);
      if (order['terminalPending'] != null ||
          asMaps(
            state['printJobs'],
          ).any((j) => j['orderId'] == orderId && j['state'] == 'Gönderiliyor'))
        throw const FormatException(
          'Bekleyen ödeme / yazdırma sonucunu önce kontrol edin',
        );
      Map? person;
      if (staffId != null) {
        person = asMaps(state['employees'])
            .where((e) => e['id'] == staffId && e['active'] == true)
            .firstOrNull;
        if (person == null) throw const FormatException('Aktif personel seçin');
      }
      final why = (reason ?? '').trim();
      if (why.length > 500) throw const FormatException('Neden çok uzun');
      final related = <String, dynamic>{};
      for (final key in ['printJobs', 'staffNotices', 'terminalAttempts']) {
        if (state[key] is! List) continue;
        final list = state[key] as List;
        related[key] = [
          for (final r in list)
            if (r is Map && r['orderId'] == orderId) r,
        ];
        list.removeWhere((r) => r is Map && r['orderId'] == orderId);
      }
      (state['orders'] as List).removeWhere((o) => o['id'] == orderId);
      final now = utcNow();
      (state.putIfAbsent('deletedOrders', () => <dynamic>[]) as List).add({
        'orderId': orderId,
        'deletedAt': now,
        'deletedBy': '${person?['name'] ?? actor ?? 'Kasa (PC)'}',
        'deletedByStaffId': ?staffId,
        'reason': why.isEmpty ? 'Belirtilmedi' : why,
        'requestId': requestId,
        'revision': revision + 1,
        'order': order,
        'related': related,
      });
      final linked = <String>[];
      for (final r in _db.select(
        'SELECT request_id,payload,result FROM command_receipts',
      )) {
        final p = jsonDecode(r['payload'] as String) as Map,
            result = jsonDecode(r['result'] as String) as Map;
        if (p['orderId'] == orderId || result['orderId'] == orderId) {
          linked.add(r['request_id'] as String);
        }
      }
      validate(state);
      debugWriteObserver?.call(state);
      final stamp = utcNow();
      final cached = _commitState(state, revision + 1, stamp);
      // Receipts stay (idempotency history); their IDs are fenced so a
      // replay is refused with a clear message instead of re-creating.
      for (final id in [...linked, requestId]) {
        _db.execute(
          'INSERT OR IGNORE INTO deleted_requests(request_id) VALUES(?)',
          [id],
        );
      }
      _recordRemoteReceipt(requestId, {'ok': true, 'revision': revision + 1});
      _db.execute('COMMIT');
      _remember(cached, revision + 1, stamp);
      notifyListeners();
      return {'ok': true, 'revision': revision + 1};
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _checkRemoteFence() {
    if (_remoteContext != null && (!remoteExecutionAllowed || _remoteExecutionGuard?.call() == false)) {
      throw const FormatException('Remote execution fence expired');
    }
  }

  /// Phase 5D: the stored attempt for [requestId], if any.
  Map<String, Object?>? platformAttempt(String requestId) {
    final rows = _db.select(
      'SELECT payload_sha256,state,result FROM platform_command_attempts WHERE request_id=?',
      [requestId],
    );
    if (rows.isEmpty) return null;
    final r = rows.single;
    return {
      'payload_sha256': r['payload_sha256'],
      'state': r['state'],
      'result': jsonDecode(r['result'] as String),
    };
  }

  /// Records `processing` before the external call. Returns false when an
  /// attempt already exists (the caller must then use [platformAttempt]).
  bool beginPlatformAttempt(String requestId, String payloadSha256) {
    _db.execute(
      'INSERT OR IGNORE INTO platform_command_attempts(request_id,payload_sha256,state,result,updated_at) '
      "VALUES(?,?,'processing','{}',?)",
      [requestId, payloadSha256, DateTime.now().toUtc().toIso8601String()],
    );
    return _db.updatedRows == 1;
  }

  void finishPlatformAttempt(String requestId, String state, Map<String, dynamic> result) {
    _db.execute(
      'UPDATE platform_command_attempts SET state=?,result=?,updated_at=? WHERE request_id=?',
      [state, jsonEncode(result), DateTime.now().toUtc().toIso8601String(), requestId],
    );
  }

  void recordBackupHistory({
    required String backupId,
    required String createdAt,
    required int revision,
    required int fileSizeBytes,
    required int compressedBytes,
    required String sha256,
    required String destination,
    required String status,
    String? verifiedAt,
    String? reason,
    String? error,
  }) {
    _db.execute(
      'INSERT OR REPLACE INTO backup_history(backup_id,created_at,revision,'
      'file_size_bytes,compressed_bytes,sha256,destination,status,'
      'verified_at,reason,error_message) VALUES(?,?,?,?,?,?,?,?,?,?,?)',
      [backupId, createdAt, revision, fileSizeBytes, compressedBytes, sha256,
        destination, status, verifiedAt, reason, error],
    );
    notifyListeners();
  }

  /// Newest first.
  List<Map<String, Object?>> backupHistory({int limit = 200}) => [
    for (final row in _db.select(
      'SELECT * FROM backup_history ORDER BY created_at DESC LIMIT ?',
      [limit],
    ))
      {for (final key in row.keys) key: row[key]},
  ];

  /// VACUUM INTO creates one consistent database even while WAL is active.
  void backup(String destination) {
    if (File(destination).existsSync() ||
        paths.equals(paths.absolute(destination), paths.absolute(filePath))) {
      throw const FormatException('Backup destination already exists');
    }
    _db.execute('VACUUM INTO ?', [paths.absolute(destination)]);
  }

  WriteResult replace(Map<String, dynamic> next, int expectedRevision) {
    validate(next);
    debugWriteObserver?.call(next);
    _db.execute('BEGIN IMMEDIATE');
    try {
      final revision = _headRevision();
      if (revision != expectedRevision) {
        _db.execute('ROLLBACK');
        return WriteResult(false, read);
      }
      final stamp = DateTime.now().toUtc().toIso8601String();
      // The caller keeps [next]; the cache holds a private copy.
      final cached = _commitState(next, revision + 1, stamp);
      _db.execute('COMMIT');
      _remember(cached, revision + 1, stamp);
      notifyListeners();
      return WriteResult(true, read);
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  void dispose() {
    _db.close();
    super.dispose();
  }
}
