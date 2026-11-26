import 'order_reporting.dart';
import 'package:nohut_core/management_sections.dart';
import 'order_actions.dart';
import 'product_customization.dart';
import 'service_metrics.dart';
import 'simple_settings.dart';
import 'qr_menu_management.dart';
import 'customer_accounts.dart';
import 'open_accounts_ui.dart';
import 'group_payments.dart';
import 'trendyol_go_readonly.dart';
import 'trendyol_go_ui.dart';
import 'sales_reports.dart';
import 'overview_metrics.dart';
import 'overview_panel.dart';
import 'tables_panel.dart';
import 'finance_ui.dart';
import 'order_alerts.dart';
import 'staff_order_popup.dart';
import 'online_order_alarm.dart';
import 'online_orders.dart';
import 'google_business.dart';
import 'google_business_ui.dart';
import 'market_prices.dart';
import 'market_price_tracking.dart';
import 'card_terminal.dart';

import 'dart:async';
import 'dart:collection';

import 'receipt_printer.dart';
import 'receipt_preview.dart';
import 'qr_menu_sync.dart';

import 'dart:convert';
import 'dart:math' show min;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'brand.dart';
import 'payment_dialog.dart';
import 'floor_plan.dart';
import 'lan_server.dart';
import 'pos_logic.dart';
import 'campaign_menu.dart';
import 'pos_store.dart';
import 'operations.dart';
import 'operations_ui.dart';
import 'platform_ui.dart';
import 'platform_workflows.dart';

part 'order_composer.dart';

const dark = Color(0xff123e30);
const cream = Color(0xfff6f2e7);
const emerald = Color(0xff3b7550);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NohutFalafelApp());
}

class Product {
  const Product({
    required this.id,
    required this.name,
    required this.category,
    this.price,
    this.active = true,
    this.image,
    this.descriptionTr,
    this.displayNameAr,
    this.displayNameEn,
    this.campaignData,
  });
  final Json? campaignData;
  final int id;
  final String name;
  final String category;
  final double? price;
  final bool active;
  final String? image, descriptionTr, displayNameAr, displayNameEn;
}

class OrderRequest {
  const OrderRequest({
    required this.source,
    required this.table,
    required this.pickupChannel,
    required this.lines,
    this.customer = const {},
    this.expectedTableOrderId,
    this.staffId,
  });
  final String source;
  final int? table;
  final String pickupChannel;
  final List<Json> lines;
  final Json customer;
  final int? expectedTableOrderId;
  /// Explicit active employee for new orders entered on the cashier PC.
  /// Existing table additions retain the original order owner.
  final int? staffId;
}

class NohutFalafelApp extends StatelessWidget {
  const NohutFalafelApp({
    super.key,
    this.databaseFile,
    this.startServer = true,
    this.inposGateway,
  });
  final InposGateway? inposGateway;
  final String? databaseFile;
  final bool startServer;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Nohut Falafel · Yönetici Paneli',
    theme: NohutBrand.theme(),
    home: ManagerDesktop(
      databaseFile: databaseFile,
      startServer: startServer,
      inposGateway: inposGateway,
    ),
  );
}

class ManagerDesktop extends StatefulWidget {
  const ManagerDesktop({
    super.key,
    this.databaseFile,
    this.startServer = true,
    this.inposGateway,
  });
  final InposGateway? inposGateway;
  final String? databaseFile;
  final bool startServer;
  @override
  State<ManagerDesktop> createState() => _ManagerDesktopState();
}

class _ManagerDesktopState extends State<ManagerDesktop> {
  late final PosStore store;
  late final InposPayments inpos;
  bool terminalBusy = false;
  late final ReceiptPrinter receiptPrinter;
  late final PosLanServer lan;
  late final QrMenuAutoSync qrSync;
  late final TrendyolGoReadonly tgo;
  late final OnlineOrderSoundPlayer onlineSound;
  late final OnlineOrderAlarm onlineAlarm;
  late final GoogleBusiness google;
  late final MarketPriceClient marketApi;
  Timer? _marketPriceTimer;
  Timer? _midnightTimer;
  Timer? _serviceTimer;
  final Set<String> seenNotices = {};
  Json? latestNotice;
  final Queue<Json> _staffPopupQueue = Queue<Json>();
  bool _staffPopupOpen = false;
  bool _marketPopupOpen = false;
  final Set<String> _seenMarketPopupIds = {};
  bool orderModalOpen = false;
  String businessDay = istanbulDay(DateTime.now());
  List<Product> menu = const [];
  String page = 'dashboard';
  String localView = 'plan';
  int? selectedTable, selectedOrder;
  bool floorEditing = false;
  Map<int, Rect> draftFloor = {...floorDefaults};
  String orderFilter = 'Tümü';
  String orderSearch = '',
      orderStatus = '',
      orderStaff = '',
      orderFrom = istanbulDay(DateTime.now()),
      orderTo = istanbulDay(DateTime.now());

  static const _sectionIcons = <IconData>[
    Icons.dashboard_outlined, Icons.table_restaurant_outlined,
    Icons.delivery_dining_outlined, Icons.star_outline, Icons.storefront_outlined,
    Icons.menu_book_outlined, Icons.account_balance_wallet_outlined,
    Icons.point_of_sale_outlined, Icons.bar_chart_outlined,
    Icons.account_balance_wallet_outlined, Icons.trending_up_outlined,
    Icons.settings_outlined,
  ];
  // Kasa & Ödemeler lives inside Masalar & Siparişler on Windows
  // ("Ödeme Bekleyen" tab); the shared list keeps it for the Android app.
  static final sections = [
    for (var i=0;i<managementSections.length;i++)
      if (managementSections[i].$1 != 'payments')
        (managementSections[i].$1,_sectionIcons[i],managementSections[i].$2),
  ];

