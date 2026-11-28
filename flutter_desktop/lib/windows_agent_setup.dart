/// Consumes Claude's verified Windows owner session. Does not log in a user,
/// store a refresh token, implement PIN/MFA, or enable cloud synchronization.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as hash;

import 'order_sync_identity.dart' show newSyncUuid;
import 'supabase_agent_transport.dart';
import 'sync_worker.dart';
import 'windows_vault.dart';

abstract interface class AgentSetupSecrets {
  Future<Map<String, dynamic>?> load();
  Future<void> save(Map<String, dynamic> fields);
  Future<T> exclusively<T>(Future<T> Function() action);
}

/// Production storage always uses current-user DPAPI and a cross-process
/// lock. The lock file contains no credentials. Tests inject a synthetic store.
class WindowsAgentSecrets implements AgentSetupSecrets {
  WindowsAgentSecrets(this.vault);
  final WindowsVault vault;
  static final _held = <String>{};
  @override
  Future<Map<String, dynamic>?> load() => vault.load();
  @override
  Future<void> save(Map<String, dynamic> fields) => vault.save(fields);
  @override
  Future<T> exclusively<T>(Future<T> Function() action) async {
    if (!Platform.isWindows)
      throw const AgentTransportException('windows_required');
    final key = vault.file.absolute.path.toLowerCase();
    if (!_held.add(key)) throw const AgentTransportException('setup_busy');
    RandomAccessFile? lock;
    var locked = false;
    try {
      await vault.file.parent.create(recursive: true);
      lock = await File('${vault.file.path}.lock').open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.exclusive);
        locked = true;
      } on FileSystemException {
        throw const AgentTransportException('setup_busy');
      }
      return await action();
    } finally {
      try {
        if (locked) await lock!.unlock();
      } finally {
        try {
          await lock?.close();
        } finally {
          _held.remove(key);
        }
      }
    }
  }
}

class WindowsAgentSetup {
  WindowsAgentSetup({
    required this.url,
    required this.publishableKey,
    required this.deviceId,
    required this.restaurantId,
    required this.authorityEpoch,
    required this.accessToken,
    required this.secrets,
    bool allowLoopbackHttpForTests = false,
    HttpClient? client,
    DateTime Function()? clock,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? HttpClient(),
       _clock = clock ?? (() => DateTime.now().toUtc()) {
    final local =
        allowLoopbackHttpForTests &&
        url.scheme == 'http' &&
        {'127.0.0.1', '::1'}.contains(url.host);
    if ((!local && url.scheme != 'https') ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment ||
        url.host.isEmpty ||
        (url.path.isNotEmpty && url.path != '/') ||
        !SupabaseAgentTransport.isPublishableKey(publishableKey) ||
        !_uuid(deviceId) ||
        !_uuid(restaurantId) ||
        !_uuid(authorityEpoch))
      throw const AgentTransportException('invalid_configuration');
  }
  final Uri url;
  final String publishableKey, deviceId, restaurantId, authorityEpoch;
  final Future<String?> Function() accessToken;
  final AgentSetupSecrets secrets;
  final HttpClient _client;
  final DateTime Function() _clock;
  final Duration timeout;
  static bool _uuid(Object? v) =>
      v is String &&
      RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      ).hasMatch(v);

  Future<Map<String, dynamic>> _rpc(
    String method,
    Map<String, Object?> args,
  ) async {
    final token = await accessToken();
    if (token == null || token.isEmpty)
      throw const AgentTransportException('owner_login_required');
    HttpClientRequest? request;
    try {
      return await (() async {
        request = await _client.postUrl(
          url.replace(path: '/rest/v1/rpc/$method'),
        );
        request!.followRedirects = false;
        request!.headers
          ..set('apikey', publishableKey)
          ..set('Authorization', 'Bearer $token')
          ..contentType = ContentType.json;
        request!.write(jsonEncode(args));
        final response = await request!.close();
        if (response.statusCode == 429 || response.statusCode >= 500) {
          await response.drain<void>();
          throw const SyncNetworkException(
            'Agent setup temporarily unavailable',
          );
        }
        if (response.statusCode != 200) {
          await response.drain<void>();
          throw const AgentTransportException('owner_setup_denied');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 65536)
            throw const AgentTransportException('setup_response_invalid');
          bytes.addAll(chunk);
        }
        final body = jsonDecode(utf8.decode(bytes));
        if (body is! Map)
          throw const AgentTransportException('setup_response_invalid');
        return Map<String, dynamic>.from(body);
      })().timeout(timeout);
    } on TimeoutException {
      request?.abort();
      throw const SyncNetworkException('Agent setup timed out');
    } on IOException {
      throw const SyncNetworkException('Agent setup unavailable');
    } on FormatException {
      throw const AgentTransportException('setup_response_invalid');
    }
  }

