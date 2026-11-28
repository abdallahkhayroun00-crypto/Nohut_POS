/// Platform Yönetimi data path on Windows. One [PlatformControl] feeds both
/// the standalone page and the Ana Sayfa quick widget, so they can never
/// disagree. Until the backend provider path (#50: verified store readback,
/// durable idempotent `platform_store_status_set`, readback reconciliation)
/// is connected, [PendingPlatformControl] reports the truth: Trendyol GO
/// credentials may be present, but no verified store status exists, so
/// every toggle is disabled with the reason shown. No provider is called.
library;

import 'package:nohut_core/platform_status.dart';

import 'trendyol_go_readonly.dart';

abstract class PlatformControl {
  Future<List<PlatformCard>> load();

  /// Read-only verification (provider readback).
  Future<void> refresh(String provider);

  /// One durable, idempotent command; the result is reconciled by readback
  /// and the next [load] shows the verified outcome. Never retried blindly.
  Future<void> setStoreStatus(String provider, PlatformWorking target,
      {required PlatformWorking expected});
}

class PlatformUnavailable implements Exception {
  const PlatformUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

class PendingPlatformControl implements PlatformControl {
  PendingPlatformControl({this.tgo});
  final TrendyolGoReadonly? tgo;

  static const waitingNote =
      'Mağaza durumu bulut üzerinden doğrulanacak. Platform bağlantısı hazırlanıyor.';

  @override
  Future<List<PlatformCard>> load() async {
    final tgoReady = tgo?.credentials?.valid == true;
    return PlatformCard.completeSet([
      PlatformCard(
        provider: 'trendyol_go',
        connection: tgoReady ? PlatformConnection.connected : PlatformConnection.notConnected,
        verifiedStoreId: null,
        note: tgoReady ? waitingNote : 'Trendyol GO API bilgileri bu bilgisayarda kayıtlı değil.',
      ),
      const PlatformCard(provider: 'yemeksepeti', connection: PlatformConnection.notConnected,
          note: 'Yemeksepeti için doğrulanmış resmî entegrasyon yok.'),
      const PlatformCard(provider: 'migros_yemek', connection: PlatformConnection.notConnected,
          note: 'Migros Yemek için yetkili entegrasyon yok.'),
    ]);
  }

  @override
  Future<void> refresh(String provider) async {}

  @override
  Future<void> setStoreStatus(String provider, PlatformWorking target,
      {required PlatformWorking expected}) async =>
      throw const PlatformUnavailable(waitingNote);
}
