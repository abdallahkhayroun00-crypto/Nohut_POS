/// Nested field registry, runtime persistence validation and explicit cloud
/// field allowlist (spec V5.1 §4.4, §18.2, §19.4, §19.9; owner decision 6).
///
/// * [unregisteredFieldPaths] walks a real state and reports every field
///   path that is not declared. Tests run it on EVERY committed write
///   (`test/flutter_test_config.dart`); production will use it to fail
///   closed in the cloud projector: an undeclared field is never uploaded,
///   but local restaurant operation is never blocked by it.
/// * [cloudAllowedFieldPaths] is the explicit allowlist of what may ever
///   leave the PC. Anything not listed (personal contact data, secrets,
///   API caches, device settings) stays local. [projectForCloud] applies it.
///
/// This is the Phase 0 typed boundary. Full typed serializers per cloud
/// table (stable IDs, integer kuruş, versions) arrive with PR-04/05.
library;

part 'sync_field_paths.g.dart';

/// `integrations.menu.Trendyol Go[]` → `integrations.menu.{platform}[]`.
String normalizeFieldPath(String path) => path.replaceFirstMapped(
  RegExp(r'^integrations\.(menu|stores)\.[^.\[]+'),
  (m) => 'integrations.${m[1]}.{platform}',
);

bool _underOpaque(String path) {
  for (final root in opaqueStatePaths.keys) {
    if (path == root ||
        path.startsWith('$root.') ||
        path.startsWith('$root[')) {
      return true;
    }
  }
  return false;
}

/// Every persisted field path in [state] that is not declared in
/// [knownStateFieldPaths] (children of [opaqueStatePaths] are skipped).
List<String> unregisteredFieldPaths(Map state) {
  final unknown = <String>{};
  void walk(Object? value, String path) {
    if (value is Map) {
      for (final entry in value.entries) {
        final raw = path.isEmpty ? '${entry.key}' : '$path.${entry.key}';
        final normalized = normalizeFieldPath(raw);
        if (_underOpaque(normalized) && !opaqueStatePaths.containsKey(normalized)) {
          continue;
        }
        if (!knownStateFieldPaths.contains(normalized) &&
            !opaqueStatePaths.containsKey(normalized)) {
          unknown.add(normalized);
        }
        if (!opaqueStatePaths.containsKey(normalized)) {
          walk(entry.value, normalized);
        }
      }
    } else if (value is List) {
      for (final item in value) {
        walk(item, '$path[]');
      }
    }
  }

  walk(state, '');
  return unknown.toList()..sort();
}

