import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/number_format.dart';

void main() {
  test('canonical internal token amounts never contain grouping commas', () {
    expect(rawTokenDecimal(BigInt.parse('2100000000000'), 8), '21000');
    expect(
        rawTokenDecimal(BigInt.parse('287000000000000000'), 8), '2870000000');
    expect(rawTokenDecimal(BigInt.parse('1000000000000000001'), 18),
        '1.000000000000000001');
    expect(rawTokenDecimal(BigInt.from(1000), 0), '1000');
    expect(rawTokenDecimal(BigInt.zero, 8), '0');
    expect(formatRawTokenAmount(BigInt.parse('2100000000000'), 8), '21,000');
  });
  test(
      'US grouping preserves large sompi values without floating-point rounding',
      () {
    expect(formatSompi(9007199254740993), '90,071,992.54740993');
    expect(formatSompi(-9007199254740993), '-90,071,992.54740993');
    expect(formatSompi(123456789, decimals: 2), '1.23');
    expect(formatRawTokenAmount(BigInt.parse('1000000000000000000000001'), 8),
        '10,000,000,000,000,000.00000001');
  });
  test('formats English thousands and decimal separators', () {
    expect(formatEnglishNumber(1234567.89, decimals: 2), '1,234,567.89');
    expect(formatSompi(123456789012), '1,234.56789012');
  });

  test('formats raw token balances without losing integer precision', () {
    expect(
      formatRawTokenAmount(BigInt.parse('123456789012345678'), 8),
      '1,234,567,890.12345678',
    );
    expect(formatRawTokenAmount(BigInt.parse('120000000000'), 8), '1,200');
  });
}
