/// Windows-only scoped Supabase transport. Business writes still execute
/// locally; these RPCs upload projections and exchange command envelopes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'remote_commands.dart';
import 'sync_worker.dart';
import 'windows_vault.dart';

class AgentCredentials {
  AgentCredentials({required this.url, required this.publishableKey,
    required this.token, required this.restaurantId, required this.authorityEpoch});
  final Uri url;
  final String publishableKey, token, restaurantId, authorityEpoch;

  static Future<AgentCredentials?> load(WindowsVault vault) async {
    final fields = await vault.load();
    if (fields == null) return null;
    return AgentCredentials(url: Uri.parse(fields['url'] as String),
      publishableKey: fields['publishableKey'] as String, token: fields['token'] as String,
      restaurantId: fields['restaurantId'] as String, authorityEpoch: fields['authorityEpoch'] as String);
  }

  Future<void> save(WindowsVault vault) => vault.save({
    'url': url.toString(), 'publishableKey': publishableKey, 'token': token,
    'restaurantId': restaurantId, 'authorityEpoch': authorityEpoch,
  });
}

class AgentTransportException extends SyncRejectedException {
  const AgentTransportException(super.code);
  @override
  String toString() => 'Cloud agent: $code';
}

class SupabaseAgentTransport implements SyncTransport, CommandTransport {
  SupabaseAgentTransport(this.credentials, {HttpClient? client, DateTime Function()? clock,
    this.timeout = const Duration(seconds: 20), bool allowLoopbackHttpForTests = false})
    : _client = client ?? HttpClient(), _clock = clock ?? (() => DateTime.now().toUtc()) {
    final url = credentials.url;
    final localTest = allowLoopbackHttpForTests && url.scheme == 'http' &&
        {'127.0.0.1', '::1'}.contains(url.host);
    if ((!localTest && url.scheme != 'https') || url.userInfo.isNotEmpty ||
        url.hasQuery || url.hasFragment || (url.path.isNotEmpty && url.path != '/') ||
        url.host.isEmpty || !RegExp(r'^[0-9a-f]{64}$').hasMatch(credentials.token) ||
        !_publicKey(credentials.publishableKey)) {
      throw const AgentTransportException('invalid_configuration');
    }
  }
  final AgentCredentials credentials;
  final HttpClient _client;
  final DateTime Function() _clock;
  final Duration timeout;

  static bool _publicKey(String key) {
    if (key.startsWith('sb_publishable_')) return key.length > 20;
    try {
      final parts = key.split('.');
      return parts.length == 3 &&
          (jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map)['role'] == 'anon';
    } catch (_) {
      return false;
    }
  }

