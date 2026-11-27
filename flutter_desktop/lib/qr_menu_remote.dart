/// QR menu management from phones (relays 7226917068, 7226936601). Windows
/// stays authoritative: phones never hold a publisher key or GitHub token and
/// never call the publisher. They read and edit the same offline draft the
/// Windows QR Menü Yönetimi page uses, through authenticated LAN commands that
/// check each `menu.*` grant on the server, are bound to the draft they were
/// based on (stale edits are refused, never merged blindly) and are audited.
/// Publishing, photo upload and POS sync are asked of Windows, which does them
/// with its own key ([QrMenuRemoteService]) after the phone's explicit review.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'pos_logic.dart';
import 'pos_store.dart';
import 'qr_menu_draft.dart';
import 'qr_publisher_client.dart';

const qrMenuAuditKey = 'qrMenuAudit';
const _draftKey = 'qrPublisherDraft', _baseKey = 'qrPublisherDraftSourceSnapshot',
    _revisionKey = 'qrPublisherDraftRevision', _pendingKey = 'qrPublisherPendingPublish';

/// Edit operations a phone may hold (permission catalogue `menu.*`).
const qrMenuEditOps = ['menu.product.edit', 'menu.price.edit', 'menu.category.edit',
  'menu.campaign.edit', 'menu.stock.toggle', 'menu.qr.publish'];

class QrMenuConflict implements Exception {
  const QrMenuConflict([this.message = 'Menü taslağı başka bir cihazda değişti. Yenileyip tekrar deneyin.']);
  final String message;
  @override
  String toString() => message;
}

/// Fingerprint of the draft a phone saw; a write must name it.
String qrDraftStamp(Object? draft) =>
    sha256.convert(utf8.encode(jsonEncode(draft))).toString().substring(0, 16);

Json? _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : null;

Json? _currentDraft(Json state) => _map(state[_draftKey]) ?? _map(state[_baseKey]);

/// What a phone sees: the shared draft, what differs from the published
/// catalog, and which edits this person may make. Never a token or key.
/// [link] is Windows' publishing chain as seen right now (`ready`, `no_key`,
/// `service_down`); null when this server cannot publish for phones.
Json qrMenuView(Json state, {required bool Function(String op) can, String? link}) {
  final draft = _currentDraft(state), base = _map(state[_baseKey]);
  final permissions = {for (final op in qrMenuEditOps) op: can(op)};
  if (draft == null) {
    return {
      'available': false,
      'can': permissions,
      'message': 'Menü henüz Windows’ta yüklenmedi. Windows › QR Menü Yönetimi sayfasını '
          'açıp GitHub’a bağlanınca burada görünür.',
    };
  }
  final revision = state[_revisionKey]?.toString();
  final changes = diffCatalog(base, draft);
  Json pick(Object? row, List<String> keys) =>
      {for (final k in keys) if (row is Map && row.containsKey(k)) k: row[k]};
  return {
    'available': true,
    'stamp': qrDraftStamp(draft),
    'revision': revision,
    'revisionLabel': qrRevisionLabel(revision),
    'offline': revision == null,
    'pendingPublish': state[_pendingKey] is Map,
    'can': permissions,
    'publish': link == null ? 'windows' : 'here',
    if (link != null) 'link': link,
    'changes': [for (final c in changes) {'list': c.list, 'id': c.id, 'label': c.label, 'detail': c.detail}],
    'catalog': {
      'categories': [for (final c in asMaps(draft['categories']))
        pick(c, ['id', 'name', 'description', 'active', 'order'])],
      'products': [for (final p in asMaps(draft['products']))
        pick(p, ['id', 'category', 'name', 'displayName', 'description', 'price', 'available', 'active', 'image', 'order'])],
      'campaigns': [for (final c in asMaps(draft['campaigns']))
        pick(c, ['id', 'title', 'description', 'price', 'active', 'poster', 'thumbnail'])],
    },
  };
}

Map<String, String> _texts(Object? raw, {required bool required, required String what}) {
  final m = raw is Map ? raw : const {};
  final out = {for (final l in ['tr', 'en', 'ar']) l: '${m[l] ?? ''}'.trim()};
  if (out.values.any((v) => v.length > 2500)) throw FormatException('$what çok uzun.');
  if (required && out.values.any((v) => v.isEmpty)) throw FormatException('$what: TR / EN / AR gerekli.');
  return out;
}

