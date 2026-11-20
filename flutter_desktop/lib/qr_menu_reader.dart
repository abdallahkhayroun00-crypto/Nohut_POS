import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef PublicJsonFetcher = Future<String> Function(Uri url);

class PublishedProductPrice {
  const PublishedProductPrice({
    required this.id,
    required this.category,
    required this.name,
    required this.priceTl,
    this.active = true,
    this.available = true,
    this.legacyKey,
    required this.names,
    required this.displayNames,
    required this.descriptions,
    this.image,
  });
  final int id;
  final String category;
  final String name;
  final double priceTl;
  final bool active, available;
  final String? legacyKey;
  final Map<String, String> names, displayNames, descriptions;
  final String? image;
}

class PublishedCategory {
  const PublishedCategory({required this.id, required this.names, required this.descriptions, this.active=true, this.order=0});
  final String id;
  final bool active;
  final int order;
  final Map<String, String> names, descriptions;
}

class PublishedCampaign {
  const PublishedCampaign({
    required this.id, required this.active, required this.priceTl,
    required this.title, required this.description, required this.items,
    required this.poster, required this.thumbnail, this.startsAt, this.endsAt,
  });
  final String id;
  final bool active;
  final double priceTl;
  final Map<String, String> title, description;
  final List<Map<String, String>> items;
  final String poster, thumbnail;
  final DateTime? startsAt, endsAt;
  bool isVisibleAt(DateTime now) => active &&
    (startsAt == null || !now.isBefore(startsAt!)) &&
    (endsAt == null || now.isBefore(endsAt!));
}

class PublishedQrMenu {
  const PublishedQrMenu({
    required this.products, required this.categories, required this.campaigns,
    required this.retrievedAtUtc,
  });
  final List<PublishedProductPrice> products;
  final List<PublishedCategory> categories;
  final List<PublishedCampaign> campaigns;
  final DateTime retrievedAtUtc;
}

/// Stable product metadata: catalog-v1; latest authoritative price/offer: CMS.
/// All three files are parsed before any SQLite state changes are considered.
class QrMenuReader {
  QrMenuReader({Uri? baseUrl, PublicJsonFetcher? fetcher})
      : baseUrl = baseUrl ?? Uri.parse('https://nohutfalafel.github.io/qr-menu/'),
        _fetcher = fetcher ?? _fetchPublicJson;
  final Uri baseUrl;
  final PublicJsonFetcher _fetcher;

  Future<PublishedQrMenu> readPublishedMenu() async {
    if (baseUrl.scheme != 'https' || !baseUrl.path.endsWith('/') ||
        baseUrl.userInfo.isNotEmpty || baseUrl.hasQuery || baseUrl.hasFragment) {
      throw const FormatException('QR URL must be an HTTPS directory.');
    }
    final managed = await _readManaged();
    if (managed != null) return managed;
    final catalog = jsonDecode(await _fetcher(baseUrl.resolve('cms/catalog-v1.json')));
    final cms = jsonDecode(await _fetcher(baseUrl.resolve('cms/menu-prices.json')));
    final campaigns = await _fetcher(baseUrl.resolve('cms/campaigns.json'));

    if (catalog is! Map || catalog['schemaVersion'] != 1 ||
        catalog['currency'] != 'TRY' || catalog['source'] != 'nohutfalafel/qr-menu' ||
        catalog['products'] is! List || catalog['categories'] is! List ||
        cms is! Map) {
      throw const FormatException('Unsupported catalog or CMS format.');
    }
    final livePrices = <String, (String, double, bool)>{};
    for (final group in cms.entries) {
      if (group.key is! String || group.value is! List) {
        throw const FormatException('Invalid CMS price group.');
      }
      for (final item in group.value as List) {
        if (item is! Map || item['name'] is! String ||
            (item['name'] as String).trim().isEmpty ||
            livePrices.containsKey(item['name'])) {
          throw const FormatException('Duplicate CMS product name.');
        }
        if (item['active'] != null && item['active'] is! bool) {
          throw const FormatException('Invalid CMS product visibility flag.');
        }
        livePrices[item['name'] as String] = (
          group.key as String,
          readPrice(item['price']),
          item['active'] != false,
        );
      }
    }

    final categories = <PublishedCategory>[], categoryIds = <String>{};
    for (final item in catalog['categories'] as List) {
      if (item is! Map || item['id'] is! String ||
          !categoryIds.add(item['id'] as String)) {
        throw const FormatException('Invalid catalog category.');
      }
      categories.add(PublishedCategory(
        id: item['id'] as String,
        names: readLanguages(item['name'], requiredText:true),
        descriptions: readLanguages(item['description']),
      ));
    }
    if (categories.length < 8 || !categoryIds.contains('all')) {
      throw const FormatException('Incomplete QR categories.');
    }

    final products = <PublishedProductPrice>[], ids = <int>{}, names = <String>{};
    for (final item in catalog['products'] as List) {
      if (item is! Map || item['id'] is! int || (item['id'] as int) < 0 ||
          (item['id'] as int) > 1000000 || !ids.add(item['id'] as int) ||
          item['category'] is! String || item['category'] == 'all' ||
          !categoryIds.contains(item['category'])) {
        throw const FormatException('Duplicate/invalid stable product ID.');
      }
      final localized = readLanguages(item['name'],requiredText:true);
      final name = localized['tr']!;
      final price = livePrices.remove(name);
      if (!names.add(name) || price == null || price.$1 != item['category']) {
        throw FormatException('Unmatched catalog/CMS item: '+name);
      }
      products.add(PublishedProductPrice(
        id: item['id'] as int, category: item['category'] as String,
        name:name, priceTl:price.$2, active:price.$3, names:localized,
        displayNames:readLanguages(item['displayName'],requiredText:true),
        descriptions:readLanguages(item['description']),
        image:readProductImage(item['image']),
      ));
    }
    // Fail closed when a CMS edit added a name before catalog IDs were published.
    if (products.length < 40 || products.length > 500 || livePrices.isNotEmpty) {
      throw const FormatException('Incomplete or stale QR catalog; no changes applied.');
    }
    return PublishedQrMenu(
      products:List.unmodifiable(products),categories:List.unmodifiable(categories),
      campaigns:parseCampaigns(campaigns),retrievedAtUtc:DateTime.now().toUtc(),
    );
  }


