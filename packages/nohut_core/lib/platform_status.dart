/// Platform Yönetimi read model (agreed on #51, 7236337904 / 7236393410),
/// shared by Windows, Android and the LAN/PWA clients so every surface —
/// the standalone page and the Ana Sayfa quick widget — derives the same
/// label and the same enabled/disabled decision from the same card.
///
/// Honesty rules: a provider without a verified, fresh readback is
/// `Bilinmiyor`; an unconnected provider is `Entegrasyon bekleniyor`; a
/// pending or uncertain command blocks further toggles until reconciled.
/// Nothing here mutates anything.
library;

const platformProviderOrder = ['trendyol_go', 'yemeksepeti', 'migros_yemek'];

const platformDisplayNames = {
  'trendyol_go': 'Trendyol GO',
  'yemeksepeti': 'Yemeksepeti',
  'migros_yemek': 'Migros Yemek',
};

/// A readback older than this is shown as unknown and cannot be toggled.
const platformStatusFreshFor = Duration(minutes: 10);

enum PlatformConnection { connected, notConnected, disabled }

enum PlatformWorking { open, closed, unknown }

class PlatformPending {
  const PlatformPending(this.requestId, this.target, this.outcome);
  final String requestId;
  final PlatformWorking target;

  /// `pending` (sent, waiting) or `unknown` (lost answer; reconcile only).
  final String outcome;
}

class PlatformAuditEntry {
  const PlatformAuditEntry({required this.at, required this.actor, required this.action,
      this.oldStatus, this.newStatus, required this.outcome});
  final String at, actor, action, outcome;
  final String? oldStatus, newStatus;
}

class PlatformHours {
  const PlatformHours(this.dayOfWeek, this.opening, this.closing);
  final String dayOfWeek, opening, closing;
}

class PlatformCard {
  const PlatformCard({
    required this.provider,
    required this.connection,
    this.working = PlatformWorking.unknown,
    this.verifiedStoreId,
    this.verifiedStoreName,
    this.lastVerifiedAt,
    this.scheduleState = 'unknown',
    this.workingHours = const [],
    this.pending,
    this.audit = const [],
    this.canToggleStore = false,
    this.canEditHours = false,
    this.canToggleCatalog = false,
    this.note,
  });

  final String provider;
  final PlatformConnection connection;
  final PlatformWorking working;
  final String? verifiedStoreId, verifiedStoreName, note;
  final DateTime? lastVerifiedAt;
  final String scheduleState;
  final List<PlatformHours> workingHours;
  final PlatformPending? pending;
  final List<PlatformAuditEntry> audit;

  /// Provider capabilities (what the integration supports), not grants.
  final bool canToggleStore, canEditHours, canToggleCatalog;

  String get displayName => platformDisplayNames[provider] ?? provider;

  bool isStale(DateTime now) =>
      lastVerifiedAt == null || now.difference(lastVerifiedAt!) > platformStatusFreshFor;

  /// The status every surface shows.
  String statusLabel(DateTime now) {
    if (connection != PlatformConnection.connected) return 'Entegrasyon bekleniyor';
    if (pending != null) return pending!.outcome == 'unknown' ? 'Doğrulanıyor' : 'İşleniyor';
    if (working == PlatformWorking.unknown || isStale(now)) return 'Bilinmiyor';
    return working == PlatformWorking.open ? 'Açık' : 'Kapalı';
  }

  /// The one action offered: close an open store, open a closed one.
  PlatformWorking? get toggleTarget => switch (working) {
    PlatformWorking.open => PlatformWorking.closed,
    PlatformWorking.closed => PlatformWorking.open,
    PlatformWorking.unknown => null,
  };

  /// Null when the toggle may be offered; otherwise the reason shown.
  String? toggleBlockedReason(DateTime now, {required bool granted}) {
    if (!granted) return 'Bu işlem için yetkiniz yok.';
    if (connection != PlatformConnection.connected) {
      return note ?? 'Bu platformun resmî entegrasyonu henüz bağlı değil.';
    }
    if (!canToggleStore) return note ?? 'Bu platformda Aç/Kapat henüz desteklenmiyor.';
    if (pending != null) return 'Önceki istek doğrulanıyor.';
    if (working == PlatformWorking.unknown || isStale(now)) {
      return 'Güncel durum doğrulanmadı. Önce Yenile.';
    }
    return null;
  }

  static PlatformWorking _working(Object? v) => switch (v) {
    'OPEN' => PlatformWorking.open,
    'CLOSED' => PlatformWorking.closed,
    _ => PlatformWorking.unknown,
  };

  static String workingWire(PlatformWorking w) => switch (w) {
    PlatformWorking.open => 'OPEN',
    PlatformWorking.closed => 'CLOSED',
    PlatformWorking.unknown => 'UNKNOWN',
  };

