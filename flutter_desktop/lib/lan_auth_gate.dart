/// LAN authentication gate for the local browser apps served by the Windows
/// POS (spec §23.4, task L1). Pure Dart over [LocalAuth] so it is testable
/// without sockets; `lan_server.dart` only moves bytes.
///
/// * Session token travels in an HttpOnly, SameSite=Strict cookie (never in
///   JS-readable storage). Plain HTTP on the restaurant LAN only; the token
///   is local, short of the cloud, and never a Supabase refresh token.
/// * Background polling does not count as activity, so the 30-minute idle
///   lock works; the page reports real taps via `/api/auth/activity`.
/// * Until the owner enables "Bireysel giriş zorunlu" the legacy shared
///   panel keeps working (existing phones are not locked out); a signed-in
///   session is still used to stamp the acting employee.
library;

import 'local_accounts.dart';
import 'pos_logic.dart';

class GateReply {
  const GateReply(this.status, this.body, {this.setToken, this.clearToken = false});
  final int status;
  final Json body;
  final String? setToken;
  final bool clearToken;
}

class GateDecision {
  const GateDecision.allow(this.context) : status = 200, error = null;
  const GateDecision.deny(this.status, this.error) : context = null;
  final int status;
  final String? error;
  /// Signed-in session, when there is one (also in legacy mode).
  final AuthContext? context;
  bool get allowed => status == 200;
}

