import 'package:flutter/material.dart';
import '../number_format.dart';
import '../services/dex_display_price.dart';

class DexTokenMetrics extends StatelessWidget {
  const DexTokenMetrics(
      {super.key,
      required this.marketCapKas,
      required this.priceKas,
      required this.volume24hKas,
      required this.kasUsd});
  final double? marketCapKas, priceKas, volume24hKas;
  final Future<double?> kasUsd;

  static String kas(double? value) {
    final n = DexDisplayPrice.nonnegative(value);
    if (n == null) return 'Unavailable';
    if (n > 0 && n < 0.00000001) return '<0.00000001 KAS';
    return '${formatEnglishNumber(n, trimTrailingZeros: true)} KAS';
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<double?>(
      future: kasUsd,
      builder: (context, snapshot) {
        final cap = DexDisplayPrice.nonnegative(marketCapKas);
        final rate = DexDisplayPrice.nonnegative(snapshot.data);
        final usd =
            cap == null || rate == null || rate <= 0 ? null : cap * rate;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              'Market cap: ${usd == null || !usd.isFinite ? 'Unavailable' : '${formatEnglishNumber(usd, decimals: 2)} USD'}'),
          Text('Price: ${kas(priceKas)} / token'),
          Text('24h volume: ${kas(volume24hKas)}'),
        ]);
      });
}
