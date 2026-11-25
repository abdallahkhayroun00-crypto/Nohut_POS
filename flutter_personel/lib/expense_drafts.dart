import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:nohut_core/nohut_core.dart';

/// Local-only expense drafts. No server credentials or salary data are
/// accessed. A later authenticated finance protocol must acknowledge each
/// immutable request ID before a draft can be considered synchronized.
class ExpenseDraftStore {
  ExpenseDraftStore(this.serverId, {FlutterSecureStorage? storage})
      : storage = storage ?? const FlutterSecureStorage();
  final String serverId;
  final FlutterSecureStorage storage;
  String get key => 'finance_drafts_v1_$serverId';

  Future<List<Map<String, dynamic>>> read() async {
    final raw = await storage.read(key: key);
    if (raw == null) return [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('Taslak kaydı okunamadı.');
    }
    return decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> write(List<Map<String, dynamic>> entries) =>
      storage.write(key: key, value: jsonEncode(entries));
}

class ExpenseDraftPage extends StatefulWidget {
  const ExpenseDraftPage({super.key, required this.store});
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
    _load();
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

  Future<void> _save(List<Map<String, dynamic>> next) async {
    setState(() => busy = true);
    try {
      await widget.store.write(next);
      if (mounted) setState(() { entries = next; error = null; });
    } catch (_) {
      if (mounted) setState(() =>
        error = 'Cihaza kaydedilemedi. Önceki taslaklar korundu.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _edit([Map<String, dynamic>? previous]) async {
    if (busy || error != null) return;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ExpenseDraftDialog(previous: previous),
    );
    if (!mounted || result == null) return;
    final next = [...entries];
    final index = previous == null ? -1 :
      next.indexWhere((e) => e['id'] == previous['id']);
    if (index < 0) {
      next.add(result);
    } else {
      next[index] = result;
    }
    await _save(next);
  }

  Future<void> _remove(Map<String, dynamic> entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Yerel taslak silinsin mi?'),
        content: const Text('Bu işlem yalnızca telefondaki taslağı siler.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sil')),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _save(entries.where((e) => e['id'] != entry['id']).toList());
    }
  }

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Hızlı Gider Taslakları',
            style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text('Çevrimdışı giriş · Bu sürümde yalnızca cihazda saklanır. '
            'Windows finansına gönderilmez ve resmi gider sayılmaz.'),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey('android-quick-draft-add'),
            onPressed: busy || error != null ? null : () => _edit(),
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
              subtitle: Text(entry['date'].toString() +
                ' · Yerel taslak · Gönderilmedi'),
              onTap: busy || error != null ? null : () => _edit(entry),
              trailing: IconButton(
                tooltip: 'Taslağı Sil',
                onPressed: busy || error != null ? null : () => _remove(entry),
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
              'id': widget.previous?['id'] ??
                DateTime.now().microsecondsSinceEpoch.toString(),
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
