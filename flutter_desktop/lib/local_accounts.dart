/// Individual local accounts for the Windows POS and its LAN apps
/// (spec §23.3, §23.4; tasks A3/A4/L1).
///
/// The Windows POS is the authority. Accounts, trusted devices and sessions
/// live in dedicated SQLite tables of the POS database — never in the synced
/// state JSON — so they travel with an encrypted backup but are never
/// projected to the cloud.
///
/// * Passwords and PINs: PBKDF2-HMAC-SHA256, per-record salt, never stored
///   or logged in clear.
/// * Sessions: opaque 256-bit tokens returned once; only SHA-256 stored.
///   Bounded lifetime (default 30 days) so local apps work offline without
///   any cloud refresh token. After [idleLock] without activity a session is
///   `locked` and needs the device PIN (or the password).
/// * Authorization: the shared catalogue (docs/contracts/v1/permissions.json)
///   with per-user grants; owner holds everything; Windows-only operations
///   (sync.*, backup.*) are refused for LAN clients, owner included.
/// * Owner MFA: TOTP (RFC 6238). Sensitive administration from a LAN client
///   needs a session whose MFA was verified within [mfaWindow].
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:sqlite3/sqlite3.dart';

import 'permission_catalogue.g.dart';
import 'permission_roles.g.dart';
import 'pos_logic.dart';

const localAuthClients = {'windows', 'personel', 'yonetici'};
const localAuthRoles = ['Personel', 'Müdür', 'Muhasebe', 'Yönetici'];

class LocalAuthException implements Exception {
  const LocalAuthException(this.code, [this.message = '']);
  final String code, message;
  @override
  String toString() => 'LocalAuthException($code)';
}

/// Result of checking a session token.
class AuthContext {
  const AuthContext({
    required this.status,
    this.userId, this.username, this.role, this.employeeId,
    this.isOwner = false, this.deviceId, this.client,
    this.grants = const {}, this.permissionVersion = 0, this.mfa = false,
  });
  /// ok | locked | expired | revoked | inactive | unknown | client_mismatch
  final String status;
  final String? userId, username, role, deviceId, client;
  final int? employeeId;
  final bool isOwner, mfa;
  final Set<String> grants;
  final int permissionVersion;
  bool get ok => status == 'ok';
  Json toJson() => {
    'status': status,
    if (ok) ...{
      'username': username, 'role': role, 'employeeId': employeeId,
      'isOwner': isOwner, 'client': client, 'mfa': mfa,
      'permissionVersion': permissionVersion,
      'grants': [
        for (final g in grants.toList()..sort())
          if (client != null && (permissionCatalogue[g]?.clients.contains(client) ?? false)) g,
      ],
    },
  };
}

class LoginResult {
  const LoginResult(this.token, this.context);
  final String token;
  final AuthContext context;
}

class LocalAuth {
  LocalAuth(this.db, {
    DateTime Function()? clock,
    this.iterations = 120000,
    this.sessionLifetime = const Duration(days: 30),
    this.idleLock = const Duration(minutes: 30),
    this.mfaWindow = const Duration(hours: 12),
    Random? random,
  }) : _clock = clock ?? DateTime.now, _random = random ?? Random.secure() {
    createTables(db);
  }

  final Database db;
  final DateTime Function() _clock;
  final Random _random;
  final int iterations;
  final Duration sessionLifetime, mfaWindow;
  /// Owner-configurable (default 30 minutes).
  Duration idleLock;

