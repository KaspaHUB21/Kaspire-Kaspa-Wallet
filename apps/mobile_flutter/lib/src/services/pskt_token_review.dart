/// Display only core-verified token states; no dApp ticker/amount hints.
List<String> psktTokenDetails(Map<String, Object?> review) {
  final result = <String>[];
  for (final raw in (review['tokenReviews'] as List? ?? const [])) {
    final token = raw as Map;
    String amount(Object? value, [int? decimals, String? ticker]) {
      final n = BigInt.parse(value.toString());
      final digits = n.abs().toString().padLeft((decimals ?? token['decimals'] as int) + 1, '0');
      final d = decimals ?? token['decimals'] as int;
      final whole = d == 0 ? digits : digits.substring(0, digits.length - d);
      final fraction = d == 0 ? '' : digits.substring(digits.length - d).replaceFirst(RegExp(r'0+$'), '');
      return '${n.isNegative ? '-' : ''}$whole${fraction.isEmpty ? '' : '.$fraction'} ${ticker ?? token['ticker']}';
    }
    result.add('Token: ${token['ticker']} · ${token['covenantId']}');
    if (token['walletNetRaw'] != null) {
      result.add('Draft token balance change: ${BigInt.parse(token['walletNetRaw'].toString()) > BigInt.zero ? '+' : ''}${amount(token['walletNetRaw'])}${token['outputsBound'] == true ? '' : ' · NOT FIXED BY THIS SIGNATURE'}');
    } else {
      result.add('Full token balance change unavailable: some token states could not be verified. Unknown does not mean zero.');
    }
    for (final role in ['Input', 'Output']) {
      for (final rawCell in (token[role == 'Input' ? 'inputs' : 'outputs'] as List? ?? const [])) {
        final cell = rawCell as Map;
        result.add('$role ${cell['index']}: ${amount(cell['amountRaw'])}${cell['walletOwned'] == true ? ' · YOUR WALLET' : ''}${role == 'Output' && cell['signatureBound'] != true ? ' · UNBOUND' : ''} · carrier reserve ${amount(cell['reserveSompi'], 8, 'KAS')} (not token amount)');
      }
    }
    if (token['complete'] != true) result.add('Some token states could not be verified. Inspect all transaction details before signing.');
  }
  return result;
}
