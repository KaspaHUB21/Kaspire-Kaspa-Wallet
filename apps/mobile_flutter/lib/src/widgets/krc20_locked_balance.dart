import 'package:flutter/material.dart';

import '../models/wallet_snapshot.dart';
import '../number_format.dart';
import '../theme.dart';

/// The indexer's aggregate PSKT amount; never added to the spendable balance
/// and never attributed to a marketplace the indexer cannot identify.
class Krc20LockedBalance extends StatelessWidget {
  const Krc20LockedBalance({
    super.key,
    required this.asset,
    this.hideAmount = false,
    this.textAlign = TextAlign.start,
    this.fontSize = 12,
  });

  final WalletAsset asset;
  final bool hideAmount;
  final TextAlign textAlign;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final kind = asset.kind.toUpperCase().replaceAll('-', '');
    final raw = asset.rawLockedBalance;
    final amount = raw != null && RegExp(r'^[0-9]{1,128}$').hasMatch(raw)
        ? BigInt.tryParse(raw)
        : null;
    if (kind != 'KRC20' ||
        amount == null ||
        amount <= BigInt.zero ||
        asset.decimals < 0 ||
        asset.decimals > 18) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Text(
        hideAmount
            ? '•••••• locked'
            : '+${formatRawTokenAmount(amount, asset.decimals)} ${asset.symbol} locked',
        textAlign: textAlign,
        softWrap: true,
        style: TextStyle(
          color: KasVaultTheme.muted,
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
