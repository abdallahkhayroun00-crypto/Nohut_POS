import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:nohut_core/finance_wire.dart';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:nohut_core/nohut_core.dart';

import 'manager_finance.dart';

/// Secure, restaurant-scoped outbox and cached quick expenses. An operation
/// is frozen on disk BEFORE transport and removed only after authenticated
/// acknowledgement. Retries reuse its exact request ID and payload.
class ExpenseDraftStore extends ChangeNotifier {
  ExpenseDraftStore(this.serverId, {FlutterSecureStorage? storage, http.Client? client})
      : storage = storage ?? const FlutterSecureStorage(), _client = client;
  static final _stores = <String, ExpenseDraftStore>{};
  static ExpenseDraftStore forServer(String serverId) =>
    _stores.putIfAbsent(serverId, () => ExpenseDraftStore(serverId));

  final String serverId;
  final FlutterSecureStorage storage;
  final http.Client? _client;
  String get key => 'finance_drafts_v1_$serverId';
  String get accessKey => 'finance_key_v1_$serverId';
  String? host;
  bool syncing = false;
  String? syncError;
  DateTime? lastSync;
  Future<void> _tail = Future.value();

  Future<T> exclusive<T>(Future<T> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<List<Map<String, dynamic>>> read() async {
    final raw = await storage.read(key: key);
    if (raw == null) return [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('Taslak kaydı okunamadı.');
    }
    return decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> write(List<Map<String, dynamic>> entries) async {
    await storage.write(key: key, value: jsonEncode(entries));
    notifyListeners();
  }

  Future<bool> configured() async => await storage.read(key: accessKey) != null;

  Future<void> disconnect() async {
    host = null;
    await exclusive(() async {
      await storage.delete(key: accessKey);
      final saved = await storage.readAll();
      for (final k in saved.keys.where((k) => k.startsWith(reportCacheKey + '_'))) {
        await storage.delete(key: k);
      }
      // Preserve unacknowledged operations, but remove downloaded PC data.
      final entries = await read();
      await write(entries.where((e) => e['status'] != 'synced').toList());
      lastSync = null;
    });
  }

  Future<void> configure(String secret) async {
    FinanceWire.keyBytes(secret);
    await exclusive(() async {
      final saved = await storage.readAll();
      for (final k in saved.keys.where((k) => k.startsWith(reportCacheKey + '_'))) {
        await storage.delete(key: k);
      }
      await storage.write(key: accessKey, value: secret.trim());
      syncError = null;
      lastSync = null;
      notifyListeners();
    });
  }

  static bool editable(Map<String, dynamic> entry) =>
    ['local_draft', 'synced'].contains(entry['status']) && entry['voided'] != true;

  static Map<String, dynamic> cached(Map<String, dynamic> row) => {
    ...row,
    'id': 'pc_' + row['id'].toString(),
    'recordId': row['id'],
    'status': 'synced',
  };

  static Map<String, dynamic> operation(Map<String, dynamic> entry) => {
    'requestId': FinanceWire.randomId(),
    'operation': entry['operation'] == 'void' ? 'void' :
      entry['recordId'] == null ? 'create' : 'edit',
    if (entry['recordId'] != null) 'recordId': entry['recordId'],
    if (entry['recordId'] != null) 'expectedUpdatedAt': entry['updatedAt'],
    if (entry['operation'] != 'void') 'entry': {
      for (final field in ['date', 'storeBrand', 'market', 'amountsCents',
        'paymentMethod', 'note']) field: entry[field],
    },
  };

  Future<Map<String, dynamic>> _send(String secret, Uri uri,
      Map<String, dynamic> payload) async {
    final envelope = await FinanceWire.seal(secret, serverId, 'request', payload);
    final client = _client ?? http.Client();
    final http.Response response;
    try {
      response = await client.post(uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(envelope)).timeout(const Duration(seconds: 10));
    } finally {
      if (_client == null) client.close();
    }
    if (response.statusCode != 200) {
      throw const FormatException('Finans erişimi veya bağlantı doğrulanamadı.');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) throw const FormatException('Geçersiz sunucu yanıtı.');
    return FinanceWire.open(secret, serverId,
      'response:' + envelope['nonce'].toString(),
      Map<String, dynamic>.from(decoded));
  }

  String get reportCacheKey => 'finance_view_v2_$serverId';

  Future<Map<String, dynamic>?> cachedMonth(String month) async {
    if (!await configured()) return null;
    final raw = await storage.read(key: reportCacheKey + '_' + month);
    if (raw == null) return null;
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  String get managerQueueKey => 'finance_manager_queue_v1_$serverId';

  Future<List<Map<String, dynamic>>> managerQueue() async {
    final raw = await storage.read(key: managerQueueKey);
    if (raw == null) return [];
    return (jsonDecode(raw) as List).map((r) =>
      Map<String, dynamic>.from(r as Map)).toList();
  }

  Future<void> _saveManagerQueue(List<Map<String, dynamic>> queue) async {
    await storage.write(key: managerQueueKey, value: jsonEncode(queue));
    notifyListeners();
  }

  Future<void> enqueueManager(String action, Map<String, dynamic> data) =>
    exclusive(() async {
      if (!await configured()) throw const FormatException('Finans anahtarı gerekli.');
      final queue = await managerQueue();
      queue.add({
        'status': 'pending',
        'payload': {'operation': 'managerWrite', 'requestId': FinanceWire.randomId(),
          'action': action, 'data': data},
      });
      await _saveManagerQueue(queue);
    });

  Future<void> discardManagerConflict(String id) => exclusive(() async {
    final queue = await managerQueue();
    await _saveManagerQueue(queue.where((e) =>
      !(e['status'] == 'conflict' && (e['payload'] as Map)['requestId'] == id)).toList());
  });

  Future<void> _flushManager(String secret, Uri endpoint) async {
    final queue = await managerQueue();
    // Stop on a transport failure; the original durable payload stays intact.
    for (var i = 0; i < queue.length;) {
      final item = queue[i];
      if (item['status'] != 'pending') { i++; continue; }
      final response = await _send(secret, endpoint,
        Map<String, dynamic>.from(item['payload'] as Map));
      if (response['ok'] == true) {
        queue.removeAt(i);
      } else if (['conflict', 'invalid'].contains(response['error'])) {
        queue[i] = {...item, 'status': 'conflict', 'message': response['message']};
        i++;
      } else {
        throw const FormatException('Yönetici işlemi onaylanmadı.');
      }
      await _saveManagerQueue(queue);
    }
  }

  Future<Map<String, dynamic>> _managerRequest(Map<String, dynamic> payload) async {
    final secret = await storage.read(key: accessKey);
    final uri = Uri.tryParse(host ?? '');
    if (secret == null || uri == null || !_local(uri)) {
      throw const FormatException('Windows bağlantısı ve yönetici finans anahtarı gerekli.');
    }
    final response = await _send(secret,
      uri.replace(path: '/api/finance/v1', query: ''), payload);
    if (response['ok'] != true) {
      throw FormatException((response['message'] ?? 'Finans isteği başarısız.').toString());
    }
    return response;
  }

  Future<Map<String, dynamic>> managerRequest(Map<String, dynamic> payload) =>
    exclusive(() => _managerRequest(payload));

  Future<Map<String, dynamic>> fetchMonth(String month) => exclusive(() async {
    final response = await _managerRequest({'operation': 'monthView', 'month': month});
    final view = Map<String, dynamic>.from(response['view'] as Map);
    view['snapshotAt'] = response['updatedAt'];
    view['revision'] = response['revision'];
    await storage.write(key: reportCacheKey + '_' + month, value: jsonEncode(view));
    return view;
  });

  bool _local(Uri uri) {
    final b = InternetAddress.tryParse(uri.host)?.rawAddress;
    return uri.scheme == 'http' && uri.userInfo.isEmpty && b != null &&
      b.length == 4 && (b[0] == 10 || (b[0] == 192 && b[1] == 168) ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31));
  }

  Future<void> sync({bool force = false}) async {
    if (syncing || host == null) return;
    if (!force && lastSync != null &&
        DateTime.now().difference(lastSync!) < const Duration(seconds: 20)) return;
    final uri = Uri.tryParse(host!);
    if (uri == null || !_local(uri)) return;
    syncing = true;
    notifyListeners();
    try {
      await exclusive(() async {
        final secret = await storage.read(key: accessKey);
        if (secret == null) return;
        final endpoint = uri.replace(path: '/api/finance/v1', query: '');
        var entries = await read();
        for (var i = 0; i < entries.length; i++) {
          var entry = entries[i];
          if (!['local_draft', 'pending'].contains(entry['status'])) continue;
          final payload = entry['status'] == 'pending'
            ? Map<String, dynamic>.from(entry['pendingPayload'] as Map)
            : operation(entry);
          if (entry['status'] != 'pending') {
            entry = {...entry, 'status': 'pending', 'pendingPayload': payload};
            entries[i] = entry;
            await write(entries); // durable before sending
          }
          final response = await _send(secret, endpoint, payload);
          if (response['ok'] == true && response['record'] is Map) {
            entries[i] = cached(Map<String, dynamic>.from(response['record'] as Map));
          } else if (['conflict', 'invalid'].contains(response['error'])) {
            entries[i] = {...entry, 'status': 'conflict',
              'syncMessage': response['message']};
          } else {
            throw const FormatException('İşlem onayı alınamadı.');
          }
          await write(entries);
        }
        await _flushManager(secret, endpoint);
        // Full paginated quick-expense view. Keep unsent edits intact.
        final remote = <Map<String, dynamic>>[];
        var cursor = 0;
        while (true) {
          final response = await _send(secret, endpoint,
            {'operation': 'pull', 'afterId': cursor});
          if (response['ok'] != true || response['records'] is! List) {
            throw const FormatException('Giderler okunamadı.');
          }
          final page = (response['records'] as List).map((r) =>
            Map<String, dynamic>.from(r as Map)).toList();
          remote.addAll(page.map(cached));
          if (response['hasMore'] != true) break;
          if (page.isEmpty || (page.last['id'] as int) <= cursor) {
            throw const FormatException('Gider sayfalaması geçersiz.');
          }
          cursor = page.last['id'] as int;
        }
        final pending = entries.where((e) => e['status'] != 'synced').toList();
        final pendingIds = pending.map((e) => e['recordId']).whereType<int>().toSet();
        entries = [
          ...pending,
          ...remote.where((e) => !pendingIds.contains(e['recordId'])),
        ];
        await write(entries);
        lastSync = DateTime.now();
        syncError = null;
      });
    } catch (_) {
      syncError = 'Senkronizasyon tamamlanmadı. Bekleyen kayıtlar korundu.';
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  Future<void> discardConflict(String id) async {
    await exclusive(() async {
      final entries = await read();
      await write(entries.where((e) =>
        !(e['id'] == id && e['status'] == 'conflict')).toList());
    });
    await sync(force: true);
  }
}

class ExpenseDraftPage extends StatefulWidget {
  const ExpenseDraftPage({super.key, required this.store, this.ownerMode = false});
  final bool ownerMode;
  final ExpenseDraftStore store;

  @override
  State<ExpenseDraftPage> createState() => _ExpenseDraftPageState();
}

class _ExpenseDraftPageState extends State<ExpenseDraftPage> {
  List<Map<String, dynamic>> entries = [];
  bool busy = true;
  String? error;

  static String _day(DateTime d) => d.toIso8601String().substring(0, 10);
  static DateTime _today() => DateTime.now().toUtc().add(
    const Duration(hours: 3));
  static String _money(int cents) =>
      (cents / 100).toStringAsFixed(2).replaceAll('.', ',') + ' ₺';

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_storeChanged);
    _load();
  }

  void _storeChanged() {
    if (mounted) {
      setState(() {});
      _load();
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_storeChanged);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final next = await widget.store.read();
      if (mounted) setState(() { entries = next; busy = false; error = null; });
    } catch (_) {
      if (mounted) setState(() {
        busy = false;
        error = 'Taslaklar okunamadı. Veriler değiştirilmedi.';
      });
    }
  }

  Future<void> _edit([Map<String, dynamic>? previous]) async {
    if (busy || error != null || widget.store.syncing) return;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ExpenseDraftDialog(previous: previous),
    );
    if (!mounted || result == null) return;
    try {
      await widget.store.exclusive(() async {
        final latest = await widget.store.read();
        if (previous == null) {
          latest.add(result);
        } else {
          final index = latest.indexWhere((e) => e['id'] == previous['id']);
          if (index < 0 || !ExpenseDraftStore.editable(latest[index]) ||
              latest[index]['updatedAt'] != previous['updatedAt'] ||
              latest[index]['status'] != previous['status']) {
            throw const FormatException('Kayıt değişti. Yenileyip tekrar deneyin.');
          }
          latest[index] = result;
        }
        await widget.store.write(latest);
      });
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is FormatException ? e.message :
          'Kayıt kaydedilemedi. Önceki bilgiler korundu.')));
    }
  }

  Future<void> _remove(Map<String, dynamic> entry) async {
    final remote = entry['recordId'] != null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(remote ? 'Gider iptal edilsin mi?' : 'Yerel taslak silinsin mi?'),
        content: Text(remote ? 'Windows onayı alınana kadar iptal bekler.' :
          'Bu işlem yalnızca telefondaki taslağı siler.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Onayla')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.store.exclusive(() async {
        final latest = await widget.store.read();
        final index = latest.indexWhere((e) => e['id'] == entry['id']);
        if (index < 0 || !ExpenseDraftStore.editable(latest[index]) ||
            latest[index]['updatedAt'] != entry['updatedAt'] ||
            latest[index]['status'] != entry['status']) {
          throw const FormatException('Kayıt değişti. Önce yenileyin.');
        }
        if (remote) {
          latest[index] = {...latest[index], 'operation': 'void', 'status': 'local_draft'};
        } else {
          latest.removeAt(index);
        }
        await widget.store.write(latest);
      });
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('İşlem uygulanamadı. Kayıt korundu.')));
    }
  }

  Future<void> _configure() async {
    final controller = TextEditingController();
    final secret = await showDialog<String>(context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Yönetici Finans Anahtarı'),
        content: TextField(controller: controller, obscureText: true,
          autocorrect: false, enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'Windows finans anahtarı')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Bağla')),
        ],
      ));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    if (secret == null || !mounted) return;
    try {
      await widget.store.configure(secret);
      await widget.store.sync(force: true);
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Geçersiz finans anahtarı.')));
    }
  }

  String _status(Map<String, dynamic> e) => switch (e['status']) {
    'synced' => e['voided'] == true ? 'İptal' : 'Senkronize edildi',
    'pending' => 'Onay bekliyor · tekrar gönderilecek',
    'conflict' => 'Çakışma / hata · ' + (e['syncMessage'] ?? '').toString(),
    _ => 'Yerel taslak · Gönderilmedi',
  };

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Hızlı Günlük Giderler',
            style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text('Çevrimdışı giriş · Windows onayı gelene kadar giderler '
            'bekler. Finans anahtarı ile restoran ağına bağlanın.'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (!widget.ownerMode) OutlinedButton.icon(onPressed: widget.store.syncing ? null : _configure,
              icon: const Icon(Icons.vpn_key_outlined), label: const Text('Finans Anahtarı')),
            OutlinedButton.icon(onPressed: widget.store.syncing ? null :
              () => widget.store.sync(force: true), icon: const Icon(Icons.sync),
              label: const Text('Şimdi Senkronize Et')),
          ]),
          OutlinedButton.icon(
            onPressed: () async {
              if (!await widget.store.configured()) {
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Önce yönetici finans anahtarını girin.')));
                return;
              }
              if (!mounted) return;
              await Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  appBar: AppBar(title: const Text('Nohut · Finans')),
                  body: ManagerFinancePage(store: widget.store),
                )));
            },
            icon: const Icon(Icons.bar_chart),
            label: const Text('Finans · Maaşlar · PDF'),
          ),
          if (widget.store.syncing) const LinearProgressIndicator(),
          if (widget.store.syncError != null) Text(widget.store.syncError!),
          if (widget.store.lastSync != null) const Text('Windows ile son bağlantı başarılı.'),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey('android-quick-draft-add'),
            onPressed: busy || error != null || widget.store.syncing ? null : () => _edit(),
            icon: const Icon(Icons.add),
            label: const Text('Gider Taslağı Ekle'),
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null) ...[
            Text(error!),
            TextButton(onPressed: busy ? null : _load,
              child: const Text('Tekrar Dene')),
          ],
          for (final entry in entries)
            Card(child: ListTile(
              title: Text(entry['storeBrand'].toString() + ' · ' +
                _money(entry['totalCents'] as int)),
              subtitle: Text(entry['date'].toString() + ' · ' + _status(entry)),
              onTap: busy || error != null || widget.store.syncing ||
                !ExpenseDraftStore.editable(entry) ? null : () => _edit(entry),
              trailing: entry['status'] == 'conflict'
                ? TextButton(
                    onPressed: widget.store.syncing ? null : () async {
                      final ok = await showDialog<bool>(context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Yerel değişiklikten vazgeç?'),
                          content: const Text('Yerel değişiklik silinir; Windows kaydı yeniden alınır.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
                            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Windows Kaydını Al')),
                          ],
                        ));
                      if (ok == true && mounted) {
                        await widget.store.discardConflict(entry['id'].toString());
                      }
                    },
                    child: const Text('Vazgeç'))
                : IconButton(
                    tooltip: 'Gideri İptal Et',
                    onPressed: busy || error != null || widget.store.syncing ||
                      !ExpenseDraftStore.editable(entry) ? null : () => _remove(entry),
                    icon: const Icon(Icons.delete_outline)),
            )),
          if (!busy && entries.isEmpty && error == null)
            const Padding(padding: EdgeInsets.all(16),
              child: Text('Henüz taslak yok.')),
        ],
      ),
    ),
  );
}

