import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/wallet_snapshot.dart';
import '../number_format.dart';
import '../services/privacy_settings.dart';
import '../theme.dart';

class TransactionDetailScreen extends StatelessWidget {
  const TransactionDetailScreen({
    super.key,
    required this.transaction,
    required this.walletAddress,
  });

  final WalletTransaction transaction;
  final String walletAddress;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: PrivacySettings.hideAmounts,
        builder: (context, hideAmounts, _) {
          final from = transaction.from.isNotEmpty
              ? transaction.from
              : [
                  TransactionParty(
                    address: transaction.incoming
                        ? transaction.counterparty ?? ''
                        : walletAddress,
                  ),
                ];
          final to = transaction.to.isNotEmpty
              ? transaction.to
              : [
                  TransactionParty(
                    address: transaction.incoming
                        ? walletAddress
                        : transaction.counterparty ?? '',
                  ),
                ];
          return Scaffold(
            appBar: AppBar(title: const Text('Transaction details')),
            body: ListView(
              padding: EdgeInsets.fromLTRB(
                20,
                8,
                20,
                32 + MediaQuery.viewPaddingOf(context).bottom,
              ),
              children: [
                _Header(transaction: transaction, hideAmounts: hideAmounts),
                const SizedBox(height: 16),
                _Section(
                  title: 'TRANSFER',
                  children: [
                    _ValueRow(
                      'Direction',
                      transaction.operationLabel ??
                          (transaction.incoming ? 'Received' : 'Sent'),
                    ),
                    _ValueRow('Asset', _assetLabel(transaction)),
                    _ValueRow('Amount',
                        hideAmounts ? '••••••' : transaction.amountLabel),
                    _ValueRow('Status', transaction.status.name.toUpperCase()),
                    _ValueRow(
                      'Date',
                      '${transaction.timestamp.toLocal()}'.split('.').first,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _PartySection(
                    title: 'FROM', parties: from, hideAmounts: hideAmounts),
                const SizedBox(height: 12),
                _PartySection(
                    title: 'TO', parties: to, hideAmounts: hideAmounts),
                const SizedBox(height: 12),
                _Section(
                  title: 'NETWORK',
                  children: [
                    if (transaction.feeSompi != null)
                      _ValueRow('Fee',
                          hideAmounts ? '••••••' : _kas(transaction.feeSompi!)),
                    if (transaction.totalInputSompi != null)
                      _ValueRow(
                          'Total inputs',
                          hideAmounts
                              ? '••••••'
                              : _kas(transaction.totalInputSompi!)),
                    if (transaction.totalOutputSompi != null)
                      _ValueRow(
                          'Total outputs',
                          hideAmounts
                              ? '••••••'
                              : _kas(transaction.totalOutputSompi!)),
                    if (transaction.inputCount != null)
                      _ValueRow('Inputs', '${transaction.inputCount}'),
                    if (transaction.outputCount != null)
                      _ValueRow('Outputs', '${transaction.outputCount}'),
                    if (transaction.mass != null)
                      _ValueRow('Mass', '${transaction.mass}'),
                    if (transaction.blockDaaScore != null)
                      _ValueRow(
                          'Block DAA score', '${transaction.blockDaaScore}'),
                    _ValueRow(
                        'Coinbase', transaction.isCoinbase ? 'Yes' : 'No'),
                  ],
                ),
                const SizedBox(height: 12),
                _CopyField(label: 'TRANSACTION ID', value: transaction.id),
                if (transaction.tokenId != null &&
                    transaction.tokenId!.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _CopyField(
                      label: 'TOKEN / ASSET ID', value: transaction.tokenId!),
                ],
              ],
            ),
          );
        },
      );

  static String _assetLabel(WalletTransaction transaction) {
    final symbol = transaction.assetSymbol;
    return symbol == null || symbol.isEmpty || symbol == transaction.assetKind
        ? transaction.assetKind
        : '${transaction.assetKind} · $symbol';
  }

  static String _kas(int sompi) =>
      '${formatEnglishNumber(sompi / 100000000, decimals: 8)} KAS';
}

class _Header extends StatelessWidget {
  const _Header({required this.transaction, required this.hideAmounts});
  final WalletTransaction transaction;
  final bool hideAmounts;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: KasVaultTheme.panel,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: KasVaultTheme.line),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 25,
              backgroundColor: transaction.incoming
                  ? KasVaultTheme.mint.withValues(alpha: .13)
                  : const Color(0x22FF8A65),
              child: Icon(
                transaction.incoming
                    ? Icons.south_west_rounded
                    : Icons.north_east_rounded,
                color: transaction.incoming
                    ? KasVaultTheme.mint
                    : const Color(0xFFFF8A65),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    transaction.operationLabel ??
                        (transaction.incoming ? 'Received' : 'Sent'),
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    hideAmounts
                        ? '••••••'
                        : '${transaction.incoming ? '+' : '-'}${transaction.amountLabel}',
                    style: TextStyle(
                      color: transaction.incoming
                          ? KasVaultTheme.mint
                          : Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}

class _PartySection extends StatelessWidget {
  const _PartySection({
    required this.title,
    required this.parties,
    required this.hideAmounts,
  });
  final String title;
  final List<TransactionParty> parties;
  final bool hideAmounts;

  @override
  Widget build(BuildContext context) => _Section(
        title: title,
        children: parties
            .where((party) => party.address.isNotEmpty)
            .map(
              (party) => _AddressRow(
                address: party.address,
                amountSompi: hideAmounts ? null : party.amountSompi,
                ownerId: party.ownerId,
              ),
            )
            .toList(),
      );
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(17),
        decoration: BoxDecoration(
          color: KasVaultTheme.panel,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: KasVaultTheme.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: KasVaultTheme.muted,
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 12),
            if (children.isEmpty)
              const Text(
                'Not available',
                style: TextStyle(color: KasVaultTheme.muted),
              )
            else
              ...children,
          ],
        ),
      );
}

class _ValueRow extends StatelessWidget {
  const _ValueRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: KasVaultTheme.muted)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.right,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      );
}

class _AddressRow extends StatelessWidget {
  const _AddressRow({
    required this.address,
    this.amountSompi,
    this.ownerId,
  });
  final String address;
  final int? amountSompi;
  final String? ownerId;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    address,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: KasVaultTheme.mint,
                    ),
                  ),
                ),
                if (amountSompi != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    TransactionDetailScreen._kas(amountSompi!),
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Copy address',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: address));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Address copied')),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded, size: 17),
                ),
              ],
            ),
            if (ownerId != null && ownerId!.isNotEmpty)
              SelectableText(
                'Covenant owner ID: $ownerId',
                style: const TextStyle(
                  color: KasVaultTheme.muted,
                  fontFamily: 'monospace',
                  fontSize: 10,
                ),
              ),
          ],
        ),
      );
}

class _CopyField extends StatelessWidget {
  const _CopyField({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(17),
        decoration: BoxDecoration(
          color: KasVaultTheme.panel,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: KasVaultTheme.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: KasVaultTheme.muted,
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    value,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: value));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied')),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded),
                ),
              ],
            ),
          ],
        ),
      );
}
