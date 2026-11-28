// QR Menü Yönetimi, pure draft logic (no UI, no network): what changed in a
// draft, a three-way merge of an offline draft onto the latest GitHub
// catalog with explicit conflicts, and the page's truthful state.
import 'dart:convert';

import 'pos_logic.dart';

const qrCatalogLists = ['categories', 'products', 'campaigns'];

/// Price in a catalog is TL as a number (140, 140.5). Shown as `140,00 ₺`.
String qrPrice(Object? tl) {
  if (tl is! num) return '—';
  return formatTry((tl * 100).round());
}

String qrText(Object? field, [String lang = 'tr']) =>
    field is Map ? '${field[lang] ?? ''}' : '${field ?? ''}';

bool _same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

Map<Object?, Map<String, dynamic>> _byId(Object? rows) => {
  if (rows is List)
    for (final r in rows)
      if (r is Map) r['id']: Map<String, dynamic>.from(r),
};

class QrChange {
  const QrChange(this.list, this.id, this.label, this.detail);
  final String list; // categories | products | campaigns
  final Object? id;
  final String label;
  final String detail;
  @override
  String toString() => '$label: $detail';
}

/// Every difference between the catalog the draft started from and the draft.
List<QrChange> diffCatalog(Json? base, Json? draft) {
  if (base == null || draft == null) return const [];
  final out = <QrChange>[];
  for (final list in qrCatalogLists) {
    final before = _byId(base[list]);
    final after = _byId(draft[list]);
    String name(Map r) => qrText(list == 'campaigns' ? r['title'] : r['name']).trim().isEmpty
        ? '${r['id']}' : qrText(list == 'campaigns' ? r['title'] : r['name']);
    for (final entry in after.entries) {
      final now = entry.value, old = before[entry.key];
      final label = name(now);
      if (old == null) {
        out.add(QrChange(list, entry.key, label,
            list == 'products' ? 'yeni ürün' : list == 'categories' ? 'yeni kategori' : 'yeni kampanya'));
        continue;
      }
      if (_same(old, now)) continue;
      if (old['price'] != now['price']) {
        out.add(QrChange(list, entry.key, label, 'fiyat ${qrPrice(old['price'])} → ${qrPrice(now['price'])}'));
      }
      if (list == 'products' && old['available'] != now['available']) {
        out.add(QrChange(list, entry.key, label, now['available'] == false ? 'Tükendi' : 'Stokta'));
      }
      if (old['active'] != now['active']) {
        out.add(QrChange(list, entry.key, label,
            now['active'] == false ? (list == 'campaigns' ? 'pasif' : 'QR’den gizlendi')
                : (list == 'campaigns' ? 'aktif' : 'QR’de gösteriliyor')));
      }
      if (old['category'] != now['category']) out.add(QrChange(list, entry.key, label, 'kategori değişti'));
      if (old['order'] != now['order']) out.add(QrChange(list, entry.key, label, 'sıra değişti'));
      if (!_same(old['name'], now['name']) || !_same(old['displayName'], now['displayName']) ||
          !_same(old['title'], now['title'])) {
        out.add(QrChange(list, entry.key, label, 'isim / çeviri'));
      }
      if (!_same(old['description'], now['description'])) out.add(QrChange(list, entry.key, label, 'açıklama'));
      if (old['image'] != now['image'] || old['poster'] != now['poster'] || old['thumbnail'] != now['thumbnail']) {
        out.add(QrChange(list, entry.key, label, 'görsel'));
      }
      const known = {'price', 'available', 'active', 'category', 'order', 'name', 'displayName', 'title',
        'description', 'image', 'poster', 'thumbnail'};
      final other = {...old.keys, ...now.keys}.where((k) => !known.contains(k) && !_same(old[k], now[k]));
      if (other.isNotEmpty) out.add(QrChange(list, entry.key, label, 'diğer alanlar (${other.join(', ')})'));
    }
    for (final id in before.keys) {
      if (!after.containsKey(id)) out.add(QrChange(list, id, name(before[id]!), 'taslakta yok'));
    }
  }
  return out;
}

/// One field that was changed both in the offline draft and on GitHub.
class QrConflict {
  QrConflict(this.list, this.id, this.field, this.label, this.local, this.remote);
  final String list;
  final Object? id;
  final String field; // a top-level field, or '*' when the record was removed on GitHub
  final String label;
  final Object? local, remote;
  String get key => '$list/${jsonEncode(id)}/$field';
  String show(Object? v) => field == 'price' ? qrPrice(v)
      : field == 'available' ? (v == false ? 'Tükendi' : 'Stokta')
      : field == 'active' ? (v == false ? 'Gizli' : 'Görünür')
      : v is Map ? qrText(v) : v == null ? '—' : '$v';
}

class QrMergeResult {
  QrMergeResult(this.merged, this.conflicts, this.fromGitHub);
  /// Draft with every non-conflicting change from both sides. Conflicting
  /// fields hold the local value until [resolve] says otherwise.
  final Json merged;
  final List<QrConflict> conflicts;
  /// Fields and records taken from GitHub because the draft had not touched them.
  final int fromGitHub;

  Json resolve(Map<String, String> choice) {
    final out = copyJson(merged);
    for (final c in conflicts) {
      if (choice[c.key] != 'remote') continue;
      final rows = out[c.list] as List;
      final i = rows.indexWhere((r) => r is Map && r['id'] == c.id);
      if (c.field == '*') {
        if (i >= 0) rows.removeAt(i);
      } else if (i >= 0) {
        final row = rows[i] as Map;
        if (c.remote == null) {
          row.remove(c.field);
        } else {
          row[c.field] = copyJsonValue(c.remote);
        }
      }
    }
    return out;
  }
}

