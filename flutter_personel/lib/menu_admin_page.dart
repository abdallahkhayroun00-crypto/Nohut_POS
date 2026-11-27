/// Menü Yönetimi on Android (Personel with grants, Yönetici as owner).
/// Edits the shared QR menu draft that lives on the Windows POS: the server
/// checks every `menu.*` grant and refuses edits based on an older draft.
/// No publisher key or GitHub token is ever on the phone: when this person
/// holds `menu.qr.publish` (Personel and Yönetici by default, owner decision
/// 2026-11-27), the phone asks Windows to publish the exact draft it reviewed,
/// and Windows does it with its own key, recording who did it.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'pos_api.dart';
import 'style.dart';

String menuPrice(Object? tl) => tl is num ? money((tl * 100).round()) : '—';
String _priceInput(Object? tl) {
  if (tl is! num) return '';
  final c = (tl * 100).round();
  return '${c ~/ 100},${(c % 100).toString().padLeft(2, '0')}';
}
int? _parseCents(String text) {
  final t = text.trim().replaceAll('₺', '').trim();
  if (!RegExp(r'^\d{1,7}([.,]\d{1,2})?$').hasMatch(t)) return null;
  final parts = t.replaceAll(',', '.').split('.');
  return int.parse(parts[0]) * 100 + (parts.length > 1 ? int.parse(parts[1].padRight(2, '0')) : 0);
}
String _tr(Object? f, [String l = 'tr']) => f is Map ? '${f[l] ?? ''}' : '';

/// A product photo chosen on the phone: (mime, bytes), or null when cancelled.
typedef MenuPhotoPicker = Future<(String, List<int>)?> Function();

/// Android photo picker (no storage permission), resized so the photo also
/// fits the owner channel's request limit.
Future<(String, List<int>)?> pickMenuPhoto() async {
  final f = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1000, maxHeight: 1000, imageQuality: 75);
  if (f == null) return null;
  final name = f.name.toLowerCase();
  final mime = name.endsWith('.png') ? 'image/png' : name.endsWith('.webp') ? 'image/webp' : 'image/jpeg';
  return (mime, await f.readAsBytes());
}

/// Full-screen route used by both apps.
Route<void> menuAdminRoute(NohutApi api, {String? imageBase = 'https://nohutfalafel.github.io/qr-menu/'}) =>
    MaterialPageRoute<void>(builder: (_) => Scaffold(
      appBar: AppBar(title: const Text('Menü Yönetimi')),
      body: MenuAdminPage(api: api, imageBase: imageBase)));

class MenuAdminPage extends StatefulWidget {
  const MenuAdminPage({super.key, required this.api, this.imageBase = 'https://nohutfalafel.github.io/qr-menu/',
    this.pickPhoto = pickMenuPhoto});
  final NohutApi api;
  final String? imageBase;
  final MenuPhotoPicker pickPhoto;
  @override
  State<MenuAdminPage> createState() => _MenuAdminPageState();
}

class _MenuAdminPageState extends State<MenuAdminPage> {
  Json? view;
  String? error;
  bool busy = false;
  String tab = 'products', query = '', category = 'all';
  final _rand = Random.secure();

  @override
  void initState() {
    super.initState();
    load();
  }

  Map<String, dynamic> get can => Map<String, dynamic>.from(view?['can'] as Map? ?? const {});
  bool allowed(String op) => can[op] == true && view?['pendingPublish'] != true && !busy;
  Json get catalog => Map<String, dynamic>.from(view?['catalog'] as Map? ?? const {});
  List<Json> list(String k) => rows(catalog[k]);

