import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/number_format.dart';

void main() {
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
