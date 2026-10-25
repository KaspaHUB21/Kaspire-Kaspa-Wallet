import 'package:flutter/material.dart';

/// Integer arithmetic only: never round above the wallet or a venue's lot size.
BigInt sellPercentageRaw(BigInt balance, int percent, {BigInt? step}) {
  final unit = step ?? BigInt.one;
  if (balance < BigInt.zero ||
      unit <= BigInt.zero ||
      !const [25, 50, 75, 100].contains(percent)) {
    throw ArgumentError('Invalid sell percentage or token unit.');
  }
  return (balance * BigInt.from(percent) ~/ BigInt.from(100)) ~/ unit * unit;
}

String sellAmountInput(BigInt raw, int decimals) {
  if (raw < BigInt.zero || decimals < 0 || decimals > 18) {
    throw ArgumentError('Invalid token amount.');
  }
  if (decimals == 0) return raw.toString();
  final scale = BigInt.from(10).pow(decimals);
  final fraction = (raw % scale)
      .toString()
      .padLeft(decimals, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  return '${raw ~/ scale}${fraction.isEmpty ? '' : '.$fraction'}';
}

class SellAmountButtons extends StatelessWidget {
  const SellAmountButtons(
      {super.key,
      required this.balance,
      required this.decimals,
      required this.onSelected,
      this.enabled = true,
      this.step});
  final BigInt? balance, step;
  final int decimals;
  final bool enabled;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => Row(children: [
        for (final percent in const [25, 50, 75, 100]) ...[
          if (percent != 25) const SizedBox(width: 6),
          Expanded(
              child: OutlinedButton(
            style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                minimumSize: const Size(0, 40)),
            onPressed: !enabled ||
                    balance == null ||
                    balance! <= BigInt.zero ||
                    sellPercentageRaw(balance!, percent, step: step) ==
                        BigInt.zero
                ? null
                : () => onSelected(sellAmountInput(
                    sellPercentageRaw(balance!, percent, step: step),
                    decimals)),
            child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(percent == 100 ? 'MAX' : '$percent%')),
          )),
        ],
      ]);
}