  Future<void> load() async {
    setState(() { busy = true; error = null; });
    try {
      final (code, body) = await widget.api.menu('GET', 'view');
      if (!mounted) return;
      setState(() {
        if (code == 200) {
          view = body;
        } else {
          error = code == 403
              ? 'Menü yönetimi için yetkiniz yok. İşletme sahibi Windows › Kullanıcılar’dan verebilir.'
              : '${body['message'] ?? body['error'] ?? 'Menü alınamadı.'}';
        }
      });
    } on FormatException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Windows POS’a ulaşılamadı. Menü yönetimi yalnızca restoran ağında '
            'çalışır; uzaktan (bulut) erişim henüz hazır değil.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _say(String m) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m)));

  /// One edit, bound to the draft this screen shows.
  Future<bool> send(Json body, String done) async {
    if (view == null) return false;
    setState(() => busy = true);
    try {
      final requestId = 'menu-${DateTime.now().microsecondsSinceEpoch}-${_rand.nextInt(1 << 30)}';
      final (code, result) = await widget.api.menu('POST', 'write',
          body: {...body, 'requestId': requestId, 'expectedStamp': view!['stamp']});
      if (!mounted) return false;
      if (code == 200) {
        _say(done);
        await load();
        return true;
      }
      if (code == 409) {
        _say('${result['message'] ?? 'Menü başka bir cihazda değişti.'} Güncel hali yüklendi.');
        await load();
      } else {
        _say('${result['message'] ?? result['error'] ?? 'Kaydedilemedi.'}');
      }
    } on FormatException catch (e) {
      if (mounted) _say(e.message);
    } catch (_) {
      if (mounted) _say('Windows POS’a ulaşılamadı. Değişiklik kaydedilmedi.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
    return false;
  }

  Widget _status() {
    final v = view!;
    final n = (v['changes'] as List? ?? const []).length;
    final pending = v['pendingPublish'] == true, offline = v['offline'] == true;
    final here = v['publish'] == 'here';
    final linkProblem = !here ? null : switch (v['link']) {
      'no_key' => 'Windows’ta yayınlama anahtarı kayıtlı değil (Windows › Ayarlar › Entegrasyonlar).',
      'service_down' => 'Windows’ta QR yayınlama hizmeti çalışmıyor; yayın şu an yapılamaz.',
      _ => null,
    };
    return Card(
      key: const ValueKey('menu-status'),
      child: Padding(padding: const EdgeInsets.all(14), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(n == 0 ? 'Yayındakiyle aynı' : '$n değişiklik yayın bekliyor',
              key: const ValueKey('menu-state'),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
            NohutPill(pending ? 'Doğrulanıyor' : offline ? 'Çevrimdışı taslak' : 'Taslak',
              tone: pending ? NohutTone.danger : n == 0 ? NohutTone.success : NohutTone.warning),
          ]),
          const SizedBox(height: 6),
          Text(pending
              ? 'Bir yayının sonucu henüz doğrulanmadı; bu sırada düzenleme ve yeni yayın yapılamaz. '
                '“Sonucu Doğrula” GitHub’daki menüyü okuyup ne olduğunu belirler.'
              : 'Yayındaki sürüm ${v['revisionLabel']}. Değişiklikler Windows’taki ortak taslağa kaydedilir. '
                '${here ? 'Yayınla: önce değişiklikleri gözden geçirir, onayınızla Windows QR menüyü yayınlar.' : 'Bu Windows sürümü telefondan yayınlamayı desteklemiyor; Windows › QR Menü Yönetimi’nden yayınlayın.'}',
            style: Theme.of(context).textTheme.bodySmall),
          if (linkProblem != null) ...[
            const SizedBox(height: 6),
            Text(linkProblem, key: const ValueKey('menu-link'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: context.nohut.danger, fontWeight: FontWeight.w700)),
          ],
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, children: [
            if (here && pending)
              FilledButton.icon(key: const ValueKey('menu-reconcile'),
                onPressed: can['menu.qr.publish'] == true && !busy ? _reconcile : null,
                icon: const Icon(Icons.sync_problem_outlined, size: 18), label: const Text('Sonucu Doğrula'))
            else if (here)
              FilledButton.icon(key: const ValueKey('menu-publish'),
                onPressed: n > 0 && allowed('menu.qr.publish') && v['link'] == 'ready' ? _publish : null,
                icon: const Icon(Icons.publish_outlined, size: 18), label: const Text('Yayınla')),
            OutlinedButton.icon(key: const ValueKey('menu-changes'), onPressed: n == 0 ? null : _changes,
              icon: const Icon(Icons.fact_check_outlined, size: 18), label: const Text('Değişiklikler')),
            OutlinedButton.icon(key: const ValueKey('menu-preview'), onPressed: _preview,
              icon: const Icon(Icons.visibility_outlined, size: 18), label: const Text('Önizle')),
            if (here)
              OutlinedButton.icon(key: const ValueKey('menu-sync'),
                onPressed: can['menu.product.edit'] == true && !busy ? _syncPos : null,
                icon: const Icon(Icons.point_of_sale_outlined, size: 18), label: const Text('POS’a Eşitle')),
          ]),
        ])),
    );
  }

  /// Publish / verify / POS sync: Windows does the work with its own key.
  Future<Json?> _command(String path, [Json body = const {}]) async {
    setState(() => busy = true);
    try {
      final requestId = 'menu-${DateTime.now().microsecondsSinceEpoch}-${_rand.nextInt(1 << 30)}';
      final (code, result) = await widget.api.menu('POST', path, body: {...body, 'requestId': requestId});
      if (!mounted) return null;
      if (code == 200) return result;
      _say(code == 409
          ? '${result['message'] ?? 'Menü başka bir cihazda değişti.'} Güncel hali yüklendi.'
          : code == 403 ? 'Bu işlem için yetkiniz yok.'
          : '${result['message'] ?? result['error'] ?? 'İşlem yapılamadı.'}');
      return null;
    } on FormatException catch (e) {
      if (mounted) _say(e.message);
      return null;
    } catch (_) {
      if (mounted) _say('Windows POS’a ulaşılamadı. Yayın gönderilmedi.');
      return null;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _publish() async {
    final v = view!;
    final changes = rows(v['changes']);
    final ok = await showModalBottomSheet<bool>(context: context, showDragHandle: true, isScrollControlled: true,
      builder: (sheet) => SafeArea(child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * .8),
        child: Column(key: const ValueKey('menu-publish-sheet'), mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 4), child: Text('QR menüde yayınla',
            style: Theme.of(sheet).textTheme.titleLarge)),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(
            '${changes.length} değişiklik, yayındaki sürüm ${v['revisionLabel']} üzerine yayınlanacak. '
            'Müşteriler QR menüde bu hali görür.', style: Theme.of(sheet).textTheme.bodySmall)),
          Flexible(child: ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
            for (final c in changes)
              ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text('${c['label']}'),
                subtitle: Text('${c['detail']}')),
          ])),
          Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 12), child: Row(children: [
            Expanded(child: OutlinedButton(onPressed: () => _preview(), child: const Text('Önizle'))),
            const SizedBox(width: 8),
            Expanded(child: FilledButton(key: const ValueKey('menu-publish-confirm'),
              onPressed: () => Navigator.pop(sheet, true), child: const Text('Onayla ve Yayınla'))),
          ])),
        ]))));
    if (ok != true || !mounted) return;
    final r = await _command('publish', {'expectedStamp': v['stamp']});
    if (r != null) {
      _say(switch (r['outcome']) {
        'published' => 'QR menü yayınlandı (sürüm ${r['revisionLabel'] ?? r['revision']}).',
        _ => '${r['message'] ?? 'Yayın sonucu alınamadı.'}',
      });
    }
    await load();
  }

  /// Windows uploads the photo with its own key, then puts its path in the draft.
  Future<void> _photo(Json p) async {
    final picked = await widget.pickPhoto();
    if (picked == null || !mounted) return;
    final (mime, bytes) = picked;
    if (bytes.length > 6000000) return _say('Fotoğraf en fazla 6 MB olabilir.');
    final r = await _command('image', {'id': p['id'], 'mime': mime, 'base64': base64Encode(bytes),
      'expectedStamp': view!['stamp']});
    if (r != null) _say('Fotoğraf yüklendi ve taslağa eklendi.');
    await load();
  }

  Future<void> _reconcile() async {
    final r = await _command('reconcile');
    if (r != null) _say('${r['message'] ?? 'Doğrulanacak yayın yok.'}');
    await load();
  }

  Future<void> _syncPos() async {
    final r = await _command('sync');
    if (r != null) _say('POS menüsü QR menüden eşitleniyor.');
  }

  void _changes() => showModalBottomSheet<void>(context: context, showDragHandle: true, isScrollControlled: true,
    builder: (_) => SafeArea(child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .7),
      child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
        Text('Yayın bekleyen değişiklikler', style: Theme.of(context).textTheme.titleLarge),
        for (final c in rows(view?['changes']))
          ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text('${c['label']}'),
            subtitle: Text('${c['detail']}')),
      ]))));

  void _preview() {
    final cats = list('categories').where((c) => c['active'] != false && c['id'] != 'all');
    final prods = list('products').where((p) => p['active'] != false);
    showModalBottomSheet<void>(context: context, showDragHandle: true, isScrollControlled: true,
      builder: (_) => SafeArea(child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .8),
        child: ListView(key: const ValueKey('menu-preview-sheet'), shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
          Text('Müşteri görünümü (taslak)', style: Theme.of(context).textTheme.titleLarge),
          for (final c in cats) ...[
            const SizedBox(height: 10),
            Text(_tr(c['name']), style: const TextStyle(fontWeight: FontWeight.w800)),
            for (final p in prods.where((p) => p['category'] == c['id']))
              ListTile(dense: true, contentPadding: EdgeInsets.zero,
                title: Text(_tr(p['displayName']).isNotEmpty ? _tr(p['displayName']) : _tr(p['name'])),
                subtitle: p['available'] == false ? const Text('Tükendi') : null,
                trailing: Text(menuPrice(p['price']), style: const TextStyle(fontWeight: FontWeight.w700))),
          ],
        ]))));
  }

  Widget _thumb(Json p) {
    final image = '${p['image'] ?? ''}';
    final nc = context.nohut;
    final fallback = Container(color: nc.raised, child: Icon(Icons.restaurant_menu_outlined, color: nc.muted, size: 20));
    return ClipRRect(borderRadius: BorderRadius.circular(10), child: SizedBox(width: 44, height: 44,
      child: widget.imageBase != null && image.startsWith('assets/') && !image.contains('..')
          ? Image.network('${widget.imageBase}$image', fit: BoxFit.cover, errorBuilder: (_, __, ___) => fallback)
          : fallback));
  }

  Widget _productRow(Json p, Map<Object?, String> names) {
    final id = p['id'];
    final visible = p['active'] != false, inStock = p['available'] != false;
    final nc = context.nohut;
    return ListTile(
      key: ValueKey('menu-product-$id'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      leading: _thumb(p),
      title: Text(_tr(p['name']), maxLines: 1, overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text('${names[p['category']] ?? p['category']} · ${menuPrice(p['price'])}',
        maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: allowed('menu.product.edit') || allowed('menu.price.edit') ? () => _editProduct(p) : null,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        InkWell(
          key: ValueKey('menu-stock-$id'),
          borderRadius: BorderRadius.circular(20),
          onTap: allowed('menu.stock.toggle')
              ? () => send({'action': 'set_stock', 'id': id, 'available': !inStock},
                  inStock ? 'Tükendi olarak işaretlendi.' : 'Stokta olarak işaretlendi.')
              : null,
          child: NohutPill(inStock ? 'Stokta' : 'Tükendi', tone: inStock ? NohutTone.success : NohutTone.warning)),
        IconButton(
          key: ValueKey('menu-visible-$id'),
          tooltip: visible ? 'QR’den Gizle' : 'QR’de Göster',
          onPressed: allowed('menu.product.edit')
              ? () => send({'action': 'set_visible', 'list': 'products', 'id': id, 'active': !visible},
                  visible ? 'QR menüden gizlendi.' : 'QR menüde gösteriliyor.')
              : null,
          icon: Icon(visible ? Icons.visibility_outlined : Icons.visibility_off_outlined,
            color: visible ? nc.success : nc.muted)),
      ]),
    );
  }

  Future<void> _editProduct([Json? p]) async {
    final cats = list('categories').where((c) => c['id'] != 'all').toList();
    if (cats.isEmpty) return;
    final saved = await Navigator.of(context).push<Json>(MaterialPageRoute(
      builder: (_) => _ProductEditor(product: p, categories: cats,
        canProduct: allowed('menu.product.edit'), canPrice: allowed('menu.price.edit'),
        canPhoto: p != null && view?['publish'] == 'here' && allowed('menu.product.edit'))));
    if (saved == null) return;
    if (saved['pickPhoto'] == true) {
      await _photo(p!);
      return;
    }
    if (saved['onlyPrice'] == true) {
      await send({'action': 'set_price', 'id': p!['id'], 'priceCents': saved['priceCents']}, 'Fiyat taslağa kaydedildi.');
    } else {
      await send({'action': 'save_product', if (p != null) 'id': p['id'], ...saved..remove('onlyPrice')},
        p == null ? 'Yeni ürün taslağa eklendi.' : 'Ürün taslağa kaydedildi.');
    }
  }

  Future<void> _editNamed(String list, [Json? row]) async {
    final isCampaign = list == 'campaigns';
    final saved = await Navigator.of(context).push<Json>(MaterialPageRoute(
      builder: (_) => _NamedEditor(row: row, campaign: isCampaign)));
    if (saved == null) return;
    await send({'action': isCampaign ? 'save_campaign' : 'save_category', 'isNew': row == null,
      if (row != null) 'id': row['id'], ...saved}, 'Taslağa kaydedildi.');
  }

  @override
  Widget build(BuildContext context) {
    final v = view;
    final body = <Widget>[];
    if (v == null) {
      body.add(Padding(padding: const EdgeInsets.all(24), child: Column(children: [
        if (busy) const CircularProgressIndicator()
        else ...[
          Text(error ?? 'Menü yükleniyor…', key: const ValueKey('menu-error'), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: load, icon: const Icon(Icons.refresh), label: const Text('Tekrar Dene')),
        ],
      ])));
    } else if (v['available'] != true) {
      body.add(Card(child: Padding(padding: const EdgeInsets.all(16),
        child: Text('${v['message']}', key: const ValueKey('menu-error')))));
    } else {
      final names = {for (final c in list('categories')) c['id']: _tr(c['name'])};
      final q = query.trim().toLowerCase();
      final products = list('products').where((p) =>
          (category == 'all' || p['category'] == category) &&
          (q.isEmpty || ['tr', 'en', 'ar'].any((l) => _tr(p['name'], l).toLowerCase().contains(q)))).toList();
      body.addAll([
        _status(),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          key: const ValueKey('menu-tabs'),
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: 'products', label: Text('Ürünler · ${list('products').length}')),
            ButtonSegment(value: 'categories', label: Text('Kategori · ${list('categories').length}')),
            ButtonSegment(value: 'campaigns', label: Text('Kampanya · ${list('campaigns').length}')),
          ],
          selected: {tab},
          onSelectionChanged: (s) => setState(() => tab = s.first)),
        const SizedBox(height: 8),
        if (tab == 'products') ...[
          TextField(key: const ValueKey('menu-search'),
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Ürün ara', isDense: true),
            onChanged: (t) => setState(() => query = t)),
          const SizedBox(height: 6),
          SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
            for (final c in [{'id': 'all', 'name': {'tr': 'Tümü'}}, ...list('categories').where((c) => c['id'] != 'all')])
              Padding(padding: const EdgeInsets.only(right: 6), child: ChoiceChip(
                label: Text(_tr(c['name'])), selected: category == c['id'],
                onSelected: (_) => setState(() => category = '${c['id']}'))),
          ])),
          const SizedBox(height: 6),
          if (allowed('menu.product.edit') && allowed('menu.price.edit'))
            Align(alignment: Alignment.centerLeft, child: FilledButton.tonalIcon(
              key: const ValueKey('menu-new-product'), onPressed: () => _editProduct(),
              icon: const Icon(Icons.add), label: const Text('Yeni Ürün'))),
          Card(child: Column(children: [
            if (products.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Ürün yok.')),
            for (var i = 0; i < products.length; i++) ...[
              if (i > 0) const Divider(height: 1),
              _productRow(products[i], names),
            ],
          ])),
        ] else ...[
          if (allowed(tab == 'categories' ? 'menu.category.edit' : 'menu.campaign.edit'))
            Align(alignment: Alignment.centerLeft, child: FilledButton.tonalIcon(
              key: ValueKey('menu-new-$tab'), onPressed: () => _editNamed(tab),
              icon: const Icon(Icons.add), label: Text(tab == 'categories' ? 'Yeni Kategori' : 'Yeni Kampanya'))),
          Card(child: Column(children: [
            for (final r in list(tab))
              ListTile(
                key: ValueKey('menu-$tab-${r['id']}'),
                title: Text(_tr(tab == 'campaigns' ? r['title'] : r['name']),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(tab == 'campaigns' ? menuPrice(r['price'])
                    : '${list('products').where((p) => p['category'] == r['id']).length} ürün'),
                onTap: allowed(tab == 'categories' ? 'menu.category.edit' : 'menu.campaign.edit') && r['id'] != 'all'
                    ? () => _editNamed(tab, r) : null,
                trailing: Switch(
                  value: tab == 'campaigns' ? r['active'] == true : r['active'] != false,
                  onChanged: allowed(tab == 'categories' ? 'menu.category.edit' : 'menu.campaign.edit') && r['id'] != 'all'
                      ? (on) => send({'action': 'set_visible', 'list': tab, 'id': r['id'], 'active': on},
                          on ? 'Gösteriliyor.' : 'Gizlendi.')
                      : null),
              ),
          ])),
        ],
        const SizedBox(height: 8),
        Text('Fotoğraf yükleme ve QR menüde yayınlama Windows’taki QR Menü Yönetimi’nden yapılır.',
          style: Theme.of(context).textTheme.bodySmall),
      ]);
    }
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(key: const ValueKey('menu-admin'), padding: const EdgeInsets.all(16), children: [
        if (busy && v != null) const LinearProgressIndicator(),
        ...body,
      ]),
    );
  }
}

