import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'expense_drafts.dart';

typedef Json = Map<String, dynamic>;

List<Json> rows(Object? value) {
  if (value is! List) return [];
  return value.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
}

/// Turkish lira from exact kuruş, e.g. 447500 → "4.475,00 ₺" (integer math).
String money(int cents) {
  final a = cents.abs();
  final lira = '${a ~/ 100}'.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => '.');
  return '${cents < 0 ? '-' : ''}$lira,${(a % 100).toString().padLeft(2, '0')} ₺';
}
int asCents(Object? amount) => amount is num ? (amount * 100).round() : 0;

class NohutApi {
  NohutApi({http.Client? client, FlutterSecureStorage? storage})
      : _client = client ?? http.Client(),
        _storage = storage ?? const FlutterSecureStorage();

  final http.Client _client;
  final FlutterSecureStorage _storage;
  String? host;
  String? token;
  String? serverId;
  String? employeeId;
  /// Individual LAN session (cookie value). Identity on the server always
  /// comes from this session, never from a picker on the phone.
  String? session;
  /// Last `/api/auth/session` reply: {required, session: {status, username, employeeId, …}}.
  Json sessionInfo = const {};
  bool get paired => host != null && token != null && serverId != null;
  bool get signedIn => sessionInfo['session'] is Map && (sessionInfo['session'] as Map)['status'] == 'ok';
  bool get loginRequired => sessionInfo['required'] == true;
  int? get sessionEmployeeId => signedIn ? (sessionInfo['session'] as Map)['employeeId'] as int? : null;
  String? get sessionUser => signedIn ? '${(sessionInfo['session'] as Map)['username']}' : null;
  String? get sessionStatus => sessionInfo['session'] is Map ? '${(sessionInfo['session'] as Map)['status']}' : null;

  static const _cookie = 'nohut_lan';
  Map<String, String> _headers({bool json = false}) => {
    'Authorization': 'Bearer $token',
    if (json) 'Content-Type': 'application/json',
    if (session != null) 'Cookie': '$_cookie=$session',
  };

  static bool isLocalHost(String host) {
    final ip = InternetAddress.tryParse(host);
    if (ip == null || ip.type != InternetAddressType.IPv4) return false;
    final b = ip.rawAddress;
    return b[0] == 10 || b[0] == 192 && b[1] == 168 ||
        b[0] == 172 && b[1] >= 16 && b[1] <= 31 ||
        host == '127.0.0.1';
  }

  /// Accepts the *existing* PC QR payload, e.g. http://192.168.1.5:8787/personel
  /// but refuses public destinations to prevent sending the pairing PIN off LAN.
  static Uri? normalizeQr(String value) {
    final incoming = Uri.tryParse(value.trim());
    if (incoming == null || incoming.scheme != 'http' ||
        !isLocalHost(incoming.host) || incoming.userInfo.isNotEmpty) return null;
    if (incoming.path.isNotEmpty &&
        incoming.path != '/personel' && incoming.path != '/personel/') {
      return null;
    }
    return Uri(scheme: 'http', host: incoming.host,
        port: incoming.hasPort ? incoming.port : 8787);
  }

  Future<void> restore() async {
    host = await _storage.read(key: 'lanUrl');
    token = await _storage.read(key: 'deviceToken');
    serverId = await _storage.read(key: 'serverId');
    employeeId = await _storage.read(key: 'employeeId');
    session = await _storage.read(key: 'lanSession');
  }

  Future<String> _deviceId() async {
    var id = await _storage.read(key: 'authDeviceId');
    if (id == null) {
      final r = Random.secure();
      id = 'android-${List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join()}';
      await _storage.write(key: 'authDeviceId', value: id);
    }
    return id;
  }