/// Field paths that may be projected to the cloud. Owner decisions
/// (2026-11-27): Gel-Al personal contact details stay local for now;
/// delivery-platform customer contact data is never projected; no CRM.
/// Prefix semantics: listing `orders[].batches[].lines[].removed` allows
/// that field; a parent is never implicitly allowed by a child.
const cloudAllowedFieldPaths = <String>{
  // Orders: commercial and financial facts, no customer contact data.
  'orders', 'orders[].id', 'orders[].dailyNumber', 'orders[].numberDay',
  'orders[].source', 'orders[].table', 'orders[].pickupChannel',
  'orders[].created', 'orders[].createdAt', 'orders[].closed',
  'orders[].closedAt', 'orders[].cancelled', 'orders[].cancelledAt',
  'orders[].cancelReason', 'orders[].tableReleased', 'orders[].serviceStatus',
  'orders[].serviceStartedAt', 'orders[].readyAt', 'orders[].deliveredAt',
  // Pseudonymous link for Açık Hesaplar balances; contact data stays local.
  'orders[].customer', 'orders[].customer.id',
  'orders[].batches', 'orders[].batches[].id', 'orders[].batches[].staff',
  'orders[].batches[].staffId', 'orders[].batches[].time',
  'orders[].batches[].createdAt', 'orders[].batches[].lines',
  'orders[].batches[].lines[].productId',
  'orders[].batches[].lines[].productKey', 'orders[].batches[].lines[].name',
  'orders[].batches[].lines[].price', 'orders[].batches[].lines[].qty',
  'orders[].batches[].lines[].originalQty',
  'orders[].batches[].lines[].removed', 'orders[].batches[].lines[].note',
  'orders[].batches[].lines[].voided', 'orders[].batches[].lines[].correction',
  'orders[].batches[].lines[].campaignId',
  'orders[].batches[].lines[].basePrice',
  'orders[].batches[].lines[].adjustmentCents',
  'orders[].batches[].lines[].customItem',
  'orders[].batches[].lines[].components',
  'orders[].batches[].lines[].components[].productId',
  'orders[].batches[].lines[].components[].name',
  'orders[].batches[].lines[].components[].slot',
  'orders[].batches[].lines[].components[].qty',
  'orders[].batches[].lines[].components[].price',
  'orders[].batches[].lines[].components[].basePrice',
  'orders[].batches[].lines[].components[].removed',
  'orders[].batches[].lines[].components[].note',
  'orders[].batches[].lines[].components[].adjustmentCents',
  'orders[].payments', 'orders[].payments[].createdAt',
  'orders[].payments[].method', 'orders[].payments[].amount',
  'orders[].payments[].received', 'orders[].payments[].change',
  'orders[].payments[].time', 'orders[].payments[].by',
  'orders[].payments[].guestCheckId', 'orders[].payments[].reversed',
  'orders[].payments[].combinedPaymentId',
  'orders[].payments[].terminalReference', 'orders[].payments[].transactionId',
  'orders[].payments[].guestAllocations',
  'orders[].payments[].guestAllocations[].guestCheckId',
  'orders[].payments[].guestAllocations[].amount',
  'orders[].payments[].refunds', 'orders[].payments[].refunds[].amount',
  'orders[].payments[].refunds[].reason', 'orders[].payments[].refunds[].by',
  'orders[].payments[].refunds[].createdAt',
  'orders[].guestChecks', 'orders[].guestChecks[].id',
  'orders[].guestChecks[].name', 'orders[].guestChecks[].allocations',
  'orders[].guestChecks[].allocations[].key',
  'orders[].guestChecks[].allocations[].cents',
  'orders[].voids', 'orders[].voids[].name', 'orders[].voids[].qty',
  'orders[].voids[].price', 'orders[].voids[].reason',
  'orders[].voids[].createdAt',
  // Trendyol Go: business facts only (spec §19.4), never contact data.
  'trendyolGoOrders', 'trendyolGoOrders[].source', 'trendyolGoOrders[].orderId',
  'trendyolGoOrders[].packageId', 'trendyolGoOrders[].orderNumber',
  'trendyolGoOrders[].orderCode', 'trendyolGoOrders[].supplierId',
  'trendyolGoOrders[].storeId', 'trendyolGoOrders[].packageItemIds',
  'trendyolGoOrders[].status', 'trendyolGoOrders[].createdAt',
  'trendyolGoOrders[].modifiedAt', 'trendyolGoOrders[].totalCents',
  'trendyolGoOrders[].paymentType', 'trendyolGoOrders[].cancelReason',
  'trendyolGoOrders[].preparationMinutes', 'trendyolGoOrders[].pickup',
  'trendyolGoOrders[].testPackage', 'trendyolGoOrders[].dailyNumber',
  'trendyolGoOrders[].numberDay', 'trendyolGoOrders[].customerNote',
  'trendyolGoOrders[].deliveryType', 'trendyolGoOrders[].appName',
  'trendyolGoOrders[].lines', 'trendyolGoOrders[].lines[].name',
  'trendyolGoOrders[].lines[].qty', 'trendyolGoOrders[].lines[].unitPriceCents',
  'trendyolGoOrders[].lines[].options', 'trendyolGoOrders[].lines[].removed',
  'trendyolGoOrders[].lines[].extras',
  // Staff and money records.
  'employees', 'employees[].id', 'employees[].name', 'employees[].role',
  'employees[].active',
  'combinedPayments', 'combinedPayments[].id', 'combinedPayments[].orderIds',
  'combinedPayments[].amount', 'combinedPayments[].cash',
  'combinedPayments[].card', 'combinedPayments[].received',
  'combinedPayments[].method', 'combinedPayments[].createdAt',
  'terminalAttempts', 'terminalAttempts[].reference',
  'terminalAttempts[].orderId', 'terminalAttempts[].amountCents',
  'terminalAttempts[].status', 'terminalAttempts[].dispatched',
  'terminalAttempts[].transactionId',
  'tgoOperationAudit', 'tgoOperationAudit[].platform',
  'tgoOperationAudit[].packageId', 'tgoOperationAudit[].orderNumber',
  'tgoOperationAudit[].action', 'tgoOperationAudit[].result',
  'tgoOperationAudit[].at',
};

/// Personal contact / secret field paths that must never be allowlisted.
/// The test suite asserts the intersection with [cloudAllowedFieldPaths]
/// is empty.
const neverProjectedFieldPaths = <String>{
  'orders[].customer.name',
  'orders[].customer.phone',
  'orders[].customer.time',
  'orders[].customerLinkHistory',
  'customers',
  'customers[].name',
  'customers[].phone',
  'trendyolGoOrders[].customerName',
  'trendyolGoOrders[].customerPhone',
  'trendyolGoOrders[].customerEmail',
  'trendyolGoOrders[].deliveryAddress',
  'printJobs[].snapshot.order.customer.name',
  'printJobs[].text',
  'mobileDevices',
  'mobileDevices[].hash',
  'tgoReviewCache',
  'settings',
};

/// Deep copy of [state] keeping only [cloudAllowedFieldPaths].
Map<String, dynamic> projectForCloud(Map state) {
  Object? copy(Object? value, String path) {
    if (value is Map) {
      final out = <String, dynamic>{};
      for (final entry in value.entries) {
        final child = path.isEmpty ? '${entry.key}' : '$path.${entry.key}';
        if (cloudAllowedFieldPaths.contains(normalizeFieldPath(child))) {
          out['${entry.key}'] = copy(entry.value, normalizeFieldPath(child));
        }
      }
      return out;
    }
    if (value is List) return [for (final v in value) copy(v, '$path[]')];
    return value;
  }

  return copy(state, '') as Map<String, dynamic>;
}