  /// Keep the working public catalog as source of truth until the publisher
  /// has finished its first commit and enabled the versioned status marker.
  /// GitHub Pages can report 503 (rather than 404) for a missing optional file.
  /// After enabling, never silently fall back if the managed catalog is broken.
  Future<PublishedQrMenu?> _readManaged() async {
    final String statusRaw;
    try {
      statusRaw=await _fetcher(baseUrl.resolve('cms/pos-managed-status.json'));
    } on HttpException catch(e) {
      if(e.message.contains('404')||e.message.contains('503'))return null;
      rethrow;
    }
    final status=jsonDecode(statusRaw);
    if(status is! Map||status['schemaVersion']!=1||
       status['enabled'] is! bool) {
      throw const FormatException('QR yönetilen katalog durum dosyası geçersiz.');
    }
    if(status['enabled']!=true)return null;
    final raw=await _fetcher(baseUrl.resolve('cms/pos-managed-menu.json'));
    final decoded=jsonDecode(raw);
    if(decoded is! Map||decoded['schemaVersion']!=1||
       decoded['source']!='nohutfalafel/qr-menu'||
       decoded['currency']!='TRY'||decoded['products'] is! List||
       decoded['categories'] is! List||decoded['campaigns'] is! List) {
      throw const FormatException('QR yönetilen katalog biçimi geçersiz.');
    }
    final categoryIds=<String>{},categories=<PublishedCategory>[];
    for(final c in decoded['categories'] as List){
      if(c is! Map||c['id'] is! String||
          !categoryIds.add(c['id'] as String)||
          c['active'] is! bool||c['order'] is! int) {
        throw const FormatException('QR kategori kaydı geçersiz.');
      }
      categories.add(PublishedCategory(
        id:c['id'] as String,
        names:readLanguages(c['name'],requiredText:true),
        descriptions:readLanguages(c['description']),
        active:c['active'] as bool,order:c['order'] as int,
      ));
    }
    final ids=<int>{},names=<String>{},products=<PublishedProductPrice>[];
    for(final p in decoded['products'] as List){
      if(p is! Map||p['id'] is! int||p['category'] is! String||
         !categoryIds.contains(p['category'])||p['category']=='all'||
         !ids.add(p['id'] as int)||p['active'] is! bool||
         p['available'] is! bool||p['legacyKey'] is! String){
        throw const FormatException('QR yönetilen ürün kimliği geçersiz.');
      }
      final namesLocalized=readLanguages(p['name'],requiredText:true);
      if(!names.add(namesLocalized['tr']!)||
         p['price'] is! num||
         !((p['price'] as num).toDouble().isFinite)||
         (p['price'] as num)<0||(p['price'] as num)>100000){
        throw const FormatException('QR ürün adı/fiyatı geçersiz.');
      }
      products.add(PublishedProductPrice(
        id:p['id'] as int,category:p['category'] as String,
        name:namesLocalized['tr']!,priceTl:(p['price'] as num).toDouble(),
        names:namesLocalized,
        displayNames:readLanguages(p['displayName'],requiredText:true),
        descriptions:readLanguages(p['description']),
        active:p['active'] as bool,available:p['available'] as bool,
        legacyKey:p['legacyKey'] as String,
        image:readProductImage(p['image']),
      ));
    }
    if(products.length<40||products.length>500||
       categories.length<8||!categoryIds.contains('all')){
      throw const FormatException('QR yönetilen katalog eksik.');
    }
    return PublishedQrMenu(
      products:List.unmodifiable(products),
      categories:List.unmodifiable(categories),
      campaigns:parseCampaigns(jsonEncode(decoded['campaigns'])),
      retrievedAtUtc:DateTime.now().toUtc(),
    );
  }

