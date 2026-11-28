/// Windows-authoritative serializer for QR Menu cloud read projection (`qrMenuState`).
///
/// Produces the exact payload accepted by `nohut_private.apply_qr_menu_projection`
/// and returned by `public.nohut_qr_menu_view` (matching Claude's #7228113217 contract).
/// Strictly strips/blocks any credential or token keys so GitHub tokens and publisher
/// keys never leave Windows DPAPI storage.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'pos_logic.dart';

const qrDraftKey = 'qrPublisherDraft';
const qrBaseKey = 'qrPublisherDraftSourceSnapshot';
const qrRevisionKey = 'qrPublisherDraftRevision';
const qrPendingKey = 'qrPublisherPendingPublish';
const qrAuditKey = 'qrMenuAudit';

const _forbiddenSecretKeys = {
  'token',
  'githubtoken',
  'github_token',
  'publisherkey',
  'publisher_key',
  'apikey',
  'api_key',
  'secret',
  'password',
  'authorization',
  'cookie',
  'bearer',
};

/// 16-char lowercase hex fingerprint of the current QR draft, matching
/// Claude's `qrDraftStamp(draft)` in `qr_menu_remote.dart`.
String computeQrDraftStamp(Object? draft) =>
    sha256.convert(utf8.encode(jsonEncode(draft))).toString().substring(0, 16);

String? formatQrRevisionLabel(String? revision) {
  if (revision == null || revision.isEmpty) return null;
  return revision.length <= 8 ? revision : revision.substring(0, 8);
}

Json? _asMap(Object? v) => v is Map ? Map<String, dynamic>.from(v) : null;

Json _pickAllowed(Object? row, List<String> keys) {
  if (row is! Map) return <String, dynamic>{};
  final out = <String, dynamic>{};
  for (final k in keys) {
    if (row.containsKey(k) && !_forbiddenSecretKeys.contains(k.toLowerCase())) {
      out[k] = row[k];
    }
  }
  return out;
}

/// Builds the cloud-safe `qrMenuState` payload from authoritative Windows POS state.
///
/// [link] is the current local publisher status (`ready`, `no_key`, `service_down`, or null).
/// [changes] may be supplied from `diffCatalog(base, draft)` when available.
Json serializeQrMenuCloudState(
  Json state, {
  String? link,
  List<Json>? changes,
  DateTime? now,
}) {
  final calcAt = (now ?? DateTime.now()).toUtc().toIso8601String();
  final draft = _asMap(state[qrDraftKey]) ?? _asMap(state[qrBaseKey]);
  if (draft == null) {
    return {
      'available': false,
      'calculated_at': calcAt,
    };
  }
  final revision = state[qrRevisionKey]?.toString();
  final auditRaw = asMaps(state[qrAuditKey]);
  final boundedAudit = auditRaw.length > 100
      ? auditRaw.sublist(auditRaw.length - 100)
      : auditRaw;

  return {
    'available': true,
    'stamp': computeQrDraftStamp(draft),
    'revision': revision,
    'revisionLabel': formatQrRevisionLabel(revision),
    'offline': revision == null,
    'pendingPublish': state[qrPendingKey] is Map,
    if (link != null) 'link': link,
    'changes': changes ?? const <Json>[],
    'catalog': {
      'categories': [
        for (final c in asMaps(draft['categories']))
          _pickAllowed(c, ['id', 'name', 'description', 'active', 'order']),
      ],
      'products': [
        for (final p in asMaps(draft['products']))
          _pickAllowed(p, [
            'id',
            'category',
            'name',
            'displayName',
            'description',
            'price',
            'available',
            'active',
            'image',
            'order',
          ]),
      ],
      'campaigns': [
        for (final c in asMaps(draft['campaigns']))
          _pickAllowed(c, [
            'id',
            'title',
            'description',
            'price',
            'active',
            'poster',
            'thumbnail',
          ]),
      ],
    },
    'recentAudit': [
      for (final a in boundedAudit)
        _pickAllowed(a, ['at', 'actor', 'actorId', 'action', 'id', 'revision', 'outcome']),
    ],
    'calculated_at': calcAt,
  };
}
