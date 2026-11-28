import 'pos_api.dart';

class CartEntry {
  CartEntry(this.product, {this.qty = 1, this.note = '', this.removed = const []});

  final Json product;
  int qty;
  String note;
  List<String> removed;

  int get productId => product['id'] as int;
  String get name => '${product['name'] ?? 'Ürün'}';
  int get unitCents => asCents(product['price']);
  int get totalCents => qty * unitCents;

  Json asOrderLine() => {
    'productId': productId,
    'qty': qty,
    'expectedPriceCents': unitCents,
    'note': note,
    'removed': removed,
  };
}

String orderLabel(Json o) {
  final day = '${o['dailyNumber'] ?? o['id'] ?? '—'}';
  final source = '${o['source'] ?? 'Masa'}';
  final place = source == 'Masa' ? 'Masa ${o['table'] ?? '—'}' : source;
  return '#$day · $place';
}

/// Windows menu category keys (`localMenu[].category`) and their Turkish
/// labels, in the Windows composer's order. Unknown keys keep their text.
const menuCategoryLabels = <String, String>{
  'campaign': 'Kampanyalar',
  'wrap': 'Dürümler',
  'plate': 'Porsiyonlar',
  'meze': 'Mezeler',
  'fatte': 'Fatte',
  'side': 'Diğer',
  'salad': 'Salatalar',
  'dessert': 'Tatlılar',
  'drink': 'İçecekler',
};

String menuCategoryLabel(String key) => menuCategoryLabels[key] ?? key;

/// Category keys present in [products], Windows order first, unknown last.
List<String> menuCategoriesOf(Iterable<Json> products) {
  final present = {for (final p in products) '${p['category'] ?? p['group'] ?? 'Diğer'}'};
  return [
    for (final k in menuCategoryLabels.keys) if (present.contains(k)) k,
    ...present.where((k) => !menuCategoryLabels.containsKey(k)).toList()..sort(),
  ];
}

List<Json> orderLines(Json order) => [
  for (final batch in rows(order['batches']))
    for (final line in rows(batch['lines']))
      if (line['voided'] != true && line['correction'] != true) line,
];

int orderTotal(Json order) {
  final stored = order['totalCents'];
  if (stored is int) return stored;
  return orderLines(order).fold(0, (sum, line) =>
      sum + asCents(line['price']) * ((line['qty'] as num?)?.toInt() ?? 0));
}
