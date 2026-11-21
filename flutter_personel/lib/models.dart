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
