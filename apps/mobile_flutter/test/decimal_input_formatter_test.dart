import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/decimal_input_formatter.dart';

void main() {
  test('accepts at most eight decimal places', () {
    final formatter = DecimalInputFormatter(decimalPlaces: 8);
    const empty = TextEditingValue.empty;
    const valid = TextEditingValue(text: '12.12345678');
    const invalid = TextEditingValue(text: '12.123456789');

    expect(formatter.formatEditUpdate(empty, valid).text, valid.text);
    expect(formatter.formatEditUpdate(valid, invalid).text, valid.text);
  });

  test('supports comma input and token-specific precision', () {
    final formatter = DecimalInputFormatter(decimalPlaces: 2);
    const oldValue = TextEditingValue(text: '1,23');

    expect(
      formatter.formatEditUpdate(TextEditingValue.empty, oldValue).text,
      '1,23',
    );
    expect(
      formatter
          .formatEditUpdate(oldValue, const TextEditingValue(text: '1,234'))
          .text,
      '1,23',
    );
  });
}