Widget _field(TextEditingController c, String label, {bool rtl = false, int lines = 1, Key? key,
        bool enabled = true, TextInputType? type}) =>
    Padding(padding: const EdgeInsets.only(bottom: 10), child: TextField(key: key, controller: c, enabled: enabled,
      maxLines: lines, keyboardType: type, textDirection: rtl ? TextDirection.rtl : null,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true)));

/// Save stays visible above the keyboard, whatever the form length.
Widget _saveBar(BuildContext context, VoidCallback save, String? problem) => SafeArea(child: Padding(
  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    if (problem != null) Padding(padding: const EdgeInsets.only(bottom: 8),
      child: Text(problem, style: TextStyle(color: Theme.of(context).colorScheme.error))),
    FilledButton.icon(key: const ValueKey('menu-save'), onPressed: save,
      icon: const Icon(Icons.save_outlined), label: const Text('Taslağa Kaydet')),
  ])));

class _ProductEditor extends StatefulWidget {
  const _ProductEditor({required this.product, required this.categories,
    required this.canProduct, required this.canPrice, this.canPhoto = false});
  final Json? product;
  final List<Json> categories;
  final bool canProduct, canPrice, canPhoto;
  @override
  State<_ProductEditor> createState() => _ProductEditorState();
}

class _ProductEditorState extends State<_ProductEditor> {
  late final p = widget.product ?? const <String, dynamic>{};
  late final names = [for (final l in ['tr', 'en', 'ar']) TextEditingController(text: _tr(p['name'], l))];
  late final descs = [for (final l in ['tr', 'en', 'ar']) TextEditingController(text: _tr(p['description'], l))];
  late final price = TextEditingController(text: _priceInput(p['price']));
  late String category = widget.categories.any((c) => c['id'] == p['category'])
      ? '${p['category']}' : '${widget.categories.first['id']}';
  String? problem;

