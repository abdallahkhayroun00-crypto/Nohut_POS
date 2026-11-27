/// Sync Entity Registry (spec V5 §4.4 "Schema Drift Guard", Phase 0).
///
/// Every top-level key that the POS persists inside
/// `state_snapshot.payload` must be listed here with its data class, the
/// proposed cloud target and its verification status. Nothing in this file
/// syncs anything: it is the inventory contract that later phases build on.
/// `test/sync_registry_drift_test.dart` fails CI when a new top-level key
/// appears in the source without an entry here.
///
/// Human-readable detail lives in `docs/cloud-sync/data-inventory.md`.
library;

enum DataClass {
  public,
  internal,
  personalPii,
  financial,
  secret,
  deviceLocal,
  derived,
  transientApi,
}

enum InventoryStatus { verifiedExisting, inFlightPr, proposedV5 }

class SyncEntity {
  const SyncEntity({
    required this.classes,
    required this.cloudTarget,
    required this.policy,
    this.status = InventoryStatus.verifiedExisting,
  });

  /// Every class the key's content can contain (an order can hold PII).
  final Set<DataClass> classes;

  /// Proposed cloud table(s), or `null` when the key never leaves the PC.
  final String? cloudTarget;

  /// One-line sync / retention policy (see data-inventory.md for detail).
  final String policy;
  final InventoryStatus status;
}

const syncEntityRegistry = <String, SyncEntity>{
  // Core POS.
  'employees': SyncEntity(
    classes: {DataClass.personalPii, DataClass.internal},
    cloudTarget: 'employees',
    policy: 'POS→Cloud; keep historical attribution, deactivate not delete',
  ),
  'orders': SyncEntity(
    classes: {DataClass.financial, DataClass.personalPii, DataClass.internal},
    cloudTarget: 'orders, order_batches, order_items, payments, order_events',
    policy: 'POS→Cloud; full history; Gel-Al phone protected, never printed',
  ),
  'deletedOrders': SyncEntity(
    classes: {DataClass.financial, DataClass.personalPii, DataClass.internal},
    cloudTarget: 'orders (deleted_at tombstone) + audit_logs',
    policy: 'Audited soft delete: full order + related rows + who/when/why; '
        'excluded from reports exactly like before; never erased',
  ),
  'nextId': SyncEntity(
    classes: {DataClass.internal},
    cloudTarget: null,
    policy: 'Local ID sequence; single-writer authority, not replicated',
  ),
  'printJobs': SyncEntity(
    classes: {DataClass.internal, DataClass.personalPii},
    cloudTarget: 'receipt_snapshots, print_jobs',
    policy: 'Audit only, never replayed elsewhere; snapshot has name+time, '
        'no phone',
  ),
  'settings': SyncEntity(
    classes: {DataClass.internal, DataClass.deviceLocal},
    cloudTarget: 'restaurant_settings',
    policy: 'Business settings sync; printer/paper/device keys stay local',
  ),
  'shifts': SyncEntity(
    classes: {DataClass.personalPii, DataClass.internal},
    cloudTarget: 'shifts',
    policy: 'Phase 5C: employee shifts; never deleted, corrections audited',
    status: InventoryStatus.verifiedExisting,
  ),
  'staffNotices': SyncEntity(
    classes: {DataClass.internal},
    cloudTarget: 'audit_logs',
    policy: 'Rolling last 100 staff notices; operational audit',
  ),
  'floorPositions': SyncEntity(
    classes: {DataClass.internal},
    cloudTarget: 'pos_tables',
    policy: 'Table layout; owner commands only',
  ),
  'combinedPayments': SyncEntity(
    classes: {DataClass.financial},
    cloudTarget: 'payments (combined group link)',
    policy: 'Append-only group payment records',
  ),
  'terminalAttempts': SyncEntity(
    classes: {DataClass.financial},
    cloudTarget: 'payments (terminal attempts)',
    policy: 'Card-terminal attempts/references; no PAN ever stored',
  ),
  'cashBook': SyncEntity(
    classes: {DataClass.financial},
    cloudTarget: 'cash_sessions, cash_movements',
    policy: 'Legacy cash sessions/movements (UI removed); preserve history',
  ),

  // Menu and campaigns.
  'localMenu': SyncEntity(
    classes: {DataClass.public, DataClass.internal},
    cloudTarget: 'products, product_versions',
    policy: 'Catalog; versioned so old orders keep labels and prices',
  ),
  'internalMenu': SyncEntity(
    classes: {DataClass.internal},
    cloudTarget: 'products (internal/custom)',
    policy: 'Cashier custom items; never published to QR',
  ),
  'qrCategories': SyncEntity(
    classes: {DataClass.public},
    cloudTarget: 'categories',
    policy: 'Mirror of public QR menu categories',
  ),
  'qrCampaigns': SyncEntity(
    classes: {DataClass.public},
    cloudTarget: 'campaigns, campaign_versions',
    policy: 'Mirror of public QR campaigns; versioned',
  ),
  'qrMenuSync': SyncEntity(
    classes: {DataClass.internal},
    cloudTarget: null,
    policy: 'Local QR sync bookkeeping; derived, not replicated',
  ),
  'qrPublisherDraft': SyncEntity(
    classes: {DataClass.public, DataClass.internal},
    cloudTarget: null,
    policy: 'Unpublished menu draft; local until published to QR repo',
  ),
  'qrPublisherDraftRevision': SyncEntity(
    classes: {DataClass.internal},
    cloudTarget: null,
    policy: 'Draft base revision; local',
  ),
  'qrPublisherDraftSourceSnapshot': SyncEntity(
    classes: {DataClass.public},
    cloudTarget: null,
    policy: 'Copy of published catalog the draft was based on; derived',
  ),

  // Customers (existing local Gel-Al directory, PR #17 on main).
  'customers': SyncEntity(
    classes: {DataClass.personalPii},
    cloudTarget: 'BLOCKED: owner + KVKK decision (spec §19.5)',
    policy: 'Existing saved Gel-Al customers + açık hesap links; preserve, '
        'do not expand, no platform customers',
  ),

  // Finance and market prices.
  'finance': SyncEntity(
    classes: {DataClass.financial, DataClass.personalPii},
    cloudTarget: 'material_purchases, expenses, fixed_expenses, '
        'payroll_*, platform_sales',
    policy: 'Full history; payroll rows RLS-restricted to owner/self',
  ),
  'marketPrices': SyncEntity(
    classes: {DataClass.internal},
    cloudTarget: 'market_price_history',
    policy: 'Tracked market products, alerts and refresh status',
  ),

  // Delivery platforms.
  'integrations': SyncEntity(
    classes: {DataClass.internal, DataClass.financial},
    cloudTarget: 'platform_order_records (settlements), platform_menu',
    policy: 'Platform hub: demo stores, platform menu, settlements',
  ),
  'trendyolGoOrders': SyncEntity(
    classes: {
      DataClass.financial,
      DataClass.internal,
      DataClass.transientApi,
    },
    cloudTarget: 'orders (channel=trendyol), platform_order_records',
    policy: 'Business facts durable; customerName/Phone/Email/'
        'deliveryAddress are TRANSIENT_API (see platform-data-policy.md)',
  ),
  'tgoSyncInfo': SyncEntity(
    classes: {DataClass.internal},
    cloudTarget: null,
    policy: 'Local polling cursor/status; not replicated',
  ),
  'tgoOperationAudit': SyncEntity(
    classes: {DataClass.internal},
    cloudTarget: 'audit_logs',
    policy: 'Kabul Et / Hazır / İptal outcomes per package',
  ),
  'tgoReviewStoreId': SyncEntity(
    classes: {DataClass.internal},
    cloudTarget: 'restaurant_settings',
    policy: 'Trendyol review store id (not a secret)',
  ),
  'tgoReviewCache': SyncEntity(
    classes: {DataClass.transientApi, DataClass.personalPii},
    cloudTarget: null,
    policy: 'Refreshable API cache; reviewer names transient, no CRM',
  ),

  // Staff devices.
  'mobileDevices': SyncEntity(
    classes: {DataClass.secret, DataClass.deviceLocal},
    cloudTarget: null,
    policy: 'Paired LAN devices with token hashes; control plane, '
        'never in business projection',
  ),
  'mobileServerId': SyncEntity(
    classes: {DataClass.deviceLocal},
    cloudTarget: null,
    policy: 'Identity of this POS for LAN pairing',
  ),
};

