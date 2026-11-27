import 'operations.dart';
import 'floor_plan.dart' show positionsFromJson;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'staff_commands.dart';
import 'pos_logic.dart';
import 'campaign_menu.dart';
import 'pos_store.dart';
import 'mobile_pairing.dart';
import 'finance_sync_server.dart';
import 'google_business.dart';
import 'lan_auth_gate.dart';
import 'yonetici_api.dart';
import 'notification_events.dart';

/// Native Flutter Windows HTTP server for employee phones. No Python process.
class PosLanServer extends ChangeNotifier {
  PosLanServer(this.store, {this.port = 8787, String? staffHtml, String? yoneticiHtml,
      this.googleProvider, this.platformAction, this.platformWritable, this.authGate})
    : _staffHtml = staffHtml, _yoneticiHtml = yoneticiHtml;
  String? _yoneticiHtml;
  late final YoneticiApi? yonetici = authGate == null ? null : YoneticiApi(store, authGate!);
  late final LanNotificationsApi? notifications =
      authGate == null ? null : LanNotificationsApi(store, authGate!.auth);
  /// Individual LAN logins (spec §23.4). Null = legacy shared panel only.
  final LanAuthGate? authGate;
  final PosStore store;
  /// Runs a staff phone's Trendyol Go Kabul Et / Hazır through the laptop's
  /// own integration (same validation and platform pre-check as the POS).
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> request)?
      platformAction;
  final bool Function()? platformWritable;
  final GoogleBusiness Function()? googleProvider;
  late final MobilePairing pairing = MobilePairing(store);
  late final FinanceSyncServer financeSync = FinanceSyncServer(store, staffProjection: _staffState, googleProvider: googleProvider);
  HttpServer? _server;
  RawDatagramSocket? _discovery;
  String? error;
  int port;
  String? selectedIp;
  List<String> addresses = const [];
  String? _staffHtml;
  bool _starting = false, _disposed = false;
  int _generation = 0;
  bool get starting => _starting;

  bool get running => _server != null;
  bool get available => addresses.any((a) => a != '127.0.0.1');
  String get staffUrl => 'http://${selectedIp ?? '127.0.0.1'}:$port/personel';
  String get adminBrowserUrl => 'Windows Yönetici Paneli';

  Future<void> discover() async {
    if (_disposed) return;
    error = null;
    List<NetworkInterface> list;
    try {
      list = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
    } on SocketException catch (e) {
      if (_disposed) return;
      addresses = const [];
      selectedIp = '127.0.0.1';
      error = 'Wi-Fi adresi okunamadı; yerel bağlantı korunuyor: $e';
      notifyListeners();
      return;
    }
    if (_disposed) return;
    final found = <String>[];
    final ranked = <(String, String)>[];
    for (final interface in list) {
      for (final address in interface.addresses) {
        final ip = address.address;
        if (!_privateIp(ip) || found.contains(ip)) continue;
        found.add(ip);
        ranked.add((interface.name.toLowerCase(), ip));
      }
    }
    ranked.sort((a, b) {
      int rank(String x) {
        if (x.contains('wi-fi') ||
            x.contains('wlan') ||
            x.contains('wireless')) {
          return 0;
        }
        if (x.contains('ethernet')) return 1;
        return 2;
      }

      return rank(a.$1).compareTo(rank(b.$1));
    });
    addresses = ranked.map((v) => v.$2).toList(growable: false);
    if (selectedIp == null || !addresses.contains(selectedIp)) {
      selectedIp = addresses.isEmpty ? '127.0.0.1' : addresses.first;
    }
    notifyListeners();
  }

  static bool _privateIp(String ip) {
    final bytes = InternetAddress.tryParse(ip)?.rawAddress;
    if (bytes == null || bytes.length != 4) return false;
    return bytes[0] == 10 ||
        (bytes[0] == 192 && bytes[1] == 168) ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31);
  }

  void chooseIp(String value) {
    if (addresses.contains(value)) {
      selectedIp = value;
      notifyListeners();
    }
  }

  Future<void> start() async {
    if (_disposed || _server != null || _starting) return;
    _starting = true;
    final generation = _generation;
    error = null;
    notifyListeners();
    try {
      await discover();
      if (_disposed || generation != _generation) return;
      _staffHtml ??= await rootBundle.loadString('assets/staff.html');
      if (authGate != null && _yoneticiHtml == null) {
        try {
          _yoneticiHtml = await rootBundle.loadString('assets/yonetici.html');
        } catch (e) {
          debugPrint('Yönetici page unavailable: $e'); // Personel keeps working.
        }
      }
      if (_disposed || generation != _generation) return;
      final bound = await HttpServer.bind(InternetAddress.anyIPv4, port);
      if (_disposed || generation != _generation) {
        await bound.close(force: true);
        return;
      }
      _server = bound;
      port = _server!.port;
      // Broadcast discovery works only on the local restaurant network.
      // A paired phone compares the stable opaque serverId before reconnecting.
      try {
        _discovery = await RawDatagramSocket.bind(
            InternetAddress.anyIPv4, 8788);
        _discovery!.listen((event) {
          if (event != RawSocketEvent.read) return;
          final packet = _discovery?.receive();
          if (packet == null) return;
          final ip = packet.address.address;
          if (!_privateIp(ip) && ip != '127.0.0.1') return;
          final message = utf8.decode(packet.data, allowMalformed: true);
          if (message != 'NOHUT_DISCOVER_V1:${pairing.serverId}') return;
          final reply = utf8.encode(
              'NOHUT_HERE_V1:${pairing.serverId}:$port');
          _discovery?.send(reply, packet.address, packet.port);
        });
      } catch (e) {
        debugPrint('Optional Android LAN discovery unavailable: $e');
      }
      _server!.listen(
        (r) => _handle(r).catchError((Object e, StackTrace stack) {
          debugPrint('LAN server error: $e');
          try {
            _json(r.response, 500, {'error': 'server_error'});
          } catch (_) {
            try {
              r.response.close();
            } catch (_) {}
          }
        }),
        onError: (Object e) {
          if (_disposed) return;
          error = 'Local Server error: $e';
          notifyListeners();
        },
      );
    } catch (e) {
      if (_disposed || generation != _generation) return;
      error = 'Port $port kullanılamıyor: $e';
    } finally {
      _starting = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> stop() async {
    _generation++;
    final server = _server;
    _server = null;
    _discovery?.close();
    _discovery = null;
    await server?.close(force: true);
    if (!_disposed) notifyListeners();
  }

  void _json(HttpResponse response, int status, Map<String, dynamic> data) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.headers.set('Cache-Control', 'no-store');
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.write(jsonEncode(data));
    response.close();
  }

  // Hide unpublished products from staff phones without touching SQLite or
  // archived order snapshots used for accounting and reprints.
  Map<String, dynamic> _staffState(Map<String, dynamic> source) {
    // Phone ordering does not need the cash book, settings, old receipts,
    // payments, reconciliation records or the closed-order archive.
    return {
      'floorPlan': {
        for (final entry in positionsFromJson(source['floorPositions']).entries)
          '${entry.key}': {
            'x': entry.value.left,
            'y': entry.value.top,
            'width': entry.value.width,
            'height': entry.value.height,
          },
      },
      'employees': asMaps(source['employees'])
          .map(
            (e) => {
              for (final key in ['id', 'name', 'active']) key: e[key],
            },
          )
          .toList(),
      'localMenu': orderingProducts(source)
          .where((p) => p['active'] != false)
          .toList(),
      // Send only sanitized order information to the staff panel.
      // API credentials, customer address, contact and financial internals stay on the laptop.
      'trendyolGoOrders': asMaps(source['trendyolGoOrders']).reversed
          .where((order) => const {'created', 'picking', 'invoiced', 'shipped'}
              .contains('${order['status'] ?? ''}'.trim().toLowerCase()))
          .map(
            (o) => {
              for (final key in [
                'dailyNumber',
                'numberDay',
                'orderNumber',
                'orderCode',
                'status',
                'createdAt',
                'totalCents',
                'paymentType',
                'customerNote',
                'pickup',
                'testPackage',
                'packageId',
                'preparationMinutes',
                'kitchenPrintState',
              ])
                key: o[key],
              'lines': [
                for (final l in asMaps(o['lines']))
                  {
                    for (final key in [
                      'name',
                      'qty',
                      'unitPriceCents',
                      'options',
                      'removed',
                      'extras',
                    ])
                      key: l[key],
                  },
              ],
            },
          )
          .toList(),
      'orders': asMaps(source['orders'])
          .where(
            (o) =>
                ['Masa', 'Gel-Al'].contains(o['source']) &&
                o['closed'] != true &&
                o['cancelled'] != true &&
                o['tableReleased'] != true,
          )
          .map(
            (o) => {
              for (final key in [
                'id',
                'dailyNumber',
                'numberDay',
                'source',
                'table',
                'createdAt',
                'serviceStatus',
                'customer',
                'batches',
              ])
                key: o[key],
              'totalCents': orderTotalCents(o),
              'paidCents': orderPaidCents(o),
              'dueCents': orderDueCents(o),
              'guestChecks': [
                for (final guest in asMaps(o['guestChecks']))
                  {
                    ...guest,
                    'balanceCents': guestBalance(o, guest['id'] as int),
                  },
              ],
              'serviceStartedAt': o['serviceStartedAt'],
              'readyAt': o['readyAt'],
              'deliveredAt': o['deliveredAt'],
            },
          )
          .toList(),
    };
  }

  String? _token(HttpRequest r) => LanAuthGate.tokenFrom(
      cookie: r.headers.value(HttpHeaders.cookieHeader),
      authorization: r.headers.value(HttpHeaders.authorizationHeader));

  bool _sameOrigin(HttpRequest r) {
    final origin = r.headers.value('origin');
    return origin == null || Uri.tryParse(origin)?.authority == r.headers.value('host');
  }

  /// Applies the LAN auth gate; writes the refusal and returns null when denied.
  GateDecision? _guard(HttpRequest r, String operation, {bool touch = true}) {
    final gate = authGate;
    if (gate == null) return const GateDecision.allow(null);
    final d = gate.guard(token: _token(r), client: 'personel', operation: operation, touch: touch);
    if (d.allowed) return d;
    _json(r.response, d.status, {'error': d.error});
    return null;
  }

  /// LAN-only, same-origin JSON body for the authenticated browser APIs.
  /// Writes the refusal and returns null when the request is not acceptable.
  Future<Json?> _lanJsonBody(HttpRequest request, int limit) async {
    final addr = request.connectionInfo?.remoteAddress.address ?? '';
    if (!_privateIp(addr) && addr != '127.0.0.1' && addr != '::1') {
      _json(request.response, 403, {'error': 'lan_only'});
      return null;
    }
    if (!_sameOrigin(request)) {
      _json(request.response, 403, {'error': 'origin'});
      return null;
    }
    Json body = {...request.uri.queryParameters};
    if (request.method == 'POST') {
      final chunks = <int>[];
      await for (final part in request) {
        chunks.addAll(part);
        if (chunks.length > limit) {
          _json(request.response, 413, {'error': 'payload_size'});
          return null;
        }
      }
      try {
        final decoded = chunks.isEmpty ? const {} : jsonDecode(utf8.decode(chunks));
        if (decoded is! Map) throw const FormatException('invalid');
        body = Map<String, dynamic>.from(decoded);
      } on FormatException {
        _json(request.response, 422, {'error': 'invalid_request'});
        return null;
      }
    }
    return body;
  }

  void _reply(HttpRequest request, GateReply reply) {
    if (reply.setToken != null) {
      request.response.headers.add(HttpHeaders.setCookieHeader,
          LanAuthGate.cookieHeader(reply.setToken!));
    } else if (reply.clearToken) {
      request.response.headers.add(HttpHeaders.setCookieHeader, LanAuthGate.clearCookieHeader);
    }
    _json(request.response, reply.status, reply.body);
  }

  Future<void> _handleYonetici(HttpRequest request, String path) async {
    final api = yonetici;
    if (api == null) {
      _json(request.response, 404, {'error': 'not_found'});
      return;
    }
    final body = await _lanJsonBody(request, 64 * 1024);
    if (body == null) return;
    _reply(request, await api.handle(request.method, path,
        request.uri.queryParameters, body, token: _token(request)));
  }

  Future<void> _handleNotifications(HttpRequest request, bool markRead) async {
    final api = notifications, gate = authGate;
    if (api == null || gate == null) {
      _json(request.response, 404, {'error': 'not_found'});
      return;
    }
    final body = await _lanJsonBody(request, 16 * 1024);
    if (body == null) return;
    if ((request.method == 'POST') != markRead) {
      _json(request.response, 405, {'error': 'method_not_allowed'});
      return;
    }
    final client = body['client'] == 'yonetici' ? 'yonetici' : 'personel';
    final d = gate.guard(token: _token(request), client: client,
        operation: client == 'yonetici' ? 'dashboard.view' : 'tables.view',
        touch: markRead, forceRequired: true);
    if (!d.allowed) {
      _json(request.response, d.status, {'error': d.error});
      return;
    }
    _json(request.response, 200, markRead ? api.markRead(d.context!, body) : api.list(d.context!));
  }

  Future<void> _handleAuth(HttpRequest request, String path) async {
    final gate = authGate;
    if (gate == null) {
      _json(request.response, 404, {'error': 'not_found'});
      return;
    }
    final body = await _lanJsonBody(request, 8 * 1024);
    if (body == null) return;
    final addr = request.connectionInfo?.remoteAddress.address ?? '';
    final reply = await gate.handle(request.method, path, body,
        token: _token(request), ip: addr);
    _reply(request, reply);
  }

  Future<void> _handle(HttpRequest request) async {
    final uri = request.uri;
    final resource = uri.path;
    if (resource.startsWith('/api/auth/')) {
      await _handleAuth(request, resource.substring('/api/auth/'.length));
      return;
    }
    if (resource == '/api/notifications' || resource == '/api/notifications/read') {
      await _handleNotifications(request, resource.endsWith('/read'));
      return;
    }
    if (resource.startsWith('/api/yonetici/')) {
      await _handleYonetici(request, resource.substring('/api/yonetici/'.length));
      return;
    }
    if (request.method == 'GET' && ['/yonetici', '/yonetici/'].contains(resource) &&
        _yoneticiHtml != null && authGate != null) {
      request.response.headers.contentType = ContentType.html;
      request.response.headers.set('Cache-Control', 'no-store');
      request.response.headers.set('X-Content-Type-Options', 'nosniff');
      request.response.headers.set('X-Frame-Options', 'DENY');
      request.response.headers.set('Referrer-Policy', 'no-referrer');
      request.response.write(_yoneticiHtml);
      await request.response.close();
      return;
    }
    if (request.method == 'POST' && resource == '/api/finance/v1') {
      final addr = request.connectionInfo?.remoteAddress.address ?? '';
      if (!_privateIp(addr) && addr != '127.0.0.1') {
        _json(request.response, 403, {'error': 'lan_only'});
        return;
      }
      try {
        final bytes = <int>[];
        await for (final chunk in request.timeout(const Duration(seconds: 10))) {
          bytes.addAll(chunk);
          if (bytes.length > 256 * 1024) {
            _json(request.response, 413, {'error': 'payload_size'});
            return;
          }
        }
        final incoming = jsonDecode(utf8.decode(bytes));
        if (incoming is! Map) throw const FormatException('invalid');
        final result = await financeSync.handle(
          Map<String, dynamic>.from(incoming), pairing.serverId);
        _json(request.response, 200, result);
      } catch (_) {
        _json(request.response, 403, {'error': 'finance_authorization_required'});
      }
      return;
    }
    const brandFonts = [
      'Barlow-Regular.ttf',
      'Barlow-SemiBold.ttf',
      'Barlow-Bold.ttf',
      'BreeSerif-Regular.ttf',
    ];
    if (request.method == 'GET' &&
        brandFonts.any((font) => resource == '/assets/fonts/$font')) {
      final font = resource.substring('/assets/fonts/'.length);
      final bytes = await rootBundle.load('assets/brand/fonts/$font');
      request.response.headers.set('Content-Type', 'font/ttf');
      request.response.headers.set('Cache-Control', 'public, max-age=86400');
      request.response.add(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
      await request.response.close();
      return;
    }
    if (request.method == 'GET' && resource == '/assets/nohut-logo.webp') {
      final bytes = await rootBundle.load('assets/brand/nohut-logo.webp');
      request.response.headers.set('Content-Type', 'image/webp');
      request.response.headers.set('Cache-Control', 'public, max-age=86400');
      request.response.add(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
      await request.response.close();
      return;
    }
    if (request.method == 'GET' &&
        ['/', '/personel', '/personel/'].contains(resource)) {
      request.response.headers.contentType = ContentType.html;
      request.response.headers.set('Cache-Control', 'no-store');
      request.response.headers.set('X-Content-Type-Options', 'nosniff');
      request.response.write(_staffHtml);
      await request.response.close();
      return;
    }
    if (request.method == 'GET' && resource == '/api/health') {
      _json(request.response, 200, {
        'online': true,
        'revision': store.read().revision,
        'serverId': pairing.serverId,
      });
      return;
    }
    if (request.method == 'GET' &&
        (resource == '/api/state' || resource == '/api/bootstrap') &&
        _guard(request, 'tables.view', touch: false) == null) {
      return;
    }
    if (request.method == 'GET' && resource == '/api/state') {
      final current = store.read();
      _json(request.response, 200, {
        'revision': current.revision,
        'state': {
          ..._staffState(current.data),
          'tgoCanWrite': platformWritable?.call() ?? false,
        },
      });
      return;
    }
    if (request.method == 'GET' && resource == '/api/bootstrap') {
      final current = store.read();
      _json(request.response, 200, {
        'online': true,
        'revision': current.revision,
        'state': {
          ..._staffState(current.data),
          'tgoCanWrite': platformWritable?.call() ?? false,
        },
        'ip': selectedIp,
        'port': port,
        'staffUrl': staffUrl,
        'adminUrl': adminBrowserUrl,
        'storage': 'SQLite (Flutter Desktop)',
        'updatedAt': current.updatedAt,
      });
      return;
    }
    if (request.method == 'GET' && resource == '/api/mobile/bootstrap') {
      if (!pairing.authorized(request.headers.value('authorization'))) {
        _json(request.response, 401, {'error': 'pairing_required'});
        return;
      }
      final snapshot = store.read();
      final state = _staffState(snapshot.data);
      state['staffNotices'] = [
        for (final notice in asMaps(snapshot.data['staffNotices']).take(30))
          {
            for (final key in ['id', 'staff', 'action', 'table', 'orderId', 'at'])
              key: notice[key],
          },
      ];
      _json(request.response, 200, {
        'revision': snapshot.revision,
        'serverId': pairing.serverId,
        'state': state,
      });
      return;
    }

    if (request.method == 'POST' &&
        ['/api/mobile/pair', '/api/mobile/orders', '/api/mobile/actions']
            .contains(resource)) {
      final addr = request.connectionInfo?.remoteAddress.address ?? '';
      if (!_privateIp(addr) && addr != '127.0.0.1' && addr != '::1') {
        _json(request.response, 403, {'error': 'lan_only'});
        return;
      }
      if (resource != '/api/mobile/pair' &&
          !pairing.authorized(request.headers.value('authorization'))) {
        _json(request.response, 401, {'error': 'device_revoked_or_unpaired'});
        return;
      }
      if (request.contentLength > 256 * 1024) {
        _json(request.response, 413, {'error': 'payload_size'});
        return;
      }
      final chunks = <int>[];
      await for (final chunk in request) {
        chunks.addAll(chunk);
        if (chunks.length > 256 * 1024) {
          _json(request.response, 413, {'error': 'payload_size'});
          return;
        }
      }
      try {
        final payload = jsonDecode(utf8.decode(chunks));
        if (payload is! Map) throw const FormatException('İstek geçersiz');
        final decoded = Map<String, dynamic>.from(payload);
        final Json result;
        if (resource == '/api/mobile/pair') {
          result = pairing.pair(addr, decoded);
        } else if (resource == '/api/mobile/orders') {
          result = submitStaffOrder(store, decoded);
        } else {
          result = submitStaffAction(store, decoded);
        }
        _json(request.response, 200, result);
      } on StaffConflict {
        _json(request.response, 409, {
          'error': 'conflict', 'revision': store.read().revision,
        });
      } on FormatException catch (e) {
        _json(request.response, 422, {
          'error': 'invalid_request', 'message': e.message,
        });
      } catch (e) {
        _json(request.response, 500, {'error': 'request_failed'});
      }
      return;
    }

    if (request.method == 'POST' && resource == '/api/staff/platform') {
      final origin = request.headers.value('origin');
      if (origin != null &&
          Uri.tryParse(origin)?.authority != request.headers.value('host')) {
        _json(request.response, 403, {'error': 'origin'});
        return;
      }
      final platformDecision = _guard(request, 'online.act');
      if (platformDecision == null) return;
      final chunks = <int>[];
      await for (final part in request) {
        chunks.addAll(part);
        if (chunks.length > 16 * 1024) {
          _json(request.response, 413, {'error': 'payload_size'});
          return;
        }
      }
      final handler = platformAction;
      if (handler == null) {
        _json(request.response, 503, {'error': 'unavailable',
          'message': 'Trendyol Go işlemleri bu cihazda kapalı.'});
        return;
      }
      try {
        final incoming = jsonDecode(utf8.decode(chunks));
        if (incoming is! Map) throw const FormatException('Geçersiz istek');
        final result = await handler(LanAuthGate.withIdentity(
            Map<String, dynamic>.from(incoming), platformDecision.context));
        _json(request.response, 200, result);
      } on FormatException catch (e) {
        _json(request.response, 422, {'error': 'invalid_action',
          'message': e.message});
      } catch (_) {
        _json(request.response, 502, {'error': 'platform_failed',
          'message': 'Trendyol Go işlemi tamamlanamadı. Partner Paneli’ni kontrol edin.'});
      }
      return;
    }
    if (request.method == 'POST' &&
        ['/api/staff/orders', '/api/staff/actions'].contains(resource)) {
      // Reject browser requests from unrelated origins (prototype has no login).
      final origin = request.headers.value('origin');
      if (origin != null &&
          Uri.tryParse(origin)?.authority != request.headers.value('host')) {
        _json(request.response, 403, {'error': 'origin'});
        return;
      }
      if (request.contentLength > 256 * 1024) {
        _json(request.response, 413, {'error': 'payload_size'});
        return;
      }
      final chunks = <int>[];
      await for (final part in request) {
        chunks.addAll(part);
        if (chunks.length > 256 * 1024) {
          _json(request.response, 413, {'error': 'payload_size'});
          return;
        }
      }
      try {
        final incoming = jsonDecode(utf8.decode(chunks));
        if (incoming is! Map) throw const FormatException('Geçersiz istek');
        final payload = Map<String, dynamic>.from(incoming);
        final isOrder = resource == '/api/staff/orders';
        final decision = _guard(request,
            isOrder ? 'orders.create' : LanAuthGate.operationForAction(payload));
        if (decision == null) return;
        final acting = LanAuthGate.withIdentity(payload, decision.context);
        final result = isOrder
            ? submitStaffOrder(store, acting)
            : submitStaffAction(store, acting);
        _json(request.response, 200, result);
      } on StaffConflict {
        _json(request.response, 409, {
          'error': 'conflict',
          'revision': store.read().revision,
        });
      } on FormatException catch (e) {
        _json(request.response, 422, {
          'error': 'invalid_order',
          'message': e.message,
        });
      }
      return;
    }
    if (request.method != 'GET') {
      _json(request.response, 405, {'error': 'method_not_allowed'});
      return;
    }
    _json(request.response, 404, {'error': 'not_found'});
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _server?.close(force: true);
    _discovery?.close();
    pairing.dispose();
    super.dispose();
  }
}