  static void createTables(Database db) {
    db.execute('''CREATE TABLE IF NOT EXISTS auth_users(
      user_id TEXT PRIMARY KEY,
      username TEXT NOT NULL UNIQUE COLLATE NOCASE,
      employee_id INTEGER,
      role TEXT NOT NULL,
      is_owner INTEGER NOT NULL DEFAULT 0,
      active INTEGER NOT NULL DEFAULT 1,
      password_hash TEXT NOT NULL,
      grants TEXT NOT NULL DEFAULT '[]',
      permission_version INTEGER NOT NULL DEFAULT 1,
      failed_logins INTEGER NOT NULL DEFAULT 0,
      locked_until TEXT,
      totp_secret TEXT,
      totp_last_step INTEGER,
      created_at TEXT NOT NULL,
      last_login_at TEXT)''');
    db.execute('''CREATE TABLE IF NOT EXISTS auth_devices(
      device_id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES auth_users(user_id),
      client TEXT NOT NULL,
      label TEXT NOT NULL DEFAULT '',
      enrolled_at TEXT NOT NULL,
      last_seen_at TEXT,
      revoked_at TEXT,
      pin_hash TEXT,
      pin_failed INTEGER NOT NULL DEFAULT 0)''');
    db.execute('''CREATE TABLE IF NOT EXISTS auth_sessions(
      token_sha256 TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES auth_users(user_id),
      device_id TEXT NOT NULL REFERENCES auth_devices(device_id),
      created_at TEXT NOT NULL,
      last_seen_at TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      mfa_at TEXT,
      revoked_at TEXT)''');
    db.execute('''CREATE TABLE IF NOT EXISTS auth_audit(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      at TEXT NOT NULL,
      actor TEXT,
      action TEXT NOT NULL,
      target TEXT,
      detail TEXT NOT NULL DEFAULT '{}')''');
    db.execute('''CREATE TABLE IF NOT EXISTS auth_settings(
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL)''');
  }

  // ---------------------------------------------------------------- settings
  String? setting(String key) {
    final r = db.select('SELECT value FROM auth_settings WHERE key=?', [key]);
    return r.isEmpty ? null : r.single['value'] as String;
  }

  void setSetting(String key, String value, {String? actor}) {
    db.execute('INSERT INTO auth_settings(key,value) VALUES(?,?) '
        'ON CONFLICT(key) DO UPDATE SET value=excluded.value', [key, value]);
    _audit('setting.update', actor: actor, target: key, detail: {'value': value});
  }

  /// "Bireysel giriş zorunlu": LAN apps need an individual login. Off until
  /// the owner turns it on, so existing restaurant phones keep working.
  bool get lanLoginRequired => setting('lan_login_required') == '1';

  /// Loads the owner-configured idle lock (minutes) into [idleLock].
  void loadSettings() {
    final m = int.tryParse(setting('idle_lock_minutes') ?? '');
    if (m != null && m >= 1 && m <= 720) idleLock = Duration(minutes: m);
  }

  List<Json> audit({int limit = 200}) => [
    for (final r in db.select('SELECT * FROM auth_audit ORDER BY id DESC LIMIT ?', [limit]))
      {'at': r['at'], 'actor': r['actor'], 'action': r['action'], 'target': r['target']},
  ];

  // ---------------------------------------------------------------- crypto
  String _randomB64(int bytes) => base64UrlEncode(
      List<int>.generate(bytes, (_) => _random.nextInt(256))).replaceAll('=', '');

  static String sha256Hex(String v) => crypto.sha256.convert(utf8.encode(v)).toString();