  Future<Json> _auth(String method, String path, [Json? body]) async {
    if (!paired) throw const FormatException('Önce cihazı eşleştirin.');
    final uri = Uri.parse(host!).replace(path: '/api/auth/$path',
        queryParameters: method == 'GET' ? {'client': 'personel'} : null);
    final response = method == 'GET'
        ? await _client.get(uri, headers: _headers()).timeout(const Duration(seconds: 8))
        : await _client.post(uri, headers: _headers(json: true),
            body: jsonEncode({'client': 'personel', ...?body})).timeout(const Duration(seconds: 12));
    final setCookie = response.headers['set-cookie'] ?? '';
    final m = RegExp('$_cookie=([^;]*)').firstMatch(setCookie);
    if (m != null) {
      final v = m.group(1)!;
      if (v.isEmpty || setCookie.contains('Max-Age=0')) {
        session = null;
        await _storage.delete(key: 'lanSession');
      } else {
        session = v;
        await _storage.write(key: 'lanSession', value: v);
      }
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final result = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    if (response.statusCode >= 400) {
      throw FormatException(_authMessage('${result['error'] ?? ''}', result['message']));
    }
    return result;
  }

  static String _authMessage(String code, Object? message) => message is String && message.isNotEmpty
      ? message
      : switch (code) {
          'invalid_credentials' => 'Kullanıcı adı veya şifre hatalı.',
          'locked_out' || 'too_many_attempts' => 'Çok fazla hatalı deneme. Biraz sonra tekrar deneyin.',
          'invalid_pin' => 'PIN hatalı.',
          'inactive' => 'Hesap devre dışı.',
          'device_revoked' || 'revoked' => 'Bu cihazın oturumu kaldırıldı. Yeniden giriş yapın.',
          _ => 'Giriş yapılamadı.',
        };

  Future<Json> refreshSession() async => sessionInfo = await _auth('GET', 'session');

  Future<void> login(String username, String password) async {
    await _auth('POST', 'login', {'username': username.trim(), 'password': password,
      'deviceId': await _deviceId(), 'label': 'Android Personel'});
    await refreshSession();
    if (sessionEmployeeId != null) await saveEmployee(sessionEmployeeId!);
  }

  Future<void> unlock({String? pin, String? password}) async {
    await _auth('POST', 'unlock', pin != null ? {'pin': pin} : {'password': password ?? ''});
    await refreshSession();
  }

  Future<void> logout() async {
    try { await _auth('POST', 'logout'); } catch (_) {}
    session = null;
    sessionInfo = const {};
    await _storage.delete(key: 'lanSession');
  }

  Future<void> saveEmployee(int id) async {
    employeeId = '$id';
    await _storage.write(key: 'employeeId', value: employeeId);
  }

  Future<void> pair(Uri url, String pin) async {
    if (!isLocalHost(url.host)) throw const FormatException('Yalnızca restoran Wi-Fi ağı.');
    final response = await _client.post(
      url.replace(path: '/api/mobile/pair'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'pin': pin, 'deviceName': 'Nohut Personel Android'}),
    ).timeout(const Duration(seconds: 10));
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map || response.statusCode != 200 ||
        decoded['token'] is! String || decoded['serverId'] is! String) {
      throw FormatException(decoded is Map
          ? '${decoded['message'] ?? 'Eşleştirme başarısız'}'
          : 'Eşleştirme başarısız');
    }
    host = url.toString().replaceAll(RegExp(r'/$'), '');
    token = decoded['token'] as String;
    serverId = decoded['serverId'] as String;
    await _storage.write(key: 'lanUrl', value: host);
    await _storage.write(key: 'deviceToken', value: token);
    await _storage.write(key: 'serverId', value: serverId);
  }

  Future<Json> _jsonRequest(String path, {Json? body}) async {
    if (!paired) throw const FormatException('Önce cihazı eşleştirin.');
    final uri = Uri.parse(host!).replace(path: path);
    final response = body == null
        ? await _client.get(uri, headers: _headers())
            .timeout(const Duration(seconds: 8))
        : await _client.post(uri, headers: _headers(json: true),
            body: jsonEncode(body)).timeout(const Duration(seconds: 12));
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    if (data is! Map) throw const FormatException('Geçersiz sunucu yanıtı');
    final result = Map<String, dynamic>.from(data);
    if (response.statusCode == 401) {
      final code = '${result['error'] ?? ''}';
      if (code == 'auth_required' || code == 'expired' || code == 'locked' || code == 'unknown') {
        throw const FormatException('Giriş gerekli. Kullanıcı adınızla giriş yapın.');
      }
      throw const FormatException('Bu cihazın yetkisi kaldırılmış. Yeniden eşleştirin.');
    }
    if (response.statusCode == 409) {
      throw const FormatException('Başka cihaz siparişi değiştirdi. Önce yenileyin.');
    }
    if (response.statusCode >= 400) {
      throw FormatException('${result['message'] ?? result['error'] ?? 'Bağlantı hatası'}');
    }
    return result;
  }

  /// `/api/work/*` (Vardiya, Mesai, own pay). Needs an individual session;
  /// the server decides whose week it is. Returns the status with the body
  /// so the screen can tell an overlap warning (409) from a hard error.
  Future<(int, Json)> work(String method, String path,
      {Map<String, String>? query, Json? body}) async {
    if (!paired) throw const FormatException('Önce cihazı eşleştirin.');
    final uri = Uri.parse(host!).replace(path: '/api/work/$path',
        queryParameters: {'client': 'personel', ...?query});
    final response = method == 'GET'
        ? await _client.get(uri, headers: _headers()).timeout(const Duration(seconds: 8))
        : await _client.post(uri, headers: _headers(json: true),
            body: jsonEncode({'client': 'personel', ...?body})).timeout(const Duration(seconds: 12));
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final result = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    if (response.statusCode == 401) {
      throw const FormatException('Giriş gerekli. Kullanıcı adınızla giriş yapın.');
    }
    return (response.statusCode, result);
  }

  Future<Json> bootstrap() async {
    try {
      final data = await _jsonRequest('/api/mobile/bootstrap');
      if (data['serverId'] != serverId) {
        throw const FormatException('Başka restoran sunucusu tespit edildi.');
      }
      return data;
    } on SocketException {
      final found = await discover();
      if (!found) rethrow;
      return _jsonRequest('/api/mobile/bootstrap');
    } on TimeoutException {
      final found = await discover();
      if (!found) rethrow;
      return _jsonRequest('/api/mobile/bootstrap');
    }
  }

  Future<Json> submitOrder(Json payload) =>
      _jsonRequest('/api/mobile/orders', body: payload);

  Future<Json> submitAction(Json payload) =>
      _jsonRequest('/api/mobile/actions', body: payload);

  /// LAN UDP broadcast: reconnect after DHCP IP changes without QR rescanning.
  Future<bool> discover() async {
    if (serverId == null) return false;
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      final found = Completer<Uri>();
      final subscription = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final packet = socket?.receive();
        if (packet == null || !isLocalHost(packet.address.address)) return;
        final parts = utf8.decode(packet.data, allowMalformed: true).split(':');
        if (parts.length != 3 || parts[0] != 'NOHUT_HERE_V1' ||
            parts[1] != serverId) return;
        final port = int.tryParse(parts[2]);
        if (port == null || port < 1024 || port > 65535 || found.isCompleted) return;
        found.complete(Uri(scheme: 'http', host: packet.address.address, port: port));
      });
      final ping = utf8.encode('NOHUT_DISCOVER_V1:$serverId');
      socket.send(ping, InternetAddress('255.255.255.255'), 8788);
      final uri = await found.future.timeout(const Duration(seconds: 3));
      await subscription.cancel();
      // Probe authenticated endpoint before replacing the trusted URL.
      final response = await _client.get(uri.replace(path: '/api/mobile/bootstrap'),
        headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 5));
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (response.statusCode != 200 || data is! Map ||
          data['serverId'] != serverId) return false;
      host = uri.toString().replaceAll(RegExp(r'/$'), '');
      await _storage.write(key: 'lanUrl', value: host);
      return true;
    } catch (_) {
      return false;
    } finally {
      socket?.close();
    }
  }

  Future<void> forget() async {
    if (serverId != null) await ExpenseDraftStore.forServer(serverId!).disconnect();
    for (final key in ['lanUrl', 'deviceToken', 'serverId', 'employeeId', 'lanSession']) {
      await _storage.delete(key: key);
    }
    host = null;
    token = null;
    serverId = null;
    employeeId = null;
    session = null;
    sessionInfo = const {};
  }

  void close() => _client.close();
}

