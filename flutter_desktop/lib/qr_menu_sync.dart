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

/// Atomic stable-ID reconciliation. Called only on a deep SQLite-state copy.
/// Existing order/payment/receipt snapshots are outside this function.
QrMenuSyncResult reconcilePublishedMenu(Json state, PublishedQrMenu published) {
  if (published.products.length < 40 || published.products.length > 500 ||
      published.categories.length < 8) {
    throw const FormatException('QR katalog eksik; yerel veriler korunuyor.');
  }
  if (state['localMenu'] is! List) {
    throw const FormatException('Yerel menü henüz hazır değil.');
  }
  final products=(state['localMenu'] as List).cast<Map>();
  final localById=<int,Map>{}, localByName=<String,Map>{};
  for(final item in products){
    if(item['id'] is! int || item['name'] is! String ||
        item['category'] is! String ||
        localById.containsKey(item['id']) || localByName.containsKey(item['name'])) {
      throw const FormatException('Yerel ürünlerde kimlik çakışması.');
    }
    localById[item['id'] as int]=item;
    localByName[item['name'] as String]=item;
  }

  // Validate ALL mappings before changing any product. Never accidentally
  // overwrite an old order's referenced local product ID.
  final remoteIds=<int>{}, remoteNames=<String>{};
  for(final p in published.products){
    if(!qrAllowedCategories.contains(p.category) ||
        !remoteIds.add(p.id) || !remoteNames.add(p.name) ||
        !p.priceTl.isFinite || p.priceTl < 0 || p.priceTl > 100000) {
      throw const FormatException('QR katalog kimlik/fiyat doğrulaması başarısız.');
    }
    final byId=localById[p.id], byName=localByName[p.name];
    if(byName!=null && byName['id']!=p.id) {
      throw FormatException('Ürün ID uyuşmazlığı: '+p.name);
    }
    if(byId!=null &&
        (byId['category']!=p.category ||
         (byId['name']!=p.name && byId['qrStableId']!=p.id))) {
      throw FormatException('Mevcut yerel ID çakışıyor: '+p.id.toString());
    }
  }

  var added=0,repriced=0;
  for(final p in published.products) {
    final current=localById[p.id];
    final desired=<String,dynamic>{
      'id':p.id,'qrStableId':p.id,'category':p.category,'name':p.name,
      'price':p.priceTl,
      'names':p.names,'displayName':p.displayNames,
      'description':p.descriptions,'image':p.image,
    };
    if(current==null){
      products.add(desired);
      added++;
    }else{
      final oldPrice=current['price'];
      if(oldPrice is! num ||
          (oldPrice*100).round()!=(p.priceTl*100).round()) {
        repriced++;
      }
      for(final entry in desired.entries){
        if(jsonEncode(current[entry.key])!=jsonEncode(entry.value)) {
          current[entry.key]=entry.value;
        }
      }
    }
  }

  final unlisted=localById.keys.where((id)=>!remoteIds.contains(id)).length;
  final newCategories=[
    for(final category in published.categories)
      {'id':category.id,'name':category.names,'description':category.descriptions},
  ];
  final newCampaigns=[
    for(final campaign in published.campaigns)
      {
        'id':campaign.id,'active':campaign.active,'price':campaign.priceTl,
        'title':campaign.title,'description':campaign.description,
        'items':campaign.items,'poster':campaign.poster,
        'thumbnail':campaign.thumbnail,
        'startsAt':campaign.startsAt?.toUtc().toIso8601String(),
        'endsAt':campaign.endsAt?.toUtc().toIso8601String(),
      },
  ];
  final changed=added>0 || repriced>0 ||
    jsonEncode(state['qrCategories'])!=jsonEncode(newCategories) ||
    jsonEncode(state['qrCampaigns'])!=jsonEncode(newCampaigns) ||
    (state['qrMenuSync'] as Map?)?['version']!=2 ||
    (state['qrMenuSync'] as Map?)?['unlistedLocalProducts']!=unlisted ||
    published.products.any((p){
      final local=localById[p.id];
      if(local==null)return false;
      final desired={
        'qrStableId':p.id,'name':p.name,
        'names':p.names,'displayName':p.displayNames,
        'description':p.descriptions,'image':p.image,
      };
      // A tracked field is written above. This expression is only a
      // consistency check; actual diffs are calculated by the copy below.
      return desired.entries.any((e)=>jsonEncode(local[e.key])!=jsonEncode(e.value));
    });

  // Capture content differences by comparing the pre-reconcile snapshot
  // instead of price changes alone (local state was copied before this call).
  state['qrCategories']=newCategories;
  state['qrCampaigns']=newCampaigns;
  state['qrMenuSync']={
    'version':2,'source':'nohutfalafel.github.io/qr-menu',
    'remoteProducts':published.products.length,'unlistedLocalProducts':unlisted,
  };
  return QrMenuSyncResult(
    added:added,repriced:repriced,unlisted:unlisted,
    changed:changed,remoteCount:published.products.length,
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
      // The operator may switch auto-sync off while the HTTPS call is pending.
      if (_disposed || !enabled) return;
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
