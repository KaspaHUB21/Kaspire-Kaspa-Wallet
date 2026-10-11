import 'package:flutter/material.dart';

/// Presentation only: buying/reviewing an order remains in the marketplace.
class Krc20OrderCard extends StatelessWidget {
  const Krc20OrderCard(
      {super.key,
      required this.totalKas,
      required this.quantity,
      required this.ticker,
      required this.unitPrice,
      required this.logo,
      required this.onOpen});

  final String totalKas, quantity, ticker, unitPrice;
  final Widget logo;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final amountStyle = theme.textTheme.headlineSmall?.copyWith(
      fontSize: 26,
      fontWeight: FontWeight.w700,
    );
    final secondaryStyle = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    Widget amount(String value, {Alignment alignment = Alignment.centerLeft}) =>
        FittedBox(
            fit: BoxFit.scaleDown,
            alignment: alignment,
            child: Text(value, maxLines: 1, style: amountStyle));

    return Card(
        child: Padding(
            padding: const EdgeInsets.all(14),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                    flex: 4,
                    child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text.rich(
                            TextSpan(children: [
                              TextSpan(text: totalKas, style: amountStyle),
                              TextSpan(text: ' KAS', style: secondaryStyle),
                            ]),
                            maxLines: 1))),
                const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.chevron_right_rounded, size: 28)),
                Expanded(
                    flex: 6,
                    child: Row(children: [
                      logo,
                      const SizedBox(width: 8),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                            SizedBox(
                                width: double.infinity,
                                child: amount(quantity,
                                    alignment: Alignment.centerRight)),
                            Text(ticker,
                                textAlign: TextAlign.right,
                                style: secondaryStyle),
                          ])),
                    ])),
              ]),
              const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Divider(height: 1)),
              LayoutBuilder(builder: (context, constraints) {
                final price = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Price', style: secondaryStyle),
                      Text('$unitPrice KAS / $ticker',
                          style: theme.textTheme.bodyLarge
                              ?.copyWith(fontWeight: FontWeight.w600))
                    ]);
                final button = FilledButton(
                    onPressed: onOpen,
                    style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12)),
                    child: const Text('View order'));
                if (MediaQuery.textScalerOf(context).scale(14) > 20 ||
                    constraints.maxWidth < 220) {
                  return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        price,
                        const SizedBox(height: 8),
                        Align(alignment: Alignment.centerRight, child: button)
                      ]);
                }
                return Row(children: [
                  Expanded(child: price),
                  const SizedBox(width: 10),
                  button
                ]);
              }),
            ])));
  }
}