  @override
  void dispose() {
    for (final c in [...names, ...descs, price]) {
      c.dispose();
    }
    super.dispose();
  }

  void save() {
    final cents = _parseCents(price.text);
    if (cents == null) return setState(() => problem = 'Geçerli bir fiyat girin. Örnek: 140 veya 140,50');
    if (!widget.canProduct) {
      Navigator.pop(context, {'onlyPrice': true, 'priceCents': cents});
      return;
    }
    if (names.any((c) => c.text.trim().isEmpty)) return setState(() => problem = 'TR / EN / AR ürün adları gerekli.');
    Navigator.pop(context, <String, dynamic>{
      'name': {'tr': names[0].text.trim(), 'en': names[1].text.trim(), 'ar': names[2].text.trim()},
      'description': {'tr': descs[0].text.trim(), 'en': descs[1].text.trim(), 'ar': descs[2].text.trim()},
      'category': category,
      'priceCents': cents,
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.product == null ? 'Yeni Ürün' : 'Ürünü Düzenle')),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      _field(names[0], 'Ürün adı · Türkçe', key: const ValueKey('menu-name-tr'), enabled: widget.canProduct),
      _field(names[1], 'English · Product name', key: const ValueKey('menu-name-en'), enabled: widget.canProduct),
      _field(names[2], 'العربية · اسم المنتج', rtl: true, key: const ValueKey('menu-name-ar'), enabled: widget.canProduct),
      _field(price, 'Fiyat · ₺', key: const ValueKey('menu-price'), enabled: widget.canPrice,
        type: const TextInputType.numberWithOptions(decimal: true)),
      Padding(padding: const EdgeInsets.only(bottom: 10), child: DropdownButtonFormField<String>(
        initialValue: category,
        decoration: const InputDecoration(labelText: 'Kategori', border: OutlineInputBorder(), isDense: true),
        items: [for (final c in widget.categories)
          DropdownMenuItem(value: '${c['id']}', child: Text(_tr(c['name'])))],
        onChanged: widget.canProduct ? (v) => setState(() => category = v ?? category) : null)),
      _field(descs[0], 'Açıklama · Türkçe', lines: 2, enabled: widget.canProduct),
      _field(descs[1], 'Description · English', lines: 2, enabled: widget.canProduct),
      _field(descs[2], 'الوصف · العربية', lines: 2, rtl: true, enabled: widget.canProduct),
      if (!widget.canPrice) const Text('Fiyat değiştirme yetkiniz yok.'),
      if (widget.canPhoto)
        Align(alignment: Alignment.centerLeft, child: OutlinedButton.icon(key: const ValueKey('menu-photo'),
          onPressed: () => Navigator.pop(context, <String, dynamic>{'pickPhoto': true}),
          icon: const Icon(Icons.add_photo_alternate_outlined), label: const Text('Fotoğraf Seç ve Yükle')))
      else
        Text(widget.product == null ? 'Fotoğraf, ürün kaydedildikten sonra eklenir.'
            : 'Fotoğraf Windows’taki QR Menü Yönetimi’nden yüklenir.', style: Theme.of(context).textTheme.bodySmall),
    ]),
    bottomNavigationBar: _saveBar(context, save, problem),
  );
}