num _price(Object? cents) {
  if (cents is! int || cents < 0 || cents > 10000000) throw const FormatException('Fiyat geçersiz.');
  return fromCents(cents);
}

final _asset = RegExp(r'^assets/[A-Za-z0-9_./-]+\.(png|jpg|jpeg|webp)$');
String? _image(Object? raw) {
  final v = '${raw ?? ''}'.trim();
  if (v.isEmpty) return null;
  if (!_asset.hasMatch(v) || v.contains('..')) throw const FormatException('Görsel yolu geçersiz (assets/...).');
  return v;
}

/// Applies one phone edit to the shared draft. [can] answers the server-side
/// permission check for the signed-in person; the phone's claims are ignored.
Json applyQrMenuCommand(PosStore store, Json payload,
    {required bool Function(String op) can, required String actor, int? actorId, DateTime? now}) {
  final requestId = payload['requestId'];
  if (requestId is! String) throw const FormatException('İstek kimliği gerekli.');
  final at = (now ?? DateTime.now()).toUtc().toIso8601String();
  return store.command('qr_$requestId', payload, (s) {
    if (s[_pendingKey] is Map) {
      throw const QrMenuConflict('Windows’ta bir yayının sonucu doğrulanıyor. Bitince tekrar deneyin.');
    }
    final base = _map(s[_baseKey]);
    final current = _currentDraft(s);
    if (base == null || current == null) {
      throw const FormatException('Menü henüz Windows’ta yüklenmedi.');
    }
    if (payload['expectedStamp'] != qrDraftStamp(current)) throw const QrMenuConflict();
    final draft = copyJson(current);
    final action = '${payload['action'] ?? ''}';
    void need(String op) {
      if (!can(op)) throw QrMenuForbidden(op);
    }
    List rows(String list) => (draft[list] ??= <dynamic>[]) as List;
    Map find(String list, Object? id) {
      final row = rows(list).whereType<Map>().where((r) => r['id'] == id).firstOrNull;
      if (row == null) throw const QrMenuConflict('Kayıt bulunamadı. Yenileyin.');
      return row;
    }
    String list = 'products';
    Object? id = payload['id'];
    switch (action) {
      case 'set_price':
        need('menu.price.edit');
        find('products', id)['price'] = _price(payload['priceCents']);
      case 'set_stock':
        need('menu.stock.toggle');
        if (payload['available'] is! bool) throw const FormatException('Stok değeri geçersiz.');
        find('products', id)['available'] = payload['available'];
      case 'set_visible':
        list = '${payload['list']}';
        need(switch (list) {
          'products' => 'menu.product.edit',
          'categories' => 'menu.category.edit',
          'campaigns' => 'menu.campaign.edit',
          _ => throw const FormatException('Liste geçersiz.'),
        });
        if (payload['active'] is! bool) throw const FormatException('Görünürlük değeri geçersiz.');
        if (list == 'categories' && id == 'all') throw const FormatException('“Tümü” kategorisi gizlenemez.');
        find(list, id)['active'] = payload['active'];
      case 'set_image':
        need('menu.product.edit');
        find('products', id)['image'] = _image(payload['image']);
      case 'save_product':
        need('menu.product.edit');
        final names = _texts(payload['name'], required: true, what: 'Ürün adı');
        final category = '${payload['category'] ?? ''}';
        if (category == 'all' || !rows('categories').whereType<Map>().any((c) => c['id'] == category)) {
          throw const FormatException('Kategori bulunamadı.');
        }
        final products = rows('products');
        if (products.whereType<Map>().any((p) => p['id'] != id &&
            qrText(p['name']).trim().toLowerCase() == names['tr']!.toLowerCase())) {
          throw const FormatException('Bu Türkçe ürün adı zaten mevcut.');
        }
        final price = _price(payload['priceCents']);
        final Map row;
        if (id == null) {
          need('menu.price.edit'); // a new product's price is a price decision
          final next = products.whereType<Map>().fold<int>(0, (m, p) =>
              p['id'] is int && (p['id'] as int) >= m ? (p['id'] as int) + 1 : m);
          id = next;
          row = {'id': next, 'legacyKey': 'pos-id-$next', 'active': true, 'available': true,
            'order': products.length};
          products.add(row);
        } else {
          row = find('products', id);
          if (row['price'] != price) need('menu.price.edit');
        }
        row['name'] = names;
        row['category'] = category;
        row['price'] = price;
        final description = _texts(payload['description'], required: false, what: 'Açıklama');
        if (row.containsKey('description') || description.values.any((v) => v.isNotEmpty)) {
          row['description'] = description;
        }
        if (payload.containsKey('image')) {
          final image = _image(payload['image']);
          if (image != null || row.containsKey('image')) row['image'] = image;
        }
      case 'save_category':
        need('menu.category.edit');
        list = 'categories';
        final names = _texts(payload['name'], required: true, what: 'Kategori adı');
        final description = _texts(payload['description'], required: false, what: 'Açıklama');
        if (payload['isNew'] == true) {
          final code = '${payload['id'] ?? ''}';
          if (!RegExp(r'^[a-z][a-z0-9-]{0,49}$').hasMatch(code)) {
            throw const FormatException('Kategori kodu: küçük Latin harfleri ve rakamlar.');
          }
          if (rows('categories').whereType<Map>().any((c) => c['id'] == code)) {
            throw const FormatException('Kategori kodu zaten kullanılıyor.');
          }
          id = code;
          rows('categories').add({'id': code, 'active': true, 'order': rows('categories').length,
            'name': names, if (description.values.any((v) => v.isNotEmpty)) 'description': description});
        } else {
          final row = find('categories', id);
          row['name'] = names;
          if (row.containsKey('description') || description.values.any((v) => v.isNotEmpty)) {
            row['description'] = description;
          }
        }
      case 'save_campaign':
        need('menu.campaign.edit');
        list = 'campaigns';
        final title = _texts(payload['title'], required: true, what: 'Kampanya başlığı');
        final description = _texts(payload['description'], required: false, what: 'Açıklama');
        final price = _price(payload['priceCents']);
        if (payload['isNew'] == true) {
          final code = '${payload['id'] ?? ''}';
          if (!RegExp(r'^[a-z0-9-]{1,70}$').hasMatch(code)) throw const FormatException('Kampanya kodu geçersiz.');
          if (rows('campaigns').whereType<Map>().any((c) => c['id'] == code)) {
            throw const FormatException('Kampanya kodu zaten kullanılıyor.');
          }
          final poster = _image(payload['poster']), thumb = _image(payload['thumbnail']);
          if (poster == null || thumb == null) {
            throw const FormatException('Yeni kampanya için poster ve küçük görsel yolu gerekli (assets/...).');
          }
          id = code;
          rows('campaigns').add({'id': code, 'active': false, 'items': <dynamic>[], 'title': title,
            'description': description, 'price': price, 'poster': poster, 'thumbnail': thumb});
        } else {
          final row = find('campaigns', id);
          row['title'] = title;
          row['description'] = description;
          row['price'] = price;
        }
      default:
        throw const FormatException('Menü işlemi desteklenmiyor.');
    }
    final problems = validateQrCatalog(draft);
    if (problems.isNotEmpty) throw FormatException(problems.first);
    if (diffCatalog(base, draft).isEmpty) {
      s.remove(_draftKey);
    } else {
      s[_draftKey] = draft;
    }
    final audit = (s[qrMenuAuditKey] ??= <dynamic>[]) as List;
    audit.add({'at': at, 'by': actor, 'byId': actorId, 'action': action, 'list': list, 'id': id});
    if (audit.length > 200) audit.removeRange(0, audit.length - 200);
    return {'ok': true, 'id': id, 'stamp': qrDraftStamp(_currentDraft(s))};
  });
}