Object? copyJsonValue(Object? v) => v == null ? null : jsonDecode(jsonEncode(v));

/// Three-way merge by record id and top-level field: untouched draft fields
/// follow GitHub (so an old offline copy never overwrites newer published
/// prices), untouched GitHub fields keep the draft edit, and a field changed
/// on both sides becomes a conflict the owner must decide.
QrMergeResult mergeOfflineDraft({required Json base, required Json local, required Json remote}) {
  final merged = copyJson(remote);
  final conflicts = <QrConflict>[];
  var fromGitHub = 0;
  for (final list in qrCatalogLists) {
    final b = _byId(base[list]), l = _byId(local[list]), r = _byId(remote[list]);
    final rows = <Map<String, dynamic>>[];
    for (final id in {...r.keys, ...l.keys}) {
      final lr = l[id], rr = r[id], br = b[id];
      String label(Map x) => qrText(list == 'campaigns' ? x['title'] : x['name']);
      if (lr == null) {
        rows.add(rr!);
        if (br == null) fromGitHub++; // added on GitHub
        continue;
      }
      if (rr == null) {
        // Only in the draft: new locally, or removed on GitHub meanwhile.
        if (br != null && _same(br, lr)) { fromGitHub++; continue; } // untouched → follow GitHub
        rows.add(lr);
        if (br != null) conflicts.add(QrConflict(list, id, '*', label(lr), lr, null));
        continue;
      }
      if (list == 'products' && lr['legacyKey'] != rr['legacyKey']) {
        throw FormatException('GitHub ürün kimliği değişmiş: $id');
      }
      final row = <String, dynamic>{};
      for (final k in {...rr.keys, ...lr.keys}) {
        final bv = br?[k], lv = lr[k], rv = rr[k];
        if (_same(lv, rv)) {
          if (lr.containsKey(k)) row[k] = lv;
        } else if (br != null && _same(lv, bv)) {
          if (rr.containsKey(k)) row[k] = rv;
          fromGitHub++;
        } else if (br != null && _same(rv, bv)) {
          if (lr.containsKey(k)) row[k] = lv;
        } else {
          if (lr.containsKey(k)) row[k] = lv;
          conflicts.add(QrConflict(list, id, k, label(lr), lv, rv));
        }
      }
      rows.add(row);
    }
    merged[list] = rows;
  }
  return QrMergeResult(merged, conflicts, fromGitHub);
}

/// What the page tells the owner, and which primary action it offers.
enum QrPageState { notLoaded, connecting, offlineDraft, clean, dirty, conflict, publishing, unknownOutcome }

QrPageState qrPageState({required bool hasMenu, required bool busy, required bool publishing,
    required String? revision, required int changes, required bool conflicts, required bool pendingPublish}) {
  if (publishing) return QrPageState.publishing;
  if (pendingPublish) return QrPageState.unknownOutcome;
  if (!hasMenu) return busy ? QrPageState.connecting : QrPageState.notLoaded;
  if (conflicts) return QrPageState.conflict;
  if (revision == null) return QrPageState.offlineDraft;
  return changes > 0 ? QrPageState.dirty : QrPageState.clean;
}

/// `140` → `140,00` for a price text field (parseMoney reads it back).
String qrPriceInput(Object? tl) {
  if (tl is! num) return '';
  final cents = (tl * 100).round();
  return '${cents ~/ 100},${(cents % 100).toString().padLeft(2, '0')}';
}

/// `abc1234…` for a GitHub blob sha; first publication shows as such.
String qrRevisionLabel(String? revision) {
  if (revision == null || revision.isEmpty) return 'Bilinmiyor';
  final boot = revision.startsWith('bootstrap:');
  final sha = boot ? revision.substring(10) : revision;
  final short = sha.length > 7 ? sha.substring(0, 7) : sha;
  return boot ? 'İlk yayın öncesi · $short' : short;
}

/// What would make the publisher refuse the catalog, in the owner's words.
List<String> validateQrCatalog(Json catalog) {
  final out = <String>[];
  final categories = catalog['categories'], products = catalog['products'], campaigns = catalog['campaigns'];
  if (categories is! List || products is! List || campaigns is! List) return ['Katalog eksik.'];
  final catIds = <Object?>{};
  for (final c in categories) {
    if (c is! Map) continue;
    if (!catIds.add(c['id'])) out.add('Kategori kodu iki kez kullanılmış: ${c['id']}');
    if (qrText(c['name']).trim().isEmpty) out.add('Kategori ${c['id']}: Türkçe ad boş.');
  }
  final ids = <Object?>{};
  for (final p in products) {
    if (p is! Map) continue;
    final name = qrText(p['name']).trim();
    final label = name.isEmpty ? 'Ürün #${p['id']}' : name;
    if (!ids.add(p['id'])) out.add('$label: ürün numarası iki kez kullanılmış.');
    if (name.isEmpty) out.add('$label: Türkçe ad boş.');
    final price = p['price'];
    if (price is! num || price < 0 || price > 100000) out.add('$label: fiyat geçersiz.');
    if (!catIds.contains(p['category'])) out.add('$label: kategori bulunamadı.');
  }
  for (final c in campaigns) {
    if (c is! Map) continue;
    if (qrText(c['title']).trim().isEmpty) out.add('Kampanya ${c['id']}: Türkçe başlık boş.');
    final price = c['price'];
    if (price is! num || price < 0) out.add('Kampanya ${c['id']}: fiyat geçersiz.');
  }
  return out;
}