class _ExpenseDraftDialog extends StatefulWidget {
  const _ExpenseDraftDialog({this.previous});
  final Map<String, dynamic>? previous;

  @override
  State<_ExpenseDraftDialog> createState() => _ExpenseDraftDialogState();
}

class _ExpenseDraftDialogState extends State<_ExpenseDraftDialog> {
  late String store = (widget.previous?['storeBrand'] ?? 'BİM').toString();
  late String date = (widget.previous?['date'] ??
    _ExpenseDraftPageState._day(_ExpenseDraftPageState._today())).toString();
  late final market = TextEditingController(
    text: (widget.previous?['market'] ?? '').toString());
  late final note = TextEditingController(
    text: (widget.previous?['note'] ?? '').toString());
  late String method = (widget.previous?['paymentMethod'] ?? 'Nakit').toString();
  late final amounts = <TextEditingController>[
    if (widget.previous?['amountsCents'] is List)
      for (final value in widget.previous!['amountsCents'] as List)
        TextEditingController(text: ((value as int) / 100).toStringAsFixed(2))
    else TextEditingController(),
  ];
  final removed = <TextEditingController>[];
  String? error;

  @override
  void dispose() {
    for (final c in [...amounts, ...removed, market, note]) {
      c.dispose();
    }
    super.dispose();
  }

