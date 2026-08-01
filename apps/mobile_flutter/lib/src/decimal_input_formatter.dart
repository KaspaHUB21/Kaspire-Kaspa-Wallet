import 'package:flutter/services.dart';

class DecimalInputFormatter extends TextInputFormatter {
  DecimalInputFormatter({required this.decimalPlaces})
      : assert(decimalPlaces >= 0);

  final int decimalPlaces;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    if (text.isEmpty) return newValue;
    final pattern = decimalPlaces == 0
        ? RegExp(r'^\d*$')
        : RegExp('^\\d*(?:[.,]\\d{0,$decimalPlaces})?\$');
    return pattern.hasMatch(text) ? newValue : oldValue;
  }
}