/// Strings the source scanner in the drift test matches that are NOT
/// top-level state keys (fields of nested maps, or of other JSON documents
/// that happen to use the same variable names). Each entry names its owner.
const syncRegistryScannerFalsePositives = <String, String>{
  'advanceCents': 'finance.weeklyPayroll row',
  'amountCents': 'finance row',
  'amountsCents': 'finance sync request body',
  'bonusCents': 'finance.weeklyPayroll row',
  'workedMinutes': 'finance.weeklyPayroll row',
  'averageRating': 'Google Business API response',
  'multiDailyMetricTimeSeries': 'Google Business API response',
  'nextPageToken': 'Google Business API response',
  'notificationTypes': 'Google Business API response',
  'phoneNumbers': 'Google Business API response',
  'pubsubTopic': 'Google Business API response',
  'regularHours': 'Google Business API response',
  'reviews': 'Google Business API response',
  'storefrontAddress': 'Google Business API response',
  'title': 'Google Business API response',
  'totalReviewCount': 'Google Business API response',
  'websiteUri': 'Google Business API response',
  'campaigns': 'QR catalog JSON (cms/catalog-v1.json)',
  'categories': 'QR catalog JSON',
  'products': 'QR catalog / assets/menu.json',
  'price': 'product row',
  'qrPublisherUrl': 'QR publisher settings form',
  'closed': 'order row',
  'guestChecks': 'order row',
  'id': 'nested row id',
  'kitchenPrintState': 'trendyolGoOrders row',
  'kitchenQueuedAt': 'trendyolGoOrders row',
  'confirmed': 'marketPrices import row',
  'customCategories': 'marketPrices settings',
  'depotId': 'marketPrices tracked row',
  'distance': 'marketPrices settings',
  'enabled': 'marketPrices settings',
  'googleMapsFeatureId': 'marketPrices store match',
  'latitude': 'marketPrices settings',
  'longitude': 'marketPrices settings',
  'market': 'finance / market row',
  'refreshAt': 'marketPrices settings',
  'refreshIntervalHours': 'marketPrices settings',
  'storeMatches': 'marketPrices settings',
  'tracked': 'marketPrices settings',
  'lastRefreshAttempt': 'marketPrices settings',
  'lastRefreshError': 'marketPrices settings',
  'lastRefreshResult': 'marketPrices settings',
  'date': 'finance sync request body',
  'note': 'finance sync request body',
  'paymentMethod': 'finance sync request body',
  'staffId': 'finance sync request body',
  'storeBrand': 'finance sync request body',
  'updatedAt': 'finance sync request body',
  'voided': 'finance sync request body',
};
