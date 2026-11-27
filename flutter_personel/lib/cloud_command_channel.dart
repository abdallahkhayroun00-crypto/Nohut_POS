/// Shared by the Personel and Yönetici Android entrypoints. Phase 3 supplies
/// sessions; this adapter never implements login/PIN/MFA or stores passwords.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class CloudCommandSession {
  const CloudCommandSession({required this.accessToken, required this.deviceId,
    required this.client, required this.permissionVersion});
  final String accessToken, deviceId, client;
  final int permissionVersion;
}

enum CloudCommandState { pending, confirmed, rejected, reconciliationRequired }

class CloudCommandResult {
  const CloudCommandResult(this.requestId, this.state, this.result);
  final String requestId;
  final CloudCommandState state;
  final Map<String, dynamic>? result;
}

class CloudCommandException implements Exception {
  const CloudCommandException(this.code);
  final String code;
  @override
  String toString() => 'Cloud command: $code';
}

class CloudCommandChannel {
  CloudCommandChannel({required this.url, required this.publishableKey,
    required this.session, required this.authorityAvailable, http.Client? client})
    : _client = client ?? http.Client() {
    if (!RegExp(r'^https://[a-z0-9-]+\.supabase\.co$').hasMatch(url.toString()) || !_publicKey(publishableKey)) {
      throw const CloudCommandException('invalid_configuration');
    }
  }
  final Uri url;
  final String publishableKey;
  final Future<CloudCommandSession?> Function() session;
  final bool Function() authorityAvailable;
  final http.Client _client;

  static bool _publicKey(String value) {
    if (value.startsWith('sb_publishable_')) return value.length > 20;
    try {
      final parts = value.split('.');
      return parts.length == 3 && (jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map)['role'] == 'anon';
    } catch (_) { return false; }
  }

  Future<Map<String, dynamic>> _rpc(String name, Map<String, Object?> args) async {
    final current = await session();
    if (current == null || !{'personel','yonetici'}.contains(current.client)) {
      throw const CloudCommandException('session_required');
    }
    final request = http.Request('POST', url.replace(path: '/rest/v1/rpc/$name'))
      ..followRedirects = false
      ..headers.addAll({'apikey': publishableKey, 'Authorization': 'Bearer ${current.accessToken}', 'Content-Type': 'application/json'})
      ..body = jsonEncode({'p_device_id': current.deviceId, 'p_client': current.client,
        'p_permission_version': current.permissionVersion, ...args});
    final response = await _client.send(request).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw CloudCommandException(response.statusCode == 401 || response.statusCode == 403
          ? 'authorization_denied' : response.statusCode == 400 ? 'invalid_request' : 'unavailable');
    }
    final bytes = <int>[];
    await for (final part in response.stream.timeout(const Duration(seconds: 15))) {
      if (bytes.length + part.length > 256 * 1024) throw const CloudCommandException('invalid_response');
      bytes.addAll(part);
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) throw const CloudCommandException('invalid_response');
    return Map<String, dynamic>.from(decoded);
  }

  /// The caller retains this UUID on retries. Enqueue never means executed.
  Future<CloudCommandResult> enqueue(String requestId, String action, Map<String, dynamic> payload) async {
    if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(requestId)) throw const CloudCommandException('invalid_request_id');
    if (!authorityAvailable()) throw const CloudCommandException('windows_offline');
    try {
      final result = await _rpc('nohut_enqueue_command', {
        'p_request_id': requestId, 'p_action': action, 'p_payload': payload,
      });
      if (result['status'] == 'conflict') return CloudCommandResult(requestId, CloudCommandState.rejected, null);
      if (!{'accepted','duplicate'}.contains(result['status'])) throw const CloudCommandException('invalid_response');
      return CloudCommandResult(requestId, CloudCommandState.pending, null);
    } on CloudCommandException catch (e) {
      if ({'authorization_denied','invalid_request','session_required'}.contains(e.code)) rethrow;
      // The response may be lost after enqueue committed. Query this UUID;
      // never generate a replacement or claim authoritative success.
      return CloudCommandResult(requestId, CloudCommandState.pending, null);
    } on TimeoutException {
      return CloudCommandResult(requestId, CloudCommandState.pending, null);
    } on http.ClientException {
      return CloudCommandResult(requestId, CloudCommandState.pending, null);
    }
  }

  Future<CloudCommandResult> status(String requestId) async {
    final result = await _rpc('nohut_command_status', {'p_request_id': requestId});
    final state = switch (result['state']) {
      'confirmed' => CloudCommandState.confirmed,
      'pending' || 'processing' => CloudCommandState.pending,
      'reconciliation_required' => CloudCommandState.reconciliationRequired,
      'conflict' || 'rejected' || 'expired' => CloudCommandState.rejected,
      _ => throw const CloudCommandException('invalid_response'),
    };
    return CloudCommandResult(requestId, state, result['result'] is Map
        ? Map<String, dynamic>.from(result['result'] as Map) : null);
  }

  void close() => _client.close();
}