class StaffNotifications {
  final FlutterLocalNotificationsPlugin plugin = FlutterLocalNotificationsPlugin();
  bool initialized = false;

  Future<void> init() async {
    try {
      initialized = await plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      ) ?? false;
      if (initialized) {
        await plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      }
    } catch (_) {
      initialized = false;
    }
  }

  Future<void> newStaffOrder(Json notice) async {
    if (!initialized) return;
    final title = notice['action'] == 'Ek sipariş'
        ? 'Nohut · Ek sipariş' : 'Nohut · Yeni sipariş';
    final place = notice['table'] == null
        ? 'Gel-Al' : 'Masa ${notice['table']}';
    try {
      await plugin.show(
        (DateTime.now().millisecondsSinceEpoch ~/ 1000) % 100000,
        title,
        '${notice['staff'] ?? 'Personel'} · $place',
        const NotificationDetails(android: AndroidNotificationDetails(
          'nohut_staff_orders_v1',
          'Personel Siparişleri',
          channelDescription: 'Restoran personelinden yeni sipariş bildirimleri',
          importance: Importance.high,
          priority: Priority.high,
        )),
      );
    } catch (_) {
      // Notifications are supplementary: the full order remains in the app.
    }
  }
}

class PersonelController extends ChangeNotifier {
  PersonelController(this.api, this.notifications);
  final NohutApi api;
  final StaffNotifications notifications;
  Timer? _poller;
  Json state = {};
  int revision = -1;
  bool busy = false;
  bool online = false;
  bool firstLoad = true;
  String? error;
  final Set<String> seen = {};
  bool _disposed = false;