  /// From the backend read model; unknown shapes degrade to "unknown".
  factory PlatformCard.fromJson(Map json) {
    final caps = json['capabilities'] is Map ? json['capabilities'] as Map : const {};
    final pending = json['pendingMutation'] is Map ? json['pendingMutation'] as Map : null;
    return PlatformCard(
      provider: '${json['provider']}',
      connection: switch (json['connectionState']) {
        'connected' => PlatformConnection.connected,
        'disabled' => PlatformConnection.disabled,
        _ => PlatformConnection.notConnected,
      },
      working: _working(json['workingStatus']),
      verifiedStoreId: json['verifiedStoreId'] as String?,
      verifiedStoreName: json['verifiedStoreName'] as String?,
      lastVerifiedAt: DateTime.tryParse('${json['lastVerifiedAt'] ?? ''}')?.toUtc(),
      scheduleState: '${json['scheduleState'] ?? 'unknown'}',
      workingHours: [
        for (final h in (json['workingHours'] is List ? json['workingHours'] as List : const []))
          if (h is Map) PlatformHours('${h['dayOfWeek']}', '${h['openingTime'] ?? h['opening']}',
              '${h['closingTime'] ?? h['closing']}'),
      ],
      pending: pending == null ? null : PlatformPending('${pending['requestId']}',
          _working(pending['targetStatus']), '${pending['outcome']}'),
      audit: [
        for (final a in (json['auditHistory'] is List ? json['auditHistory'] as List : const []))
          if (a is Map) PlatformAuditEntry(at: '${a['at']}', actor: '${a['actor'] ?? ''}',
              action: '${a['action']}', oldStatus: a['oldStatus'] as String?,
              newStatus: a['newStatus'] as String?, outcome: '${a['outcome']}'),
      ],
      canToggleStore: caps['toggleStore'] == true,
      canEditHours: caps['editHours'] == true,
      canToggleCatalog: caps['toggleCatalog'] == true,
      note: json['note'] as String?,
    );
  }

  static String _connectionWire(PlatformConnection c) => switch (c) {
    PlatformConnection.connected => 'connected',
    PlatformConnection.disabled => 'disabled',
    PlatformConnection.notConnected => 'not_connected',
  };

  /// The same shape [fromJson] reads, so Windows can serve its cards to the
  /// LAN/phone clients and they rebuild the identical card.
  Map<String, Object?> toJson() => {
    'provider': provider,
    'connectionState': _connectionWire(connection),
    'workingStatus': workingWire(working),
    'verifiedStoreId': verifiedStoreId,
    'verifiedStoreName': verifiedStoreName,
    'lastVerifiedAt': lastVerifiedAt?.toUtc().toIso8601String(),
    'scheduleState': scheduleState,
    'workingHours': [
      for (final h in workingHours)
        {'dayOfWeek': h.dayOfWeek, 'openingTime': h.opening, 'closingTime': h.closing},
    ],
    'pendingMutation': pending == null ? null : {
      'requestId': pending!.requestId,
      'targetStatus': workingWire(pending!.target),
      'outcome': pending!.outcome,
    },
    'auditHistory': [
      for (final a in audit)
        {'at': a.at, 'actor': a.actor, 'action': a.action, 'oldStatus': a.oldStatus,
          'newStatus': a.newStatus, 'outcome': a.outcome},
    ],
    'capabilities': {
      'toggleStore': canToggleStore, 'editHours': canEditHours, 'toggleCatalog': canToggleCatalog,
    },
    'note': note,
  };

  /// Always three cards in the fixed order; missing providers are shown
  /// as not connected rather than hidden.
  static List<PlatformCard> completeSet(Iterable<PlatformCard> known) {
    final byId = {for (final c in known) c.provider: c};
    return [
      for (final id in platformProviderOrder)
        byId[id] ?? PlatformCard(provider: id, connection: PlatformConnection.notConnected),
    ];
  }
}

const _days = {
  'MONDAY': 'Pazartesi', 'TUESDAY': 'Salı', 'WEDNESDAY': 'Çarşamba', 'THURSDAY': 'Perşembe',
  'FRIDAY': 'Cuma', 'SATURDAY': 'Cumartesi', 'SUNDAY': 'Pazar',
};

String platformDayName(String wire) => _days[wire.toUpperCase()] ?? wire;

/// Audit wording shared by every surface.
String platformStatusWord(String? s) => switch (s) { 'OPEN' => 'Açık', 'CLOSED' => 'Kapalı', _ => '?' };

String platformOutcomeWord(String s) => switch (s) {
  'confirmed' => 'doğrulandı', 'unknown' => 'belirsiz, doğrulanıyor', 'failed' => 'başarısız',
  'rejected' => 'reddedildi', 'pending' => 'bekliyor', _ => s,
};

String platformVerifiedText(DateTime? t) {
  if (t == null) return 'Hiç doğrulanmadı';
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return 'Son doğrulama ${two(l.day)}.${two(l.month)} ${two(l.hour)}:${two(l.minute)}';
}
