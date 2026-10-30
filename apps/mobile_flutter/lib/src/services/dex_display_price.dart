import 'dart:convert';
import 'package:http/http.dart' as http;

/// Display-only KAS/USD reference. Never an input to quotes or signing.
/// One shared, bounded lookup per catalogue, not one request per token.
class DexDisplayPrice {
  DexDisplayPrice({http.Client? client, DateTime Function()? now})
      : client = client ?? http.Client(),
        now = now ?? DateTime.now;
  static final shared = DexDisplayPrice();
  final http.Client client;
  final DateTime Function() now;
  final _cached = <bool, ({double value, DateTime at})>{};
  final _pending = <bool, Future<double?>>{};

  static double? nonnegative(Object? value) {
    final n = double.tryParse('$value');
    return n != null && n.isFinite && n >= 0 ? n : null;
  }

  Future<double?> kasUsd({required bool kasseal}) {
    final cached = _cached[kasseal];
    if (cached != null &&
        now().difference(cached.at) < const Duration(minutes: 2)) {
      return Future.value(cached.value);
    }
    return _pending.putIfAbsent(
        kasseal,
        () => _load(kasseal).whenComplete(() {
              _pending.remove(kasseal);
            }));
  }

  Future<Map?> _get(String url) async {
    final response =
        await client.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
    if (response.statusCode != 200 || response.bodyBytes.length > 512 * 1024)
      return null;
    final data = jsonDecode(response.body);
    return data is Map ? data : null;
  }

  Future<double?> _load(bool kasseal) async {
    double? rate;
    if (kasseal) {
      try {
        final data = await _get('https://app.kasseal.com/v1/price/kas');
        final at = data?['asOfMs'];
        if (data?['stale'] == false &&
            at is num &&
            (now().millisecondsSinceEpoch - at).abs() <= 15 * 60 * 1000) {
          rate = nonnegative(data?['usd']);
        }
      } catch (_) {/* Continue to the independent display fallback. */}
    }
    if (rate == null || rate <= 0) {
      try {
        final data =
            await _get('https://kaspatoken.kaslab.space/api/kaspa/stats');
        final at = DateTime.tryParse('${data?['updated_at']}');
        if (at != null &&
            now().difference(at).abs() <= const Duration(minutes: 15)) {
          rate = nonnegative((data?['data'] as Map?)?['price_usd']);
        }
      } catch (_) {/* Missing display prices must not block trading. */}
    }
    if (rate == null || rate <= 0) return null;
    _cached[kasseal] = (value: rate, at: now());
    return rate;
  }

  static double? kassealCapKas(Map token) {
    final cap = nonnegative(token['marketCapSompi']);
    return cap == null ? null : cap / 100000000;
  }

  static double? kassealPriceKas(Map token) {
    // Kasseal's market cap is the current spot price times whole-token supply.
    // Do not mistake a curve's 1,000-token lot price for one token's price.
    final cap = kassealCapKas(token);
    final supply = nonnegative((token['supply'] as Map?)?['total']);
    return cap == null || supply == null || supply <= 0 ? null : cap / supply;
  }
}
