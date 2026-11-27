/// Verified Trendyol Go restaurant identity (spec §23.6.3). Replaces the old
/// hard-coded store fallback: a store is used for reviews only when it is
/// proven to belong to the configured supplier.
///
/// Persisted under `tgoStoreIdentity`:
/// `{supplierId, storeId, name, verifiedAt, source}`; `source` is
/// `discovery` (official store list), `selection` (owner picked one of
/// several official stores) or `orders` (discovery unavailable, exactly one
/// store in the supplier's own authorized orders).
library;

import 'pos_logic.dart';
import 'tgo_review_api.dart';

enum StoreIdentityState {
  /// Exactly one usable store; reviews may sync.
  verified,
  /// Several official stores: the owner must choose (never guessed).
  needsSelection,
  /// Saved/derived store conflicts with the official list or the orders.
  mismatch,
  /// The supplier has no store in the official list.
  noStores,
  /// Cannot verify (no credentials, discovery failed, no saved identity).
  unverified,
}

class StoreIdentityDecision {
  const StoreIdentityDecision(this.state, {
    this.storeId,
    this.name = '',
    this.source = '',
    this.candidates = const [],
    this.suggestedStoreId,
    this.warnings = const [],
    this.discoveryFailure,
  });
  final StoreIdentityState state;
  final String? storeId, suggestedStoreId;
  final String name, source;
  final List<TgoStore> candidates;
  final List<String> warnings;
  final TgoApiFailure? discoveryFailure;
  bool get usable => state == StoreIdentityState.verified && storeId != null;
}

/// Store IDs that appear in the supplier's own authorized orders.
Set<String> orderStoreIds(Iterable<Json> orders, String supplierId) => {
  for (final o in orders)
    if ('${o['supplierId'] ?? ''}' == supplierId &&
        o['testPackage'] != true &&
        RegExp(r'^[0-9]{1,20}$').hasMatch('${o['storeId'] ?? ''}'))
      '${o['storeId']}',
};

/// Pure decision. [saved] is the persisted `tgoStoreIdentity` map (or null);
/// it is ignored when it belongs to another supplier.
StoreIdentityDecision resolveStoreIdentity({
  required String supplierId,
  required TgoStoresResult discovery,
  required Set<String> ordersStores,
  Map? saved,
}) {
  final warnings = <String>[];
  final savedOk = saved != null && '${saved['supplierId'] ?? ''}' == supplierId &&
      '${saved['storeId'] ?? ''}'.isNotEmpty;
  if (saved != null && !savedOk && '${saved['storeId'] ?? ''}'.isNotEmpty) {
    warnings.add('Kayıtlı şube başka bir Satıcı ID’ye ait; yok sayıldı.');
  }
  final savedId = savedOk ? '${saved['storeId']}' : null;

  if (!discovery.ok) {
    // Official discovery unavailable: keep a previously verified identity,
    // or use the single store of the supplier's own authorized orders.
    if (savedId != null) {
      if (ordersStores.isNotEmpty && !ordersStores.contains(savedId)) {
        return StoreIdentityDecision(StoreIdentityState.mismatch,
            storeId: savedId, name: '${saved!['name'] ?? ''}',
            source: '${saved['source'] ?? ''}',
            warnings: [...warnings,
              'Kayıtlı şube ($savedId) son siparişlerdeki şubelerle '
                  '(${ordersStores.join(', ')}) eşleşmiyor.'],
            discoveryFailure: discovery.failure);
      }
      return StoreIdentityDecision(StoreIdentityState.verified,
          storeId: savedId, name: '${saved!['name'] ?? ''}',
          source: '${saved['source'] ?? ''}',
          warnings: [...warnings, 'Şube listesi şu an doğrulanamadı; '
              'önceden doğrulanmış şube kullanılıyor.'],
          discoveryFailure: discovery.failure);
    }
    if (ordersStores.length == 1) {
      return StoreIdentityDecision(StoreIdentityState.verified,
          storeId: ordersStores.single, source: 'orders',
          warnings: [...warnings, 'Şube, yetkili sipariş verisinden belirlendi.'],
          discoveryFailure: discovery.failure);
    }
    return StoreIdentityDecision(
      ordersStores.length > 1
          ? StoreIdentityState.needsSelection : StoreIdentityState.unverified,
      candidates: [for (final id in ordersStores) TgoStore(id: id, name: '')],
      warnings: warnings, discoveryFailure: discovery.failure);
  }

  final candidates = [
    for (final s in discovery.stores)
      if (s.supplierId == null || s.supplierId == supplierId) s,
  ];
  final foreign = discovery.stores.length - candidates.length;
  if (foreign > 0) {
    warnings.add('$foreign şube farklı Satıcı ID ile döndü; kullanılmadı.');
  }
  TgoStore? byId(String? id) {
    for (final s in candidates) {
      if (s.id == id) return s;
    }
    return null;
  }

  if (candidates.isEmpty) {
    return StoreIdentityDecision(StoreIdentityState.noStores, warnings: warnings);
  }
  final unknownOrderStores = ordersStores.where((id) => byId(id) == null).toList();
  if (unknownOrderStores.isNotEmpty) {
    warnings.add('Siparişlerdeki şube(ler) ${unknownOrderStores.join(', ')} '
        'resmi şube listesinde yok.');
  }
  if (savedId != null) {
    final s = byId(savedId);
    if (s != null) {
      return StoreIdentityDecision(StoreIdentityState.verified,
          storeId: s.id, name: s.name,
          source: '${saved!['source'] ?? 'discovery'}',
          candidates: candidates, warnings: warnings);
    }
    warnings.add('Kayıtlı şube ($savedId) resmi şube listesinde yok.');
  }
  if (candidates.length == 1) {
    final s = candidates.single;
    if (ordersStores.isNotEmpty && !ordersStores.contains(s.id)) {
      return StoreIdentityDecision(StoreIdentityState.mismatch,
          candidates: candidates, suggestedStoreId: s.id, warnings: warnings);
    }
    return StoreIdentityDecision(StoreIdentityState.verified,
        storeId: s.id, name: s.name, source: 'discovery',
        candidates: candidates, warnings: warnings);
  }
  final inOrders = candidates.where((s) => ordersStores.contains(s.id)).toList();
  return StoreIdentityDecision(StoreIdentityState.needsSelection,
      candidates: candidates,
      suggestedStoreId: inOrders.length == 1 ? inOrders.single.id : null,
      warnings: warnings);
}

/// Value persisted for a verified decision.
Json storeIdentityRecord(String supplierId, StoreIdentityDecision d, DateTime now) => {
  'supplierId': supplierId,
  'storeId': d.storeId,
  'name': d.name,
  'source': d.source,
  'verifiedAt': now.toUtc().toIso8601String(),
};
