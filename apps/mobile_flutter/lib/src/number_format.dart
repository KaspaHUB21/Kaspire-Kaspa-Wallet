String _groupWholeDigits(String value) {
  final negative = value.startsWith('-');
  final digits = negative ? value.substring(1) : value;
  final grouped = digits.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return negative ? '-$grouped' : grouped;
}

String formatEnglishDecimal(String value, {bool trimTrailingZeros = false}) {
  final parts = value.split('.');
  final whole = _groupWholeDigits(parts.first);
  if (parts.length == 1) return whole;
  var fraction = parts.sublist(1).join();
  if (trimTrailingZeros) fraction = fraction.replaceFirst(RegExp(r'0+$'), '');
  return fraction.isEmpty ? whole : '$whole.$fraction';
}

String formatEnglishNumber(
  num value, {
  int decimals = 8,
  bool trimTrailingZeros = false,
}) =>
    formatEnglishDecimal(
      value.toStringAsFixed(decimals),
      trimTrailingZeros: trimTrailingZeros,
    );

String formatSompi(int sompi, {int decimals = 8}) {
  if (decimals < 0 || decimals > 18)
    throw RangeError.range(decimals, 0, 18, 'decimals');
  var raw = BigInt.from(sompi).abs();
  if (decimals < 8) {
    final scale = BigInt.from(10).pow(8 - decimals);
    raw = (raw + scale ~/ BigInt.two) ~/ scale;
  }
  if (decimals > 8) raw *= BigInt.from(10).pow(decimals - 8);
  final digits = raw.toString().padLeft(decimals + 1, '0');
  final value = decimals == 0
      ? digits
      : '${digits.substring(0, digits.length - decimals)}.${digits.substring(digits.length - decimals)}';
  return formatEnglishDecimal(
      '${sompi < 0 && raw != BigInt.zero ? '-' : ''}$value');
}

String formatRawTokenAmount(BigInt amount, int decimals) {
  if (decimals <= 0) return _groupWholeDigits(amount.toString());
  final negative = amount.isNegative;
  final digits = amount.abs().toString().padLeft(decimals + 1, '0');
  final whole = digits.substring(0, digits.length - decimals);
  final fraction = digits.substring(digits.length - decimals);
  final value = '${negative ? '-' : ''}$whole.$fraction';
  return formatEnglishDecimal(value, trimTrailingZeros: true);
}
