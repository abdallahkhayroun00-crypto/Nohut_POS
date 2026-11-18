import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as paths;

import 'order_reporting.dart';
import 'pos_logic.dart';
import 'windows_vault.dart';

class GoogleBusiness extends ChangeNotifier {
  GoogleBusiness(String databaseFile, {this.onNewReviews})
    : _vault = WindowsVault(
        File(paths.join(paths.dirname(databaseFile), 'google-business.dpapi')),
      );

  static const managerUrl = 'https://business.google.com/locations';
  static const mapsUrl =
      'https://www.google.com/maps/place/Nohut+Falafel/@40.7650391,30.3602224,17z/data=!4m8!3m7!1s0x14ccb3cd4595bcab:0xd28ffffa342dbede!8m2!3d40.7650391!4d30.3602224!9m1!1b1!16s%2Fg%2F11wjq__p26?hl=tr';
  static const _api = 'mybusiness.googleapis.com';
  static const _tokenHost = 'oauth2.googleapis.com';
  static const _performance = 'businessprofileperformance.googleapis.com';
  static const _information = 'mybusinessbusinessinformation.googleapis.com';
  static const _accounts = 'mybusinessaccountmanagement.googleapis.com';

  final WindowsVault _vault;
  final ValueChanged<int>? onNewReviews;
  Timer? _pollTimer;
  Set<String>? _seenReviews;
  bool _polling = false;
  Json? _session;
  String? _accessToken;
  DateTime? _expires;
  bool _disposed = false;
  String? loadError;
  bool get connected => _session != null;

  String get _account => 'accounts/${_session!['account']}';
  String get _location => 'locations/${_session!['location']}';
  String get _v4Location => '/v4/$_account/$_location';

  Future<void> load() async {
    try {
      _session = await _vault.load();
    } catch (_) {
      loadError = 'Google bağlantısı Windows güvenli kasasından okunamadı.';
    }
    if (!_disposed) notifyListeners();
    _startPolling();
  }