class QrMenuForbidden implements Exception {
  const QrMenuForbidden(this.operation);
  final String operation;
  @override
  String toString() => 'Bu işlem için yetkiniz yok ($operation).';
}

/// Publishing, image upload and POS sync for phones, done by Windows with
/// Windows' own publisher key (owner decision 2026-11-27: Personel and
/// Yönetici have full QR menu access). The phone names the draft it reviewed;
/// Windows publishes exactly that draft, bound to its GitHub revision, records
/// the attempt first and never retries blindly.
class QrMenuRemoteService {
  QrMenuRemoteService(this.store, {required this.publisher, required this.endpoint, this.syncPos, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;
  final PosStore store;
  final QrPublisherClient Function() publisher;
  final String Function() endpoint;
  final Future<void> Function()? syncPos;
  final DateTime Function() _clock;
  bool _publishing = false;

  void _audit(Json s, String action, String actor, int? actorId, [Json extra = const {}]) {
    final audit = (s[qrMenuAuditKey] ??= <dynamic>[]) as List;
    audit.add({'at': _clock().toUtc().toIso8601String(), 'by': actor, 'byId': actorId, 'action': action,
      'list': 'catalog', 'id': extra['commit'] ?? extra['revision']});
    if (audit.length > 200) audit.removeRange(0, audit.length - 200);
  }

  /// Applies [change] to the latest state. A concurrent POS write (order,
  /// payment) moves the revision: re-read and re-apply, never drop it (QA-20).
  void _write(void Function(Json s) change) {
    for (var attempt = 0; attempt < 5; attempt++) {
      final snap = store.read();
      final next = copyJson(snap.data);
      change(next);
      if (store.replace(next, snap.revision).ok) return;
    }
    throw const QrMenuConflict('Menü durumu kaydedilemedi; Windows başka bir işlem yazıyor. Yeniden deneyin.');
  }

  /// `ready`, `no_key` or `service_down`, for the phone's status line.
  Future<String> linkState() async {
    final p = publisher();
    if (!await p.hasToken()) return 'no_key';
    return await p.health(endpoint()) ? 'ready' : 'service_down';
  }

  /// Is the chain usable right now? Never returns the key itself.
  Future<String?> _linkProblem(QrPublisherClient p) async {
    if (!await p.hasToken()) return 'Windows’ta yayınlama anahtarı kayıtlı değil (Ayarlar › Entegrasyonlar).';
    if (!await p.health(endpoint())) return 'Windows’ta QR yayınlama hizmeti çalışmıyor.';
    return null;
  }

  Future<Json> publish({required String expectedStamp, required String actor, int? actorId}) async {
    if (_publishing) throw const QrMenuConflict('Başka bir yayın sürüyor.');
    _publishing = true;
    try {
      final state = store.read().data;
      if (state[_pendingKey] is Map) {
        throw const QrMenuConflict('Önceki yayının sonucu henüz doğrulanmadı. Önce “Sonucu Doğrula”.');
      }
      final base = _map(state[_baseKey]), draft = _map(state[_draftKey]);
      final revision = state[_revisionKey]?.toString();
      if (base == null || draft == null) throw const FormatException('Yayınlanacak değişiklik yok.');
      if (revision == null) {
        throw const FormatException('Taslak GitHub sürümüne bağlı değil. Windows’ta QR Menü Yönetimi’ni açıp bağlanın.');
      }
      if (qrDraftStamp(draft) != expectedStamp) throw const QrMenuConflict();
      final changes = diffCatalog(base, draft);
      if (changes.isEmpty) throw const FormatException('Yayınlanacak değişiklik yok.');
      final problems = validateQrCatalog(draft);
      if (problems.isNotEmpty) throw FormatException(problems.first);
      final p = publisher();
      final problem = await _linkProblem(p);
      if (problem != null) throw FormatException(problem);
      // Record the attempt before sending: a lost answer is reconciled, never retried blindly.
      _write((s) {
        s[_pendingKey] = {'revision': revision, 'at': _clock().toUtc().toIso8601String(), 'changes': changes.length};
        _audit(s, 'publish_requested', actor, actorId, {'revision': revision});
      });
      try {
        final answer = await p.publish(endpoint(), revision, draft);
        final rev = answer['revision']?.toString() ?? '';
        if (answer['published'] != true || rev.isEmpty) throw const QrPublisherNoAnswer('Yayın yanıtı eksik.');
        _write((s) {
          s[_baseKey] = copyJson(draft);
          s[_revisionKey] = rev;
          s.remove(_draftKey);
          s.remove(_pendingKey);
          _audit(s, 'publish', actor, actorId, {'commit': answer['commit'] ?? rev});
        });
        return {'ok': true, 'outcome': 'published', 'revision': rev, 'revisionLabel': qrRevisionLabel(rev),
          'changes': changes.length, 'commit': answer['commit']};
      } on QrPublisherNoAnswer catch (e) {
        return {'ok': false, 'outcome': 'unknown', 'message': 'Yayın sonucu bilinmiyor: ${e.message} '
            'Yeniden göndermeden önce “Sonucu Doğrula”.'};
      } on FormatException catch (e) {
        _write((s) => s.remove(_pendingKey));
        return {'ok': false, 'outcome': 'refused', 'message': 'Yayın reddedildi, web menüsü değişmedi: ${e.message}'};
      }
    } finally {
      _publishing = false;
    }
  }

  /// Decides what happened to an unanswered publish by reading GitHub.
  Future<Json> reconcile({required String actor, int? actorId}) async {
    final state = store.read().data;
    final pending = _map(state[_pendingKey]);
    if (pending == null) return {'ok': true, 'outcome': 'none'};
    final p = publisher();
    final problem = await _linkProblem(p);
    if (problem != null) throw FormatException(problem);
    final answer = await p.catalog(endpoint());
    final rev = answer['revision']?.toString() ?? '';
    final remote = answer['catalog'];
    if (rev.isEmpty || remote is! Map) throw const FormatException('GitHub kataloğu okunamadı.');
    final draft = _currentDraft(state);
    if (rev == pending['revision']) {
      _write((s) {
        s.remove(_pendingKey);
        _audit(s, 'publish_not_applied', actor, actorId, {'revision': rev});
      });
      return {'ok': true, 'outcome': 'not_applied', 'message': 'Önceki yayın GitHub’a ulaşmamış; taslak korunuyor, yeniden yayınlayabilirsiniz.'};
    }
    if (draft != null && diffCatalog(Map<String, dynamic>.from(remote), draft).isEmpty) {
      _write((s) {
        s[_baseKey] = copyJson(Map<String, dynamic>.from(remote));
        s[_revisionKey] = rev;
        s.remove(_draftKey);
        s.remove(_pendingKey);
        _audit(s, 'publish_confirmed', actor, actorId, {'revision': rev});
      });
      return {'ok': true, 'outcome': 'confirmed', 'message': 'Önceki yayın doğrulandı.'};
    }
    _write((s) => s.remove(_pendingKey));
    return {'ok': true, 'outcome': 'diverged', 'message': 'GitHub’da farklı bir sürüm var. Windows’ta QR Menü Yönetimi '
        'farkları birleştirir; ardından yeniden yayınlayın.'};
  }

  /// Uploads a product photo with Windows' key and puts its path in the draft.
  Future<Json> uploadImage({required Json payload, required bool Function(String op) can,
      required String actor, int? actorId}) async {
    if (!can('menu.product.edit')) throw const QrMenuForbidden('menu.product.edit');
    final mime = '${payload['mime'] ?? ''}';
    if (!['image/png', 'image/jpeg', 'image/webp'].contains(mime)) throw const FormatException('PNG/JPEG/WEBP resim gerekli.');
    final List<int> bytes;
    try {
      bytes = base64Decode('${payload['base64'] ?? ''}');
    } on FormatException {
      throw const FormatException('Resim okunamadı.');
    }
    if (bytes.isEmpty || bytes.length > 6000000) throw const FormatException('Resim en fazla 6 MB.');
    final state = store.read().data;
    if (qrDraftStamp(_currentDraft(state)) != payload['expectedStamp']) throw const QrMenuConflict();
    final p = publisher();
    final problem = await _linkProblem(p);
    if (problem != null) throw FormatException(problem);
    final uploaded = await p.uploadImage(endpoint(), mime, bytes);
    final path = '${uploaded['path'] ?? ''}';
    if (!path.startsWith('assets/')) throw const FormatException('Görsel yolu alınamadı.');
    // The draft may have moved while uploading: bind to the current one.
    return applyQrMenuCommand(store, {
      'requestId': '${payload['requestId']}-img',
      'action': 'set_image', 'id': payload['id'], 'image': path,
      'expectedStamp': qrDraftStamp(_currentDraft(store.read().data)),
    }, can: can, actor: actor, actorId: actorId);
  }

  Future<Json> sync({required String actor}) async {
    final f = syncPos;
    if (f == null) throw const FormatException('POS menü eşitlemesi bu bilgisayarda kapalı.');
    await f();
    return {'ok': true};
  }
}
