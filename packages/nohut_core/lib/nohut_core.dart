/// Shared financial rules: amounts are integer kuruş, never floating-point TL.
const materialStores = <String>['BİM', 'A101', 'Hakmar', 'Diğer'];
const financeMethods = <String>['Nakit', 'Kart', 'Banka', 'Ödenmedi'];

int quickMaterialTotalCents(List<int> amounts) {
  if (amounts.isEmpty || amounts.length > 100) {
    throw const FormatException('1 ile 100 arasında tutar girin.');
  }
  var total = 0;
  for (final amount in amounts) {
    if (amount < 1 || amount > 100000000000) {
      throw const FormatException('Tutar geçersiz.');
    }
    total += amount;
  }
  if (total > 100000000000) {
    throw const FormatException('Tutar geçersiz.');
  }
  return total;
}

/// Turkish or decimal-point input; reject ambiguous thousands separators.
int parseExpenseCents(String input) {
  final value = input.trim().replaceAll(',', '.');
  if (!RegExp(r'^\d{1,10}(\.\d{1,2})?$').hasMatch(value)) {
    throw const FormatException('Geçerli tutar girin (ör. 50,25).');
  }
  final parts = value.split('.');
  final cents = int.parse(parts[0]) * 100 +
      (parts.length == 2 ? int.parse(parts[1].padRight(2, '0')) : 0);
  quickMaterialTotalCents([cents]);
  return cents;
}