  Future<String> _hash(String secret) async {
    final salt = Uint8List.fromList(List<int>.generate(16, (_) => _random.nextInt(256)));
    final key = await Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256)
        .deriveKeyFromPassword(password: secret, nonce: salt);
    final bytes = await key.extractBytes();
    return 'pbkdf2-sha256\$$iterations\$${base64Encode(salt)}\$${base64Encode(bytes)}';
  }

  static Future<bool> _verify(String secret, String stored) async {
    final parts = stored.split('\$');
    if (parts.length != 4 || parts[0] != 'pbkdf2-sha256') return false;
    final iter = int.tryParse(parts[1]);
    if (iter == null || iter < 1000) return false;
    final key = await Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iter, bits: 256)
        .deriveKeyFromPassword(password: secret, nonce: base64Decode(parts[2]));
    final got = await key.extractBytes();
    final want = base64Decode(parts[3]);
    if (got.length != want.length) return false;
    var diff = 0;
    for (var i = 0; i < got.length; i++) {
      diff |= got[i] ^ want[i];
    }
    return diff == 0;
  }

  String _now() => _clock().toUtc().toIso8601String();

  void _audit(String action, {String? actor, String? target, Json detail = const {}}) {
    assert(!detail.keys.any((k) => const ['password', 'pin', 'token', 'totp'].contains(k)));
    db.execute('INSERT INTO auth_audit(at,actor,action,target,detail) VALUES(?,?,?,?,?)',
        [_now(), actor, action, target, jsonEncode(detail)]);
  }

  static void _checkPassword(String p) {
    if (p.length < 8 || p.length > 128) {
      throw const LocalAuthException('weak_password', 'Şifre en az 8 karakter olmalı.');
    }
  }

  /// Spec §24.1: new trusted-device PINs have 5 digits. PINs already set
  /// with 6 digits keep verifying (hash compare) until the user changes them.
  static bool _weakPin(String pin) {
    if (pin.split('').toSet().length == 1) return true; // 00000, 11111…
    const runs = '0123456789', back = '9876543210';
    if (runs.contains(pin) || back.contains(pin)) return true; // 12345, 54321…
    return const {'12121', '10101', '11211', '12321', '69696', '13579', '24680'}.contains(pin);
  }
  static void _checkPin(String pin) {
    if (!RegExp(r'^[0-9]{5}$').hasMatch(pin) || _weakPin(pin)) {
      throw const LocalAuthException('weak_pin', 'PIN 5 haneli olmalı ve tahmin edilmesi kolay olmamalı.');
    }
  }

  // ---------------------------------------------------------------- admin
  bool get hasUsers => db.select('SELECT 1 FROM auth_users LIMIT 1').isNotEmpty;

  static Set<String> defaultGrants(String role) => {
    for (final e in permissionRoleDefaults.entries)
      if (e.value.contains(role)) e.key,
  };

  /// Creates an account. The very first account must be the owner.
  Future<String> createUser({
    required String username,
    required String password,
    required String role,
    int? employeeId,
    bool isOwner = false,
    String? actor,
  }) async {
    final name = username.trim();
    if (!RegExp(r'^[\p{L}0-9._-]{3,32}$', unicode: true).hasMatch(name)) {
      throw const LocalAuthException('invalid_username', 'Kullanıcı adı 3–32 harf/rakam olmalı.');
    }
    if (!localAuthRoles.contains(role)) throw const LocalAuthException('invalid_role');
    if (!hasUsers && !isOwner) {
      throw const LocalAuthException('owner_first', 'İlk hesap işletme sahibi olmalı.');
    }
    if (isOwner && db.select('SELECT 1 FROM auth_users WHERE is_owner=1').isNotEmpty) {
      throw const LocalAuthException('owner_exists');
    }
    _checkPassword(password);
    if (db.select('SELECT 1 FROM auth_users WHERE username=?', [name]).isNotEmpty) {
      throw const LocalAuthException('username_taken', 'Bu kullanıcı adı kullanılıyor.');
    }
    final id = _uuid();
    final hash = await _hash(password);
    db.execute('INSERT INTO auth_users(user_id,username,employee_id,role,is_owner,password_hash,grants,created_at) '
        'VALUES(?,?,?,?,?,?,?,?)',
        [id, name, employeeId, role, isOwner ? 1 : 0, hash,
          jsonEncode((defaultGrants(role).toList()..sort())), _now()]);
    _audit('user.create', actor: actor, target: id, detail: {'role': role, 'owner': isOwner});
    return id;
  }

  String _uuid() {
    final b = List<int>.generate(16, (_) => _random.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }

  Row? _user(String userId) {
    final r = db.select('SELECT * FROM auth_users WHERE user_id=?', [userId]);
    return r.isEmpty ? null : r.single;
  }

  void _bump(String userId) => db.execute(
      'UPDATE auth_users SET permission_version=permission_version+1 WHERE user_id=?', [userId]);

  void setGrant(String userId, String operation, bool granted, {String? actor}) {
    final op = permissionCatalogue[operation];
    if (op == null) throw const LocalAuthException('unknown_operation');
    if (op.sensitivity == 'ownerOnly') throw const LocalAuthException('owner_only');
    final u = _user(userId) ?? (throw const LocalAuthException('unknown_user'));
    final grants = (jsonDecode(u['grants'] as String) as List).cast<String>().toSet();
    if (granted ? !grants.add(operation) : !grants.remove(operation)) return;
    db.execute('UPDATE auth_users SET grants=? WHERE user_id=?',
        [jsonEncode(grants.toList()..sort()), userId]);
    _bump(userId);
    _audit(granted ? 'grant.add' : 'grant.remove', actor: actor, target: userId,
        detail: {'operation': operation});
  }

  void setRole(String userId, String role, {String? actor}) {
    if (!localAuthRoles.contains(role)) throw const LocalAuthException('invalid_role');
    db.execute('UPDATE auth_users SET role=?, grants=? WHERE user_id=?',
        [role, jsonEncode(defaultGrants(role).toList()..sort()), userId]);
    _bump(userId);
    _audit('user.role', actor: actor, target: userId, detail: {'role': role});
  }

  void setActive(String userId, bool active, {String? actor}) {
    final u = _user(userId) ?? (throw const LocalAuthException('unknown_user'));
    if (!active && u['is_owner'] == 1) throw const LocalAuthException('owner_cannot_be_deactivated');
    db.execute('UPDATE auth_users SET active=? WHERE user_id=?', [active ? 1 : 0, userId]);
    _bump(userId);
    if (!active) revokeSessions(userId, actor: actor);
    _audit(active ? 'user.activate' : 'user.deactivate', actor: actor, target: userId);
  }

  Future<void> resetPassword(String userId, String password, {String? actor}) async {
    _user(userId) ?? (throw const LocalAuthException('unknown_user'));
    _checkPassword(password);
    final hash = await _hash(password);
    db.execute('UPDATE auth_users SET password_hash=?, failed_logins=0, locked_until=NULL WHERE user_id=?',
        [hash, userId]);
    revokeSessions(userId, actor: actor);
    _audit('user.password_reset', actor: actor, target: userId);
  }

  void resetPin(String userId, {String? actor}) {
    db.execute('UPDATE auth_devices SET pin_hash=NULL, pin_failed=0 WHERE user_id=?', [userId]);
    _audit('user.pin_reset', actor: actor, target: userId);
  }

  void revokeSessions(String userId, {bool devicesToo = false, String? actor}) {
    final now = _now();
    db.execute('UPDATE auth_sessions SET revoked_at=? WHERE user_id=? AND revoked_at IS NULL', [now, userId]);
    if (devicesToo) {
      db.execute('UPDATE auth_devices SET revoked_at=? WHERE user_id=? AND revoked_at IS NULL', [now, userId]);
    }
    _audit('user.sessions_revoked', actor: actor, target: userId, detail: {'devices': devicesToo});
  }

  void revokeDevice(String deviceId, {String? actor}) {
    final now = _now();
    db.execute('UPDATE auth_devices SET revoked_at=? WHERE device_id=? AND revoked_at IS NULL', [now, deviceId]);
    db.execute('UPDATE auth_sessions SET revoked_at=? WHERE device_id=? AND revoked_at IS NULL', [now, deviceId]);
    _audit('device.revoke', actor: actor, target: deviceId);
  }

  /// Employee profiles linked to an owner account (payroll exclusion default).
  List<int> ownerEmployeeIds() => [
    for (final u in db.select('SELECT employee_id FROM auth_users WHERE is_owner=1 AND employee_id IS NOT NULL'))
      u['employee_id'] as int,
  ];

  List<Json> users() => [
    for (final u in db.select('SELECT * FROM auth_users ORDER BY is_owner DESC, username'))
      {
        'userId': u['user_id'], 'username': u['username'], 'role': u['role'],
        'employeeId': u['employee_id'], 'isOwner': u['is_owner'] == 1,
        'active': u['active'] == 1, 'lastLoginAt': u['last_login_at'],
        'grants': jsonDecode(u['grants'] as String),
        'mfa': u['totp_secret'] != null,
        'devices': db.select('SELECT count(*) n FROM auth_devices WHERE user_id=? AND revoked_at IS NULL',
            [u['user_id']]).single['n'],
      },
  ];

  List<Json> devices({String? userId}) => [
    for (final d in db.select(
        'SELECT d.*, u.username FROM auth_devices d JOIN auth_users u USING(user_id) '
        '${userId == null ? '' : 'WHERE d.user_id=?'} ORDER BY d.last_seen_at DESC',
        [if (userId != null) userId]))
      {
        'deviceId': d['device_id'], 'userId': d['user_id'], 'username': d['username'],
        'client': d['client'], 'label': d['label'], 'enrolledAt': d['enrolled_at'],
        'lastSeenAt': d['last_seen_at'], 'revoked': d['revoked_at'] != null,
        'hasPin': d['pin_hash'] != null,
      },
  ];

  // ---------------------------------------------------------------- client
  /// Password login from a device; enrolls the device as trusted.
  Future<LoginResult> login({
    required String username,
    required String password,
    required String deviceId,
    required String client,
    String label = '',
  }) async {
    if (!localAuthClients.contains(client)) throw const LocalAuthException('client_not_allowed');
    if (!RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(deviceId)) {
      throw const LocalAuthException('invalid_device');
    }
    final rows = db.select('SELECT * FROM auth_users WHERE username=?', [username.trim()]);
    final now = _clock().toUtc();
    if (rows.isEmpty) {
      await _verify(password, 'pbkdf2-sha256\$$iterations\$AAAAAAAAAAAAAAAAAAAAAA==\$AA=='); // timing
      throw const LocalAuthException('invalid_credentials', 'Kullanıcı adı veya şifre hatalı.');
    }
    final u = rows.single;
    final lockedUntil = DateTime.tryParse('${u['locked_until'] ?? ''}');
    if (lockedUntil != null && now.isBefore(lockedUntil)) {
      throw const LocalAuthException('locked_out', 'Çok fazla hatalı deneme. 15 dakika sonra deneyin.');
    }
    if (!await _verify(password, u['password_hash'] as String)) {
      final failed = (u['failed_logins'] as int) + 1;
      db.execute('UPDATE auth_users SET failed_logins=?, locked_until=? WHERE user_id=?', [
        failed >= 5 ? 0 : failed,
        failed >= 5 ? now.add(const Duration(minutes: 15)).toIso8601String() : null,
        u['user_id']]);
      _audit('login.failed', target: u['user_id'] as String);
      throw const LocalAuthException('invalid_credentials', 'Kullanıcı adı veya şifre hatalı.');
    }
    if (u['active'] != 1) throw const LocalAuthException('inactive', 'Hesap devre dışı.');
    final userId = u['user_id'] as String;
    final existing = db.select('SELECT * FROM auth_devices WHERE device_id=?', [deviceId]);
    if (existing.isNotEmpty) {
      final d = existing.single;
      if (d['user_id'] != userId || d['client'] != client) {
        throw const LocalAuthException('device_mismatch', 'Bu cihaz başka bir hesaba bağlı.');
      }
      if (d['revoked_at'] != null) throw const LocalAuthException('device_revoked', 'Bu cihazın erişimi kaldırıldı.');
    } else {
      db.execute('INSERT INTO auth_devices(device_id,user_id,client,label,enrolled_at) VALUES(?,?,?,?,?)',
          [deviceId, userId, client, label.length > 60 ? label.substring(0, 60) : label, _now()]);
      _audit('device.enroll', actor: userId, target: deviceId, detail: {'client': client});
    }
    final token = _randomB64(32);
    db.execute('INSERT INTO auth_sessions(token_sha256,user_id,device_id,created_at,last_seen_at,expires_at) '
        'VALUES(?,?,?,?,?,?)',
        [sha256Hex(token), userId, deviceId, _now(), _now(),
          now.add(sessionLifetime).toIso8601String()]);
    db.execute('UPDATE auth_users SET failed_logins=0, locked_until=NULL, last_login_at=? WHERE user_id=?',
        [_now(), userId]);
    db.execute('UPDATE auth_devices SET last_seen_at=? WHERE device_id=?', [_now(), deviceId]);
    _audit('login', actor: userId, target: deviceId, detail: {'client': client});
    return LoginResult(token, check(token, client));
  }

  Row? _session(String token) {
    if (token.isEmpty || token.length > 100) return null;
    final r = db.select('SELECT * FROM auth_sessions WHERE token_sha256=?', [sha256Hex(token)]);
    return r.isEmpty ? null : r.single;
  }

  /// Validates a token for [client]. `touch` records activity (resets idle).
  AuthContext check(String token, String client, {bool touch = true}) {
    final sess = _session(token);
    if (sess == null) return const AuthContext(status: 'unknown');
    if (sess['revoked_at'] != null) return const AuthContext(status: 'revoked');
    final now = _clock().toUtc();
    if (!now.isBefore(DateTime.parse(sess['expires_at'] as String))) {
      return const AuthContext(status: 'expired');
    }
    final d = db.select('SELECT * FROM auth_devices WHERE device_id=?', [sess['device_id']]).single;
    if (d['revoked_at'] != null) return const AuthContext(status: 'revoked');
    if (d['client'] != client) return const AuthContext(status: 'client_mismatch');
    final u = _user(sess['user_id'] as String)!;
    if (u['active'] != 1) return const AuthContext(status: 'inactive');
    if (now.difference(DateTime.parse(sess['last_seen_at'] as String)) >= idleLock) {
      return const AuthContext(status: 'locked');
    }
    if (touch) {
      db.execute('UPDATE auth_sessions SET last_seen_at=? WHERE token_sha256=?', [_now(), sess['token_sha256']]);
      db.execute('UPDATE auth_devices SET last_seen_at=? WHERE device_id=?', [_now(), d['device_id']]);
    }
    final isOwner = u['is_owner'] == 1;
    final mfaAt = DateTime.tryParse('${sess['mfa_at'] ?? ''}');
    return AuthContext(
      status: 'ok',
      userId: u['user_id'] as String, username: u['username'] as String,
      role: u['role'] as String, employeeId: u['employee_id'] as int?,
      isOwner: isOwner, deviceId: d['device_id'] as String, client: client,
      grants: isOwner
          ? permissionCatalogue.keys.toSet()
          : (jsonDecode(u['grants'] as String) as List).cast<String>().toSet(),
      permissionVersion: u['permission_version'] as int,
      mfa: mfaAt != null && now.difference(mfaAt) < mfaWindow,
    );
  }

  /// THE local server-side check. Returns `ok` or a stable refusal code.
  String authorize(AuthContext ctx, String operation) {
    if (!ctx.ok) return ctx.status;
    final op = permissionCatalogue[operation];
    if (op == null) return 'unknown_operation';
    if (op.clients.length == 1 && op.clients.single == 'windows' && ctx.client != 'windows') {
      return 'windows_only';
    }
    if (!op.clients.contains(ctx.client)) return 'client_not_allowed';
    if (op.sensitivity == 'ownerOnly') {
      if (!ctx.isOwner) return 'forbidden';
      if (ctx.client != 'windows' && !ctx.mfa) return 'mfa_required';
      return 'ok';
    }
    return ctx.isOwner || ctx.grants.contains(operation) ? 'ok' : 'forbidden';
  }

  Future<void> setPin(String token, String client, String pin) async {
    final ctx = check(token, client);
    if (!ctx.ok) throw LocalAuthException(ctx.status);
    _checkPin(pin);
    final hash = await _hash(pin);
    db.execute('UPDATE auth_devices SET pin_hash=?, pin_failed=0 WHERE device_id=?', [hash, ctx.deviceId]);
    _audit('pin.set', actor: ctx.userId, target: ctx.deviceId);
  }

  /// Re-entry after inactivity. 5 wrong PINs clear the PIN: password needed.
  Future<AuthContext> unlockWithPin(String token, String client, String pin) async {
    final sess = _session(token);
    if (sess == null || sess['revoked_at'] != null) return const AuthContext(status: 'revoked');
    final d = db.select('SELECT * FROM auth_devices WHERE device_id=?', [sess['device_id']]).single;
    if (d['revoked_at'] != null || d['client'] != client) return const AuthContext(status: 'revoked');
    if (d['pin_hash'] == null) return const AuthContext(status: 'password_required');
    if (!await _verify(pin, d['pin_hash'] as String)) {
      final failed = (d['pin_failed'] as int) + 1;
      if (failed >= 5) {
        db.execute('UPDATE auth_devices SET pin_hash=NULL, pin_failed=0 WHERE device_id=?', [d['device_id']]);
        _audit('pin.cleared_after_failures', target: d['device_id'] as String);
        return const AuthContext(status: 'password_required');
      }
      db.execute('UPDATE auth_devices SET pin_failed=? WHERE device_id=?', [failed, d['device_id']]);
      return const AuthContext(status: 'invalid_pin');
    }
    db.execute('UPDATE auth_devices SET pin_failed=0 WHERE device_id=?', [d['device_id']]);
    db.execute('UPDATE auth_sessions SET last_seen_at=? WHERE token_sha256=?', [_now(), sess['token_sha256']]);
    return check(token, client);
  }

  /// Password re-entry on a locked session (no PIN or PIN cleared).
  /// Same protections as [login]: active account, live device for this
  /// client, and the 5-failure / 15-minute lockout with an audit entry.
  Future<AuthContext> unlockWithPassword(String token, String client, String password) async {
    final sess = _session(token);
    if (sess == null || sess['revoked_at'] != null) return const AuthContext(status: 'revoked');
    final u = _user(sess['user_id'] as String)!;
    if (u['active'] != 1) return const AuthContext(status: 'revoked');
    final d = db.select('SELECT * FROM auth_devices WHERE device_id=?', [sess['device_id']]);
    if (d.isEmpty || d.single['revoked_at'] != null || d.single['client'] != client) {
      return const AuthContext(status: 'revoked');
    }
    final now = _clock().toUtc();
    final lockedUntil = DateTime.tryParse('${u['locked_until'] ?? ''}');
    if (lockedUntil != null && now.isBefore(lockedUntil)) return const AuthContext(status: 'locked_out');
    if (!await _verify(password, u['password_hash'] as String)) {
      final failed = (u['failed_logins'] as int) + 1;
      db.execute('UPDATE auth_users SET failed_logins=?, locked_until=? WHERE user_id=?', [
        failed >= 5 ? 0 : failed,
        failed >= 5 ? now.add(const Duration(minutes: 15)).toIso8601String() : null,
        u['user_id']]);
      _audit('unlock.failed', target: u['user_id'] as String);
      return AuthContext(status: failed >= 5 ? 'locked_out' : 'invalid_credentials');
    }
    db.execute('UPDATE auth_users SET failed_logins=0, locked_until=NULL WHERE user_id=?', [u['user_id']]);
    db.execute('UPDATE auth_sessions SET last_seen_at=? WHERE token_sha256=?', [_now(), sess['token_sha256']]);
    return check(token, client);
  }

  void logout(String token) {
    final sess = _session(token);
    if (sess == null) return;
    db.execute('UPDATE auth_sessions SET revoked_at=? WHERE token_sha256=? AND revoked_at IS NULL',
        [_now(), sess['token_sha256']]);
    _audit('logout', actor: sess['user_id'] as String, target: sess['device_id'] as String);
  }

  // ---------------------------------------------------------------- TOTP
  static const _b32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  /// Starts owner MFA enrollment; returns the base32 secret for an
  /// authenticator app. Active only after [confirmTotp].
  String beginTotp(String userId) {
    final u = _user(userId) ?? (throw const LocalAuthException('unknown_user'));
    if (u['is_owner'] != 1) throw const LocalAuthException('owner_only');
    final bytes = List<int>.generate(20, (_) => _random.nextInt(256));
    var bits = 0, value = 0;
    final out = StringBuffer();
    for (final b in bytes) {
      value = (value << 8) | b;
      bits += 8;
      while (bits >= 5) {
        out.write(_b32[(value >> (bits - 5)) & 31]);
        bits -= 5;
      }
    }
    _pendingTotp[userId] = out.toString();
    return out.toString();
  }

  final Map<String, String> _pendingTotp = {};

  static List<int> _b32decode(String s) {
    var bits = 0, value = 0;
    final out = <int>[];
    for (final c in s.toUpperCase().replaceAll('=', '').split('')) {
      final i = _b32.indexOf(c);
      if (i < 0) continue;
      value = (value << 5) | i;
      bits += 5;
      if (bits >= 8) {
        out.add((value >> (bits - 8)) & 0xff);
        bits -= 8;
      }
    }
    return out;
  }

  static String totpCode(String secret, int step) {
    final msg = Uint8List(8);
    var v = step;
    for (var i = 7; i >= 0; i--) {
      msg[i] = v & 0xff;
      v >>= 8;
    }
    final h = crypto.Hmac(crypto.sha1, _b32decode(secret)).convert(msg).bytes;
    final o = h[h.length - 1] & 0x0f;
    final code = ((h[o] & 0x7f) << 24) | (h[o + 1] << 16) | (h[o + 2] << 8) | h[o + 3];
    return (code % 1000000).toString().padLeft(6, '0');
  }

  int? _matchStep(String secret, String code, int? lastStep) {
    final now = _clock().toUtc().millisecondsSinceEpoch ~/ 30000;
    for (final step in [now - 1, now, now + 1]) {
      if (lastStep != null && step <= lastStep) continue;
      if (totpCode(secret, step) == code) return step;
    }
    return null;
  }

  void confirmTotp(String userId, String code) {
    final secret = _pendingTotp[userId] ?? (throw const LocalAuthException('no_pending_mfa'));
    final step = _matchStep(secret, code, null) ?? (throw const LocalAuthException('invalid_code'));
    db.execute('UPDATE auth_users SET totp_secret=?, totp_last_step=? WHERE user_id=?', [secret, step, userId]);
    _pendingTotp.remove(userId);
    _audit('mfa.enroll', actor: userId, target: userId);
  }

  /// Marks the session MFA-verified (owner, one-time code, replay-proof).
  AuthContext verifyMfa(String token, String client, String code) {
    final ctx = check(token, client);
    if (!ctx.ok) return ctx;
    final u = _user(ctx.userId!)!;
    final secret = u['totp_secret'] as String?;
    if (u['is_owner'] != 1 || secret == null) return const AuthContext(status: 'mfa_not_enrolled');
    final step = _matchStep(secret, code, u['totp_last_step'] as int?);
    if (step == null) {
      _audit('mfa.failed', actor: ctx.userId);
      return const AuthContext(status: 'invalid_code');
    }
    db.execute('UPDATE auth_users SET totp_last_step=? WHERE user_id=?', [step, ctx.userId]);
    db.execute('UPDATE auth_sessions SET mfa_at=? WHERE token_sha256=?', [_now(), sha256Hex(token)]);
    _audit('mfa.verified', actor: ctx.userId);
    return check(token, client);
  }

  bool mfaEnrolled(String userId) => _user(userId)?['totp_secret'] != null;
}
