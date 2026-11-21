import 'package:flutter/material.dart';
import '../theme.dart';

/// A shared, stable label/value grid for payment reviews and receipts.
/// Both columns wrap independently; value origins never depend on text length.
class TransactionFactRow extends StatelessWidget {
  const TransactionFactRow(this.label, this.value, {super.key});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child:
                Text(label, style: TextStyle(color: KasVaultTheme.detailText)),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 1,
            child: Text(value,
                textAlign: TextAlign.left,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      );
}
