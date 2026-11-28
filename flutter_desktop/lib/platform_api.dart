/// Platform Yönetimi over the LAN: one handler shared by the native
/// Yönetici app (owner channel) and the local Yönetici web app, so phones
/// read the same [PlatformCard]s and send the same single command as the
/// Windows page and quick widget. Permission checks stay with the caller.
library;

import 'package:nohut_core/platform_status.dart';

import 'platform_management.dart';

typedef PlatformJson = Map<String, dynamic>;

PlatformWorking? _target(Object? v) => switch (v) {
  'OPEN' => PlatformWorking.open,
  'CLOSED' => PlatformWorking.closed,
  _ => null,
};

/// Read model for phones: always the three providers in order.
Future<PlatformJson> platformsView(PlatformControl control,
    {required bool canToggle, DateTime? now}) async {
  final cards = PlatformCard.completeSet(await control.load());
  final at = (now ?? DateTime.now()).toUtc();
  return {
    'ok': true,
    'checkedAt': at.toIso8601String(),
    'canToggle': canToggle,
    'cards': [
      for (final c in cards)
        {
          ...c.toJson(),
          // Decided here by the shared model, so the browser app shows the
          // same label and the same enabled/disabled reason as Windows.
          'display': {
            'name': c.displayName,
            'label': c.statusLabel(at),
            'blocked': c.toggleBlockedReason(at, granted: canToggle),
            'target': c.toggleTarget == null ? null : PlatformCard.workingWire(c.toggleTarget!),
            'verified': platformVerifiedText(c.lastVerifiedAt),
            'hours': [for (final h in c.workingHours) '${platformDayName(h.dayOfWeek)}  ${h.opening} – ${h.closing}'],
            'audit': [
              for (final a in c.audit.take(5))
                '${a.at} · ${a.actor} · ${platformStatusWord(a.oldStatus)} › ${platformStatusWord(a.newStatus)} · ${platformOutcomeWord(a.outcome)}',
            ],
          },
        },
    ],
  };
}

/// `refresh` (read-only) or `store` (one Aç/Kapat command). A refused
/// command answers `ok:false` with the reason; nothing is retried.
Future<PlatformJson> platformCommand(PlatformControl control, PlatformJson body,
    {required bool canToggle}) async {
  final provider = '${body['provider']}';
  if (!platformProviderOrder.contains(provider)) {
    throw const FormatException('Platform tanınmadı.');
  }
  try {
    switch (body['action']) {
      case 'refresh':
        await control.refresh(provider);
      case 'store':
        if (!canToggle) return {'ok': false, 'error': 'forbidden', 'message': 'Bu işlem için yetkiniz yok.'};
        final target = _target(body['target']), expected = _target(body['expected']);
        if (target == null || expected == null || target == expected || body['confirmed'] != true) {
          throw const FormatException('Onaylı Aç/Kapat isteği gerekli.');
        }
        await control.setStoreStatus(provider, target, expected: expected);
      default:
        throw const FormatException('Platform işlemi desteklenmiyor.');
    }
  } on PlatformUnavailable catch (e) {
    return {'ok': false, 'error': 'unavailable', 'message': e.message};
  }
  return {'ok': true};
}
