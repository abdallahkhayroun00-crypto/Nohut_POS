import 'dart:io';

import 'package:nohut_core/finance_wire.dart';

import 'finance_logic.dart';
import 'pos_logic.dart';
import 'pos_store.dart';
import 'windows_vault.dart';

/// Independent, physically enrolled financial capability. Never grant it to
/// an ordinary staff bearer token. The key is held in the Windows DPAPI vault.
class FinanceSyncServer {
  FinanceSyncServer(this.store) :
    vault = WindowsVault(File(store.filePath + '.finance-sync.dpapi'));

  final PosStore store;
  final WindowsVault vault;
  int _generation = 0;

  Future<String> rotateKey() async {
    _generation++;
    final key = FinanceWire.createKey();
    await vault.save({'key': key});
    return key;
  }

  Future<void> revoke() async {
    _generation++;
    await vault.clear();
  }

  static Json project(Json p) => {
    for (final name in [
      'id', 'date', 'storeBrand', 'market', 'amountsCents', 'totalCents',
      'paymentMethod', 'note', 'updatedAt', 'voided', 'voidedAt',
    ]) name: p[name],
  };

  /// Executed under the existing SQLite transaction and idempotency receipt.
  /// An edit/void requires the exact prior record version.
  static Json apply(PosStore store, Json payload) {
    final operation = payload['operation'];
    final requestId = payload['requestId'];
    if (requestId is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{16,80}$').hasMatch(requestId) ||
        !['create', 'edit', 'void'].contains(operation)) {
      throw const FormatException('Finans işlemi geçersiz.');
    }
    return store.command('fin_' + requestId, payload, (state) {
      final entries = financeRows(state, 'materials');
      final id = payload['recordId'];
      if (operation != 'create') {
        if (id is! int) throw const FormatException('Kayıt kimliği geçersiz.');
        final current = entries.where((p) => p['id'] == id).firstOrNull;
        if (current == null || !isQuickMaterial(current) ||
            current['voided'] == true ||
            current['updatedAt'] == null ||
            current['updatedAt'] != payload['expectedUpdatedAt']) {
          // No mutation; do not acknowledge an edit that was not applied.
          throw const FinanceVersionConflict();
        }
      }
      if (operation == 'void') {
        voidMaterialPurchase(state, id as int, 'Android yönetici iptali');
      } else {
        final data = payload['entry'];
        if (data is! Map || data['amountsCents'] is! List ||
            data['date'] is! String || data['storeBrand'] is! String ||
            data['paymentMethod'] is! String || data['market'] is! String ||
            data['note'] is! String ||
            !(data['amountsCents'] as List).every((x) => x is int)) {
          throw const FormatException('Gider alanları geçersiz.');
        }
        saveQuickMaterialPurchase(state,
          id: operation == 'create' ? null : id as int,
          date: data['date'] as String,
          storeBrand: data['storeBrand'] as String,
          amountsCents: (data['amountsCents'] as List).cast<int>(),
          market: data['market'] as String,
          paymentMethod: data['paymentMethod'] as String,
          note: data['note'] as String,
        );
      }
      final updated = financeRows(state, 'materials');
      final row = operation == 'create'
        ? updated.reduce((a, b) => (a['id'] as int) > (b['id'] as int) ? a : b)
        : updated.firstWhere((p) => p['id'] == id);
      return {'ok': true, 'record': project(row)};
    });
  }

  Future<Json> handle(Json envelope, String serverId) async {
    final generation = _generation;
    final key = (await vault.load())?['key'];
    if (key is! String) throw const FormatException('Finans erişimi kapalı.');
    final payload = await FinanceWire.open(key, serverId, 'request', envelope);
    if (generation != _generation) throw const FormatException('Finans erişimi değişti.');
    Json result;
    try {
      if (payload['operation'] == 'pull') {
        final cursor = payload['afterId'];
        if (cursor is! int || cursor < 0) {
          throw const FormatException('Sayfa kimliği geçersiz.');
        }
        final rows = financeRows(store.read().data, 'materials')
          .where((p) => isQuickMaterial(p) && p['id'] is int &&
            (p['id'] as int) > cursor).toList()
          ..sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
        result = {
          'ok': true, 'records': rows.take(100).map(project).toList(),
          'hasMore': rows.length > 100,
        };
      } else {
        result = apply(store, payload);
      }
    } on FinanceVersionConflict {
      result = {'ok': false, 'error': 'conflict',
        'message': 'Kayıt Windows üzerinde değişti. Yenileyin ve karşılaştırın.'};
    } on FormatException catch (e) {
      result = {'ok': false, 'error': 'invalid', 'message': e.message};
    }
    return FinanceWire.seal(key, serverId,
      'response:' + envelope['nonce'].toString(), result);
  }
}

class FinanceVersionConflict implements Exception {
  const FinanceVersionConflict();
}