  Future<void> _owner(int version) async {
    final ctx = await _rpc('nohut_windows_owner_session', {
      'p_device_id': deviceId,
    });
    if (ctx['status'] != 'ok' ||
        ctx['device_id'] != deviceId ||
        ctx['restaurant_id'] != restaurantId ||
        ctx['aal'] != 'aal2' ||
        ctx['permission_version'] != version ||
        !_uuid(ctx['user_id']) ||
        !_uuid(ctx['session_id']))
      throw const AgentTransportException('windows_owner_required');
  }

  /// The pending token/request is encrypted and durable BEFORE any enrollment
  /// call. A timeout or lost activation ACK retries exactly that request.
  Future<AgentCredentials> enrollOrRotate({required int permissionVersion}) =>
      secrets.exclusively(() async {
        await _owner(permissionVersion);
        final fields = await secrets.load() ?? <String, dynamic>{};
        if (fields['url'] != null &&
            (fields['url'] != url.toString() ||
                fields['restaurantId'] != restaurantId ||
                fields['authorityEpoch'] != authorityEpoch)) {
          throw const AgentTransportException(
            'authority_reconciliation_required',
          );
        }
        var pending = fields['pendingEnrollment'];
        if (pending == null) {
          final random = Random.secure();
          pending = <String, dynamic>{
            'requestId': newSyncUuid(),
            'token': List.generate(
              32,
              (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
            ).join(),
            'url': url.toString(),
            'publishableKey': publishableKey,
            'restaurantId': restaurantId,
            'authorityEpoch': authorityEpoch,
            'deviceId': deviceId,
          };
          fields['pendingEnrollment'] = pending;
          await secrets.save(fields);
        }
        if (pending is! Map ||
            !_uuid(pending['requestId']) ||
            pending['token'] is! String ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(pending['token'] as String) ||
            pending['url'] != url.toString() ||
            pending['publishableKey'] != publishableKey ||
            pending['restaurantId'] != restaurantId ||
            pending['authorityEpoch'] != authorityEpoch ||
            pending['deviceId'] != deviceId) {
          throw const AgentTransportException('pending_setup_mismatch');
        }
        final reply = await _rpc('nohut_enroll_agent', {
          'p_device_id': deviceId,
          'p_permission_version': permissionVersion,
          'p_epoch': authorityEpoch,
          'p_request_id': pending['requestId'],
          'p_token_sha256': hash.sha256
              .convert(utf8.encode(pending['token'] as String))
              .toString(),
        });
        final expiry = reply['expires_at'] is String
            ? DateTime.tryParse(reply['expires_at'] as String)
            : null;
        if (reply['status'] != 'enrolled' ||
            reply['restaurant_id'] != restaurantId ||
            reply['authority_epoch'] != authorityEpoch ||
            reply['windows_device_id'] != deviceId ||
            reply['schema_version'] != 1 ||
            !_uuid(reply['agent_id']) ||
            expiry == null ||
            !expiry.isAfter(_clock())) {
          throw const AgentTransportException('enrollment_not_confirmed');
        }
        final credentials = AgentCredentials(
          url: url,
          publishableKey: publishableKey,
          token: pending['token'] as String,
          restaurantId: restaurantId,
          authorityEpoch: authorityEpoch,
        );
        await secrets.save({
          'url': url.toString(),
          'publishableKey': publishableKey,
          'token': credentials.token,
          'restaurantId': restaurantId,
          'authorityEpoch': authorityEpoch,
          'deviceId': deviceId,
          'agentId': reply['agent_id'],
          'expiresAt': reply['expires_at'],
        });
        return credentials;
      });

  Future<void> revoke({required int permissionVersion}) =>
      secrets.exclusively(() async {
        await _owner(permissionVersion);
        final fields = await secrets.load();
        if (fields == null ||
            fields['pendingEnrollment'] != null ||
            fields['url'] != url.toString() ||
            fields['restaurantId'] != restaurantId ||
            fields['authorityEpoch'] != authorityEpoch ||
            fields['deviceId'] != deviceId ||
            !_uuid(fields['agentId']))
          throw const AgentTransportException('agent_setup_not_confirmed');
        final reply = await _rpc('nohut_revoke_agent', {
          'p_device_id': deviceId,
          'p_permission_version': permissionVersion,
          'p_agent_id': fields['agentId'],
        });
        if (reply['status'] != 'revoked' ||
            reply['agent_id'] != fields['agentId'])
          throw const AgentTransportException('revocation_not_confirmed');
        fields
          ..remove('token')
          ..['revoked'] = true;
        await secrets.save(fields);
      });

  void close() => _client.close(force: true);
}
