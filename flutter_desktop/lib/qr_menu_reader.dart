import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Fetches only PUBLIC QR-menu content. It never reads or writes POS orders,
/// payments, the local SQLite database, or private GitHub credentials.
typedef PublicJsonFetcher = Future<String> Function(Uri url);

class PublishedProductPrice {
  const PublishedProductPrice({
    required this.category,
    required this.name,
    required this.priceTl,
  });

  final String category;
  final String name;
  final double priceTl;
}

class PublishedCampaign {
  const PublishedCampaign({
    required this.id,
    required this.active,
    required this.priceTl,
    required this.title,
    required this.description,
    required this.items,
    required this.poster,
    required this.thumbnail,
    this.startsAt,
    this.endsAt,
  });

  final String id;
  final bool active;
  final double priceTl;
  final Map<String, String> title;
  final Map<String, String> description;
  final List<Map<String, String>> items;
  final String poster;
  final String thumbnail;
  final DateTime? startsAt;
  final DateTime? endsAt;

  bool isVisibleAt(DateTime now) =>
      active &&
      (startsAt == null || !now.isBefore(startsAt!)) &&
      (endsAt == null || now.isBefore(endsAt!));
}

class PublishedQrMenu {
  const PublishedQrMenu({
    required this.products,
    required this.campaigns,
    required this.retrievedAtUtc,
  });

  final List<PublishedProductPrice> products;
  final List<PublishedCampaign> campaigns;
  final DateTime retrievedAtUtc;
}

/// Phase 1: read and validate the website's existing structured public JSON.
///
/// This is deliberately NOT an automatic import: a local POS catalog can have
/// owner-edited prices and persistent product IDs. A later, explicit
/// reconciliation step must review changes before updating SQLite.
///
/// cms/menu-prices.json currently contains category/name/price only.
/// Ingredients, localized names, and product images live in site JavaScript;
/// they need a versioned JSON catalog before safe full-menu synchronization.
class QrMenuReader {
  QrMenuReader({Uri? baseUrl, PublicJsonFetcher? fetcher})
      : baseUrl = baseUrl ??
            Uri.parse('https://nohutfalafel.github.io/qr-menu/'),
        _fetcher = fetcher ?? _fetchPublicJson;

  final Uri baseUrl;
  final PublicJsonFetcher _fetcher;

  Future<PublishedQrMenu> readPublishedMenu() async {
    if (baseUrl.scheme != 'https' || !baseUrl.path.endsWith('/')) {
      throw const FormatException(
        'QR menu base URL must use HTTPS and end with a slash.',
      );
    }

    final pricesJson =
        await _fetcher(baseUrl.resolve('cms/menu-prices.json'));
    final campaignsJson =
        await _fetcher(baseUrl.resolve('cms/campaigns.json'));

    return PublishedQrMenu(
      products: _parsePrices(pricesJson),
      campaigns: _parseCampaigns(campaignsJson),
      retrievedAtUtc: DateTime.now().toUtc(),
    );
  }

  static List<PublishedProductPrice> _parsePrices(String jsonText) {
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map) {
      throw const FormatException('QR price data must be a category object.');
    }

    final products = <PublishedProductPrice>[];
    final seen = <String>{};

    for (final entry in decoded.entries) {
      final category = entry.key;
      final items = entry.value;
      if (category is! String ||
          category.trim().isEmpty ||
          items is! List) {
        throw const FormatException('Invalid QR product category.');
      }

      for (final item in items) {
        if (item is! Map) {
          throw const FormatException('Invalid QR product entry.');
        }
        final name = item['name'];
        if (name is! String ||
            name.trim().isEmpty ||
            !seen.add(name.trim())) {
          throw const FormatException('Missing or duplicate QR product name.');
        }
        products.add(PublishedProductPrice(
          category: category,
          name: name.trim(),
          priceTl: _readPrice(item['price']),
        ));
      }
    }