  Future<void> connect({
    required String clientId,
    required String clientSecret,
    required String account,
    required String location,
    required Future<void> Function(Uri) openBrowser,
  }) async {
    if (!clientId.endsWith('.apps.googleusercontent.com') ||
        clientSecret.isEmpty ||
        !RegExp(r'^\d+$').hasMatch(account) ||
        !RegExp(r'^\d+$').hasMatch(location)) {
      throw const FormatException(
        'Masaüstü OAuth istemci bilgilerini ve sayısal Google hesap/konum kimliklerini girin.',
      );
    }
    final random = Random.secure();
    String randomToken() => base64Url
        .encode(List.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    final verifier = randomToken(), state = randomToken();
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    final callback = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = 'http://127.0.0.1:${callback.port}/google';
    final result = Completer<String?>();
    final subscription = callback.listen((request) async {
      final matched =
          request.uri.path == '/google' &&
          request.uri.queryParameters['state'] == state;
      if (!matched) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        final code = request.uri.queryParameters['code'];
        request.response.headers.contentType = ContentType.text;
        request.response.write(
          code == null
              ? 'Authorization canceled. Return to Nohut POS.'
              : 'Return to Nohut POS to finish setup.',
        );
        if (!result.isCompleted) result.complete(code);
      }
      await request.response.close();
    });
    try {
      await openBrowser(
        Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
          'client_id': clientId,
          'redirect_uri': redirect,
          'response_type': 'code',
          'scope': 'https://www.googleapis.com/auth/business.manage',
          'access_type': 'offline',
          'prompt': 'consent',
          'state': state,
          'code_challenge': challenge,
          'code_challenge_method': 'S256',
        }),
      );
      final code = await result.future.timeout(
        const Duration(minutes: 3),
        onTimeout: () =>
            throw const FormatException('Google yetkilendirme süresi doldu.'),
      );
      if (code == null || code.isEmpty)
        throw const FormatException('Google yetkilendirmesi iptal edildi.');
      final tokens = await _exchange({
        'client_id': clientId,
        'client_secret': clientSecret,
        'code': code,
        'redirect_uri': redirect,
        'grant_type': 'authorization_code',
        'code_verifier': verifier,
      });
      final access = tokens['access_token'] as String?;
      final refresh = tokens['refresh_token'] as String?;
      if (access == null || refresh == null)
        throw const FormatException(
          'Google yetkilendirme anahtarları alınamadı.',
        );
      await _request(
        Uri.https(_api, '/v4/accounts/$account/locations/$location/reviews', {
          'pageSize': '1',
        }),
        bearer: access,
      );
      final session = {
        'clientId': clientId,
        'clientSecret': clientSecret,
        'refresh': refresh,
        'account': account,
        'location': location,
      };
      await _vault.save(session);
      _session = session;
      _cacheAccess(tokens);
      loadError = null;
      if (!_disposed) notifyListeners();
      _seenReviews = null;
      _startPolling();
    } finally {
      await callback.close(force: true);
      await subscription.cancel();
    }
  }

  Future<void> disconnect() async {
    await _vault.clear();
    _pollTimer?.cancel();
    _pollTimer = null;
    _seenReviews = null;
    _session = null;
    _accessToken = null;
    _expires = null;
    loadError = null;
    if (!_disposed) notifyListeners();
  }

  Future<Json> reviews({String? pageToken}) =>
      _get(_api, '$_v4Location/reviews', {
        'pageSize': '50',
        'orderBy': 'updateTime desc',
        if (pageToken != null) 'pageToken': pageToken,
      });

  void _startPolling() {
    if (_disposed || !connected || onNewReviews == null) return;
    _pollTimer ??= Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(_pollReviews()),
    );
    unawaited(_pollReviews());
  }

  Future<void> _pollReviews() async {
    final session = _session;
    if (_polling || session == null) return;
    _polling = true;
    try {
      final result = await reviews();
      if (_disposed || session != _session) return;
      final rows = asMaps(result['reviews']);
      if (_seenReviews case final seen?) {
        final count = rows
            .where(
              (row) =>
                  row['reviewReply'] == null && !seen.contains(row['reviewId']),
            )
            .length;
        if (count > 0) onNewReviews?.call(count);
      }
      _seenReviews = {
        for (final row in rows)
          if (row['reviewId'] is String) row['reviewId'] as String,
      };
    } catch (_) {
      // A transient background failure can be retried at the next interval.
    } finally {
      _polling = false;
    }
  }

  Future<Json> reply(String reviewId, String comment) {
    if (!RegExp(r'^[A-Za-z0-9_\-=]+$').hasMatch(reviewId) ||
        comment.trim().isEmpty ||
        utf8.encode(comment.trim()).length > 4096) {
      throw const FormatException(
        'Geçerli bir yorum ve en fazla 4096 bayt yanıt gerekli.',
      );
    }
    return _authorized(
      Uri.https(_api, '$_v4Location/reviews/$reviewId/reply'),
      method: 'PUT',
      payload: {'comment': comment.trim()},
    );
  }

  Future<Json> profile() => _get(_information, '/v1/$_location', {
    'readMask':
        'title,storefrontAddress,phoneNumbers,websiteUri,regularHours,metadata',
  });
  Future<Json> menu() => _get(_api, '$_v4Location/foodMenus');
  Future<Json> media() => _get(_api, '$_v4Location/media', {'pageSize': '20'});
  Future<Json> posts() =>
      _get(_api, '$_v4Location/localPosts', {'pageSize': '20'});
  Future<Json> permissions() => _get(_accounts, '/v1/$_location/admins');
  Future<Json> notifications() => _get(
    'mybusinessnotifications.googleapis.com',
    '/v1/$_account/notificationSetting',
  );

  Future<Json> performance() {
    final today = DateTime.parse(istanbulDay(DateTime.now()));
    final end = today.subtract(const Duration(days: 1));
    final start = today.subtract(const Duration(days: 30));
    return _get(
      _performance,
      '/v1/$_location:fetchMultiDailyMetricsTimeSeries',
      {
        'dailyMetrics': [
          'BUSINESS_IMPRESSIONS_MOBILE_MAPS',
          'BUSINESS_IMPRESSIONS_DESKTOP_MAPS',
          'BUSINESS_IMPRESSIONS_MOBILE_SEARCH',
          'BUSINESS_IMPRESSIONS_DESKTOP_SEARCH',
          'CALL_CLICKS',
          'WEBSITE_CLICKS',
          'BUSINESS_DIRECTION_REQUESTS',
        ],
        for (final (key, day) in [('startDate', start), ('endDate', end)]) ...{
          'dailyRange.$key.year': '${day.year}',
          'dailyRange.$key.month': '${day.month}',
          'dailyRange.$key.day': '${day.day}',
        },
      },
    );
  }

  Future<Json> searchTerms() {
    final today = DateTime.parse(istanbulDay(DateTime.now()));
    final day = DateTime(today.year, today.month, 0);
    return _get(
      _performance,
      '/v1/$_location/searchkeywords/impressions/monthly',
      {
        for (final bound in ['startMonth', 'endMonth']) ...{
          'monthlyRange.$bound.year': '${day.year}',
          'monthlyRange.$bound.month': '${day.month}',
        },
        'pageSize': '25',
      },
    );
  }

  Future<Json> _get(String host, String path, [Map<String, dynamic>? params]) =>
      _authorized(Uri.https(host, path, params));

  Future<Json> _authorized(
    Uri uri, {
    String method = 'GET',
    Json? payload,
  }) async {
    final session = _session;
    if (session == null)
      throw const FormatException('Önce Google hesabını bağlayın.');
    if (_accessToken == null || _expires?.isAfter(DateTime.now()) != true) {
      _cacheAccess(
        await _exchange({
          'client_id': session['clientId'],
          'client_secret': session['clientSecret'],
          'refresh_token': session['refresh'],
          'grant_type': 'refresh_token',
        }),
      );
    }
    return _request(
      uri,
      method: method,
      bearer: _accessToken,
      payload: payload,
    );
  }

  void _cacheAccess(Json tokens) {
    _accessToken = tokens['access_token'] as String?;
    if (_accessToken == null)
      throw const FormatException('Google erişim anahtarı alınamadı.');
    _expires = DateTime.now().add(
      Duration(seconds: (tokens['expires_in'] as int? ?? 3600) - 60),
    );
  }

  Future<Json> _exchange(Map<String, String> fields) => _request(
    Uri.https(_tokenHost, '/token'),
    method: 'POST',
    form: Uri(queryParameters: fields).query,
  );

  Future<Json> _request(
    Uri uri, {
    String method = 'GET',
    String? bearer,
    Json? payload,
    String? form,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      if (bearer != null)
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      if (payload != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(payload)));
      }
      if (form != null) {
        request.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
        );
        request.add(ascii.encode(form));
      }
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (response.statusCode == 401) _accessToken = null;
        final cause = switch (response.statusCode) {
          400 || 401 => 'Yetkilendirme veya kimlik bilgilerini kontrol edin.',
          403 => 'Proje API onayını ve işletme hesabı erişimini kontrol edin.',
          404 => 'İşletme konumu veya bu özelliğe ait kayıt bulunamadı.',
          429 =>
            'Google istek sınırına ulaşıldı. Bir süre sonra yeniden deneyin.',
          _ => 'Daha sonra tekrar deneyin.',
        };
        throw FormatException('Google API ${response.statusCode} · $cause');
      }
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 20));
      return body.isEmpty
          ? {}
          : (jsonDecode(body) as Map).cast<String, dynamic>();
    } finally {
      client.close(force: true);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    super.dispose();
  }
}
