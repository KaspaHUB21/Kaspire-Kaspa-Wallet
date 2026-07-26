class KaspaPaymentRequest {
  const KaspaPaymentRequest({required this.address, this.amount});

  final String address;
  final String? amount;

  static KaspaPaymentRequest? tryParse(String value) {
    final raw = value.trim();
    if (raw.length > 2048) return null;
    final separator = raw.indexOf('?');
    final address = (separator < 0 ? raw : raw.substring(0, separator))
        .trim()
        .toLowerCase();
    if (!RegExp(r'^kaspa:[a-z0-9]{61,63}$').hasMatch(address)) return null;
    if (separator < 0) return KaspaPaymentRequest(address: address);
    final Map<String, List<String>> query;
    try {
      query = Uri.parse(
        'https://request.invalid/?${raw.substring(separator + 1)}',
      ).queryParametersAll;
    } on FormatException {
      return null;
    }
    if (query.keys.any((key) => key != 'amount') ||
        query['amount']?.length != 1) {
      return null;
    }
    final amount = query['amount']!.single;
    if (amount.length > 32 || !RegExp(r'^\d+(\.\d{1,8})?$').hasMatch(amount)) {
      return null;
    }
    return KaspaPaymentRequest(address: address, amount: amount);
  }

  static String encode(String address, {String? amount}) {
    final normalized = amount?.trim().replaceAll(',', '.');
    if (normalized == null || normalized.isEmpty) return address;
    if (!RegExp(r'^\d+(\.\d{1,8})?$').hasMatch(normalized)) return address;
    return '$address?amount=${Uri.encodeQueryComponent(normalized)}';
  }
}