  @override
  void initState() {
    super.initState();
    store = PosStore(databaseFile: widget.databaseFile);
    marketApi = MarketPriceClient();
    final initial = store.read(), migrated = copyJson(initial.data);
    final settings =
        migrated.putIfAbsent('settings', () => <String, dynamic>{}) as Map;
    // One-time move away from the old forced "print on payment only"
    // policy: every order prints one Sipariş Fişi again. Afterwards the
    // "Otomatik Masa / Gel-Al Fişi" switch alone decides; the start time
    // stops old queued jobs from printing.
    if (settings['receiptPolicyVersion'] != 2) {
      settings.remove('receiptPolicy');
      settings['autoPrint'] = true;
      settings['autoPrintEnabledAt'] = DateTime.now().toUtc().toIso8601String();
      settings['receiptPolicyVersion'] = 2;
    }
    store.replace(migrated, initial.revision);
    onlineSound = OnlineOrderSoundPlayer();
    onlineAlarm = OnlineOrderAlarm(
      play: onlineSound.play,
      stopAudio: onlineSound.stop,
    );
    onlineAlarm.setAudioEnabled(settings['onlineOrderSound'] != false);
    inpos = InposPayments(store, widget.inposGateway ?? UnavailableInpos());
    lan = PosLanServer(
      store,
      googleProvider: () => google,
      platformWritable: () => tgo.canWrite && !tgo.writing,
      platformAction: _staffPlatformAction,
    );
    receiptPrinter = ReceiptPrinter(store);
    qrSync = QrMenuAutoSync(store);
    tgo = TrendyolGoReadonly(
      store,
      onNewOrders: (orders) {
        if (!mounted) return;
        final message = orders.length == 1
            ? "Trendyol Go · Yeni sipariş ${orders.single['orderNumber']}"
            : 'Trendyol Go · ${orders.length} yeni sipariş';
        _notify(message);
      },
      onOrdersSynced: (orders) => onlineAlarm.acceptSnapshot(
        'Trendyol Go',
        orders.where((order) =>
            order['supplierId'] == tgo.credentials?.supplierId).toList(),
      ),
    );
    google = GoogleBusiness(
      store.filePath,
      onNewReviews: (count) {
        if (mounted) _notify('$count yeni Google yorumu');
      },
    );
    if (widget.startServer) {
      unawaited(tgo.start());
      unawaited(google.load());
    }
    if (widget.startServer) {
      // Check locally every minute; the persisted per-market setting
      // (24h/12h/6h/1h) and lastRefreshAttempt gate actual network requests.
      _marketPriceTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        unawaited(refreshMarketPrices(store, marketApi));
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(refreshMarketPrices(store, marketApi));
      });
    }
    _scheduleIstanbulMidnight();
    _serviceTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    seenNotices.addAll(
      asMaps(store.read().data['staffNotices']).map((n) => '${n['id']}'),
    );
    store.addListener(_staffActivity);
    if (widget.startServer) _scheduleMarketPopup();
    // Migration completes before the print worker can inspect old jobs.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Menu initialization precedes staff order acceptance.
      unawaited(_startLan());
    });
  }

  /// Rolls daily dashboard and report filters over at 00:00 Europe/Istanbul,
  /// without deleting persisted orders, payments, or any unpaid table.
  void _scheduleIstanbulMidnight() {
    _midnightTimer?.cancel();
    final now = DateTime.now().toUtc();
    final midnight = nextIstanbulMidnightUtc(now);
    final delay = midnight.difference(now) + const Duration(milliseconds: 100);
    _midnightTimer = Timer(delay, () {
      if (!mounted) return;
      setState(() {
        businessDay = istanbulDay(DateTime.now());
        // Default order list begins with only the new day's orders.
        // All prior records remain available through the date filters.
        orderFrom = businessDay;
        orderTo = businessDay;
      });
      _scheduleIstanbulMidnight();
    });
  }

  Future<void> _startLan() async {
    await _loadMenu();
    if (mounted && widget.startServer) {
      try {
        await lan.start();
      } catch (e) {
        _notify('Yerel sunucu başlatılamadı: $e', error: true);
      }
      if (mounted) qrSync.start();
    }
  }

  Future<void> _loadMenu() async {
    try {
      final text = await rootBundle.loadString('assets/menu.json');
      if (!mounted) return;
      final data = jsonDecode(text) as Map;
      final products = (data['products'] as List).map((item) {
        final p = item as Map;
        return Product(
          id: p['id'] as int,
          name: p['name'] as String,
          category: p['category'] as String,
          price: p['price'] is num ? (p['price'] as num).toDouble() : null,
        );
      }).toList();
      final snap = store.read();
      final next = copyJson(snap.data);
      next.putIfAbsent('localMenu', () => data['products']);
      // Safe first-upgrade fallback: do not show legacy Şambali ID 32
      // before the first website sync. An explicit CMS active:true restores it.
      final rawLocalMenu = next['localMenu'];
      if (rawLocalMenu is List) {
        for (final product in rawLocalMenu.whereType<Map>()) {
          if (product['id'] == 32 && product['active'] == null) {
            product['active'] = false;
          }
        }
      }
      // Keep intentional local 'not for sale' (null) prices intact.
      // The website sync supplies published prices when enabled.
      final printerSettings =
          next.putIfAbsent('settings', () => <String, dynamic>{}) as Map;
      printerSettings['printerModel'] = 'XP-237B';
      final layoutVersion = printerSettings['receiptLayoutVersion'];
      if (layoutVersion is! int || layoutVersion < 2) {
        printerSettings['paperWidthMm'] = 56;
      }
      if (layoutVersion is! int || layoutVersion < 3) {
        // Mevax 57 mm thermal rolls; only the old untouched default moves.
        if (printerSettings['paperWidthMm'] == 56) {
          printerSettings['paperWidthMm'] = 57;
        }
        printerSettings['receiptLayoutVersion'] = 3;
      }
      printerSettings.putIfAbsent('receiptSidePaddingMm', () => 3);
      printerSettings.putIfAbsent('receiptMarginMm', () => 4);
      printerSettings.putIfAbsent('receiptOffsetMm', () => 0);
      printerSettings.putIfAbsent('receiptLogoMm', () => 18);
      printerSettings.putIfAbsent('printableWidthMm', () => 48);
      printerSettings['receiptScale'] = 'actual';
      if ('${printerSettings['printerName'] ?? ''}'.trim().isEmpty) {
        printerSettings['printerName'] = 'XP-237B';
      }
      printerSettings.putIfAbsent('autoPrint', () => true);
      printerSettings.putIfAbsent(
        'autoPrintEnabledAt',
        () => DateTime.now().toUtc().toIso8601String(),
      );
      seedPlatformMenu(next, asMaps(next['localMenu']));
      store.replace(next, snap.revision);
      receiptPrinter.start();
      if (mounted) setState(() => menu = products);
    } catch (e) {
      _notify('Menü dosyası okunamadı: $e', error: true);
    }
  }

  @override
  void dispose() {
    _midnightTimer?.cancel();
    _marketPriceTimer?.cancel();
    _serviceTimer?.cancel();
    marketApi.close();
    tgo.dispose();
    onlineAlarm.dispose();
    google.dispose();
    qrSync.dispose();
    receiptPrinter.dispose();
    lan.dispose();
    store.removeListener(_staffActivity);
    store.dispose();
    super.dispose();
  }

  Widget _onlineAlarmBanner() {
    final active = onlineAlarm.pending;
    if (active.isEmpty) return const SizedBox.shrink();
    final severity = onlineAlarm.maxSeverity;
    final bg = severity >= 2
        ? const Color(0xffFFE2E1)
        : severity == 1
            ? const Color(0xffFFF0D6)
            : const Color(0xffEDF5E9);
    final ink = severity >= 2
        ? const Color(0xff9B2226)
        : severity == 1
            ? const Color(0xff8A5000)
            : const Color(0xff184C3A);
    final first = active.first;
    final elapsed = first.elapsedSeconds(DateTime.now());
    final sourceNames = active.map((o) => o.platform).toSet().join(' · ');
    return MaterialBanner(
      backgroundColor: bg,
      leading: Icon(
        severity >= 2 ? Icons.emergency_outlined : Icons.notifications_active,
        color: ink,
        size: 30,
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            severity >= 2
                ? 'ACİL · ${active.length} onay bekleyen online sipariş!'
                : severity == 1
                    ? 'Dikkat · ${active.length} online sipariş bekliyor'
                    : 'Yeni online sipariş · ${active.length} bekliyor',
            style: TextStyle(color: ink, fontWeight: FontWeight.w800),
          ),
          Text(
            '$sourceNames · İlk sipariş #${first.number} · ${elapsed < 0 ? 0 : elapsed} sn',
            style: TextStyle(color: ink, fontSize: 12),
          ),
          if (tgo.error.isNotEmpty)
            const Text(
              'Bağlantı hatası: Son doğrulanmış durum korunuyor. Partner panelini kontrol edin.',
              style: TextStyle(color: Color(0xff9B2226), fontSize: 11),
            ),
          if (!onlineAlarm.audioEnabled)
            Text('Ses kapalı · Ayarlar > Bildirimler',
                style: TextStyle(color: ink, fontSize: 11)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => setState(() {
            page = 'online';
            onlinePlatform = first.platform;
            _onlineView++;
          }),
          child: const Text('Siparişi Aç'),
        ),
        if (first.platform == 'Trendyol Go')
          TextButton(
            onPressed: () => openExternalPage(
                context, 'https://partner.tgoyemek.com/'),
            child: const Text('Partner Paneli'),
          ),
      ],
    );
  }

  void _notify(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: error ? const Color(0xffa63831) : dark,
        content: Text(message),
      ),
    );
  }

  bool _edit(void Function(Json state) change) {
    try {
      final snap = store.read();
      final next = copyJson(snap.data);
      change(next);
      final result = store.replace(next, snap.revision);
      if (!result.ok) {
        _notify(
          'Başka cihaz önce kayıt yaptı. Güncel hesap yüklendi; işlemi kontrol edin.',
          error: true,
        );
        return false;
      }
      onlineAlarm.setAudioEnabled(
        store.read().data['settings']?['onlineOrderSound'] != false,
      );
      return true;
    } on FormatException catch (e) {
      _notify(e.message, error: true);
      return false;
    } catch (e) {
      _notify('İşlem kaydedilemedi: $e', error: true);
      return false;
    }
  }

  void _switch(String next) {
    setState(() {
      if (next == 'payments') {
        next = 'tables';
        localView = 'unpaid';
      }
      page = next;
      if (next == 'online') {
        onlinePlatform = 'Tümü';
        _onlineView++;
      }
      selectedOrder = null;
      if (next != 'tables') selectedTable = null;
      floorEditing = false;
    });
  }

  void _focusOrder(Json order) {
    setState(() {
      selectedOrder = order['id'] as int;
      selectedTable = order['table'] as int?;
      page = 'tables';
      orderFrom = orderTo = '${order['numberDay'] ?? ''}';
      orderFilter = 'Tümü';
      localView = order['source'] == 'Masa' ? 'plan' : 'pickup';
      orderSearch = orderStatus = orderStaff = '';
    });
    _showOrder(order['id'] as int);
  }

  List<Product> _currentProducts() =>
      orderingProducts(store.read().data)
          .where((p) => p['active'] != false)
          .map(
            (p) => Product(
              id: p['id'] as int,
              campaignData: p['campaignId'] != null ? p : null,
              name: p['name'] as String,
              category: p['category'] as String,
              price: (p['price'] as num?)?.toDouble(),
              image: p['image'] as String?,
              descriptionTr: (p['description'] as Map?)?['tr'] as String?,
            ),
          )
          .toList();

  Future<void> _composer({
    int? table,
    int? addToOrder,
    bool pickup = false,
  }) async {
    menu = _currentProducts();
    if (menu.isEmpty) {
      _notify('Menü yükleniyor veya okunamadı.', error: true);
      return;
    }
    int? created;
    bool saveRequest(OrderRequest request) => _edit((data) {
      validateCashierDraft(data, request.lines);
      final existing = addToOrder != null
          ? mutableOrder(data, addToOrder)
          : request.source == 'Masa' && request.table != null
              ? activeTable(data, request.table!)
              : null;
      if (addToOrder != null && existing == null) {
        throw const FormatException('Ek sipariş hesabı bulunamadı.');
      }
      if (request.source == 'Masa' && addToOrder == null &&
          existing?['id'] != request.expectedTableOrderId) {
        throw const FormatException(
          'Masa hesabı değişti. Güncel masayı kontrol edip yeniden sipariş açın.',
        );
      }
      if (existing != null) {
        if (existing['source'] != request.source) {
          throw const FormatException('Sipariş türü değişti; yeniden açın.');
        }
        // The first persisted batch owns the order, even for inactive staff.
        final firstBatch = asMaps(existing['batches']).firstOrNull;
        if (firstBatch == null) {
          throw const FormatException('Siparişin ilk personel kaydı bulunamadı.');
        }
        final ownerName = (firstBatch['staff'] ?? 'Kasa (PC)').toString();
        final ownerId = firstBatch['staffId'] is int
            ? firstBatch['staffId'] as int : null;
        addOrderBatch(
          data,
          existing['id'] as int,
          request.lines,
          cashier: ownerName,
          staffId: ownerId,
        );
        created = existing['id'] as int;
        return;
      }
      final person = asMaps(data['employees']).where(
        (entry) =>
            entry['id'] == request.staffId &&
            entry['active'] == true &&
            (entry['name'] ?? '').toString().trim().isNotEmpty,
      ).firstOrNull;
      if (person == null) {
        throw const FormatException(
          'Sipariş için aktif personel seçilmelidir.',
        );
      }
      final personName = person['name'].toString();
      final personId = person['id'] as int;
      final o = newLocalOrder(
        state: data,
        source: request.source,
        table: request.table,
        pickupChannel: request.pickupChannel,
        productLines: request.lines,
        cashier: personName,
      );
      ((o['batches'] as List).first as Map)['staffId'] = personId;
      o['customer'] = request.source == 'Gel-Al'
          ? linkedPickupCustomer(data, request.customer)
          : request.customer;
      created = o['id'] as int;
    });
    final request = await showDialog<OrderRequest>(
      context: context,
      builder: (ctx) => _OrderComposer(
        products: menu,
        customers: savedCustomers(store.read().data),
        employees: asMaps(store.read().data['employees'])
            .where((entry) =>
                entry['active'] == true &&
                entry['id'] is int &&
                '${entry['name'] ?? ''}'.trim().isNotEmpty)
            .toList(),
        onSubmit: saveRequest,
        refreshProducts: _currentProducts,
        refreshTables: () => {
          for (var n = 1; n <= 5; n++)
            if (activeTable(store.read().data, n) != null)
              n: activeTable(store.read().data, n)!,
        },
        table: table,
        adding: addToOrder != null,
        originalOrder: addToOrder == null
            ? null : mutableOrder(store.read().data, addToOrder),
        pickupOnly: pickup,
        tableOrders: {
          for (var n = 1; n <= 5; n++)
            if (activeTable(store.read().data, n) != null)
              n: activeTable(store.read().data, n)!,
        },
      ),
    );
    if (request == null) return;
    if (created != null) {
      final saved = mutableOrder(store.read().data, created!)!;
      _focusOrder(saved);
      _notify('Sipariş #${displayOrderNumber(saved)} kaydedildi.');
    }
  }

  void _staffActivity() {
    if (!mounted) return;
    _scheduleMarketPopup();
    final incoming = asMaps(store.read().data['staffNotices'])
        .where((n) => !seenNotices.contains('${n['id']}'))
        .toList();
    if (incoming.isEmpty) return;
    seenNotices.addAll(incoming.map((n) => '${n['id']}'));
    setState(() => latestNotice = incoming.last);

    // All phone order notifications are deduplicated by requestId, just as
    // submitStaffOrder itself is idempotent. Only order creation/addition
    // gets a popup; other staff actions remain silent.
    final orders = incoming
        .where((n) =>
            n['action'] == 'Yeni sipariş' || n['action'] == 'Ek sipariş')
        .toList();
    _staffPopupQueue.addAll(orders);
    if (orders.isNotEmpty &&
        store.read().data['settings']?['soundAlerts'] != false) {
      for (final _ in orders) {
        queueStaffPhoneOrderSoundTwice();
      }
    }
    _scheduleStaffPopup();
  }

  Widget _marketAlertProductImage(Json alert) {
    final watched = trackedMarketProducts(store.read().data)
        .where((p) => p['key'] == alert['key']).toList();
    final product = watched.isEmpty ? <String, dynamic>{} : watched.first;
    final imageUrl = marketImageUrl(alert['customImageUrl']) ??
        marketImageUrl(product['customImageUrl']) ??
        marketImageUrl(alert['imageUrl']) ??
        marketImageUrl(product['imageUrl']);
    return Container(
      width: 61, height: 61,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xffDEE7DC)),
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
      ),
      child: imageUrl == null
        ? const Icon(Icons.image_outlined, color: NohutBrand.muted)
        : Image.network(imageUrl, fit: BoxFit.contain,
            cacheWidth: 190,
            errorBuilder: (context, error, stack) =>
                const Icon(Icons.image_outlined,
                  color: NohutBrand.muted)),
    );
  }

  void _scheduleMarketPopup() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showMarketPopup();
    });
  }

  void _showMarketPopup() {
    if (!widget.startServer || !mounted || _marketPopupOpen || _staffPopupOpen ||
        orderModalOpen || _staffPopupQueue.isNotEmpty) return;
    final alerts = unreadMarketPriceAlerts(store.read().data)
        .where((a) => !_seenMarketPopupIds.contains(
            (a['id'] ?? '').toString())).toList();
    if (alerts.isEmpty) return;
    for (final alert in alerts) {
      _seenMarketPopupIds.add((alert['id'] ?? '').toString());
    }
    _marketPopupOpen = true;
    final displayed = alerts.take(6).toList();
    showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          const Icon(Icons.notifications_active_rounded,
            color: Color(0xffB45E32)),
          const SizedBox(width: 9),
          Expanded(child: Text(
            alerts.length == 1 ? 'Market Fiyat Uyarısı' :
                'Market Fiyat Uyarıları (' + alerts.length.toString() + ')')),
        ]),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Takip edilen ürünlerde yeni fiyat değişikliği '
                'algılandı.', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 12),
              for (final alert in displayed)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: const Color(0xffF4F7F3),
                    borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [
                    _marketAlertProductImage(alert),
                    const SizedBox(width: 10),
                    Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text((alert['title'] ?? '').toString(),
                          maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13,
                            fontWeight: FontWeight.w800)),
                        Text(
                          (alert['direction'] == 'down' ? '↓ İndirim · ' :
                            '↑ Zam · ') +
                          (alert['depotName'] ?? alert['market'] ?? '').toString(),
                          style: TextStyle(fontSize: 11,
                            color: alert['direction'] == 'down'
                              ? const Color(0xff277A4E)
                              : const Color(0xffB3453A),
                            fontWeight: FontWeight.w800)),
                        Text(
                          ((alert['oldPriceCents'] as num) / 100)
                            .toStringAsFixed(2).replaceAll('.', ',') +
                          ' TL  →  ' +
                          ((alert['newPriceCents'] as num) / 100)
                            .toStringAsFixed(2).replaceAll('.', ',') + ' TL',
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                      ],
                    )),
                    const SizedBox(width: 5),
                    TextButton(
                      key: ValueKey('popup-market-read-' +
                        alert['id'].toString()),
                      onPressed: () {
                        _edit((db) => markMarketPriceAlertsRead(
                          db, [alert['id'].toString()]));
                        Navigator.pop(ctx, 'later');
                      },
                      child: const Text('Okundu'),
                    ),
                  ]),
                ),
              if (alerts.length > displayed.length)
                Text('+' + (alerts.length - displayed.length).toString() +
                  ' diğer uyarı Market Fiyat Takibi sayfasında',
                  style: const TextStyle(fontSize: 11)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'later'),
            child: const Text('Sonra')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'view'),
            child: const Text('Uyarıları Gör')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, 'read'),
            icon: const Icon(Icons.done_all_rounded, size: 18),
            label: const Text('Tümünü Okundu İşaretle')),
        ],
      ),
    ).then((action) {
      _marketPopupOpen = false;
      if (!mounted) return;
      if (action == 'read') {
        _edit((db) => markMarketPriceAlertsRead(db,
          alerts.map((a) => (a['id'] ?? '').toString())));
      } else if (action == 'view') {
        setState(() => page = 'market-prices');
      }
      _scheduleStaffPopup();
    });
  }

  void _scheduleStaffPopup() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showNextStaffPopup();
    });
  }

  void _showNextStaffPopup() {
    if (!mounted || _staffPopupOpen || orderModalOpen ||
        _staffPopupQueue.isEmpty) return;
    final notice = _staffPopupQueue.removeFirst();
    _staffPopupOpen = true;
    final orderId = notice['orderId'];
    showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StaffOrderPopup(
        notice: notice,
        order: orderId is int ? mutableOrder(store.read().data, orderId) : null,
        onOpen: () => Navigator.pop(ctx, true),
        onDismiss: () => Navigator.pop(ctx, false),
      ),
    ).then((open) {
      _staffPopupOpen = false;
      if (!mounted) return;
      if (latestNotice?['id'] == notice['id']) {
        setState(() => latestNotice = null);
      }
      if (open == true && orderId is int) {
        _showOrder(orderId);
      } else {
        _scheduleStaffPopup();
      }
    });
  }

  void _onTable(int table) {
    if (floorEditing) return;
    final order = activeTable(store.read().data, table);
    if (order == null) {
      unawaited(_composer(table: table));
      return;
    }
    setState(() {
      selectedTable = table;
      selectedOrder = order['id'] as int;
    });
    _showOrder(order['id'] as int);
  }

  void _showOrder(int id) {
    if (orderModalOpen) return;
    orderModalOpen = true;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: SizedBox(
          width: 1040,
          height: MediaQuery.sizeOf(ctx).height * .9,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Hesap ve Sipariş',
                        style: TextStyle(
                          fontFamily: NohutBrand.headingFont,
                          fontSize: 24,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Kapat',
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: AnimatedBuilder(
                    animation: store,
                    builder: (_, __) {
                      final current = mutableOrder(store.read().data, id);
                      return current == null
                          ? const Text('Sipariş bulunamadı')
                          : _orderDetail(current);
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ).whenComplete(() {
      orderModalOpen = false;
      _scheduleStaffPopup();
    });
  }

  Future<void> _moveOrder(Json order) async {
    final values = await askFields(
      context,
      'Masayı Taşı',
      [('Yeni masa', '${order['table']}')],
      choices: {
        0: [for (var i = 1; i <= 5; i++) '$i'],
      },
    );
    if (values != null)
      _edit(
        (s) => moveLocalTable(
          s,
          mutableOrder(s, order['id'] as int)!,
          int.parse(values[0]),
          'Kasa (PC)',
        ),
      );
  }

  void _editProducts(Json order) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ürünleri Düzenle'),
        content: SizedBox(
          width: 560,
          child: AnimatedBuilder(
            animation: store,
            builder: (_, __) {
              final current = mutableOrder(
                store.read().data,
                order['id'] as int,
              );
              if (current == null || current['closed'] == true) {
                return const Text('Hesap artık düzenlenemiyor.');
              }
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final line in checkLines(current))
                      ListTile(
                        title: Text(
                          '${line.line['qty']} × ${line.line['name']}',
                        ),
                        subtitle: Text('${line.line['note'] ?? ''}'),
                        trailing: const Icon(Icons.edit_outlined),
                        onTap: () async {
                          final original = jsonEncode(line.line);
                          final result = await customizeLineDialog(
                            ctx,
                            line.line,
                            description:
                                _currentProducts()
                                    .where(
                                      (p) => p.id == line.line['productId'],
                                    )
                                    .firstOrNull
                                    ?.descriptionTr ??
                                '',
                          );
                          if (result != null)
                            _edit((s) {
                              final target = mutableOrder(
                                s,
                                order['id'] as int,
                              );
                              if (target == null) {
                                throw const FormatException(
                                  'Sipariş artık yok.',
                                );
                              }
                              requireOpen(target);
                              final updated = checkLines(target)
                                  .where((entry) => entry.key == line.key)
                                  .firstOrNull;
                              if (updated == null ||
                                  jsonEncode(updated.line) != original) {
                                throw const FormatException(
                                  'Ürün başka bir cihazda değişti. Güncel satırı tekrar açın.',
                                );
                              }
                              editLocalLine(
                                target,
                                line.key,
                                result['qty'] as int,
                                '${result['note']}',
                                (result['removed'] as List).cast<String>(),
                                'Kasa (PC)',
                                adjustmentCents:
                                    result['adjustmentCents'] as int,
                                components: result['components'],
                              );
                            });
                        },
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Kapat'),
          ),
        ],
      ),
    );
  }

  Future<void> _selectProductsToPay(Json order) async {
    // Product lines are grouped for the kitchen, but their *units* must be
    // selectable individually at the till. Already allocated/paid units do
    // not appear again in the unpaid selector.
    final lines = checkLines(order)
        .where((line) => line.total > allocatedTo(order, line.key))
        .toList();
    if (lines.isEmpty) return;
    final shares = <String, int>{};
    final selected = await showDialog<Map<String, int>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, change) {
          int left(CheckLine line) => line.total - allocatedTo(order, line.key);
          int unit(CheckLine line) => cents(line.line['price']);
          String qtyLabel(int amount, int price) {
            if (price <= 0) return '0';
            final qty = amount / price;
            return qty == qty.truncateToDouble()
                ? qty.toInt().toString()
                : qty.toStringAsFixed(2).replaceAll('.', ',');
          }
          final total = shares.values.fold<int>(0, (a, b) => a + b);
          return AlertDialog(
            title: const Text('Ürün seçerek öde'),
            content: SizedBox(
              width: 500,
              child: ListView(
                shrinkWrap: true,
                children: [
                  Text(
                    'Ödenmemiş tutar: ${formatTry(orderDueCents(order))}',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  const Text('Her + işareti yalnızca 1 adet seçer.'),
                  const SizedBox(height: 8),
                  for (final line in lines) ...[
                    Builder(builder: (context) {
                      final available = left(line);
                      final price = unit(line);
                      final chosen = shares[line.key] ?? 0;
                      return Column(
                        children: [
                          CheckboxListTile(
                            key: ValueKey('product-pay-${line.key}'),
                            value: chosen > 0,
                            controlAffinity: ListTileControlAffinity.leading,
                            contentPadding: EdgeInsets.zero,
                            title: Text('${line.line['name']}'),
                            subtitle: Text(
                              'Kalan ${qtyLabel(available, price)} adet · '
                              '${formatTry(available)}',
                            ),
                            onChanged: price <= 0
                                ? null
                                : (value) => change(() {
                                    if (value == true) {
                                      shares[line.key] = min(price, available);
                                    } else {
                                      shares.remove(line.key);
                                    }
                                  }),
                          ),
                          if (chosen > 0)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(14, 0, 8, 10),
                              child: Row(children: [
                                IconButton.outlined(
                                  tooltip: '1 adet azalt',
                                  icon: const Icon(Icons.remove),
                                  onPressed: () => change(() {
                                    if (chosen <= price) {
                                      shares.remove(line.key);
                                    } else {
                                      shares[line.key] = chosen - price;
                                    }
                                  }),
                                ),
                                Expanded(
                                  child: Text(
                                    'Seçilen: ${qtyLabel(chosen, price)} adet',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700),
                                  ),
                                ),
                                IconButton.filledTonal(
                                  tooltip: '1 adet ekle',
                                  icon: const Icon(Icons.add),
                                  onPressed: chosen >= available
                                      ? null
                                      : () => change(() {
                                          shares[line.key] =
                                              min(available, chosen + price);
                                        }),
                                ),
                              ]),
                            ),
                          const Divider(height: 10),
                        ],
                      );
                    }),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Vazgeç'),
              ),
              FilledButton(
                onPressed: total == 0 || total > orderDueCents(order)
                    ? null
                    : () => Navigator.pop(
                        dialogContext,
                        Map<String, int>.of(shares),
                      ),
                child: Text('Seçilenleri Öde · ${formatTry(total)}'),
              ),
            ],
          );
        },
      ),
    );
    if (selected != null && mounted) await _pay(order, productShares: selected);
  }

  Future<void> _pay(
    Json order, {
    int? guestId,
    String? guestName,
    int? maximumCents,
    Map<String, int>? productShares,
  }) async {
    if (order['source'] != 'Masa' && order['source'] != 'Gel-Al') return;
    final due =
        productShares?.values.fold<int>(0, (sum, value) => sum + value) ??
        maximumCents ??
        orderDueCents(order);
    final paymentSnapshot = jsonEncode(order);
    if (due <= 0) {
      _notify('Bu hesapta kalan ödeme bulunmuyor.');
      return;
    }
    final result = await showDialog<(int, String, int?, int?)>(
      context: context,
      builder: (ctx) => PaymentEntryDialog(
        dueCents: due,
        fixedAmount: productShares != null,
        orderNumber: displayOrderNumber(order),
        guestName: guestName ?? '',
      ),
    );
    if (!mounted) return;
    if (result == null) return;
    final (amountCents, methodName, receivedCents, mixedReceived) = result;
    final confirmed = await confirmAction(
      context,
      'Ödemeyi Onayla',
      'Sipariş #${displayOrderNumber(order)} · ${guestName ?? ''}\nTutar: ${formatTry(amountCents)}\nYöntem: $methodName\n'
          '${methodName == 'Karışık'
              ? 'Nakit: ${formatTry(receivedCents!)} · Kart: ${formatTry(amountCents - receivedCents)}. Terminalde kart tahsilatını doğrulayın.'
              : receivedCents == null
              ? 'Banka terminalinde başarılı tahsilatı doğrulayın. Bu kayıt banka işlemi başlatmaz.'
              : 'Alınan: ${formatTry(receivedCents)} · Para üstü: ${formatTry(receivedCents - amountCents)}'}',
      confirm: methodName == 'Karışık'
          ? 'Nakit ve Kart Onaylandı · Kaydet'
          : methodName == 'Kart'
          ? 'Terminalde Onaylandı · Kaydet'
          : 'Nakdi Aldım · Kaydet',
    );
    if (!confirmed || !mounted) return;
    String? receipt;
    final ok = _edit((data) {
      final target = mutableOrder(data, order['id'] as int);
      if (target == null) throw const FormatException('Sipariş bulunamadı');
      if (guestId != null && amountCents > (maximumCents ?? 0)) {
        throw const FormatException('Kişi bakiyesi aşıldı');
      }
      if (jsonEncode(target) != paymentSnapshot) {
        throw const FormatException('Hesap değişti. Ödemeyi tekrar açın.');
      }
      if (productShares != null) {
        receipt = recordProductPayment(
          target,
          productShares,
          amountCents,
          methodName,
          cashCents: methodName == 'Karışık' ? receivedCents : null,
          receivedCents: methodName == 'Karışık'
              ? mixedReceived
              : receivedCents,
        );
      } else if (methodName == 'Karışık') {
        recordMixedPayment(
          target,
          amountCents,
          receivedCents!,
          guestId: guestId,
          receivedCents: mixedReceived,
        );
      } else
        recordPayment(
          target,
          amountCents,
          methodName,
          receivedCents: receivedCents,
          guestId: guestId,
        );
      finishPickupIfSettled(target);
      if (guestId != null) {
        final payments = target['payments'] as List;
        final latest = payments.last as Map;
        latest['guestCheckId'] = guestId;
        latest['guestName'] = guestName;
      }
    });
    if (ok) {
      _notify('Ödeme kaydedildi · ${formatTry(amountCents)}');
      if (!mounted) return;
      await _offerReceipt(order['id'] as int, receipt: receipt);
    }
  }

  Future<void> _payOpenAccount(List<Json> selectedOrders) async {
    final ids = selectedOrders.map((o) => o['id'] as int).toList();
    if (ids.length < 2 || ids.toSet().length != ids.length) {
      _notify('En az iki farklı Gel-Al siparişi seçin.', error: true);
      return;
    }
    final live = store.read().data;
    final originals = <int, String>{};
    var total = 0;
    String? account;
    for (final id in ids) {
      final order = mutableOrder(live, id);
      if (order == null || order['source'] != 'Gel-Al' ||
          order['closed'] == true || order['cancelled'] == true ||
          orderDueCents(order) <= 0) {
        _notify('Açık hesap değişti. Listeyi yeniden kontrol edin.', error: true);
        return;
      }
      final key = pickupAccountKey(order, live);
      if (account != null && account != key) {
        _notify('Farklı müşterilerin hesapları birleştirilemez.', error: true);
        return;
      }
      account = key;
      originals[id] = jsonEncode(order);
      total += orderDueCents(order);
    }
    final result = await showDialog<(int, String, int?, int?)>(
      context: context,
      builder: (ctx) => PaymentEntryDialog(
        dueCents: total,
        fixedAmount: true,
        orderNumber: 'TOPLU GEL-AL',
        guestName: ids.length.toString() + ' sipariş',
      ),
    );
    if (!mounted || result == null) return;
    final (amount, method, cashPartOrReceived, mixedReceived) = result;
    if (amount != total) {
      _notify('Hesap toplamı değişti. Tekrar deneyin.', error: true);
      return;
    }
    final cash = method == 'Nakit'
        ? amount
        : method == 'Karışık' ? cashPartOrReceived : 0;
    final received = method == 'Nakit'
        ? cashPartOrReceived
        : method == 'Karışık' ? mixedReceived : null;
    final confirmed = await confirmAction(
      context,
      'Toplu Ödemeyi Onayla',
      ids.length.toString() + ' Gel-Al siparişi\nToplam: ' +
      formatTry(amount) + '\nYöntem: ' + method +
      (method == 'Karışık'
        ? '\nNakit: ' + formatTry(cash!) +
          ' · Kart: ' + formatTry(amount - cash)
        : '') +
      '\nKart tahsilatını banka terminalinde ayrıca doğrulayın. '
      'Bu işlem kart terminaline ödeme göndermez.',
      confirm: method == 'Nakit'
          ? 'Nakdi Aldım · Kaydet'
          : 'Terminalde Onaylandı · Kaydet',
    );
    if (!confirmed || !mounted) return;
    String? combinedReceipt;
    final operationId = 'gel-al-' +
        DateTime.now().toUtc().microsecondsSinceEpoch.toString();
    final ok = _edit((data) {
      for (final id in ids) {
        final current = mutableOrder(data, id);
        if (current == null || jsonEncode(current) != originals[id]) {
          throw const FormatException(
            'Hesap işlem sırasında değişti. Ödeme kaydedilmedi.');
        }
      }
      combinedReceipt = recordCombinedPickupPayment(
        data,
        orderIds: ids,
        amountCents: amount,
        method: method,
        cashCents: cash,
        receivedCents: received,
        transactionId: operationId,
      );
    });
    if (!ok || !mounted) return;
    _notify('Toplu Gel-Al ödemesi kaydedildi · ' + formatTry(amount));
    await _offerReceipt(ids.first, receipt: combinedReceipt);
  }

  /// Customer-facing NON-fiscal bill preview available before payment.
  /// Unlike queuePaymentReceipt, it never writes a print job or a payment.
  Future<void> _printBillBeforePayment(Json order) async {
    if (isPlatform(order) ||
        !['Masa', 'Gel-Al'].contains(order['source'])) return;
    final settings = store.read().data['settings'] as Map?;
    final selectedPrinter =
        (settings?['printerName'] ?? '').toString().trim();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Ödeme Öncesi Hesap Fişi · #'+
          displayOrderNumber(order).toString()),
        content: SizedBox(
          width: 330,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Bu belge sadece hesap özetidir. '
                'Ödeme almaz, siparişi kapatmaz, mali fiş yerine geçmez.',
                style: TextStyle(color: NohutBrand.muted, fontSize: 12)),
              const SizedBox(height: 11),
              ReceiptPreview(order: order, settings: settings),
            ]),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Vazgeç')),
          FilledButton.icon(
            onPressed: selectedPrinter.isEmpty ? null :
                () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.print_outlined, size: 18),
            label: const Text('Ön Fiş Yazdır')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await windowsPrint(billText(order), selectedPrinter, settings: settings);
      _notify('Hesap özeti yazıcıya gönderildi. Ödeme kaydedilmedi.');
    } catch (e) {
      _notify('Ön fiş yazdırılamadı: $e', error: true);
    }
  }

  Future<void> _offerReceipt(int orderId, {String? receipt}) async {
    if (!mounted) return;
    final print = await confirmAction(
      context,
      'Fiş yazdırılsın mı?',
      'Bu ödeme için hesap özeti yazdırabilirsiniz. Mali fiş ödeme cihazından alınır.',
      confirm: 'Evet · Yazdır',
    );
    if (print)
      _edit(
        (data) => queuePaymentReceipt(
          data,
          mutableOrder(data, orderId)!,
          requestId: 'pc_${DateTime.now().microsecondsSinceEpoch}',
          receipt: receipt,
        ),
      );
  }

  void _closeTable(Json order) {
    if (_edit((data) {
      final target = mutableOrder(data, order['id'] as int);
      if (target == null) throw const FormatException('Sipariş bulunamadı');
      closeLocalTable(target);
    })) {
      setState(() {
        selectedTable = null;
        selectedOrder = null;
      });
      _notify('Masa kapatıldı ve boşaltıldı.');
    }
  }

  void _equalSplit(Json order, int people) {
    _edit(
      (data) => splitEqually(mutableOrder(data, order['id'] as int)!, people),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([store, lan, tgo, onlineAlarm]),
    builder: (ctx, _) {
      final data = store.read().data;
      final width = MediaQuery.sizeOf(context).width;
      final condensed = width < 1050;
      return Scaffold(
        drawer: condensed ? Drawer(child: _sidebar(false)) : null,
        body: Row(
          children: [
            if (!condensed) SizedBox(width: 248, child: _sidebar(false)),
            Expanded(
              child: Column(
                children: [
                  Container(
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      border: Border(bottom: BorderSide(color: Color(0xffE3EBE5))),
                    ),
                    height: 80,
                    padding: const EdgeInsets.symmetric(horizontal: 27),
                    child: Row(
                      children: [
                        if (condensed)
                          Builder(
                            builder: (ctx) => IconButton(
                              tooltip: 'Menüyü aç',
                              onPressed: () => Scaffold.of(ctx).openDrawer(),
                              icon: const Icon(Icons.menu),
                            ),
                          ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text(
                                'NOHUT FALAFEL / YÖNETİCİ',
                                style: TextStyle(
                                  color: Color(0xff526251),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.3,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                sections.firstWhere((s) => s.$1 == page).$3,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontFamily: NohutBrand.headingFont,
                                  color: NohutBrand.green,
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          lan.running ? Icons.wifi_tethering : Icons.wifi_off,
                          color: lan.running ? emerald : Colors.orange,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          lan.running ? 'Personel bağlı' : 'Bağlantı kapalı',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: lan.running ? emerald : Colors.orange,
                          ),
                        ),
                        const SizedBox(width: 14),
                        const CircleAvatar(
                          backgroundColor: dark,
                          child: Text(
                            'PC',
                            style: TextStyle(color: Colors.white, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (onlineAlarm.hasPending) _onlineAlarmBanner(),
                  if (latestNotice != null)
                    MaterialBanner(
                      content: Text(
                        '${latestNotice!['staff']} · ${latestNotice!['action']} · ${latestNotice!['table'] == null ? 'Gel-Al' : 'Masa ${latestNotice!['table']}'}',
                      ),
                      leading: const Icon(
                        Icons.notifications_active,
                        color: dark,
                      ),
                      actions: [
                        TextButton(
                          onPressed: () =>
                              _showOrder(latestNotice!['orderId'] as int),
                          child: const Text('Siparişi Aç'),
                        ),
                        TextButton(
                          onPressed: () => setState(() => latestNotice = null),
                          child: const Text('Tamam'),
                        ),
                      ],
                    ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.symmetric(
                        horizontal: width < 800 ? 12 : 26,
                        vertical: 22,
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1500),
                        child: _page(data),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _sidebar(bool condensed) => Material(
    color: dark,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 24, 14, 20),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(5),
                decoration: const BoxDecoration(
                  color: NohutBrand.cream,
                  shape: BoxShape.circle,
                ),
                child: Image.asset(
                  'assets/brand/nohut-logo.webp',
                  width: 46,
                  height: 46,
                  semanticLabel: 'Nohut Falafel',
                ),
              ),
              if (!condensed) ...[
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Nohut Falafel',
                        style: TextStyle(
                          fontFamily: NohutBrand.headingFont,
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        'İŞLETME PANELİ',
                        style: TextStyle(
                          color: Color(0xffb4cebc),
                          fontSize: 9,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 9),
            children: [
              for (final item in sections)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Tooltip(
                    message: item.$3,
                    child: ListTile(
                      key: ValueKey('navigation-${item.$1}'),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: condensed ? 15 : 12,
                      ),
                      dense: true,
                      leading: Icon(
                        item.$2,
                        color: page == item.$1
                            ? Colors.white
                            : const Color(0xffbfd4c4),
                      ),
                      title: condensed
                          ? null
                          : Text(
                              item.$3,
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: page == item.$1
                                    ? FontWeight.w800
                                    : FontWeight.w500,
                                fontSize: 12,
                              ),
                            ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(11),
                      ),
                      tileColor: page == item.$1
                          ? const Color(0xff397757)
                          : Colors.transparent,
                      onTap: () {
                        if (MediaQuery.sizeOf(context).width < 1050) {
                          Navigator.of(context).pop();
                        }
                        _switch(item.$1);
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (!condensed)
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 0, 18, 24),
            child: Text(
              'Nohut Falafel · Afiyet olsun',
              style: TextStyle(
                color: Color(0xffa4c4af),
                fontSize: 10,
                height: 1.5,
              ),
            ),
          ),
      ],
    ),
  );

  Widget _page(Json db) {
    switch (page) {
      case 'tables':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'plan',
                      icon: Icon(Icons.grid_view_outlined, size: 18),
                      label: Text('Masa Planı')),
                    ButtonSegment(value: 'list',
                      icon: Icon(Icons.list_alt_outlined, size: 18),
                      label: Text('Liste')),
                    ButtonSegment(value: 'pickup',
                      icon: Icon(Icons.shopping_bag_outlined, size: 18),
                      label: Text('Gel-Al')),
                    ButtonSegment(value: 'unpaid',
                      icon: Icon(Icons.payments_outlined, size: 18),
                      label: Text('Ödeme Bekleyen')),
                  ],
                  selected: {localView},
                  onSelectionChanged: (value) => setState(() {
                    localView = value.single;
                    orderFilter = 'Tümü';
                  }),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (localView == 'plan' && !floorEditing)
                      OutlinedButton.icon(
                        onPressed: () => setState(() {
                          floorEditing = true;
                          draftFloor = {...positionsFromJson(db['floorPositions'])};
                        }),
                        icon: const Icon(Icons.open_with),
                        label: const Text('Yerleşimi Düzenle'),
                      ),
                    if (localView == 'plan')
                      FilledButton.icon(
                        onPressed: () => _composer(),
                        icon: const Icon(Icons.add),
                        label: const Text('Masa Siparişi'),
                      )
                    else
                      FilledButton.icon(
                        onPressed: () => _composer(pickup: localView == 'pickup'),
                        icon: const Icon(Icons.add),
                        label: const Text('Sipariş Al'),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (localView == 'plan')
              _tables(db)
            else if (localView == 'unpaid')
              _payments(db)
            else
              _orders(db),
          ],
        );
      case 'online':
        return _online(db);
      case 'google':
        return GoogleBusinessPanel(google: google);
      case 'reviews':
        return FeedbackPanel(
          orders: tgoOrders(db),
          integration: tgo,
          onOpenGoogle: () => setState(() => page = 'google'),
        );
      case 'qr-menu':
        return QrMenuManagement(state:db,edit:_edit,store:store,sync:qrSync);
      case 'open-accounts':
        return OpenAccountsPanel(
          state: db,
          onOpenOrder: _focusOrder,
          onPayOrder: (order) => unawaited(_pay(order)),
          onPayAccount: (orders) => unawaited(_payOpenAccount(orders)),
          onLinkCustomer: (orderId, customerId, newName, phone) {
            _edit((state) => linkLegacyPickupOrder(
              state,
              orderId: orderId,
              existingCustomerId: customerId,
              newCustomerName: newName,
              newCustomerPhone: phone,
            ));
          },
        );
      case 'reports':
        return _reports(db);
      case 'finance':
        return FinancePanel(
          state: db, edit: _edit, onlineWarning: _onlineDataWarning,
          onOpenMarketTracking: () => setState(() => page = 'market-prices'));
      case 'market-prices':
        return MarketPriceTracking(state: db, edit: _edit, store: store, api: marketApi);
      case 'settings':
        return _settings(db);
      default:
        return _dashboard(db);
    }
  }

  Widget _sectionTitle(String title, String description, {Widget? action}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 17),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 22,
                      fontFamily: NohutBrand.headingFont,
                      fontWeight: FontWeight.w900,
                      color: dark,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    description,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xff526251),
                    ),
                  ),
                ],
              ),
            ),
            ?action,
          ],
        ),
      );

  String? get _onlineDataWarning {
    if (tgo.credentials?.valid != true) {
      return 'Trendyol Go API henüz bağlı değil. Yemeksepeti ve Migros '
          'Yemek canlı sipariş entegrasyonları da etkin değil.';
    }
    if (tgo.error.isNotEmpty) {
      return 'Trendyol Go son eşitlemesi başarısız: ${tgo.error}. '
          'Geçmiş dönemlerde 0 ₺, veri eksikliği anlamına gelebilir.';
    }
    final last = DateTime.tryParse(tgo.lastSync);
    if (last == null ||
        DateTime.now().toUtc().difference(last.toUtc()) >
            const Duration(minutes: 5)) {
      return 'Trendyol Go son doğrulanmış eşitlemesi güncel değil. '
          'Online satışlar eksik olabilir.';
    }
    return 'Yemeksepeti ve Migros Yemek canlı sipariş API bağlantıları '
        'henüz etkin değil. Bu platformlarda 0 ₺, doğrulanmış sıfır satış demek değildir.';
  }

  Widget _dashboard(Json db) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _sectionTitle(
        'Bugün',
        turkishLongDate(businessDay),
        action: FilledButton.icon(
          onPressed: () => _composer(),
          icon: const Icon(Icons.add),
          label: const Text('Sipariş Al'),
        ),
      ),
      OverviewPanel(
        state: db,
        businessDay: businessDay,
        onlineWarning: _onlineDataWarning,
        onNavigate: _switch,
      ),
      const SizedBox(height: 16),
      StaffPerformanceChart(state: db, day: businessDay),
    ],
  );

  Widget _tables(Json db) {
    final order = selectedOrder == null
        ? null
        : asMaps(db['orders'])
              .where((o) => o['id'] == selectedOrder)
              .firstOrNull;
    final positions = floorEditing
        ? draftFloor
        : positionsFromJson(db['floorPositions']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TablesSummaryStrip(state: db, now: DateTime.now()),
        const SizedBox(height: 14),
        Row(
          children: [
            if (floorEditing) ...[
              OutlinedButton(
                onPressed: () =>
                    setState(() => draftFloor = {...floorDefaults}),
                child: const Text('İlk Yerleşim'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => setState(() => floorEditing = false),
                child: const Text('Vazgeç'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  if (!validFloorPlacement(draftFloor)) {
                    _notify(
                      'Masalar çakışamaz ve kapı açık kalmalı.',
                      error: true,
                    );
                    return;
                  }
                  final done = _edit(
                    (data) =>
                        data['floorPositions'] = positionsToJson(draftFloor),
                  );
                  if (done) setState(() => floorEditing = false);
                },
                child: const Text('Düzeni Kaydet'),
              ),
            ],
          ],
        ),
        if (floorEditing) const SizedBox(height: 12),
        LayoutBuilder(builder: (context, box) {
          final plan = RestaurantFloorPlan(
          state: db,
          positions: positions,
          editing: floorEditing,
          selected: selectedTable,
          onTable: _onTable,
          onMove: (n, delta) => setState(() {
            final r = draftFloor[n]!;
            final left = (r.left + delta.dx)
                .clamp(0.0, 1.0 - r.width)
                .toDouble();
            final top = (r.top + delta.dy)
                .clamp(0.0, 1.0 - r.height)
                .toDouble();
            final next = {
              ...draftFloor,
              n: Rect.fromLTWH(left, top, r.width, r.height),
            };
            if (validFloorPlacement(next)) draftFloor = next;
          }),
          );
          if (floorEditing || box.maxWidth < 1150) return plan;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: plan),
              const SizedBox(width: 12),
              SizedBox(
                width: min(420, box.maxWidth * 0.34),
                child: OpenOrdersPanel(
                  state: db,
                  now: DateTime.now(),
                  onOpenTable: _onTable,
                  onOpenOrder: (o) => _showOrder(o['id'] as int),
                  onPrintBill: _printBillBeforePayment,
                ),
              ),
            ],
          );
        }),
        const SizedBox(height: 17),
        if (order != null && order['source'] == 'Masa')
          OutlinedButton(
            onPressed: () => _showOrder(order['id'] as int),
            child: Text('Masa ${order['table']} · Hesabı Aç'),
          ),
        if (order == null)
          Row(
            children: [
              const Icon(Icons.info_outline, size: 16, color: Color(0xff647a67)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  floorEditing
                      ? 'Masaları sürükleyin. Numaralar, hesaplar ve 5 masa değişmez.'
                      : 'Boş masaya tıklayın: yeni sipariş. Dolu masaya tıklayın: hesap, ek sipariş ve ödeme.',
                  style: const TextStyle(color: Color(0xff647a67), fontSize: 12.5),
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _orderDetail(Json o) {
    final id = o['id'] as int;
    final closed = o['closed'] == true;
    final local = o['source'] == 'Masa' || o['source'] == 'Gel-Al';
    final total = orderTotalCents(o), paid = orderPaidCents(o);
    final due = orderDueCents(o);
    final split = asMaps(o['guestChecks']);
    final customerName = o['customer'] is Map
        ? '${(o['customer'] as Map)['name'] ?? ''}'.trim() : '';
    final title = o['table'] != null
        ? 'Masa ${o['table']}'
        : '${o['source']}${customerName.isEmpty ? '' : ' · $customerName'}';
    final statusText = closed
        ? 'Kapalı'
        : o['source'] == 'Gel-Al' && o['deliveredAt'] != null
            ? 'Teslim Edildi'
            : 'Açık';
    const border = Color(0xffE1E7E3);
    // No fill by default: the dialog is white, and ListTiles inside need
    // their Material ancestor to stay visible.
    BoxDecoration panel([Color? color]) => BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: border),
    );

    Widget wide(Widget button) => SizedBox(width: double.infinity, child: button);

    final items = Container(
      padding: const EdgeInsets.all(16),
      decoration: panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            const Text('Ürünler', style: TextStyle(
              fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(width: 8),
            Text('${itemCount(o)} adet', style: const TextStyle(
              color: NohutBrand.muted, fontSize: 12.5)),
          ]),
          const SizedBox(height: 8),
          for (final line in activeLines(o))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 34,
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xffEEF3EF),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text('${line['qty']}×',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w800,
                        color: NohutBrand.green)),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${line['name'] ?? line['productKey'] ?? 'Ürün'}',
                          style: const TextStyle(fontWeight: FontWeight.w600,
                            fontSize: 14.5),
                        ),
                        if ('${line['note'] ?? ''}'.isNotEmpty)
                          Text('Not: ${line['note']}', style: const TextStyle(
                            fontSize: 12.5, color: Color(0xff8A6516))),
                        if ((line['removed'] as List? ?? []).isNotEmpty)
                          Text(
                            'Çıkar: ${(line['removed'] as List).join(', ')}',
                            style: const TextStyle(fontSize: 12.5,
                              color: NohutBrand.muted),
                          ),
                      ],
                    ),
                  ),
                  Text(
                    formatTry(
                      cents(line['price']) *
                          ((line['qty'] as num?)?.toInt() ?? 0),
                    ),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          if (split.isNotEmpty) ...[
            const Divider(height: 24),
            const Text(
              'Kişi Hesapları',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            ),
            for (final guest in split)
              Builder(
                builder: (context) {
                  final allocated = asMaps(guest['allocations'])
                      .fold<int>(0, (sum, a) => sum + (a['cents'] as int));
                  final rest = guestBalance(
                    o,
                    guest['id'] as int,
                  ).clamp(0, allocated).toInt();
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      radius: 16,
                      backgroundColor: const Color(0xffEEF3EF),
                      child: Icon(rest > 0 ? Icons.person_outline : Icons.check,
                        size: 18, color: NohutBrand.green),
                    ),
                    title: Text(
                      '${guest['name'] ?? 'Kişi'} · ${formatTry(allocated)}',
                    ),
                    subtitle: Text('Kalan ${formatTry(rest)}'),
                    trailing: rest > 0 && !closed
                        ? FilledButton(
                            onPressed: () => _pay(
                              o,
                              guestId: guest['id'] as int,
                              guestName: '${guest['name']}',
                              maximumCents: rest,
                            ),
                            child: const Text('Öde'),
                          )
                        : const Icon(Icons.check_circle, color: emerald),
                  );
                },
              ),
          ],
        ],
      ),
    );

    final canSplitByProduct = due > 0 &&
        checkLines(o).any((line) => line.total > allocatedTo(o, line.key));
    final payment = Container(
      padding: const EdgeInsets.all(16),
      decoration: panel(const Color(0xffF4F6F2)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('KALAN', style: TextStyle(fontSize: 11.5,
            letterSpacing: 1.1, fontWeight: FontWeight.w800,
            color: NohutBrand.muted)),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(formatTry(due), style: TextStyle(
              fontSize: 34, fontWeight: FontWeight.w900,
              color: due > 0 ? NohutBrand.ink : const Color(0xff2C6E86))),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: total <= 0 ? 0 : (paid / total).clamp(0, 1).toDouble(),
              minHeight: 7,
              color: const Color(0xff2E7D4F),
              backgroundColor: const Color(0xffDCE3DE),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: Text('Toplam: ${formatTry(total)}',
              style: const TextStyle(fontWeight: FontWeight.w700))),
            Text('Alınan: ${formatTry(paid)}',
              style: const TextStyle(color: NohutBrand.muted)),
          ]),
          if (o['terminalPending'] != null) ...[
            const SizedBox(height: 12),
            const Text(
              'Terminal sonucu bekleniyor. Yeniden ödeme başlatmayın.',
              style: TextStyle(color: Color(0xff8c352e),
                fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            OutlinedButton(
              onPressed: !inpos.gateway.ready || terminalBusy
                  ? null
                  : () async {
                      terminalBusy = true;
                      try {
                        final reply = await inpos.reconcile(
                          '${o['terminalPending']}',
                        );
                        if (mounted) {
                          _notify('inPOS: ${reply.status.name}');
                          if (reply.status == TerminalStatus.approved)
                            await _offerReceipt(id);
                        }
                      } catch (e) {
                        if (mounted) _notify('$e', error: true);
                      } finally {
                        terminalBusy = false;
                      }
                    },
              child: const Text('Terminal Sonucunu Sorgula'),
            ),
          ],
          if (!closed && local) ...[
            const SizedBox(height: 14),
            if (split.isEmpty && due > 0)
              wide(FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  textStyle: const TextStyle(fontFamily: NohutBrand.bodyFont,
                    fontSize: 16, fontWeight: FontWeight.w800),
                ),
                onPressed: () => _pay(o),
                icon: const Icon(Icons.payments),
                label: const Text('Nakit / Kart'),
              )),
            if (o['source'] == 'Masa' && due == 0)
              wide(FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  backgroundColor: const Color(0xff2C6E86),
                ),
                onPressed: () => _closeTable(o),
                icon: const Icon(Icons.done_all),
                label: const Text('Masayı Kapat'),
              )),
            if (canSplitByProduct || (split.isEmpty && paid == 0))
              const SizedBox(height: 8),
            Row(children: [
              if (canSplitByProduct)
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _selectProductsToPay(o),
                    icon: const Icon(Icons.checklist, size: 18),
                    label: const Text('Ürün seçerek öde',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
              if (canSplitByProduct && split.isEmpty && paid == 0)
                const SizedBox(width: 8),
              if (split.isEmpty && paid == 0)
                Expanded(
                  child: PopupMenuButton<int>(
                    tooltip: 'Hesabı eşit böl',
                    onSelected: (n) => _equalSplit(o, n),
                    itemBuilder: (context) => [
                      for (final n in [2, 3, 4, 5, 6, 7, 8, 9, 10])
                        PopupMenuItem(
                          value: n,
                          child: Text('$n kişiye eşit böl'),
                        ),
                    ],
                    child: Container(
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xffBECFC5)),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.call_split, size: 18, color: NohutBrand.green),
                          SizedBox(width: 6),
                          Flexible(child: Text('Hesabı Eşit Böl',
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: NohutBrand.green,
                              fontWeight: FontWeight.w600))),
                        ],
                      ),
                    ),
                  ),
                ),
            ]),
            const Divider(height: 26),
            const Text('Diğer İşlemler', style: TextStyle(fontSize: 12,
              fontWeight: FontWeight.w800, color: NohutBrand.muted)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _editProducts(o),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Ürünleri Düzenle'),
                ),
                if (o['source'] == 'Masa')
                  OutlinedButton.icon(
                    onPressed: () => _moveOrder(o),
                    icon: const Icon(Icons.swap_horiz, size: 18),
                    label: const Text('Masayı Taşı'),
                  ),
              ],
            ),
          ],
          if (closed) ...[
            const SizedBox(height: 12),
            const Text(
              'Bu hesap kapalı. Ek ürün ve yeni ödeme eklenemez.',
              style: TextStyle(color: Colors.teal),
            ),
          ],
          if (!isPlatform(o)) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xffB3261E)),
                onPressed: () async {
                  if (await confirmAction(
                    context,
                    'Siparişi kalıcı sil?',
                    '#${displayOrderNumber(o)} · Toplam ${formatTry(total)} · Tahsilat ${formatTry(paid)}\n'
                        'Sipariş, ödemeleri ve rapor tutarları aktif veritabanından kaldırılır. Son günlük numara yeniden kullanılabilir; diğer numaralar değişmez.',
                    confirm: 'Kalıcı Sil',
                  )) {
                    try {
                      store.deleteOrder(
                        o['id'] as int,
                        store.read().revision,
                        'delete_${DateTime.now().microsecondsSinceEpoch}',
                      );
                      if (mounted) Navigator.of(context).pop();
                    } catch (e) {
                      _notify('$e', error: true);
                    }
                  }
                },
                icon: const Icon(Icons.delete_forever, size: 18),
                label: const Text('Kalıcı Sil'),
              ),
            ),
          ],
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          decoration: panel(),
          child: Row(
            children: [
              Container(
                width: 46, height: 46,
                decoration: BoxDecoration(
                  color: const Color(0xffFFF1D6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(o['source'] == 'Masa'
                    ? Icons.table_restaurant_outlined
                    : Icons.shopping_bag_outlined,
                  color: const Color(0xff6E4614)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(
                        child: Text(title, maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 20,
                            fontWeight: FontWeight.w900)),
                      ),
                      const SizedBox(width: 8),
                      StatusPill(closed
                          ? localStatusStyle(o)
                          : statusText == 'Teslim Edildi'
                              ? ('Teslim Edildi', NohutBrand.green,
                                  const Color(0xffe5ebdf))
                              : localStatusStyle(o)),
                    ]),
                    const SizedBox(height: 2),
                    Text(
                      'Sipariş #${displayOrderNumber(o)} · ${o['source']}${o['table'] == null ? '' : ' · Masa ${o['table']}'}',
                      style: const TextStyle(color: NohutBrand.muted,
                        fontSize: 12.5),
                    ),
                    Text(
                      '${o['numberDay'] ?? ''} · $statusText · '
                      '${istanbulStamp(o['createdAt']).substring(11)} açıldı'
                      '${closed ? '' : ' · ${durationLabel(openMinutes(o, DateTime.now()))}'}'
                      ' · ${orderOwnerName(o)}',
                      style: const TextStyle(color: Color(0xff708273),
                        fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (local)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: OutlinedButton.icon(
                    key: ValueKey('prepay-print-$id'),
                    onPressed: () => _printBillBeforePayment(o),
                    icon: const Icon(Icons.print_outlined),
                    label: const Text('Ön Fiş Yazdır'),
                  ),
                ),
              if (!closed && local)
                FilledButton.tonalIcon(
                  onPressed: () =>
                      _composer(table: o['table'] as int?, addToOrder: id),
                  icon: const Icon(Icons.add),
                  label: const Text('Ek Sipariş'),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(builder: (context, box) {
          if (box.maxWidth < 760) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [payment, const SizedBox(height: 12), items],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: items),
              const SizedBox(width: 12),
              SizedBox(width: 340, child: payment),
            ],
          );
        }),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(4),
          decoration: panel(),
          child: OrderOperations(
            printSettings: store.read().data['settings'] as Map?,
            order: o,
            edit: _edit,
            printerName:
                '${store.read().data['settings']?['printerName'] ?? ''}',
          ),
        ),
      ],
    );
  }

  Widget _orders(Json db) {
    final all = asMaps(db['orders']).reversed
        .where(
          (o) =>
              !isPlatform(o) &&
              (localView != 'pickup' || o['source'] == 'Gel-Al'),
        )
        .toList();
    final filtered = all.where((o) {
      final date =
          DateTime.tryParse('${o['createdAt']}')
              ?.toUtc()
              .add(const Duration(hours: 3))
              .toIso8601String()
              .substring(0, 10) ??
          '';
      final text =
          '${o['id']} ${displayOrderNumber(o)} ${o['numberDay'] ?? ''} ${o['table'] ?? ''} ${o['customer']} ${activeLines(o).map((l) => l['name']).join(' ')}'
              .toLowerCase();
      final staff = asMaps(o['batches'])
          .map((b) => b['staff'])
          .join(' ')
          .toLowerCase();
      return (orderFilter == 'Tümü' || o['source'] == orderFilter) &&
          text.contains(orderSearch.toLowerCase()) &&
          staff.contains(orderStaff.toLowerCase()) &&
          (orderStatus.isEmpty ||
              orderStatus == 'Kapalı' && o['closed'] == true ||
              orderStatus == 'İptal' && o['cancelled'] == true ||
              orderStatus == 'Kalan' && orderDueCents(o) > 0 ||
              orderStatus == 'Ödendi' &&
                  orderDueCents(o) == 0 &&
                  o['cancelled'] != true ||
              o['source'] == 'Gel-Al' &&
                  orderStatus == 'Teslim Edildi' &&
                  o['deliveredAt'] != null) &&
          (orderFrom.isEmpty || date.compareTo(orderFrom) >= 0) &&
          (orderTo.isEmpty || date.compareTo(orderTo) <= 0);
    }).toList();
    final remoteFiltered = tgoOrders(db).where((o) {
      if (localView == 'pickup') return false;
      final day = '${o['numberDay'] ?? ''}';
      final search =
          '${o['orderNumber']} ${displayOrderNumber(o)} ${o['customerNote']} ${o['lines']}'
              .toLowerCase();
      return (orderFilter == 'Tümü' || orderFilter == 'Trendyol Go') &&
          (orderStaff.isEmpty) &&
          search.contains(orderSearch.toLowerCase()) &&
          (orderFrom.isEmpty || day.compareTo(orderFrom) >= 0) &&
          (orderTo.isEmpty || day.compareTo(orderTo) <= 0) &&
          (orderStatus.isEmpty || o['status'] == orderStatus);
    }).toList();
    final combined = <Json>[...filtered, ...remoteFiltered]
      ..sort((a, b) {
        final day = '${b['numberDay'] ?? ''}'.compareTo(
          '${a['numberDay'] ?? ''}',
        );
        if (day != 0) return day;
        return (b['dailyNumber'] as int? ?? 0).compareTo(
          a['dailyNumber'] as int? ?? 0,
        );
      });
    bool isRemote(Json order) => order['source'] == 'Trendyol Go';
    int total(Json order) => isRemote(order)
        ? order['totalCents'] as int? ?? 0
        : orderTotalCents(order);
    String remaining(Json order) =>
        isRemote(order) ? '—' : formatTry(orderDueCents(order));
    void openOrder(Json order) {
      if (isRemote(order)) {
        _showTrendyolOrders();
      } else {
        _showOrder(order['id'] as int);
      }
    }

    String clock(Json order) {
      final at = DateTime.tryParse('${order['createdAt']}');
      if (at == null) return '${order['created'] ?? ''}';
      final local = istanbulStamp(order['createdAt']);
      return local.startsWith(businessDay) ? local.substring(11) : local;
    }
    (String, Color, Color) statusOf(Json o) =>
        isRemote(o) ? tgoStatusStyle('${o['status'] ?? ''}') : localStatusStyle(o);
    String itemsOf(Json o) => isRemote(o)
        ? asMaps(o['lines']).map((l) => '${l['qty']}× ${l['name']}').join(', ')
        : itemsSummary(o, limit: 4);
    IconData iconOf(Json o) => switch ('${o['source']}') {
      'Masa' => Icons.table_restaurant_outlined,
      'Gel-Al' => Icons.shopping_bag_outlined,
      _ => Icons.delivery_dining_outlined,
    };
    final sumTotal = combined.fold<int>(0, (n, o) => n + total(o));
    final sumDue = combined.where((o) => !isRemote(o))
        .fold<int>(0, (n, o) => n + orderDueCents(o));
    const muted = TextStyle(color: NohutBrand.muted, fontSize: 12);
    const head = TextStyle(color: NohutBrand.muted, fontSize: 12,
      fontWeight: FontWeight.w700);

    Widget chip(String label, bool selected, VoidCallback onTap) => ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      onSelected: (_) => onTap(),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xffE1E7E3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 320,
                    child: TextField(
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'Sipariş, masa, müşteri veya ürün ara',
                        prefixIcon: Icon(Icons.search, size: 20),
                      ),
                      onChanged: (v) => setState(() => orderSearch = v),
                    ),
                  ),
                  const SizedBox(width: 4),
                  for (final status in [
                    '', 'Kalan', 'Ödendi',
                    if (localView == 'pickup') 'Teslim Edildi',
                    'Kapalı',
                  ])
                    chip(status.isEmpty ? 'Tümü' : status, orderStatus == status,
                      () => setState(() => orderStatus = status)),
                  Container(width: 1, height: 24,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    color: const Color(0xffD5DED8)),
                  for (final filter in [
                    'Tümü', 'Masa', 'Gel-Al',
                    if (localView != 'pickup') 'Trendyol Go',
                  ])
                    chip(filter == 'Tümü' ? 'Tüm kaynaklar' : filter,
                      orderFilter == filter,
                      () => setState(() {
                        orderFilter = filter;
                        selectedOrder = null;
                      })),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text.rich(TextSpan(children: [
                      TextSpan(text: '${combined.length} kayıt',
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                      TextSpan(text: ' · Toplam ${formatTry(sumTotal)}'
                        ' · Kalan ${formatTry(sumDue)}'
                        '${orderFrom.isEmpty && orderTo.isEmpty ? ' · Tüm tarihler' : ' · $orderFrom – $orderTo'}',
                        style: const TextStyle(color: NohutBrand.muted)),
                    ])),
                  ),
                  if (orderFrom.isNotEmpty || orderTo.isNotEmpty)
                    TextButton.icon(
                      onPressed: () => setState(() {
                        orderFrom = ''; orderTo = '';
                      }),
                      icon: const Icon(Icons.event_available_outlined, size: 17),
                      label: const Text('Tüm Tarihler'),
                    ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.tune, size: 17),
                    onPressed: () async {
                      final v = await askFields(context, 'Sipariş Filtreleri', [
                        ('Sipariş / masa / müşteri / ürün ara', orderSearch),
                        (
                          'Durum: boş / Kalan / Ödendi / Kapalı / İptal / Hazır / Hazırlanıyor / Teslim Edildi',
                          orderStatus,
                        ),
                        ('Siparişi alan personel', orderStaff),
                        ('Başlangıç YYYY-MM-DD', orderFrom),
                        ('Bitiş YYYY-MM-DD', orderTo),
                      ]);
                      if (v != null && mounted) {
                        if (v.skip(3).any((d) => d.isNotEmpty && !validBusinessDate(d)) ||
                            v[3].isNotEmpty &&
                                v[4].isNotEmpty &&
                                v[3].compareTo(v[4]) > 0) {
                          _notify('Tarih aralığı geçersiz', error: true);
                          return;
                        }
                        setState(() {
                          orderSearch = v[0];
                          orderStatus = v[1];
                          orderStaff = v[2];
                          orderFrom = v[3];
                          orderTo = v[4];
                          selectedOrder = null;
                        });
                      }
                    },
                    label: const Text('Gelişmiş Filtreler'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xffE1E7E3)),
          ),
          clipBehavior: Clip.antiAlias,
          child: combined.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Column(children: [
                    Icon(Icons.inbox_outlined, size: 32, color: Color(0xffA9B3AD)),
                    SizedBox(height: 6),
                    Text('Sipariş bulunamadı',
                      style: TextStyle(color: NohutBrand.muted)),
                  ]),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 760;
                    Widget printButton(Json o) => IconButton(
                      visualDensity: VisualDensity.compact,
                      key: ValueKey('orders-print-${o['id']}'),
                      tooltip: 'Ön Fiş Yazdır',
                      icon: const Icon(Icons.print_outlined, size: 19),
                      onPressed: () => _printBillBeforePayment(o),
                    );
                    final rows = <Widget>[
                      if (!compact)
                        Container(
                          color: const Color(0xffF4F6F2),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                          child: const Row(children: [
                            SizedBox(width: 70, child: Text('Sipariş', style: head)),
                            SizedBox(width: 150, child: Text('Masa / Kaynak', style: head)),
                            SizedBox(width: 120, child: Text('Saat', style: head)),
                            Expanded(child: Text('Ürünler', style: head)),
                            SizedBox(width: 100, child: Text('Toplam',
                              textAlign: TextAlign.right, style: head)),
                            SizedBox(width: 100, child: Text('Kalan',
                              textAlign: TextAlign.right, style: head)),
                            SizedBox(width: 16),
                            SizedBox(width: 112, child: Text('Durum', style: head)),
                            SizedBox(width: 172, child: Text('İşlem', style: head)),
                          ]),
                        ),
                      for (final (i, o) in combined.indexed) ...[
                        if (i > 0 || compact) const Divider(height: 1),
                        InkWell(
                          onTap: () => openOrder(o),
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 16, vertical: compact ? 10 : 8),
                            child: compact
                                ? Row(children: [
                                    Icon(iconOf(o), size: 20, color: NohutBrand.green),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text('#${displayOrderNumber(o)} · ${o['table'] == null ? o['source'] : "Masa ${o['table']}"}',
                                            style: const TextStyle(fontWeight: FontWeight.w800)),
                                          Text(itemsOf(o), maxLines: 1,
                                            overflow: TextOverflow.ellipsis),
                                          Text(clock(o), style: muted),
                                        ],
                                      ),
                                    ),
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.end,
                                      children: [
                                        Text(remaining(o), style: const TextStyle(
                                          fontWeight: FontWeight.w800)),
                                        const SizedBox(height: 3),
                                        StatusPill(statusOf(o)),
                                      ],
                                    ),
                                    if (!isRemote(o)) printButton(o),
                                  ])
                                : Row(children: [
                                    SizedBox(width: 70, child: Text(
                                      '#${displayOrderNumber(o)}',
                                      style: const TextStyle(fontWeight: FontWeight.w800))),
                                    SizedBox(width: 150, child: Row(children: [
                                      Icon(iconOf(o), size: 18, color: NohutBrand.green),
                                      const SizedBox(width: 8),
                                      Flexible(child: Text(
                                        o['table'] == null ? '${o['source']}' : 'Masa ${o['table']}',
                                        maxLines: 1, overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontWeight: FontWeight.w600))),
                                    ])),
                                    SizedBox(width: 120, child: Text(clock(o), style: muted)),
                                    Expanded(child: Text(itemsOf(o), maxLines: 1,
                                      overflow: TextOverflow.ellipsis)),
                                    SizedBox(width: 100, child: Text(formatTry(total(o)),
                                      textAlign: TextAlign.right)),
                                    SizedBox(width: 100, child: Text(remaining(o),
                                      textAlign: TextAlign.right,
                                      style: TextStyle(fontWeight: FontWeight.w800,
                                        color: !isRemote(o) && orderDueCents(o) > 0
                                            ? NohutBrand.ink : NohutBrand.muted))),
                                    const SizedBox(width: 16),
                                    SizedBox(width: 112, child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: StatusPill(statusOf(o)))),
                                    SizedBox(width: 172, child: Row(children: [
                                      Flexible(
                                        child: TextButton(
                                          style: TextButton.styleFrom(
                                            visualDensity: VisualDensity.compact),
                                          onPressed: () => openOrder(o),
                                          child: Text(
                                            isRemote(o)
                                                ? 'Platform Siparişi' : 'Hesabı Aç',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis),
                                        ),
                                      ),
                                      if (!isRemote(o)) printButton(o),
                                    ])),
                                  ]),
                          ),
                        ),
                      ],
                    ];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: rows,
                    );
                  },
                ),
        ),
      ],
    );
  }

  Json? platformDemo;
  String onlinePlatform = 'Tümü';
  int _onlineView = 0;

  void _showTrendyolOrders() => setState(() {
    page = 'online';
    onlinePlatform = 'Trendyol Go';
    _onlineView++;
  });

  /// Kabul Et / Hazır from a staff phone. The phone never talks to Trendyol;
  /// the laptop validates the worker, finds the package and calls the same
  /// integration as the POS buttons (which re-checks the live status first).
  Future<Map<String, dynamic>> _staffPlatformAction(
      Map<String, dynamic> request) async {
    final data = store.read().data;
    final staffId = request['staffId'];
    final worker = asMaps(data['employees'])
        .where((e) => e['id'] == staffId && e['active'] != false)
        .firstOrNull;
    if (worker == null) throw const FormatException('Çalışan seçin.');
    final action = '${request['action']}';
    if (!const ['accept', 'ready'].contains(action)) {
      throw const FormatException('Desteklenmeyen işlem.');
    }
    final packageId = '${request['packageId'] ?? ''}';
    final order = tgoOrders(data)
        .where((o) => '${o['packageId']}' == packageId && packageId.isNotEmpty)
        .firstOrNull;
    if (order == null) throw const FormatException('Sipariş bulunamadı.');
    final minutes = request['preparationMinutes'];
    final verified = await tgo.updateOrder(
      order,
      action,
      preparationMinutes: minutes is int ? minutes : null,
    );
    return {
      'ok': true,
      'verified': verified,
      'by': worker['name'],
    };
  }

  Widget _online(Json db) => OnlineOrders(
    key: ValueKey(_onlineView),
    orders: tgoOrders(db),
    integration: tgo,
    businessDay: businessDay,
    initialSource: onlinePlatform,
    demo: () => _platformDemo(db),
    // Only a ticket whose earlier send is uncertain can be sent again; the
    // operator checks the printer first (same rule as the Masa print queue).
    onReprint: (order) async {
      if (!await confirmAction(
        context,
        'Sipariş fişini tekrar yazdır?',
        'Önce yazıcıyı kontrol edin. Fiş zaten çıktıysa tekrar yazdırmayın.',
        confirm: 'Kontrol Ettim · Yazdır',
      )) return;
      final key = tgoOrderKey(order);
      _edit((data) {
        for (final current in mutableTgoOrders(data)) {
          if (tgoOrderKey(current) == key &&
              current['kitchenPrintState'] == 'Kontrol gerekli' &&
              tgoKitchenActive(current)) {
            current['kitchenPrintState'] = 'Bekliyor';
            current['kitchenQueuedAt'] = DateTime.now().toUtc().toIso8601String();
          }
        }
      });
    },
  );

  Widget _platformDemo(Json db) {
    platformDemo ??= {...emptyPosState(), 'localMenu': asMaps(db['localMenu'])};
    seedPlatformMenu(
      platformDemo!,
      asMaps(platformDemo!['localMenu'])
          .where((p) => p['active'] != false)
          .toList(),
    );
    return PlatformPanel(
      state: platformDemo!,
      fixedSource: 'Yemeksepeti',
      edit: (change) {
        try {
          final next = copyJson(platformDemo!);
          change(next);
          PosStore.validate(next);
          setState(() => platformDemo = next);
          return true;
        } catch (e) {
          _notify('$e', error: true);
          return false;
        }
      },
    );
  }

  Widget _payments(Json db) {
    final locals = asMaps(db['orders'])
        .where(
          (o) =>
              (o['source'] == 'Masa' || o['source'] == 'Gel-Al') &&
              o['closed'] != true &&
              o['cancelled'] != true &&
              orderDueCents(o) > 0,
        )
        .toList()
      ..sort((a, b) => '${a['createdAt']}'.compareTo('${b['createdAt']}'));
    final totalDue = locals.fold<int>(0, (s, o) => s + orderDueCents(o));
    final paidPart = locals.fold<int>(0, (s, o) => s + orderPaidCents(o));
    final today = dayCollections(db, businessDay);
    final now = DateTime.now();
    Widget stat(IconData icon, String label, String value, String note) =>
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xffE1E7E3)),
          ),
          child: Row(children: [
            Container(
              width: 38, height: 38,
              decoration: BoxDecoration(
                color: NohutBrand.green.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, size: 20, color: NohutBrand.green),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontSize: 12,
                    color: NohutBrand.muted, fontWeight: FontWeight.w600)),
                  Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 19,
                      fontWeight: FontWeight.w800)),
                  Text(note, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5,
                      color: NohutBrand.muted)),
                ],
              ),
            ),
          ]),
        );
    final stats = [
      stat(Icons.receipt_long_outlined, 'Açık Hesap', '${locals.length}',
        'Ödemesi tamamlanmamış masa ve Gel-Al'),
      stat(Icons.pending_actions_outlined, 'Restoran Alacağı',
        formatTry(totalDue),
        paidPart > 0 ? '${formatTry(paidPart)} kısmen alındı' : 'Tahsil edilecek toplam'),
      stat(Icons.payments_outlined, 'Bugün Nakit', formatTry(today.cashCents),
        'Nakit tahsilat (iade düşülmüş)'),
      stat(Icons.credit_card_outlined, 'Bugün Kart', formatTry(today.cardCents),
        'Kart tahsilat (iade düşülmüş)'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(builder: (context, box) {
          final columns = box.maxWidth >= 900 ? 4 : 2;
          final width = (box.maxWidth - 12 * (columns - 1)) / columns;
          return Wrap(spacing: 12, runSpacing: 12, children: [
            for (final s in stats) SizedBox(width: width, child: s),
          ]);
        }),
        const SizedBox(height: 14),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xffE1E7E3)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Text(
                  locals.isEmpty
                      ? 'Ödeme bekleyen hesap yok'
                      : 'Ödeme Bekleyen Hesaplar · en eskisi üstte',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
              ),
              if (locals.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 28),
                  child: Column(children: [
                    Icon(Icons.check_circle_outline, size: 32,
                      color: Color(0xff7FB08F)),
                    SizedBox(height: 4),
                    Text('Tüm hesaplar ödendi',
                      style: TextStyle(color: NohutBrand.muted)),
                  ]),
                ),
              for (final o in locals) ...[
                const Divider(height: 1),
                InkWell(
                  onTap: () => _focusOrder(o),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Row(children: [
                      Icon(o['source'] == 'Masa'
                          ? Icons.table_restaurant_outlined
                          : Icons.shopping_bag_outlined,
                        color: NohutBrand.green),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${o['table'] == null ? 'Gel-Al' : 'Masa ${o['table']}'} · #${displayOrderNumber(o)}',
                              style: const TextStyle(fontWeight: FontWeight.w800),
                            ),
                            Text(itemsSummary(o, limit: 4), maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                            Text(
                              '${durationLabel(openMinutes(o, now))} önce · '
                              '${orderOwnerName(o)} · Toplam ${formatTry(orderTotalCents(o))}'
                              '${orderPaidCents(o) > 0 ? ' · Alınan ${formatTry(orderPaidCents(o))}' : ''}',
                              style: const TextStyle(fontSize: 12,
                                color: NohutBrand.muted),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      StatusPill(localStatusStyle(o)),
                      const SizedBox(width: 10),
                      IconButton(
                        tooltip: 'Ön Fiş Yazdır',
                        icon: const Icon(Icons.print_outlined, size: 19),
                        onPressed: () => _printBillBeforePayment(o),
                      ),
                      const SizedBox(width: 4),
                      FilledButton(
                        onPressed: () => _focusOrder(o),
                        child: Text('Kalan ${formatTry(orderDueCents(o))}'),
                      ),
                    ]),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        const Row(children: [
          Icon(Icons.info_outline, size: 16, color: Color(0xff8A6516)),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              'Kart tahsilatı bu sürümde banka POS terminaline otomatik aktarılmaz. Fiziksel mali fiş / ÖKC entegrasyonu yoktur.',
              style: TextStyle(color: Color(0xff8A6516), fontSize: 12),
            ),
          ),
        ]),
      ],
    );
  }


  Widget _staff(Json db) => StaffPanel(state: db, edit: _edit);

  Widget _reports(Json db) => SalesReports(
    key: ValueKey('daily-reports-$businessDay'),
    state: db,
    edit: _edit,
    onlineWarning: _onlineDataWarning,
  );

  Widget _wifi(Json db) {
    final url = lan.staffUrl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(
          'Personel Bağlantısı',
          'Android uygulaması için QR + tek seferlik PIN; iPhone için Safari.',
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            lan.running
                                ? Icons.check_circle
                                : Icons.error_outline,
                            color: lan.running ? Colors.green : Colors.orange,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              lan.running
                                  ? 'Personel bağlantısı hazır'
                                  : 'Personel bağlantısı kapalı',
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Port: ${lan.port}',
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'SQLite: ${store.filePath}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      const SizedBox(height: 16),
                      if (lan.addresses.isNotEmpty)
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          key: ValueKey(
                            '${lan.selectedIp}:${lan.addresses.join(',')}',
                          ),
                          initialValue:
                              lan.selectedIp != null &&
                                  lan.addresses.contains(lan.selectedIp)
                              ? lan.selectedIp
                              : lan.addresses.first,
                          decoration: const InputDecoration(
                            labelText: 'Laptopun Wi-Fi IPv4 adresi',
                          ),
                          items: lan.addresses
                              .map(
                                (ip) => DropdownMenuItem(
                                  value: ip,
                                  child: Text(ip),
                                ),
                              )
                              .toList(),
                          onChanged: (ip) {
                            if (ip != null) lan.chooseIp(ip);
                          },
                        ),
                      if (lan.error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            lan.error!,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                      if (!lan.available)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 11),
                          child: Text(
                            'Yerel ağ IPv4 bulunamadı. Telefon QR çalışmayabilir.',
                            style: TextStyle(color: Colors.deepOrange),
                          ),
                        ),
                      const SizedBox(height: 15),
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () => lan.discover(),
                            icon: const Icon(Icons.refresh),
                            label: const Text('IP Yenile'),
                          ),
                          if (!lan.running)
                            FilledButton(
                              onPressed: lan.starting
                                  ? null
                                  : () => lan.start(),
                              child: const Text('Sunucuyu Başlat'),
                            ),
                          if (lan.running)
                            OutlinedButton(
                              onPressed: () => lan.stop(),
                              child: const Text('Sunucuyu Durdur'),
                            ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'Bağlantı Mantığı',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        '1. Laptop ve personel telefonları aynı Wi-Fi\n'
                        '2. Nohut programını açık tutun\n'
                        '3. Personel QR kodunu tarar, adını seçer\n'
                        '4. Siparişler telefon ve kasada birlikte görünür\n'
                        '5. Ödeme ve teslim durumunu aynı hesaptan takip edin',
                        style: TextStyle(height: 1.8, fontSize: 12),
                      ),
                      const SizedBox(height: 11),
                      const Text(
                        'Android uygulamasında ilk kullanımda QR + PIN gerekir. '
                        'Cihaz onaylandıktan sonra otomatik bağlanır. '
                        'iPhone Safari panelinin eski LAN erişimi PIN kullanmaz; '
                        'misafir Wi-Fi ve internet port yönlendirme kullanmayın.',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.deepOrange,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(21),
                  child: Column(
                    children: [
                      const Text(
                        'PERSONEL GİRİŞ QR',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 17),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(17),
                          border: Border.all(color: const Color(0xffdce7da)),
                        ),
                        child: lan.running && lan.available
                            ? QrImageView(
                                data: url,
                                size: 215,
                                errorCorrectionLevel: QrErrorCorrectLevel.M,
                              )
                            : const SizedBox(
                                height: 215,
                                width: 215,
                                child: Center(
                                  child: Text(
                                    'Wi-Fi IP bekleniyor',
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                      ),
                      const SizedBox(height: 13),
                      SelectableText(
                        lan.running ? url : 'Sunucu başlamadı',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 13),
                      FilledButton.icon(
                        onPressed: lan.running
                            ? () {
                                Clipboard.setData(ClipboardData(text: url));
                                _notify('Personel URL kopyalandı');
                              }
                            : null,
                        icon: const Icon(Icons.copy),
                        label: const Text('Bağlantıyı Kopyala'),
                      ),
                      const SizedBox(height: 15),
                      const Divider(height: 28),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.android, color: NohutBrand.green),
                          SizedBox(width: 6),
                          Text('ANDROID · NOHUT PERSONEL',
                              style: TextStyle(fontWeight: FontWeight.w800)),
                        ],
                      ),
                      const SizedBox(height: 5),
                      const Text(
                        'Uygulamada QR kodu tarayın, sonra bu PIN’i '
                        'yalnızca bir kez girin.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 9),
                      SelectableText(
                        lan.pairing.pin,
                        style: const TextStyle(
                          fontSize: 30,
                          letterSpacing: 6,
                          fontWeight: FontWeight.w900,
                          color: NohutBrand.green,
                        ),
                      ),
                      Text(
                        '15 dakika geçerlidir · Her eşleştirmeden sonra yenilenir',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                      TextButton.icon(
                        onPressed: () => setState(lan.pairing.rotatePin),
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('Yeni PIN Oluştur'),
                      ),
                      const Divider(height: 22),
                      const Text('Android Yönetim · Ömer Yılmaz',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                      TextButton.icon(
                        icon: const Icon(Icons.admin_panel_settings_outlined),
                        label: const Text('Yönetim APK Eşleştir'),
                        onPressed: !lan.available ? null : () async {
                          final approve = await showDialog<bool>(context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Ömer Yılmaz yönetici erişimi'),
                              content: const Text('Yalnızca Ömer Yılmaz cihazına verin. Eski finans anahtarı iptal edilir.'),
                              actions: [
                                TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Vazgeç')),
                                FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Oluştur')),
                              ]));
                          if (approve != true || !context.mounted) return;
                          try {
                            final secret = await lan.financeSync.rotateOwnerKey();
                            if (!context.mounted) return;
                            final pairingCode = jsonEncode({
                              'host': 'http://' + lan.selectedIp! + ':' + lan.port.toString(),
                              'serverId': lan.pairing.serverId, 'key': secret,
                            });
                            await showDialog<void>(context: context,builder:(ctx)=>AlertDialog(
                              title:const Text('Nohut Yönetim · Güvenli eşleştirme'),
                              content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
                                QrImageView(data:pairingCode,size:220),
                                const Text('Yalnızca yetkili yönetici cihazında okutun.'),
                                SelectableText(pairingCode),
                              ])),
                              actions:[
                                TextButton(onPressed:()async {await Clipboard.setData(ClipboardData(text:pairingCode));},child:const Text('Kopyala')),
                                TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Kapat')),
                              ]));
                          } catch(e) {
                            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content:Text('Yönetim eşleştirme: ' + e.toString())));
                          }
                        }),
                      const Divider(height: 22),
                      const Text('Android Finans Erişimi',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                      const Text('Yalnızca güvenilen yönetici cihazına verin. '
                        'Yeni anahtar eski finans anahtarını iptal eder.'),
                      TextButton.icon(
                        icon: const Icon(Icons.vpn_key_outlined),
                        label: const Text('Finans Anahtarı Oluştur'),
                        onPressed: () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Finans erişimi oluşturulsun mu?'),
                              content: const Text('Bu anahtar giderleri değiştirme, maaşları ve '
                                'finans raporlarını okuma yetkisi verir. Eski '
                                'anahtarlar geçersiz olur. Yalnızca yöneticiye verin.'),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('Vazgeç')),
                                FilledButton(onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('Oluştur')),
                              ],
                            ),
                          );
                          if (confirmed != true || !context.mounted) return;
                          try {
                            final key = await lan.financeSync.rotateKey();
                            if (!context.mounted) return;
                            await showDialog<void>(context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Android Finans Anahtarı'),
                                content: SelectableText(key),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(ctx),
                                    child: const Text('Kapat')),
                                ],
                              ));
                          } catch (_) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Finans anahtarı kaydedilemedi.')));
                            }
                          }
                        },
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.lock_outline),
                        label: const Text('Finans Erişimini Kapat'),
                        onPressed: () async {
                          try {
                            await lan.financeSync.revoke();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Finans erişimi kapatıldı.')));
                            }
                          } catch (_) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Finans erişimi kapatılamadı.')));
                            }
                          }
                        },
                      ),
                      if (lan.pairing.devices.isNotEmpty) ...[
                        const Divider(height: 22),
                        const Text('Eşleştirilmiş Android cihazlar',
                          style: TextStyle(fontWeight: FontWeight.w800)),
                        for (final device in lan.pairing.devices)
                          if (device['revoked'] != true)
                            ListTile(
                              dense: true,
                              leading: const Icon(Icons.smartphone),
                              title: Text('${device['name']}'),
                              trailing: TextButton(
                                onPressed: () => setState(() =>
                                  lan.pairing.revoke('${device['id']}')),
                                child: const Text('Erişimi Kaldır'),
                              ),
                            ),
                      ],
                      const Text(
                        'iPhone · Safari Web Paneli',
                        style: TextStyle(
                          color: Color(0xff526251),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _notice(
          'Gerçek fiziksel Windows laptopta test edilmelidir. Bu uygulama dış internete açılmamalıdır. QR menü sipariş vermek için değil, personel uygulamasını açmak içindir.',
        ),
      ],
    );
  }

  Widget _settings(Json db) => SimpleSettings(
    state: db,
    edit: _edit,
    store: store,
    qrSync: qrSync,
    tgoIntegration: tgo,
    onTestOnlineSound: (platform) => unawaited(
      onlineSound.play(platform, 0).catchError((Object _) {}),
    ),
    onOpenGoogle: () => setState(() => page = 'google'),
    staffPanel: _staff(db),
    wifiPanel: _wifi(db),
  );

  Widget _notice(String text) => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: const Color(0xfffff1d9),
      border: Border.all(color: const Color(0xfff0dbb2)),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Color(0xff775624),
        fontSize: 12,
        height: 1.5,
      ),
    ),
  );
}
