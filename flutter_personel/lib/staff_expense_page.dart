// Hızlı Gider for Personel (§24.8, G1). Only with the explicit
// `expenses.quick_add` grant. Staff add a purchase and see their own entries
// of the last 30 days; editing and voiding stay with the Yönetici.
import 'package:flutter/material.dart';

import 'expense_drafts.dart' show QuickExpenseDialog;
import 'pos_api.dart';
import 'style.dart';
import 'work_page.dart' show WorkFormat;

const staffExpenseGrant = 'expenses.quick_add';

bool canSubmitExpenses(NohutApi api) {
  final s = api.sessionInfo['session'];
  return api.signedIn && s is Map && s['grants'] is List &&
      (s['grants'] as List).contains(staffExpenseGrant);
}

class StaffExpensePage extends StatefulWidget {
  const StaffExpensePage({super.key, required this.api});
  final NohutApi api;
  @override
  State<StaffExpensePage> createState() => _StaffExpensePageState();
}

class _StaffExpensePageState extends State<StaffExpensePage> {
  List<Json> rows = [];
  String? error;
  bool loading = true, sending = false;
  /// A send that got no answer keeps its request ID, so a retry can never
  /// add the purchase twice.
  (String, Json)? _unsent;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { loading = true; error = null; });
    try {
      final (status, body) = await widget.api.work('GET', 'expenses');
      if (!mounted) return;
      setState(() {
        if (status == 200) {
          rows = [for (final r in (body['expenses'] as List? ?? const [])) Map<String, dynamic>.from(r as Map)];
        } else {
          error = status == 403 ? 'Gider ekleme yetkiniz yok. Yöneticinizden isteyin.'
              : '${body['message'] ?? 'Giderler alınamadı.'}';
        }
      });
    } on Object catch (e) {
      if (mounted) setState(() => error = e is FormatException ? e.message : 'Windows’a ulaşılamadı.');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _add() async {
    final v = await showDialog<Map<String, dynamic>>(context: context,
      builder: (_) => const QuickExpenseDialog(title: 'Hızlı Gider Ekle', saveLabel: 'Gönder'));
    if (v == null || !mounted) return;
    await _send(requestId(), v);
  }

  Future<void> _send(String id, Json v) async {
    setState(() { sending = true; _unsent = (id, v); });
    try {
      final (status, body) = await widget.api.work('POST', 'expense', body: {
        'requestId': id, 'date': v['date'], 'storeBrand': v['storeBrand'],
        'market': v['market'], 'amountsCents': v['amountsCents'],
        'paymentMethod': v['paymentMethod'], 'note': v['note'],
      });
      if (!mounted) return;
      if (status == 200) {
        _unsent = null;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Gider kaydedildi · ${money((body['totalCents'] as num?)?.toInt() ?? 0)}')));
        await _load();
      } else {
        // Refused: nothing was written, the draft can be dropped.
        _unsent = null;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${body['message'] ?? 'Gider kaydedilemedi.'}')));
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Yanıt alınamadı. “Tekrar Gönder” aynı gideri ikinci kez eklemez.')));
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nc = context.nohut;
    final unsent = _unsent;
    final total = rows.where((r) => r['voided'] != true)
        .fold<int>(0, (n, r) => n + ((r['totalCents'] as num?)?.toInt() ?? 0));
    return Scaffold(
      appBar: AppBar(title: const Text('Hızlı Gider')),
      floatingActionButton: error == null ? FloatingActionButton.extended(
        key: const ValueKey('staff-expense-add'),
        onPressed: sending ? null : _add,
        icon: const Icon(Icons.add),
        label: const Text('Hızlı Gider Ekle')) : null,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 96), children: [
          if (unsent != null && !sending)
            Card(color: Theme.of(context).colorScheme.errorContainer, child: ListTile(
              key: const ValueKey('staff-expense-retry'),
              leading: const Icon(Icons.sync_problem_outlined),
              title: const Text('Son gider gönderilemedi'),
              subtitle: Text('${unsent.$2['storeBrand']} · ${money(((unsent.$2['amountsCents'] as List?) ?? const [])
                  .fold<int>(0, (n, x) => n + (x as int)))}'),
              trailing: TextButton(onPressed: () => _send(unsent.$1, unsent.$2),
                child: const Text('Tekrar Gönder')))),
          if (loading && rows.isEmpty)
            const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
          else if (error != null)
            Card(child: NohutEmpty(icon: Icons.receipt_long_outlined, message: error!,
              action: 'Tekrar dene', onAction: _load))
          else ...[
            NohutMetric(label: 'Son 30 günde girdiğim', value: money(total),
              icon: Icons.shopping_basket_outlined,
              caption: '${rows.where((r) => r['voided'] != true).length} kayıt'),
            const SizedBox(height: 12),
            if (rows.isEmpty)
              const Card(child: NohutEmpty(icon: Icons.receipt_long_outlined,
                message: 'Henüz gider girmediniz.'))
            else
              for (final r in rows)
                Card(margin: const EdgeInsets.only(bottom: 8), child: ListTile(
                  leading: const Icon(Icons.shopping_basket_outlined),
                  title: Text('${r['market'] ?? r['storeBrand']} · ${money((r['totalCents'] as num?)?.toInt() ?? 0)}',
                    style: TextStyle(fontWeight: FontWeight.w700,
                      decoration: r['voided'] == true ? TextDecoration.lineThrough : null)),
                  subtitle: Text([
                    WorkFormat.day('${r['date']}'),
                    '${r['paymentMethod']}',
                    if (r['voided'] == true) 'İptal edildi',
                    if ('${r['note'] ?? ''}'.isNotEmpty) '${r['note']}',
                  ].join(' · ')),
                )),
            const SizedBox(height: 8),
            Text('Düzeltme veya iptal için yöneticinize başvurun.',
              style: TextStyle(fontSize: 12.5, color: nc.muted)),
          ],
        ]),
      ),
    );
  }
}