  Future<Object?> _rpc(String method, Map<String, Object?> args) async {
    HttpClientRequest? request;
    try {
      return await (() async {
        request = await _client.postUrl(credentials.url.replace(path: '/rest/v1/rpc/$method'));
        request!.followRedirects = false;
        request!.headers.set('apikey', credentials.publishableKey);
        request!.headers.contentType = ContentType.json;
        request!.write(jsonEncode({'p_token': credentials.token, ...args}));
        final response = await request!.close();
        if (response.statusCode == 429 || response.statusCode >= 500) {
          await response.drain<void>();
          throw const SyncNetworkException('Cloud temporarily unavailable');
        }
        if (response.statusCode != 200) {
          await response.drain<void>();
          throw AgentTransportException(response.statusCode == 401 || response.statusCode == 403
              ? 'authentication_denied' : 'rpc_refused');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 2 * 1024 * 1024) {
            throw const AgentTransportException('response_too_large');
          }
          bytes.addAll(chunk);
        }
        return jsonDecode(utf8.decode(bytes));
      })().timeout(timeout);
    } on TimeoutException {
      request?.abort();
      throw const SyncNetworkException('Cloud request timed out');
    } on IOException {
      request?.abort();
      throw const SyncNetworkException('Cloud connection failed');
    } on FormatException {
      throw const AgentTransportException('invalid_response');
    }
  }

  @override
  Future<IngestResult> ingest(SyncTransaction tx) async {
    if (tx.authorityEpoch != credentials.authorityEpoch.replaceAll('-', '').toLowerCase()) throw const AgentTransportException('authority_mismatch');
    final result = await _rpc('nohut_agent_ingest', {'p_tx': tx.toJson()});
    if (result is! Map || result['acked_through_seq'] is! int) throw const AgentTransportException('invalid_checkpoint');
    final status = switch (result['status']) {
      'accepted' => IngestStatus.accepted, 'duplicate' => IngestStatus.duplicate,
      'conflict' => IngestStatus.conflict, 'gap' => IngestStatus.gap,
      _ => throw const AgentTransportException('invalid_ingest_status'),
    };
    return IngestResult(status, ackedThroughSeq: result['acked_through_seq'] as int);
  }

  Future<Map<String, dynamic>> checkpoint() async {
    final result = await _rpc('nohut_agent_checkpoint', {});
    if (result is! Map || result['last_acked_seq'] is! int || result['last_acked_revision'] is! int) {
      throw const AgentTransportException('invalid_checkpoint');
    }
    return Map<String, dynamic>.from(result);
  }

  @override
  Future<List<CommandClaim>> claim({required int max}) async {
    if (max < 1 || max > 20) throw ArgumentError.value(max, 'max');
    final result = await _rpc('nohut_agent_claim', {'p_max': max});
    if (result is! Map || result['claims'] is! List ||
        result['restaurant_id'] != credentials.restaurantId || result['authority_epoch'] != credentials.authorityEpoch) {
      throw const AgentTransportException('authority_mismatch');
    }
    final serverNow = DateTime.tryParse('${result['server_now']}');
    if (serverNow == null || _clock().difference(serverNow).abs() > const Duration(seconds: 5)) {
      throw const AgentTransportException('clock_skew');
    }
    return [for (final raw in result['claims'] as List) _decodeClaim(raw)];
  }

  CommandClaim _decodeClaim(Object? raw) {
    if (raw is! Map || raw['envelope'] is! Map || raw['lease_generation'] is! int || (raw['lease_generation'] as int) < 1) {
      throw const AgentTransportException('invalid_claim');
    }
    final envelope = Map<String, dynamic>.from(raw['envelope'] as Map);
    final deadline = DateTime.tryParse('${raw['lease_until']}');
    if (deadline == null || envelope['restaurant_id'] != credentials.restaurantId ||
        envelope['authority_epoch'] != credentials.authorityEpoch || envelope['schema_version'] != 1) {
      throw const AgentTransportException('invalid_claim');
    }
    // Conservative margin covers the bounded clock skew accepted above.
    return CommandClaim(envelope: envelope, generation: raw['lease_generation'] as int,
        leaseUntil: deadline.subtract(const Duration(seconds: 5)));
  }

  @override
  Future<bool> validate(CommandClaim claim) async =>
      await _rpc('nohut_agent_validate_claim', _claimArgs(claim)) == true;

  Map<String, Object?> _claimArgs(CommandClaim claim) => {
    'p_request': claim.requestId, 'p_generation': claim.generation,
    'p_envelope_sha256': envelopeSha256(claim.envelope),
  };

  void _requireAck(Object? result) {
    if (result != 'accepted' && result != 'duplicate') throw AgentTransportException('$result');
  }

  @override
  Future<void> complete(CommandClaim claim, Map<String, dynamic> result) async =>
      _requireAck(await _rpc('nohut_agent_complete', {..._claimArgs(claim), 'p_result': result}));

  @override
  Future<void> reportReceipt(String requestId, String fingerprint, Map<String, dynamic> result) async =>
      _requireAck(await _rpc('nohut_agent_report_receipt', {
        'p_request': requestId, 'p_envelope_sha256': fingerprint, 'p_result': result,
      }));

  void close() => _client.close(force: true);
}