  static String? readProductImage(dynamic value) {
    if (value == null) return null;
    if (value is! String || !RegExp(r'^assets/[a-zA-Z0-9_./-]+\.(?:png|jpg|jpeg|webp|svg)$')
        .hasMatch(value) || value.contains('..') || value.contains('//')) {
      throw const FormatException('Invalid product image path.');
    }
    return value;
  }

  static List<PublishedCampaign> parseCampaigns(String source) {
    final decoded=jsonDecode(source);
    if (decoded is! List || decoded.length > 200) {
      throw const FormatException('Invalid campaigns.');
    }
    final result=<PublishedCampaign>[], ids=<String>{};
    for(final item in decoded) {
      if(item is! Map || item['id'] is! String ||
          !RegExp(r'^[a-z0-9-]+$').hasMatch(item['id'] as String) ||
          !ids.add(item['id'] as String) || item['active'] is! bool) {
        throw const FormatException('Invalid/duplicate campaign.');
      }
      final rawItems=item['items'];
      if(rawItems is! List || rawItems.isEmpty || rawItems.length > 100) {
        throw const FormatException('Invalid campaign items.');
      }
      final start=readDate(item['startsAt']),end=readDate(item['endsAt']);
      if(start != null && end != null && !start.isBefore(end)) {
        throw const FormatException('Invalid campaign dates.');
      }
      final poster=readCampaignImage(item['poster']);
      result.add(PublishedCampaign(
        id:item['id'] as String,active:item['active'] as bool,
        priceTl:readPrice(item['price']),
        title:readLanguages(item['title'],requiredText:true),
        description:readLanguages(item['description']),
        items:List.unmodifiable(rawItems.map((x)=>readLanguages(x,requiredText:true))),
        poster:poster,
        thumbnail:item['thumbnail']==null?poster:readCampaignImage(item['thumbnail']),
        startsAt:start,endsAt:end,
      ));
    }
    return List.unmodifiable(result);
  }

  static double readPrice(dynamic value) {
    if(value is! num || !value.isFinite || value < 0 || value > 100000) {
      throw const FormatException('Invalid QR price.');
    }
    return value.toDouble();
  }
  static Map<String,String> readLanguages(dynamic value,{bool requiredText=false}) {
    if(value is! Map)throw const FormatException('Missing localization.');
    final result=<String,String>{};
    for(final locale in const ['tr','en','ar']){
      final x=value[locale];
      if(x is! String || (requiredText && x.trim().isEmpty)) {
        throw const FormatException('Missing localized text.');
      }
      result[locale]=x.trim();
    }
    return Map.unmodifiable(result);
  }
  static String readCampaignImage(dynamic value) {
    if(value is! String ||
      !RegExp(r'^assets/campaigns/[a-zA-Z0-9_./-]+\.(?:png|jpg|jpeg|webp)$')
        .hasMatch(value) || value.contains('..')) {
      throw const FormatException('Invalid QR campaign image.');
    }
    return value;
  }
  static DateTime? readDate(dynamic value) {
    if(value==null || value=='')return null;
    if(value is! String)throw const FormatException('Invalid campaign date.');
    final parsed=DateTime.tryParse(value);
    if(parsed==null || !RegExp(r'(?:Z|[+-][0-9]{2}:[0-9]{2})$').hasMatch(value)) {
      throw const FormatException('Campaign date requires timezone.');
    }
    return parsed;
  }
  static Future<String> _fetchPublicJson(Uri url) async {
    if(url.scheme!='https')throw const FormatException('HTTPS required.');
    const timeout=Duration(seconds:10),maxBytes=1024*1024;
    final client=HttpClient()..connectionTimeout=const Duration(seconds:6);
    try{
      final request=await client.getUrl(url).timeout(timeout);
      request.followRedirects=false;
      request.headers.set(HttpHeaders.acceptHeader,'application/json');
      final response=await request.close().timeout(timeout);
      if(response.statusCode!=HttpStatus.ok) {
        throw HttpException('QR HTTP '+response.statusCode.toString(),uri:url);
      }
      if(response.contentLength>maxBytes)throw const FormatException('QR JSON too large.');
      final bytes=<int>[];
      await for(final chunk in response.timeout(timeout)){
        bytes.addAll(chunk);
        if(bytes.length>maxBytes)throw const FormatException('QR JSON too large.');
      }
      return utf8.decode(bytes);
    }finally{client.close(force:true);}
  }
}
