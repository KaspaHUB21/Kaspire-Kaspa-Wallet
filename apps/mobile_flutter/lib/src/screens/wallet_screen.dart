import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/wallet_snapshot.dart';
import '../number_format.dart';
import '../services/kaspa_api.dart';
import '../services/activity_store.dart';
import '../services/native_security.dart';
import '../services/privacy_settings.dart';
import '../services/signer_service.dart';
import '../models/asset_send_intent.dart';
import '../theme.dart';
import 'nft_collection_screen.dart';
import 'transaction_detail_screen.dart';
import '../widgets/kaspire_brand.dart';

class WalletScreen extends StatefulWidget {
  const WalletScreen({
    super.key,
    required this.address,
    required this.onSend,
    required this.onReceive,
    required this.onPairDapps,
    required this.onSendAsset,
    required this.onSwitchWallet,
  });
  final String address;
  final VoidCallback onSend;
  final VoidCallback onReceive;
  final VoidCallback onPairDapps;
  final ValueChanged<AssetSendIntent> onSendAsset;
  final VoidCallback onSwitchWallet;

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  late Future<WalletSnapshot> _snapshot;
  int _historyLimit = 20;
  bool _compounding = false;

  @override
  void initState() {
    super.initState();
    _snapshot = _loadSnapshot();
  }

  Future<WalletSnapshot> _loadSnapshot() async {
    final results = await Future.wait([
      KaspaApi().loadWallet(
        widget.address,
        transactionLimit: _historyLimit,
      ),
      ActivityStore().load(widget.address),
    ]);
    final snapshot = results[0] as WalletSnapshot;
    final local = results[1] as List<WalletTransaction>;
    final transactions = mergeWalletActivity(local, snapshot.transactions);
    return snapshot.withTransactions(transactions);
  }

  void _refresh() => setState(() => _snapshot = _loadSnapshot());