class LanAuthGate {
  LanAuthGate(this.auth, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final LocalAuth auth;
  final DateTime Function() _clock;

  static const cookieName = 'nohut_lan';
  static const lanClients = {'personel', 'yonetici'};
  static const maxFailuresPerIp = 10;
  static const failureWindow = Duration(minutes: 10);
  final Map<String, List<DateTime>> _failures = {};

  bool get required => auth.lanLoginRequired;

  /// Session token from the cookie header (preferred) or `Authorization:
  /// Bearer lan.<token>` (scripts/tests). Mobile pairing tokens never match.
  static String? tokenFrom({String? cookie, String? authorization}) {
    for (final part in (cookie ?? '').split(';')) {
      final kv = part.trim();
      if (kv.startsWith('$cookieName=')) {
        final v = kv.substring(cookieName.length + 1);
        if (v.isNotEmpty) return v;
      }
    }
    final a = authorization ?? '';
    if (a.startsWith('Bearer lan.')) return a.substring('Bearer lan.'.length);
    return null;
  }

  static String cookieHeader(String token, {Duration maxAge = const Duration(days: 30)}) =>
      '$cookieName=$token; Path=/; HttpOnly; SameSite=Strict; Max-Age=${maxAge.inSeconds}';
  static String get clearCookieHeader =>
      '$cookieName=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0';

  bool _throttled(String ip) {
    final now = _clock();
    final list = _failures[ip]
      ?..removeWhere((t) => now.difference(t) >= failureWindow);
    return (list?.length ?? 0) >= maxFailuresPerIp;
  }

  void _fail(String ip) => (_failures[ip] ??= []).add(_clock());

  /// Operation required by a staff phone action (server-side, never trusted
  /// from the client). Unknown actions map to `orders.edit`.
  static String operationForAction(Json payload) => switch ('${payload['action']}') {
    'printProductPayment' => 'receipts.print',
    'move' => 'orders.move',
    'pay' || 'payProducts' || 'payMixed' => 'payments.take',
    'close' => 'orders.release',
    _ => 'orders.edit',
  };

  /// Checks a request for [operation]. `touch` = counts as user activity.
  GateDecision guard({
    required String? token,
    required String client,
    required String operation,
    bool touch = true,
    bool forceRequired = false,
  }) {
    final ctx = token == null ? null : auth.check(token, client, touch: touch);
    if (!required && !forceRequired) {
      // Legacy shared panel: allowed; an ok session still identifies the user.
      if (ctx != null && ctx.ok && auth.authorize(ctx, operation) != 'ok') {
        return const GateDecision.deny(403, 'forbidden');
      }
      return GateDecision.allow(ctx != null && ctx.ok ? ctx : null);
    }
    if (ctx == null) return const GateDecision.deny(401, 'auth_required');
    if (!ctx.ok) return GateDecision.deny(401, ctx.status);
    final verdict = auth.authorize(ctx, operation);
    if (verdict != 'ok') return GateDecision.deny(403, verdict);
    return GateDecision.allow(ctx);
  }

  /// The acting employee is the signed-in user, not what the phone claims.
  /// A signed-in account that is not linked to an employee can never act
  /// as one: the phone's `staffId` is ignored, never trusted.
  static Json withIdentity(Json payload, AuthContext? ctx) {
    if (ctx == null) return payload;
    if (ctx.employeeId == null) {
      throw const FormatException(
          'Hesabınız bir personele bağlı değil. Windows › Kullanıcılar’dan bağlayın.');
    }
    return {...payload, 'staffId': ctx.employeeId};
  }

  Json _session(String? token, String client) {
    final ctx = token == null ? null : auth.check(token, client, touch: false);
    return {
      'required': required,
      'configured': auth.hasUsers,
      'idleLockMinutes': auth.idleLock.inMinutes,
      'session': ctx?.toJson() ?? const {'status': 'none'},
    };
  }

  static String _client(Json body) {
    final c = '${body['client'] ?? 'personel'}';
    if (!lanClients.contains(c)) throw const LocalAuthException('client_not_allowed');
    return c;
  }

  /// Handles `/api/auth/*`. [path] is the part after `/api/auth/`.
  Future<GateReply> handle(String method, String path, Json body,
      {String? token, required String ip}) async {
    try {
      if (method == 'GET' && path == 'session') {
        final c = lanClients.contains('${body['client']}') ? '${body['client']}' : 'personel';
        return GateReply(200, _session(token, c));
      }
      if (method != 'POST') return const GateReply(405, {'error': 'method_not_allowed'});
      final client = _client(body);
      switch (path) {
        case 'login':
          if (_throttled(ip)) {
            return const GateReply(429, {'error': 'too_many_attempts',
              'message': 'Çok fazla hatalı deneme. Biraz sonra tekrar deneyin.'});
          }
          try {
            final r = await auth.login(
              username: '${body['username'] ?? ''}',
              password: '${body['password'] ?? ''}',
              deviceId: '${body['deviceId'] ?? ''}',
              client: client,
              label: '${body['label'] ?? ''}',
            );
            if (token != null && token != r.token) auth.logout(token);
            return GateReply(200, {'session': r.context.toJson()}, setToken: r.token);
          } on LocalAuthException catch (e) {
            if (e.code == 'invalid_credentials') _fail(ip);
            rethrow;
          }
        case 'unlock':
          if (token == null) return const GateReply(401, {'error': 'auth_required'});
          if (_throttled(ip)) return const GateReply(429, {'error': 'too_many_attempts'});
          final ctx = body['pin'] != null
              ? await auth.unlockWithPin(token, client, '${body['pin']}')
              : await auth.unlockWithPassword(token, client, '${body['password'] ?? ''}');
          if (!ctx.ok) {
            if (ctx.status.startsWith('invalid')) _fail(ip);
            final revoked = ctx.status == 'revoked';
            return GateReply(revoked ? 401 : 403, {'error': ctx.status}, clearToken: revoked);
          }
          return GateReply(200, {'session': ctx.toJson()});
        case 'pin':
          if (token == null) return const GateReply(401, {'error': 'auth_required'});
          if (body['password'] != null && _throttled(ip)) return const GateReply(429, {'error': 'too_many_attempts'});
          try {
            await auth.setPin(token, client, '${body['pin'] ?? ''}',
                password: body['password'] == null ? null : '${body['password']}');
          } on LocalAuthException catch (e) {
            if (e.code == 'invalid_credentials') _fail(ip);
            // A wrong password while changing the PIN keeps the session:
            // 403, so the page stays on the PIN form instead of signing out.
            if (e.code == 'invalid_credentials' || e.code == 'locked_out') {
              return GateReply(403, {'error': e.code});
            }
            rethrow;
          }
          return const GateReply(200, {'ok': true});
        case 'mfa':
          if (token == null) return const GateReply(401, {'error': 'auth_required'});
          if (_throttled(ip)) return const GateReply(429, {'error': 'too_many_attempts'});
          final ctx = auth.verifyMfa(token, client, '${body['code'] ?? ''}');
          if (!ctx.ok) {
            if (ctx.status == 'invalid_code') _fail(ip);
            return GateReply(ctx.status == 'invalid_code' || ctx.status == 'mfa_not_enrolled' ? 403 : 401,
                {'error': ctx.status});
          }
          return GateReply(200, {'session': ctx.toJson()});
        case 'activity':
          if (token == null) return const GateReply(401, {'error': 'auth_required'});
          final ctx = auth.check(token, client);
          return GateReply(ctx.ok ? 200 : 401, {'session': ctx.toJson()});
        case 'logout':
          if (token != null) auth.logout(token);
          return const GateReply(200, {'ok': true}, clearToken: true);
      }
      return const GateReply(404, {'error': 'not_found'});
    } on LocalAuthException catch (e) {
      final status = switch (e.code) {
        'invalid_credentials' || 'locked_out' || 'inactive' || 'device_revoked' => 401,
        'unknown' || 'revoked' || 'expired' || 'locked' => 401,
        _ => 403,
      };
      return GateReply(status, {'error': e.code, if (e.message.isNotEmpty) 'message': e.message});
    }
  }
}