    if (products.isEmpty || products.length > 1000) {
      throw const FormatException('Unexpected QR product count.');
    }
    return List.unmodifiable(products);
  }

  static List<PublishedCampaign> _parseCampaigns(String jsonText) {
    final decoded = jsonDecode(jsonText);
    if (decoded is! List || decoded.length > 200) {
      throw const FormatException('Invalid QR campaigns list.');
    }

    final campaigns = <PublishedCampaign>[];
    final seen = <String>{};
    for (final item in decoded) {
      if (item is! Map) {
        throw const FormatException('Invalid QR campaign entry.');
      }
      final id = item['id'];
      if (id is! String ||
          !RegExp(r'^[a-z0-9-]+$').hasMatch(id) ||
          !seen.add(id) ||
          item['active'] is! bool) {
        throw const FormatException('Invalid or duplicate campaign ID.');
      }
      final poster = _readAssetPath(item['poster']);
      final thumbnail = item['thumbnail'] == null
          ? poster
          : _readAssetPath(item['thumbnail']);
      final startsAt = _readOptionalDate(item['startsAt']);
      final endsAt = _readOptionalDate(item['endsAt']);
      if (startsAt != null &&
          endsAt != null &&
          !startsAt.isBefore(endsAt)) {
        throw const FormatException('Invalid campaign date range.');
      }
      final rawItems = item['items'];
      if (rawItems is! List || rawItems.isEmpty || rawItems.length > 100) {
        throw const FormatException('Invalid campaign items.');
      }
      campaigns.add(PublishedCampaign(
        id: id,
        active: item['active'] as bool,
        priceTl: _readPrice(item['price']),
        title: _readLanguages(item['title'], requiredText: true),
        description: _readLanguages(item['description']),
        items: List.unmodifiable(rawItems.map(
          (row) => _readLanguages(row, requiredText: true),
        )),
        poster: poster,
        thumbnail: thumbnail,
        startsAt: startsAt,
        endsAt: endsAt,
      ));
    }
    return List.unmodifiable(campaigns);
  }

  static double _readPrice(dynamic value) {
    if (value is! num ||
        !value.isFinite ||
        value < 0 ||
        value > 100000) {
      throw const FormatException('Invalid QR menu price.');
    }
    return value.toDouble();
  }

  static Map<String, String> _readLanguages(
    dynamic value, {
    bool requiredText = false,
  }) {
    if (value is! Map) {
      if (!requiredText && value == null) {
        return const {'tr': '', 'en': '', 'ar': ''};
      }
      throw const FormatException('Missing localized content.');
    }
    final result = <String, String>{};
    for (final language in const ['tr', 'en', 'ar']) {
      final text = value[language];
      if (text is! String || (requiredText && text.trim().isEmpty)) {
        throw const FormatException('Invalid localized content.');
      }
      result[language] = text.trim();
    }
    return Map.unmodifiable(result);
  }

  static String _readAssetPath(dynamic value) {
    if (value is! String ||
        !value.startsWith('assets/campaigns/') ||
        value.contains('..') ||
        value.contains('?') ||
        value.contains('#')) {
      throw const FormatException('Invalid QR campaign asset path.');
    }
    return value;
  }

  static DateTime? _readOptionalDate(dynamic value) {
    if (value == null || value == '') return null;
    if (value is! String) {
      throw const FormatException('Invalid QR campaign date.');
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null || !RegExp(r'(?:Z|[+-][0-9]{2}:[0-9]{2})$')
        .hasMatch(value)) {
      throw const FormatException('QR campaign dates need a timezone.');
    }
    return parsed;
  }

  static Future<String> _fetchPublicJson(Uri url) async {
    if (url.scheme != 'https') {
      throw const FormatException('Public menu fetch requires HTTPS.');
    }
    const timeout = Duration(seconds: 10);
    const maxBytes = 1024 * 1024;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6);
    try {
      final request = await client.getUrl(url).timeout(timeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Public QR menu returned HTTP ' + response.statusCode.toString(),
          uri: url,
        );
      }
      if (response.contentLength > maxBytes) {
        throw const FormatException('Public QR JSON is too large.');
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > maxBytes) {
          throw const FormatException('Public QR JSON is too large.');
        }
      }
      return utf8.decode(bytes);
    } finally {
      client.close(force: true);
    }
  }
}
