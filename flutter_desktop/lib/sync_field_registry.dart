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

/// `integrations.menu.Trendyol Go[]` → `integrations.menu.{platform}[]`;
/// an archived (soft-deleted) order and its related rows follow exactly the
/// same field rules as live ones: `deletedOrders[].order.x` → `orders[].x`,
/// `deletedOrders[].related.printJobs[].x` → `printJobs[].x`.
String normalizeFieldPath(String path) => path
    .replaceFirst(RegExp(r'^internalMenu(?=\[|$)'), 'localMenu')
    .replaceFirstMapped(
      RegExp(r'^integrations\.(menu|stores)\.[^.\[]+'),
      (m) => 'integrations.${m[1]}.{platform}',
    )
    .replaceFirst(RegExp(r'^deletedOrders\[\]\.order(?=\.|$)'), 'orders[]')
    .replaceFirstMapped(
      RegExp(r'^deletedOrders\[\]\.related\.(printJobs|staffNotices|terminalAttempts)(?=\[|$)'),
      (m) => m[1]!,
    )
    .replaceFirst(RegExp(r'^orders\[\]\.lineEdits\[\]\.before(?=\.|$)'), 'orders[].batches[].lines[]');

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
  'cashBook','cashBook.sessions','cashBook.sessions[].id','cashBook.sessions[].openedAt','cashBook.sessions[].openedBy',
  'cashBook.sessions[].openingCents','cashBook.sessions[].closedAt','cashBook.sessions[].closedBy',
  'cashBook.sessions[].countedCents','cashBook.sessions[].expectedCents','cashBook.sessions[].differenceCents',
  'cashBook.movements','cashBook.movements[].syncId','cashBook.movements[].sessionId','cashBook.movements[].cents',
  'cashBook.movements[].note','cashBook.movements[].at','cashBook.movements[].by',
  'terminalAttempts[].syncHistory','terminalAttempts[].syncHistory[].id','terminalAttempts[].syncHistory[].ordinal',
  'terminalAttempts[].syncHistory[].observedAt','terminalAttempts[].syncHistory[].origin','terminalAttempts[].syncHistory[].status',
  'terminalAttempts[].syncHistory[].dispatched','terminalAttempts[].syncHistory[].transactionId',
  'terminalAttempts[].syncHistory[].amountCents','terminalAttempts[].syncHistory[].orderId',
  'trendyolGoOrders[].totalKnown','trendyolGoOrders[].lineFacts',
  'trendyolGoOrders[].lineFacts[].name','trendyolGoOrders[].lineFacts[].qty',
  'trendyolGoOrders[].lineFacts[].unitPriceCents','trendyolGoOrders[].lineFacts[].options',
  'trendyolGoOrders[].lineFacts[].removed','trendyolGoOrders[].lineFacts[].extras',
  'trendyolGoOrders[].lineFacts[].originalQty','trendyolGoOrders[].lineFacts[].quantityKnown',
  'trendyolGoOrders[].lineFacts[].unitPriceKnown','trendyolGoOrders[].lineFacts[].itemIds',
  'trendyolGoOrders[].lineFacts[].cancelledItemIds',
  'trendyolGoOrders[].kitchenPrintState','trendyolGoOrders[].kitchenQueuedAt',
  'trendyolGoOrders[].pickupEtaState','trendyolGoOrders[].deliveryEta',
  'trendyolGoOrders[].courierNearby','trendyolGoOrders[].courierEtaFrom','trendyolGoOrders[].courierEtaTo',
  'printJobs','printJobs[].syncId','printJobs[].orderId','printJobs[].batchId','printJobs[].kind',
  'printJobs[].state','printJobs[].attempts','printJobs[].createdAt','printJobs[].spooledAt',
  'printJobs[].receiptRequestId','printJobs[].syncReceipt','printJobs[].syncReceipt.schemaVersion',
  'printJobs[].syncReceipt.sourceFormat','printJobs[].syncReceipt.body','printJobs[].syncReceipt.privacy',
  'printJobs[].syncPrintHistory','printJobs[].syncPrintHistory[].id','printJobs[].syncPrintHistory[].ordinal',
  'printJobs[].syncPrintHistory[].observedAt','printJobs[].syncPrintHistory[].origin',
  'printJobs[].syncPrintHistory[].state','printJobs[].syncPrintHistory[].attempts','printJobs[].syncPrintHistory[].spooledAt',
  'orders[].platformCollection', 'orders[].payments[].staffId', 'orders[].payments[].productPaymentId',
  'orders[].lineEdits', 'orders[].lineEdits[].syncId', 'orders[].lineEdits[].at',
  'orders[].lineEdits[].by', 'orders[].lineEdits[].key', 'orders[].batches[].lines[]',
  'orders[].batches[].lines[].syncId', 'orders[].batches[].lines[].syncOriginalQty',
  'orders[].payments[].syncId', 'orders[].payments[].refunds[].syncId',
  'orders[].payments[].guestAllocations[].syncId', 'orders[].guestChecks[].syncId',
  'orders[].guestChecks[].allocations[].syncId', 'orders[].voids[].syncId',
  // Existing published catalog and cashier-only custom products. This is
  // replication only; unpublished QR drafts and publisher state stay local.
  'localMenu', 'localMenu[].id', 'localMenu[].qrStableId', 'localMenu[].name',
  'localMenu[].price', 'localMenu[].category', 'localMenu[].active', 'localMenu[].available',
  'localMenu[].names', 'localMenu[].names.tr', 'localMenu[].names.en', 'localMenu[].names.ar',
  'localMenu[].displayName', 'localMenu[].displayName.tr', 'localMenu[].displayName.en', 'localMenu[].displayName.ar',
  'localMenu[].description', 'localMenu[].description.tr', 'localMenu[].description.en', 'localMenu[].description.ar',
  'localMenu[].image',
  'qrCategories', 'qrCategories[].id', 'qrCategories[].name', 'qrCategories[].name.tr',
  'qrCategories[].name.en', 'qrCategories[].name.ar', 'qrCategories[].description',
  'qrCategories[].description.tr', 'qrCategories[].description.en', 'qrCategories[].description.ar',
  'qrCategories[].active', 'qrCategories[].order',
  'qrCampaigns', 'qrCampaigns[].id', 'qrCampaigns[].title', 'qrCampaigns[].title.tr',
  'qrCampaigns[].title.en', 'qrCampaigns[].title.ar', 'qrCampaigns[].description',
  'qrCampaigns[].description.tr', 'qrCampaigns[].description.en', 'qrCampaigns[].description.ar',
  'qrCampaigns[].price', 'qrCampaigns[].active', 'qrCampaigns[].startsAt', 'qrCampaigns[].endsAt',
  'qrCampaigns[].items', 'qrCampaigns[].items[].tr', 'qrCampaigns[].items[].en', 'qrCampaigns[].items[].ar',
  'qrCampaigns[].poster', 'qrCampaigns[].thumbnail',
  // Typed finance records; all money is integer kuruş. Business notes and
  // immutable correction facts are retained; device/customer fields are not.
  'finance', 'finance.materials', 'finance.materials[].id', 'finance.materials[].date',
  'finance.materials[].title', 'finance.materials[].recordType', 'finance.materials[].unit',
  'finance.materials[].quantityMilli', 'finance.materials[].pricePerUnitCents',
  'finance.materials[].subtotalCents', 'finance.materials[].discountCents',
  'finance.materials[].discountType', 'finance.materials[].discountValue', 'finance.materials[].totalCents',
  'finance.materials[].market', 'finance.materials[].marketKey', 'finance.materials[].marketUnit',
  'finance.materials[].storeBrand', 'finance.materials[].referencePriceCents',
  'finance.materials[].amountsCents', 'finance.materials[].note', 'finance.materials[].paymentMethod',
  'finance.materials[].createdAt', 'finance.materials[].updatedAt', 'finance.materials[].voided',
  'finance.materials[].voidedAt', 'finance.materials[].voidReason', 'finance.materials[].history',
  'finance.materials[].history[].changedAt', 'finance.materials[].history[].previousTotalCents',
  'finance.materials[].history[].previousDiscountCents', 'finance.materials[].history[].previousUnitPriceCents',
  'finance.materials[].history[].previousQuantityMilli', 'finance.materials[].history[].previousDate',
  'finance.materials[].history[].previousStoreBrand', 'finance.materials[].history[].previousMarket',
  'finance.materials[].history[].previousAmountsCents', 'finance.materials[].history[].previousPaymentMethod',
  'finance.materials[].history[].previousNote',
  'finance.monthlyFixed', 'finance.monthlyFixed[].id', 'finance.monthlyFixed[].category',
  'finance.monthlyFixed[].name', 'finance.monthlyFixed[].amountCents', 'finance.monthlyFixed[].startMonth',
  'finance.monthlyFixed[].dueDay', 'finance.monthlyFixed[].active', 'finance.monthlyFixed[].createdAt',
  'finance.monthlyFixed[].updatedAt', 'finance.monthlyFixed[].activeRanges',
  'finance.monthlyFixed[].activeRanges[].from', 'finance.monthlyFixed[].activeRanges[].to',
  'finance.monthlyFixed[].amountHistory', 'finance.monthlyFixed[].amountHistory[].fromMonth',
  'finance.monthlyFixed[].amountHistory[].amountCents',
  'finance.fixedPayments', 'finance.fixedPayments[].templateId', 'finance.fixedPayments[].month',
  'finance.fixedPayments[].amountCents', 'finance.fixedPayments[].paidAt',
  'finance.weeklyPayroll', 'finance.weeklyPayroll[].id', 'finance.weeklyPayroll[].employeeId',
  'finance.weeklyPayroll[].employeeName', 'finance.weeklyPayroll[].weekStart', 'finance.weeklyPayroll[].weekEnd',
  'finance.weeklyPayroll[].payType', 'finance.weeklyPayroll[].rateCents', 'finance.weeklyPayroll[].workedMinutes',
  'finance.weeklyPayroll[].baseCents', 'finance.weeklyPayroll[].bonusCents', 'finance.weeklyPayroll[].advanceCents',
  'finance.weeklyPayroll[].grossCents', 'finance.weeklyPayroll[].payableCents', 'finance.weeklyPayroll[].paid',
  'finance.weeklyPayroll[].paidAt', 'finance.weeklyPayroll[].createdAt', 'finance.weeklyPayroll[].updatedAt',
  'finance.other', 'finance.other[].id', 'finance.other[].date', 'finance.other[].category', 'finance.other[].name',
  'finance.other[].amountCents', 'finance.other[].paymentMethod', 'finance.other[].voided', 'finance.other[].createdAt',
  'finance.manualPlatformSales', 'finance.manualPlatformSales[].id', 'finance.manualPlatformSales[].source',
  'finance.manualPlatformSales[].month', 'finance.manualPlatformSales[].kind', 'finance.manualPlatformSales[].amountCents',
  'finance.manualPlatformSales[].note', 'finance.manualPlatformSales[].createdAt', 'finance.manualPlatformSales[].updatedAt',
  'finance.manualPlatformSales[].voided', 'finance.manualPlatformSales[].history',
  'finance.manualPlatformSales[].history[].changedAt', 'finance.manualPlatformSales[].history[].kind',
  'finance.manualPlatformSales[].history[].amountCents',
  // Phase 5C shifts (employee hours; no contact data).
  'shifts', 'shifts[]', 'shifts[].id', 'shifts[].employeeId', 'shifts[].employeeName', 'shifts[].start', 'shifts[].end', 'shifts[].source', 'shifts[].corrections', 'shifts[].corrections[]', 'shifts[].corrections[].at', 'shifts[].corrections[].byId', 'shifts[].corrections[].by', 'shifts[].corrections[].before', 'shifts[].corrections[].before.start', 'shifts[].corrections[].before.end', 'shifts[].corrections[].after', 'shifts[].corrections[].after.start', 'shifts[].corrections[].after.end', 'shifts[].corrections[].reason',
  // Orders: commercial and financial facts, no customer contact data.
  'orders', 'orders[].id', 'orders[].dailyNumber', 'orders[].numberDay',
  'orders[].source', 'orders[].table', 'orders[].pickupChannel',
  'orders[].created', 'orders[].createdAt', 'orders[].closed',
  'orders[].closedAt', 'orders[].cancelled', 'orders[].cancelledAt',
  'orders[].cancelReason', 'orders[].tableReleased', 'orders[].serviceStatus',
  'orders[].serviceStartedAt', 'orders[].readyAt', 'orders[].deliveredAt',
  // Pseudonymous link for Açık Hesaplar balances, plus the promised pickup
  // time (owner decision 2026-11-27: operational, visible to authorized
  // staff on Windows/Android/iPhone). Name and phone stay local.
  'orders[].customer', 'orders[].customer.id', 'orders[].customer.time',
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
  'employees[].payrollEligible', 'employees[].payType', 'employees[].payRateCents',
  'employees[].payHistory', 'employees[].payHistory[].effectiveFrom',
  'employees[].payHistory[].payType', 'employees[].payHistory[].rateCents',
  'employees[].payHistory[].setAt', 'employees[].payHistory[].setBy',
  'finance.payrollPayments', 'finance.payrollPayments[].id',
  'finance.payrollPayments[].employeeId', 'finance.payrollPayments[].employeeName',
  'finance.payrollPayments[].weekStart', 'finance.payrollPayments[].kind',
  'finance.payrollPayments[].method', 'finance.payrollPayments[].cashCents',
  'finance.payrollPayments[].bankCents', 'finance.payrollPayments[].amountCents',
  'finance.payrollPayments[].paidOn', 'finance.payrollPayments[].note',
  'finance.payrollPayments[].createdAt', 'finance.payrollPayments[].createdBy',
  'finance.payrollPayments[].reverses',
  'finance.payrollReviews', 'finance.payrollReviews[].employeeId',
  'finance.payrollReviews[].weekStart', 'finance.payrollReviews[].state',
  'finance.payrollReviews[].at', 'finance.payrollReviews[].by', 'finance.payrollReviews[].note',
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
  // Soft-deleted orders (tombstones with audit); the archived order itself
  // is projected through the `orders[]` rules above.
  'deletedOrders', 'deletedOrders[].orderId', 'orders[]', 'deletedOrders[].deletedAt',
  'deletedOrders[].deletedBy', 'deletedOrders[].deletedByStaffId',
  'deletedOrders[].reason', 'deletedOrders[].requestId',
  'deletedOrders[].revision',
};

/// Personal contact / secret field paths that must never be allowlisted.
/// The test suite asserts the intersection with [cloudAllowedFieldPaths]
/// is empty.
const neverProjectedFieldPaths = <String>{
  'orders[].customer.name',
  'orders[].customer.phone',
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
