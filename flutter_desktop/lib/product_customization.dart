import 'package:flutter/material.dart';
import 'pos_logic.dart';
import 'operations_ui.dart';

List<String> ingredientChoices(String name, [String description = '']) {
  final text = description.toLowerCase();
  final known = [
    'Falafel',
    'Humus',
    'Marul',
    'Domates',
    'Salatalık',
    'Nane',
    'Tarator sosu',
    'Mütebbel',
    'Babagannuş',
    'Sarma',
    'Kibbe',
    'Patates',
    'Patlıcan',
    'Yoğurt',
    'Tahin',
    'Sarımsak',
    'Sembusek',
  ];
  final found = known.where((s) => text.contains(s.toLowerCase())).toList();
  if (found.isNotEmpty) return found;
  if (name.contains('Dürüm'))
    return [
      'Humus',
      'Marul',
      'Domates',
      'Salatalık',
      'Nane',
      if (!name.contains('Vegan')) 'Tarator sosu',
    ];
  if (name.contains('Tabağı'))
    return ['Falafel', 'Humus', 'Sarma', 'Sembusek', 'Kibbe'];
  if (name.contains('Salata') || name == 'Fettuş' || name == 'Tabbule')
    return ['Domates', 'Salatalık', 'Marul', 'Sos'];
  return [];
}

void applyLineCustomization(
  Json line,
  int adjustment,
  String note,
  List<String> removed,
) {
  final base = cents(line['basePrice'] ?? line['price']);
  if (adjustment.abs() > 10000000 ||
      base + adjustment < 0 ||
      note.length > 500 ||
      removed.length > 50 ||
      removed.any((s) => s.length > 100))
    throw const FormatException('Fiyat farkı / not / malzeme geçersiz');
  if (adjustment != 0 && note.trim().isEmpty)
    throw const FormatException('Fiyat farkının nedenini not edin');
  line['basePrice'] = fromCents(base);
  line['adjustmentCents'] = adjustment;
  line['price'] = fromCents(base + adjustment);
  line['note'] = note;
  line['removed'] = removed;
}

Future<Json?> customizeLineDialog(
  BuildContext context,
  Json line, {
  String description = '',
}) => showDialog<Json>(
  context: context,
  builder: (_) => _CustomizationDialog(line: line, description: description),
);

class _CustomizationDialog extends StatefulWidget {
  const _CustomizationDialog({required this.line, required this.description});
  final Json line;
  final String description;
  @override
  State<_CustomizationDialog> createState() => _CustomizationDialogState();
}

class _CustomizationDialogState extends State<_CustomizationDialog> {
  Json get line => widget.line;
  String get description => widget.description;
  late final TextEditingController note, extra, qty, other;
  late final Set<String> removed, choices;
  String? error;
  @override
  void initState() {
    super.initState();
    note = TextEditingController(text: '${line['note'] ?? ''}');
    extra = TextEditingController(
      text:
          (line['adjustmentCents'] is int
                  ? (line['adjustmentCents'] as int) / 100
                  : 0)
              .toString(),
    );
    qty = TextEditingController(text: '${line['qty'] ?? 1}');
    other = TextEditingController();
    removed = Set<String>.from((line['removed'] as List? ?? []).cast<String>());
    choices = {
      ...ingredientChoices('${line['name']}', description),
      ...removed,
    };
  }

  @override
  void dispose() {
    note.dispose();
    extra.dispose();
    qty.dispose();
    other.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${line['name']}'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: qty,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Adet (0 = kaldır)'),
            ),
            const Text('Çıkarmak için dokunun'),
            Wrap(
              spacing: 6,
              children: [
                for (final name in choices)
                  FilterChip(
                    label: Text(name),
                    selected: removed.contains(name),
                    onSelected: (v) => setState(
                      () => v ? removed.add(name) : removed.remove(name),
                    ),
                  ),
              ],
            ),
            TextField(
              controller: other,
              decoration: const InputDecoration(
                labelText: 'Diğer çıkarılacaklar (virgülle)',
              ),
            ),
            TextField(
              key: const ValueKey('customization-note'),
              controller: note,
              maxLines: 3,
              maxLength: 500,
              decoration: const InputDecoration(
                labelText: 'Değişiklik / özel istek notu',
              ),
            ),
            TextField(
              controller: extra,
              keyboardType: const TextInputType.numberWithOptions(
                signed: true,
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Her adet için fark (₺): + ekle / − indir',
              ),
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Vazgeç'),
      ),
      FilledButton(
        onPressed: () {
          try {
            final raw = extra.text.trim();
            final negative = raw.startsWith('-');
            final amount =
                parseMoney(raw.replaceFirst(RegExp(r'^[+−-]'), '')) *
                (negative || raw.startsWith('−') ? -1 : 1);
            final count = int.tryParse(qty.text);
            if (count == null || count < 0 || count > 1000)
              throw const FormatException('Adet 0–1000');
            final result = copyJson(line)..['qty'] = count;
            applyLineCustomization(result, amount, note.text, [
              ...removed,
              ...other.text
                  .split(',')
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty),
            ]);
            Navigator.pop(context, result);
          } catch (e) {
            setState(() => error = '$e');
          }
        },
        child: const Text('Kaydet'),
      ),
    ],
  );
}
