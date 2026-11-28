/// Windows client for `cloud-capabilities` (#46 contract v1). Reports which
/// secrets already live in Supabase Edge secrets, so a new PC does not ask
/// for the GitHub App `.pem` or provider API keys that are held in the cloud.
///
/// Fail-closed: anything but a strict `200` v1 answer means "all false", and
/// the existing local (DPAPI) prompts stay exactly as they were. No secret
/// material is ever read or sent; only the agent token header is.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'supabase_agent_transport.dart';

enum CloudProvider { trendyolGo, yemeksepeti, migrosYemek, uberEats }

class CloudCapabilities {
  const CloudCapabilities({this.qrPublish = false, this.providers = const {}});
  static const none = CloudCapabilities();

  final bool qrPublish;
  final Set<CloudProvider> providers;

  bool has(CloudProvider p) => providers.contains(p);

  static const _names = {
    'trendyol_go': CloudProvider.trendyolGo,
    'yemeksepeti': CloudProvider.yemeksepeti,
    'migros_yemek': CloudProvider.migrosYemek,
    'uber_eats': CloudProvider.uberEats,
  };

  /// Strict parse of the v1 body; anything else is [none].
  static CloudCapabilities parse(Object? json) {
    if (json is! Map || json['version'] != 1 || json['qrPublish'] is! bool ||
        json['providers'] is! Map) {
      return none;
    }
    final raw = json['providers'] as Map;
    final on = <CloudProvider>{};
    for (final e in raw.entries) {
      final p = _names[e.key];
      if (p == null || e.value is! bool) return none;
      if (e.value == true) on.add(p);
    }
    return CloudCapabilities(qrPublish: json['qrPublish'] as bool, providers: on);
  }
}

typedef CapabilitiesFetch = Future<({int status, String body})> Function(
    Uri url, Map<String, String> headers);

Future<({int status, String body})> _get(Uri url, Map<String, String> headers) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.getUrl(url).timeout(const Duration(seconds: 10));
    req.followRedirects = false;
    headers.forEach(req.headers.set);
    final res = await req.close().timeout(const Duration(seconds: 10));
    final bytes = <int>[];
    await for (final c in res.timeout(const Duration(seconds: 10))) {
      bytes.addAll(c);
      if (bytes.length > 4096) throw const HttpException('too large');
    }
    return (status: res.statusCode, body: utf8.decode(bytes));
  } finally {
    client.close(force: true);
  }
}

class CloudCapabilitiesSource {
  CloudCapabilitiesSource({required this.credentials, CapabilitiesFetch? fetch,
      DateTime Function()? clock})
      : _fetch = fetch ?? _get, _clock = clock ?? DateTime.now;

  /// Null when this PC has no cloud agent yet.
  final Future<AgentCredentials?> Function() credentials;
  final CapabilitiesFetch _fetch;
  final DateTime Function() _clock;
  CloudCapabilities? _cached;
  DateTime? _at;
  Future<CloudCapabilities>? _inflight;

  Future<CloudCapabilities> load({bool force = false}) {
    final at = _at;
    if (!force && _cached != null && at != null &&
        _clock().difference(at) < const Duration(minutes: 2)) {
      return Future.value(_cached);
    }
    return _inflight ??= _read().whenComplete(() => _inflight = null);
  }

  Future<CloudCapabilities> _read() async {
    CloudCapabilities result = CloudCapabilities.none;
    try {
      final c = await credentials();
      if (c != null && c.url.scheme == 'https' &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(c.token)) {
        final res = await _fetch(
          c.url.replace(path: '/functions/v1/cloud-capabilities'),
          {'x-nohut-agent-token': c.token, 'apikey': c.publishableKey,
           'accept': 'application/json'});
        if (res.status == 200) result = CloudCapabilities.parse(jsonDecode(res.body));
      }
    } catch (_) {
      result = CloudCapabilities.none;
    }
    _cached = result;
    _at = _clock();
    return result;
  }
}

/// Shows [child] (the local credential prompt) unless the cloud already
/// holds that secret, in which case a short status card replaces it.
class CloudManaged extends StatelessWidget {
  const CloudManaged({super.key, required this.source, required this.title,
      required this.isManaged, required this.child});
  final CloudCapabilitiesSource? source;
  final String title;
  final bool Function(CloudCapabilities) isManaged;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final s = source;
    if (s == null) return child;
    return FutureBuilder<CloudCapabilities>(
      future: s.load(),
      builder: (context, snap) {
        final caps = snap.data ?? CloudCapabilities.none;
        if (!isManaged(caps)) return child;
        return Card(
          key: ValueKey('cloud-managed-$title'),
          child: ListTile(
            leading: const Icon(Icons.cloud_done_outlined),
            title: Text(title),
            subtitle: const Text('Bulutta güvenle saklanıyor. Bu bilgisayarda '
                'anahtar veya API bilgisi girmeniz gerekmez.'),
          ),
        );
      },
    );
  }
}
