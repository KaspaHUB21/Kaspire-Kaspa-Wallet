import 'dart:convert';

/// Display metadata only. Never selects a program, owner or signing template.
Map<String, dynamic>? verifiedKascovDeclaration(String covenantId, Map source) {
  if (source['covenant_id'] != covenantId || source['kcc23'] is! Map)
    return null;
  final proof = source['kcc23'] as Map, text = proof['declaration'];
  if (proof['binding'] != 'verified' || text is! String || text.length > 16384)
    return null;
  try {
    final data = jsonDecode(text);
    if (data is! Map) return null;
    final symbol = '${data['ticker'] ?? data['symbol'] ?? ''}'.toUpperCase();
    final decimals = data['decimals'];
    if (!RegExp(r'^[A-Z0-9_.-]{1,32}$').hasMatch(symbol) ||
        decimals is! int ||
        decimals < 0 ||
        decimals > 18) return null;
    return {...Map<String, dynamic>.from(data), 'ticker': symbol};
  } catch (_) {
    return null;
  }
}