  List<int> _values() => amounts.map((c) => parseExpenseCents(c.text)).toList();

  @override
  Widget build(BuildContext context) {
    int? total;
    try { total = quickMaterialTotalCents(_values()); } on FormatException {
      // Blank/incomplete fields are not treated as money.
    }
    return AlertDialog(
      title: Text(widget.previous == null ? 'Gider Taslağı Ekle' : 'Taslağı Düzenle'),
      content: SizedBox(width: 480, child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.calendar_today_outlined),
              label: Text(date),
              onPressed: () async {
                final today = _ExpenseDraftPageState._today();
                final selected = await showDatePicker(
                  context: context, initialDate: DateTime.parse(date),
                  firstDate: DateTime(2000), lastDate: today);
                if (selected != null && mounted) {
                  setState(() => date = _ExpenseDraftPageState._day(selected));
                }
              },
            ),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final brand in materialStores)
                ChoiceChip(label: Text(brand), selected: store == brand,
                  onSelected: (_) => setState(() => store = brand)),
            ]),
            if (store == 'Diğer')
              TextField(controller: market, maxLength: 160,
                decoration: const InputDecoration(labelText: 'Market adı')),
            const SizedBox(height: 10),
            for (var i = 0; i < amounts.length; i++)
              Row(key: ObjectKey(amounts[i]), children: [
                Expanded(child: TextField(
                  controller: amounts[i],
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: 'Tutar ' +
                    (i + 1).toString() + ' (₺)'),
                  onChanged: (_) => setState(() => error = null))),
                IconButton(icon: const Icon(Icons.remove_circle_outline),
                  tooltip: 'Tutarı Kaldır',
                  onPressed: amounts.length <= 1 ? null :
                    () => setState(() => removed.add(amounts.removeAt(i)))),
              ]),
            TextButton.icon(icon: const Icon(Icons.add),
              label: const Text('Tutar Ekle'),
              onPressed: amounts.length >= 100 ? null :
                () => setState(() => amounts.add(TextEditingController()))),
            DropdownButtonFormField<String>(
              initialValue: method, isExpanded: true,
              decoration: const InputDecoration(labelText: 'Ödeme'),
              items: [for (final m in financeMethods)
                DropdownMenuItem(value: m, child: Text(m))],
              onChanged: (m) => setState(() => method = m ?? method)),
            TextField(controller: note, maxLength: 500,
              decoration: const InputDecoration(labelText: 'Not')),
            Text('Toplam: ' + (total == null ? '—' :
              _ExpenseDraftPageState._money(total)),
              style: Theme.of(context).textTheme.titleLarge),
            if (error != null) Text(error!,
              style: const TextStyle(color: Colors.red)),
          ],
        ),
      )),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context),
          child: const Text('Vazgeç')),
        FilledButton(onPressed: () {
          try {
            final values = _values();
            final sum = quickMaterialTotalCents(values);
            Navigator.pop(context, <String, dynamic>{
              'id': widget.previous?['id'] ?? FinanceWire.randomId(),
              if (widget.previous?['recordId'] != null) ...{
                'recordId': widget.previous!['recordId'],
                'updatedAt': widget.previous!['updatedAt'],
              },
              'date': date, 'storeBrand': store,
              'market': store == 'Diğer' ? market.text.trim() : store,
              'amountsCents': values, 'totalCents': sum,
              'paymentMethod': method, 'note': note.text.trim(),
              'status': 'local_draft',
            });
          } on FormatException catch (e) {
            setState(() => error = e.message);
          }
        }, child: const Text('Cihaza Kaydet')),
      ],
    );
  }
}