  List<Json> get employees => rows(state['employees'])
      .where((e) => e['active'] == true && e['id'] is int).toList();
  List<Json> get products => rows(state['localMenu'])
      .where((p) => p['active'] != false && p['id'] is int &&
          p['price'] is num).toList();
  List<Json> get orders => rows(state['orders']);
  List<Json> get notices => rows(state['staffNotices']);

  Future<void> start() async {
    await api.restore();
    await notifications.init();
    if (api.paired) await refresh();
    _poller = Timer.periodic(const Duration(seconds: 9), (_) {
      if (api.paired && !busy) unawaited(refresh());
    });
    notifyListeners();
  }

  Future<void> refresh() async {
    if (!api.paired || busy) return;
    try {
      final result = await api.bootstrap();
      try { await api.refreshSession(); } catch (_) {}
      if (_disposed) return;
      final next = Map<String, dynamic>.from(result['state'] as Map);
      final incoming = rows(next['staffNotices']);
      if (!firstLoad) {
        for (final n in incoming) {
          final id = '${n['id'] ?? ''}';
          if (id.isNotEmpty && !seen.contains(id) &&
              (n['action'] == 'Yeni sipariş' || n['action'] == 'Ek sipariş')) {
            unawaited(notifications.newStaffOrder(n));
          }
        }
      }
      seen.addAll(incoming.map((n) => '${n['id']}'));
      firstLoad = false;
      revision = result['revision'] as int;
      state = next;
      online = true;
      error = null;
      final restaurant = api.serverId;
      if (restaurant != null && api.host != null) {
        final finance = ExpenseDraftStore.forServer(restaurant);
        finance.host = api.host;
        unawaited(finance.sync());
      }
    } catch (e) {
      online = false;
      error = '$e';
      // With Bireysel giriş zorunlu the server refuses the bootstrap until
      // someone signs in: learn that, so the Giriş Yap button appears.
      if (e is FormatException && e.message.startsWith('Giriş gerekli')) {
        try { await api.refreshSession(); } catch (_) {}
      }
    }
    if (!_disposed) notifyListeners();
  }

  Future<String> sendOrder(Json order) async {
    if (!online || busy) throw const FormatException('Laptop bağlantısı gerekli.');
    busy = true;
    notifyListeners();
    try {
      final result = await api.submitOrder(order);
      await refreshAfterWrite();
      return '${result['orderNumber'] ?? result['orderId'] ?? '—'}';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> refreshAfterWrite() async {
    try {
      final result = await api.bootstrap();
      state = Map<String, dynamic>.from(result['state'] as Map);
      revision = result['revision'] as int;
      seen.addAll(rows(state['staffNotices']).map((e) => '${e['id']}'));
      online = true;
      error = null;
      final restaurant = api.serverId;
      if (restaurant != null && api.host != null) {
        final finance = ExpenseDraftStore.forServer(restaurant);
        finance.host = api.host;
        unawaited(finance.sync());
      }
    } catch (e) {
      error = '$e';
      online = false;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poller?.cancel();
    api.close();
    super.dispose();
  }
}

String requestId() {
  final random = Random.secure();
  return 'android_${DateTime.now().microsecondsSinceEpoch}_${random.nextInt(999999999)}';
}
