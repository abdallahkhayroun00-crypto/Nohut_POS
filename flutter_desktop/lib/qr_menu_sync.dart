import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'pos_logic.dart';
import 'pos_store.dart';
import 'qr_menu_reader.dart';

/// QR website is the authority for future local menu prices.
/// Existing order lines are immutable price snapshots and are NEVER touched.
///
/// No product deletion or rename is inferred from a name-only public feed.
/// A future catalog with permanent product IDs can safely support those.
class QrMenuSyncResult {
  const QrMenuSyncResult({
    required this.added,
    required this.repriced,
    required this.unlisted,
    required this.changed,
    required this.remoteCount,
  });

  final int added;
  final int repriced;
  final int unlisted;
  final bool changed;
  final int remoteCount;
}

const qrAutoSyncInterval = Duration(minutes: 10);
const qrAllowedCategories = <String>{
  'wrap',
  'plate',
  'fatte',
  'meze',
  'side',
  'salad',
  'dessert',
  'drink',
};

/// Pure reconciliation of PUBLIC catalog data against a copied POS snapshot.
/// Existing product IDs stay stable. Missing online products are left untouched
/// (removal or renaming needs explicit owner review).
QrMenuSyncResult reconcilePublishedMenu(
  Json state,
  PublishedQrMenu published,
) {
  if (published.products.length < 40 ||
      published.products.length > 500) {
    throw const FormatException(
      'QR katalog sayısı beklenmedik; yerel menü değiştirilmedi.',
    );
  }
  if (state['localMenu'] is! List) {
    throw const FormatException('Yerel menü henüz hazır değil.');
  }
  final products = (state['localMenu'] as List).cast<Map>();
  final localByName = <String, Map>{};
  final ids = <int>{};

  for (final p in products) {
    if (p['name'] is! String ||
        p['id'] is! int ||
        p['category'] is! String ||
        !ids.add(p['id'] as int) ||
        localByName.containsKey(p['name'])) {
      throw const FormatException('Yerel ürünler eşlenemedi.');
    }
    localByName[p['name'] as String] = p;
  }

  final remoteNames = <String>{};
  for (final p in published.products) {
    if (!qrAllowedCategories.contains(p.category) ||
        !remoteNames.add(p.name) ||
        p.priceTl < 0 ||
        p.priceTl > 100000 ||
        !p.priceTl.isFinite) {
      throw const FormatException(
        'QR ürünleri doğrulanamadı; senkronizasyon iptal edildi.',
      );
    }
    final local = localByName[p.name];
    if (local != null && local['category'] != p.category) {
      throw FormatException(
        'Ürün kategorisi çakışıyor: ${p.name}. Kayıtlar değiştirilmedi.',
      );
    }
  }

  var nextId = ids.isEmpty ? 0 : ids.reduce((a, b) => a > b ? a : b) + 1;
  var added = 0, repriced = 0;

  for (final p in published.products) {
    final local = localByName[p.name];
    if (local == null) {
      products.add({
        'id': nextId++,
        'category': p.category,
        'name': p.name,
        'price': p.priceTl,
      });
      added++;
    } else {
      final oldPrice = local['price'];
      if (oldPrice is! num ||
          (oldPrice * 100).round() != (p.priceTl * 100).round()) {
        local['price'] = p.priceTl;
        repriced++;
      }
    }
  }

  final unlisted = localByName.keys
      .where((name) => !remoteNames.contains(name))
      .length;

  final newCampaigns = [
    for (final c in published.campaigns)
      {
        'id': c.id,
        'active': c.active,
        'price': c.priceTl,
        'title': c.title,
        'description': c.description,
        'items': c.items,
        'poster': c.poster,
        'thumbnail': c.thumbnail,
        'startsAt': c.startsAt?.toUtc().toIso8601String(),
        'endsAt': c.endsAt?.toUtc().toIso8601String(),
      },
  ];

  final oldCampaigns = state['qrCampaigns'];
  final campaignChanged = jsonEncode(oldCampaigns) != jsonEncode(newCampaigns);
  if (campaignChanged) state['qrCampaigns'] = newCampaigns;

  final oldInfo = state['qrMenuSync'] as Map?;
  final newInfo = {
    'version': 1,
    'source': 'nohutfalafel.github.io/qr-menu',
    'remoteProducts': published.products.length,
    'unlistedLocalProducts': unlisted,
  };
  final infoChanged = oldInfo == null ||
      oldInfo['version'] != newInfo['version'] ||
      oldInfo['source'] != newInfo['source'] ||
      oldInfo['remoteProducts'] != newInfo['remoteProducts'] ||
      oldInfo['unlistedLocalProducts'] != newInfo['unlistedLocalProducts'];
  final changed = added > 0 || repriced > 0 || campaignChanged || infoChanged;
  if (changed) {
    state['qrMenuSync'] = {
      ...newInfo,
      'lastChangedAt': DateTime.now().toUtc().toIso8601String(),
    };
  }
  return QrMenuSyncResult(
    added: added,
    repriced: repriced,
    unlisted: unlisted,
    changed: changed,
    remoteCount: published.products.length,
  );
}

/// Runs while the Windows program is open: once at start, then every 10 mins.
/// On an HTTP error or invalid payload, the POS stays fully offline-capable.
/// Writes are atomic, revision-checked and retried against fresh SQLite state.
class QrMenuAutoSync extends ChangeNotifier {
  QrMenuAutoSync(this.store, {QrMenuReader? reader})
      : reader = reader ?? QrMenuReader();

  final PosStore store;
  final QrMenuReader reader;
  Timer? _timer;
  bool _busy = false;
  bool _disposed = false;

  bool get busy => _busy;
  DateTime? lastCheckedAtUtc;
  DateTime? lastSuccessAtUtc;
  String? lastError;
  QrMenuSyncResult? lastResult;

  bool get enabled =>
      (store.read().data['settings'] as Map?)?['qrAutoSync'] != false;

  void start() {
    if (_timer != null || _disposed) return;
    _timer = Timer.periodic(
      qrAutoSyncInterval,
      (_) => unawaited(syncNow()),
    );
    unawaited(syncNow());
  }

  Future<void> syncNow() async {
    if (_busy || _disposed || !enabled) return;
    _busy = true;
    lastError = null;
    notifyListeners();
    try {
      // No store access or mutation while waiting for the network.
      final remote = await reader.readPublishedMenu();
      if (_disposed) return;
      QrMenuSyncResult? result;
      for (var attempt = 0; attempt < 4; attempt++) {
        final current = store.read();
        final next = copyJson(current.data);
        result = reconcilePublishedMenu(next, remote);
        if (!result.changed) break;
        if (store.replace(next, current.revision).ok) break;
        if (attempt == 3) {
          throw const FormatException(
            'Kasa kaydı değişti; QR eşitlemesi sonra tekrar denenecek.',
          );
        }
      }
      lastResult = result;
      lastSuccessAtUtc = DateTime.now().toUtc();
    } catch (e) {
      if (_disposed) return;
      lastError = e.toString();
    } finally {
      if (!_disposed) {
        _busy = false;
        lastCheckedAtUtc = DateTime.now().toUtc();
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