  Future<void> _compoundUtxos() async {
    if (_compounding) return;
    setState(() => _compounding = true);
    try {
      final security = NativeSecurity();
      if (!await security.hasNativeWalletFor(widget.address)) {
        throw StateError(
          'This watch-only wallet cannot authorize UTXO compound.',
        );
      }
      final api = KaspaApi();
      final results = await Future.wait([
        api.loadUtxos(widget.address),
        api.loadFeeRate(),
      ]);
      final all =
          (jsonDecode(results[0] as String) as List).whereType<Map>().toList();
      if (all.length < 2) {
        throw StateError('At least two spendable UTXOs are required.');
      }
      int amount(Map item) {
        final value = item['utxoEntry'];
        final raw = value is Map ? value['amount'] : null;
        return raw is num ? raw.toInt() : int.tryParse('$raw') ?? 0;
      }

      all.sort((a, b) => amount(a).compareTo(amount(b)));
      final selected =
          all.length <= 80 ? all : <Map>[...all.take(79), all.last];
      final payment = await SignerService().prepare(
        sender: widget.address,
        recipient: widget.address,
        amountSompi: 0,
        feeRate: results[1] as double,
        utxosJson: jsonEncode(selected),
        sendAll: true,
      );
      if (!mounted) return;
      final approved = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ConfirmCompound(
          payment: payment,
          totalUtxos: all.length,
        ),
      );
      if (approved != true || !mounted) return;
      final authenticated = await security.authenticate(
        context,
        'Authorize UTXO compound',
      );
      if (!authenticated) return;
      final signed = await SignerService().sign(payment);
      final broadcastId = await api.broadcast(signed.submitJson);
      if (broadcastId.isNotEmpty && broadcastId != signed.transactionId) {
        throw StateError('Node returned a mismatching transaction ID.');
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${payment.inputCount} UTXOs compounded into one. '
            'TX ${signed.transactionId.substring(0, 10)}…',
          ),
        ),
      );
      _refresh();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Bad state: ', '')),
        ),
      );
    } finally {
      if (mounted) setState(() => _compounding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: PrivacySettings.hideAmounts,
      builder: (context, hideAmounts, _) => SafeArea(
        child: RefreshIndicator(
          onRefresh: () async => _refresh(),
          child: FutureBuilder<WalletSnapshot>(
            future: _snapshot,
            builder: (context, snapshot) => ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: KaspireWordmark(height: 19),
                    ),
                    IconButton(
                      onPressed: widget.onSwitchWallet,
                      tooltip: 'Switch wallet',
                      icon: const Icon(Icons.account_balance_wallet_outlined),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0x2249EACB),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.circle,
                              size: 8, color: KasVaultTheme.mint),
                          SizedBox(width: 7),
                          Text(
                            'MAINNET',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                _BalanceCard(snapshot: snapshot, hideAmounts: hideAmounts),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _Action(
                        icon: Icons.arrow_upward_rounded,
                        label: 'SEND',
                        onTap: widget.onSend,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _Action(
                        icon: Icons.arrow_downward_rounded,
                        label: 'RECEIVE',
                        onTap: widget.onReceive,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _Action(
                        icon: Icons.qr_code_scanner_rounded,
                        label: 'PAIR DAPPS',
                        onTap: widget.onPairDapps,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                if (snapshot.hasData) ...[
                  const Text(
                    'ASSETS & NAMES',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _AssetOverview(
                    data: snapshot.data!,
                    address: widget.address,
                    onSendAsset: widget.onSendAsset,
                    hideAmounts: hideAmounts,
                  ),
                  const SizedBox(height: 12),
                  _UtxoCard(
                    count: snapshot.data!.utxoCount,
                    working: _compounding,
                    onCompound: _compoundUtxos,
                  ),
                  const SizedBox(height: 32),
                ],
                const Row(
                  children: [
                    Expanded(
                      child: Text(
                        'ACTIVITY',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                    Text(
                      'LIVE',
                      style: TextStyle(
                        color: KasVaultTheme.mint,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (snapshot.connectionState == ConnectionState.waiting)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(36),
                      child: CircularProgressIndicator(),
                    ),
                  ),
                if (snapshot.hasError)
                  _ErrorCard(error: snapshot.error, onRetry: _refresh),
                if (snapshot.hasData && snapshot.data!.transactions.isEmpty)
                  const _EmptyActivity(),
                if (snapshot.hasData)
                  ...snapshot.data!.transactions.map(
                    (tx) => _TransactionTile(
                      transaction: tx,
                      walletAddress: widget.address,
                      hideAmounts: hideAmounts,
                    ),
                  ),
                if (snapshot.hasData && snapshot.data!.hasMoreTransactions)
                  OutlinedButton.icon(
                    onPressed: () {
                      setState(() {
                        _historyLimit += 20;
                        _snapshot = _loadSnapshot();
                      });
                    },
                    icon: const Icon(Icons.expand_more_rounded),
                    label: const Text('LOAD MORE ACTIVITY'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AssetOverview extends StatelessWidget {
  const _AssetOverview(
      {required this.data,
      required this.address,
      required this.onSendAsset,
      required this.hideAmounts});
  final WalletSnapshot data;
  final String address;
  final ValueChanged<AssetSendIntent> onSendAsset;
  final bool hideAmounts;

  @override
  Widget build(BuildContext context) {
    final empty = data.krc20Tokens.isEmpty &&
        data.kcc20Tokens.isEmpty &&
        data.krc721Collections.isEmpty &&
        data.knsDomains.isEmpty;
    return Container(
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        color: KasVaultTheme.panel,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: KasVaultTheme.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (data.assetWarning != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                data.assetWarning!,
                style: const TextStyle(color: Color(0xFFFFB65C), fontSize: 12),
              ),
            ),
          if (empty && data.assetWarning == null)
            const Text(
              'No KRC-20, KRC-721 or KNS assets found for this address.',
              style: TextStyle(color: KasVaultTheme.muted),
            ),
          if (data.krc20Tokens.isNotEmpty) ...[
            const _AssetHeading('KRC-20 TOKENS'),
            ...data.krc20Tokens.map(
              (asset) => _AssetRow(
                asset: asset,
                hideAmount: hideAmounts,
                onTap: () => onSendAsset(AssetSendIntent.krc20(asset.symbol)),
              ),
            ),
          ],
          if (data.kcc20Tokens.isNotEmpty) ...[
            if (data.krc20Tokens.isNotEmpty) const Divider(height: 26),
            const _AssetHeading('KCC20 COVENANT TOKENS'),
            ...data.kcc20Tokens.map(
              (asset) => _AssetRow(
                asset: asset,
                hideAmount: hideAmounts,
                onTap: () => onSendAsset(
                  AssetSendIntent.kcc20(
                    asset.symbol,
                    asset.covenantId ?? asset.id ?? '',
                  ),
                ),
              ),
            ),
          ],
          if (data.krc721Collections.isNotEmpty) ...[
            if (data.krc20Tokens.isNotEmpty || data.kcc20Tokens.isNotEmpty)
              const Divider(height: 26),
            const _AssetHeading('KRC-721 COLLECTIONS'),
            ...data.krc721Collections.map(
              (asset) => _AssetRow(
                asset: asset,
                hideAmount: hideAmounts,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => NftCollectionScreen(
                      address: address,
                      ticker: asset.symbol,
                      onSend: (nft) => onSendAsset(
                        AssetSendIntent.krc721(
                          nft.ticker,
                          tokenId: nft.tokenId,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
          if (data.knsDomains.isNotEmpty) ...[
            if (data.krc20Tokens.isNotEmpty ||
                data.kcc20Tokens.isNotEmpty ||
                data.krc721Collections.isNotEmpty)
              const Divider(height: 26),
            const _AssetHeading('KNS DOMAINS'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: data.knsDomains
                  .map(
                    (domain) => ActionChip(
                      avatar: const Icon(
                        Icons.language_rounded,
                        size: 17,
                        color: KasVaultTheme.mint,
                      ),
                      label: Text(domain.name),
                      onPressed: () => onSendAsset(
                        AssetSendIntent.kns(domain.name, domain.assetId),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

class _AssetHeading extends StatelessWidget {
  const _AssetHeading(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Text(
          text,
          style: const TextStyle(
            color: KasVaultTheme.muted,
            fontSize: 11,
            fontWeight: FontWeight.w900,
            letterSpacing: .8,
          ),
        ),
      );
}

class _AssetRow extends StatelessWidget {
  const _AssetRow({
    required this.asset,
    required this.hideAmount,
    this.onTap,
  });
  final WalletAsset asset;
  final bool hideAmount;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            children: [
              _AssetIcon(asset: asset),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      asset.symbol,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 3),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        hideAmount ? '••••••' : _formatAssetBalance(asset),
                        maxLines: 1,
                        style: const TextStyle(
                          color: KasVaultTheme.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 6),
                const Icon(Icons.chevron_right_rounded,
                    color: KasVaultTheme.muted),
              ],
            ],
          ),
        ),
      );

  static String _formatAssetBalance(WalletAsset asset) {
    final raw = BigInt.tryParse(asset.rawBalance ?? '');
    if (raw != null) return formatRawTokenAmount(raw, asset.decimals);
    final value = asset.balance;
    return formatEnglishNumber(
      value,
      decimals: value == value.roundToDouble() ? 0 : 8,
      trimTrailingZeros: true,
    );
  }
}

class _AssetIcon extends StatelessWidget {
  const _AssetIcon({required this.asset});
  final WalletAsset asset;

  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: const Color(0xFF12302E),
      child: Center(
        child: Text(
          asset.symbol.isEmpty ? '?' : asset.symbol.substring(0, 1),
          style: const TextStyle(
            color: KasVaultTheme.mint,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
    return ClipOval(
      child: SizedBox.square(
        dimension: 36,
        child: asset.imageUrl == null
            ? fallback
            : Image.network(
                asset.imageUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => fallback,
              ),
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.snapshot, required this.hideAmounts});
  final AsyncSnapshot<WalletSnapshot> snapshot;
  final bool hideAmounts;
  @override
  Widget build(BuildContext context) {
    final data = snapshot.data;
    final kas = hideAmounts
        ? '••••••'
        : data == null
            ? '—'
            : formatEnglishNumber(data.balanceKas, decimals: 4);
    final fiat = hideAmounts
        ? 'Amounts hidden'
        : data?.fiatValue == null
            ? 'Live balance'
            : '\$${formatEnglishNumber(data!.fiatValue!, decimals: 2)} USD';
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF122B2B), Color(0xFF0B151A)],
        ),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0x6649EACB)),
        boxShadow: const [
          BoxShadow(color: Color(0x2249EACB), blurRadius: 34, spreadRadius: -8),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'TOTAL BALANCE',
            style: TextStyle(
              color: KasVaultTheme.muted,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 12),
          FittedBox(
            child: Text(
              '$kas KAS',
              style: const TextStyle(
                fontSize: 38,
                fontWeight: FontWeight.w900,
                letterSpacing: -1.5,
              ),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            fiat,
            style: const TextStyle(
              color: KasVaultTheme.mint,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 17),
          decoration: BoxDecoration(
            color: KasVaultTheme.panel,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: KasVaultTheme.line),
          ),
          child: Column(
            children: [
              Icon(icon, color: KasVaultTheme.mint),
              const SizedBox(height: 7),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  letterSpacing: .7,
                ),
              ),
            ],
          ),
        ),
      );
}

class _UtxoCard extends StatelessWidget {
  const _UtxoCard({
    required this.count,
    required this.working,
    required this.onCompound,
  });

  final int count;
  final bool working;
  final VoidCallback onCompound;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(17),
        decoration: BoxDecoration(
          color: KasVaultTheme.panel,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: KasVaultTheme.line),
        ),
        child: Row(
          children: [
            const CircleAvatar(
              backgroundColor: Color(0x2249EACB),
              child: Icon(Icons.join_inner_rounded, color: KasVaultTheme.mint),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'UTXOs',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '$count spendable output${count == 1 ? '' : 's'}',
                    style: const TextStyle(
                      color: KasVaultTheme.muted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            FilledButton.icon(
              onPressed: count > 1 && !working ? onCompound : null,
              icon: working
                  ? const SizedBox.square(
                      dimension: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.compress_rounded, size: 18),
              label: Text(working ? 'WORKING' : 'COMPOUND'),
            ),
          ],
        ),
      );
}

class _ConfirmCompound extends StatelessWidget {
  const _ConfirmCompound({
    required this.payment,
    required this.totalUtxos,
  });

  final PreparedPayment payment;
  final int totalUtxos;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Compound UTXOs'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This sends selected KAS outputs back to your own address.',
            ),
            const SizedBox(height: 18),
            _CompoundRow('Wallet UTXOs', '$totalUtxos'),
            _CompoundRow('Inputs selected', '${payment.inputCount}'),
            const _CompoundRow('Resulting outputs', '1'),
            _CompoundRow(
              'Network fee',
              '${formatEnglishNumber(payment.feeKas, decimals: 8)} KAS',
            ),
            if (totalUtxos > payment.inputCount) ...[
              const SizedBox(height: 12),
              Text(
                '${totalUtxos - payment.inputCount} UTXOs remain for a later '
                'compound because one transaction is limited to 80 inputs.',
                style: const TextStyle(
                  color: KasVaultTheme.muted,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('AUTHORIZE'),
          ),
        ],
      );
}

class _CompoundRow extends StatelessWidget {
  const _CompoundRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Row(
          children: [
            Text(label, style: const TextStyle(color: KasVaultTheme.muted)),
            const Spacer(),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
      );
}

class _TransactionTile extends StatelessWidget {
  const _TransactionTile({
    required this.transaction,
    required this.walletAddress,
    required this.hideAmounts,
  });
  final WalletTransaction transaction;
  final String walletAddress;
  final bool hideAmounts;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => TransactionDetailScreen(
                transaction: transaction,
                walletAddress: walletAddress,
              ),
            ),
          );
        },
        borderRadius: BorderRadius.circular(18),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: KasVaultTheme.panel,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: KasVaultTheme.line),
          ),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: transaction.incoming
                    ? const Color(0x2249EACB)
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
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          transaction.incoming ? 'Received' : 'Sent',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(width: 7),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0x2249EACB),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text(
                            transaction.assetKind,
                            style: const TextStyle(
                              color: KasVaultTheme.mint,
                              fontSize: 9,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: switch (transaction.status) {
                              TransactionStatus.confirmed =>
                                const Color(0x2249EACB),
                              TransactionStatus.failed =>
                                const Color(0x33FF6B6B),
                              _ => const Color(0x33FFB65C),
                            },
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text(
                            transaction.status.name.toUpperCase(),
                            style: TextStyle(
                              color:
                                  transaction.status == TransactionStatus.failed
                                      ? const Color(0xFFFF8A65)
                                      : transaction.status ==
                                              TransactionStatus.confirmed
                                          ? KasVaultTheme.mint
                                          : const Color(0xFFFFB65C),
                              fontSize: 9,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      "${'${transaction.timestamp.toLocal()}'.split('.').first}  ·  ${transaction.id.length > 10 ? '${transaction.id.substring(0, 10)}…' : transaction.id}",
                      style: const TextStyle(
                        color: KasVaultTheme.muted,
                        fontSize: 12,
                      ),
                    ),
                    if (transaction.counterparty != null &&
                        transaction.counterparty!.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        '${transaction.incoming ? 'From' : 'To'} '
                        '${_shortAddress(transaction.counterparty!)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: KasVaultTheme.mint,
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  hideAmounts
                      ? '••••••'
                      : '${transaction.incoming ? '+' : '-'}${transaction.amountLabel}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: transaction.incoming
                        ? KasVaultTheme.mint
                        : Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  static String _shortAddress(String value) {
    if (value.length <= 24) return value;
    return '${value.substring(0, 14)}…${value.substring(value.length - 8)}';
  }
}

class _EmptyActivity extends StatelessWidget {
  const _EmptyActivity();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 38),
        child: Column(
          children: [
            Icon(Icons.bolt_outlined, color: KasVaultTheme.muted, size: 36),
            SizedBox(height: 10),
            Text(
              'No transactions yet',
              style: TextStyle(color: KasVaultTheme.muted),
            ),
          ],
        ),
      );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.error, required this.onRetry});
  final Object? error;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final detail = error
        .toString()
        .replaceFirst('KaspaApiException: ', '')
        .replaceFirst('Exception: ', '');
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0x22FF6B6B),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              detail.contains('returned') || detail.contains('UTXO')
                  ? 'Security check rejected network data:\n$detail'
                  : 'Live data is temporarily unavailable.\n$detail',
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