class _NamedEditor extends StatefulWidget {
  const _NamedEditor({required this.row, required this.campaign});
  final Json? row;
  final bool campaign;
  @override
  State<_NamedEditor> createState() => _NamedEditorState();
}

class _NamedEditorState extends State<_NamedEditor> {
  late final r = widget.row ?? const <String, dynamic>{};
  late final code = TextEditingController(text: '${r['id'] ?? ''}');
  late final titles = [for (final l in ['tr', 'en', 'ar'])
    TextEditingController(text: _tr(widget.campaign ? r['title'] : r['name'], l))];
  late final descs = [for (final l in ['tr', 'en', 'ar']) TextEditingController(text: _tr(r['description'], l))];
  late final price = TextEditingController(text: _priceInput(r['price']));
  late final poster = TextEditingController(text: '${r['poster'] ?? ''}');
  late final thumb = TextEditingController(text: '${r['thumbnail'] ?? ''}');
  String? problem;

  @override
  void dispose() {
    for (final c in [code, ...titles, ...descs, price, poster, thumb]) {
      c.dispose();
    }
    super.dispose();
  }

  void save() {
    if (titles.any((c) => c.text.trim().isEmpty)) return setState(() => problem = 'TR / EN / AR gerekli.');
    final texts = {'tr': titles[0].text.trim(), 'en': titles[1].text.trim(), 'ar': titles[2].text.trim()};
    final out = <String, dynamic>{
      if (widget.row == null) 'id': code.text.trim(),
      widget.campaign ? 'title' : 'name': texts,
      'description': {'tr': descs[0].text.trim(), 'en': descs[1].text.trim(), 'ar': descs[2].text.trim()},
    };
    if (widget.campaign) {
      final cents = _parseCents(price.text);
      if (cents == null) return setState(() => problem = 'Geçerli bir fiyat girin.');
      out['priceCents'] = cents;
      if (widget.row == null) {
        out['poster'] = poster.text.trim();
        out['thumbnail'] = thumb.text.trim();
      }
    }
    Navigator.pop(context, out);
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.row == null;
    final what = widget.campaign ? 'Kampanya' : 'Kategori';
    return Scaffold(
      appBar: AppBar(title: Text(isNew ? 'Yeni $what' : '$what Düzenle')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (isNew) _field(code, '$what kodu (ör. ${widget.campaign ? 'aksam-menusu' : 'icecekler'})',
          key: const ValueKey('menu-code')),
        _field(titles[0], widget.campaign ? 'Başlık · Türkçe' : 'Ad · Türkçe', key: const ValueKey('menu-title-tr')),
        _field(titles[1], 'English', key: const ValueKey('menu-title-en')),
        _field(titles[2], 'العربية', rtl: true, key: const ValueKey('menu-title-ar')),
        _field(descs[0], 'Açıklama · Türkçe', lines: 2),
        _field(descs[1], 'Description · English', lines: 2),
        _field(descs[2], 'الوصف · العربية', lines: 2, rtl: true),
        if (widget.campaign) ...[
          _field(price, 'Fiyat · ₺', key: const ValueKey('menu-campaign-price'),
            type: const TextInputType.numberWithOptions(decimal: true)),
          if (isNew) ...[
            _field(poster, 'Poster · assets/...'),
            _field(thumb, 'Küçük görsel · assets/...'),
            Text('Yeni kampanyalar pasif başlar; Windows’ta yayınlanınca görünür.',
              style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ]),
      bottomNavigationBar: _saveBar(context, save, problem),
    );
  }
}
