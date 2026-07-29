import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/wallet_snapshot.dart';
import '../number_format.dart';
import '../services/app_settings.dart';
import '../theme.dart';

class Krc20TokenDetailScreen extends StatelessWidget {
  const Krc20TokenDetailScreen({
    super.key,
    required this.asset,
    required this.onSend,
  });

  final WalletAsset asset;
  final VoidCallback onSend;

  String _price(double? value, String unit) {
    if (value == null) return '—';
    final prefix = unit == 'USD' ? '\$' : '';
    return '$prefix${formatEnglishNumber(value, decimals: 8, trimTrailingZeros: true)} $unit';
  }

  String get _balance {
    final raw = BigInt.tryParse(asset.rawBalance ?? '');
    if (raw == null || asset.decimals <= 0) {
      return formatEnglishNumber(
        asset.balance,
        decimals: asset.decimals.clamp(0, 18),
        trimTrailingZeros: true,
      );
    }
    final digits = raw.toString().padLeft(asset.decimals + 1, '0');
    final split = digits.length - asset.decimals;
    final fraction = digits.substring(split).replaceFirst(RegExp(r'0+$'), '');
    return fraction.isEmpty
        ? digits.substring(0, split)
        : '${digits.substring(0, split)}.$fraction';
  }

  Future<void> _openExplorer() => launchUrl(
        Uri.parse(
          'https://kaspatoken.kaslab.space/token/'
          '${Uri.encodeComponent(asset.id ?? 'krc20-${asset.symbol.toLowerCase()}')}',
        ),
        mode: LaunchMode.externalApplication,
      );

  @override
  Widget build(BuildContext context) {
    final valueKas =
        asset.priceKas == null ? null : asset.priceKas! * asset.balance;
    final valueUsd =
        asset.priceUsd == null ? null : asset.priceUsd! * asset.balance;
    return Scaffold(
      appBar: AppBar(title: Text(asset.symbol)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const SizedBox(height: 10),
            Center(child: _TokenImage(asset.imageUrl)),
            const SizedBox(height: 18),
            Text(
              asset.symbol,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '$_balance ${asset.symbol}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: KasVaultTheme.muted,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 28),
            _PricePanel(
              title: 'Floor price',
              kas: _price(asset.priceKas, 'KAS'),
              usd: _price(asset.priceUsd, 'USD'),
            ),
            const SizedBox(height: 12),
            _PricePanel(
              title: 'Balance value',
              kas: _price(valueKas, 'KAS'),
              usd: _price(valueUsd, 'USD'),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                onSend();
              },
              icon: const Icon(Icons.arrow_upward_rounded),
              label: Text(buttonLabel('SEND ASSET')),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _openExplorer,
              icon: const Icon(Icons.open_in_new_rounded),
              label: Text(buttonLabel('CHECK ON EXPLORER')),
            ),
          ],
        ),
      ),
    );
  }
}

class _PricePanel extends StatelessWidget {
  const _PricePanel({
    required this.title,
    required this.kas,
    required this.usd,
  });

  final String title;
  final String kas;
  final String usd;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: KasVaultTheme.panel,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: KasVaultTheme.mint, width: 1.2),
          boxShadow: [
            BoxShadow(
              color: KasVaultTheme.mint.withValues(alpha: .13),
              blurRadius: 18,
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: KasVaultTheme.muted,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              kas,
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              usd,
              style: TextStyle(
                color: KasVaultTheme.mint,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      );
}

class _TokenImage extends StatelessWidget {
  const _TokenImage(this.url);
  final String? url;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: 104,
      height: 104,
      decoration: BoxDecoration(
        color: KasVaultTheme.mint.withValues(alpha: .13),
        shape: BoxShape.circle,
        border: Border.all(color: KasVaultTheme.mint),
      ),
      child: Icon(
        Icons.token_rounded,
        size: 52,
        color: KasVaultTheme.mint,
      ),
    );
    if (url == null || url!.isEmpty) return fallback;
    return ClipOval(
      child: Image.network(
        url!,
        width: 104,
        height: 104,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback,
      ),
    );
  }
}
