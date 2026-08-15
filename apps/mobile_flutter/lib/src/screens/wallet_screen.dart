import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/wallet_snapshot.dart';
import '../number_format.dart';
import '../services/kaspa_api.dart';
import '../services/activity_store.dart';
import '../services/native_security.dart';
import '../services/privacy_settings.dart';
import '../services/app_settings.dart';
import '../services/preferences_service.dart';
import '../services/signer_service.dart';
import '../services/network_settings.dart';
import '../services/dapp_session_service.dart';
import '../models/asset_send_intent.dart';
import '../theme.dart';
import 'nft_collection_screen.dart';
import 'krc20_token_detail_screen.dart';
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
  final KaspaApi _api = KaspaApi();
  late Future<WalletSnapshot> _snapshot;
  late Future<WalletSnapshot> _balance;
  late Future<int> _kasBalance;
  late Future<String> _walletName;
  Future<List<WalletTransaction>>? _activity;
  bool _activityExpanded = false;
  int _historyLimit = 20;
  bool _compounding = false;

  @override
  void initState() {
    super.initState();
    _kasBalance = _api.loadBalanceSompi(widget.address);
    _balance =
        _api.loadWalletBalance(widget.address, balanceSompi: _kasBalance);
    _snapshot = _loadSnapshot();
    _activity = Future<void>.delayed(const Duration(milliseconds: 500))
        .then<List<WalletTransaction>>((_) => _loadActivity());
    _walletName = _loadWalletName();
  }

  Future<String> _loadWalletName() async {
    final storedAddress = NetworkSettings.storageAddress(widget.address);
    final addressNames = await PreferencesService().getSubwalletNames();
    final addressName = addressNames[storedAddress.toLowerCase()];
    if (addressName != null && addressName.trim().isNotEmpty) {
      return addressName;
    }
    final native = await NativeSecurity().listWallets();
    for (final wallet in native) {
      if (wallet.address == storedAddress ||
          wallet.addresses.any((item) => item.address == storedAddress)) {
        return wallet.name;
      }
    }
    for (final wallet in await PreferencesService().getWatchWallets()) {
      if (wallet.address == storedAddress) return wallet.name;
    }
    return 'Wallet';
  }

  Future<WalletSnapshot> _loadSnapshot() async {
    final results = await Future.wait([
      _api.loadWallet(
        widget.address,
        transactionLimit: _historyLimit,
        includeNativeTransactions: false,
      ),
      ActivityStore().load(widget.address),
    ]);
    final snapshot = results[0] as WalletSnapshot;
    final local = results[1] as List<WalletTransaction>;
    final transactions = mergeWalletActivity(local, snapshot.transactions);
    return snapshot.withTransactions(transactions);
  }

  void _refresh() => setState(() {
        _kasBalance = _api.loadBalanceSompi(widget.address);
        _balance =
            _api.loadWalletBalance(widget.address, balanceSompi: _kasBalance);
        _snapshot = _loadSnapshot();
        if (_activityExpanded) _activity = _loadActivity();
      });

  Future<List<WalletTransaction>> _loadActivity() async {
    final results = await Future.wait([
      _snapshot,
      _api.loadNativeTransactions(widget.address, limit: _historyLimit),
      ActivityStore().load(widget.address),
    ]);
    final snapshot = results[0] as WalletSnapshot;
    final native = results[1] as List<WalletTransaction>;
    final local = results[2] as List<WalletTransaction>;
    return mergeWalletActivity(
      local,
      <WalletTransaction>[...snapshot.transactions, ...native]
        ..sort((a, b) => b.timestamp.compareTo(a.timestamp)),
    );
  }

  void _toggleActivity() {
    setState(() {
      _activityExpanded = !_activityExpanded;
      if (_activityExpanded) _activity ??= _loadActivity();
    });
  }

  Future<void> _chooseNetwork() async {
    final selected = await showDialog<KaspaNetwork>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Select Kaspa network'),
        children: [
          ListTile(
            leading: Icon(NetworkSettings.isTestnet
                ? Icons.radio_button_unchecked
                : Icons.radio_button_checked),
            title: const Text('Mainnet'),
            subtitle: const Text('Real KAS and Mainnet assets'),
            onTap: () => Navigator.pop(context, KaspaNetwork.mainnet),
          ),
          ListTile(
            leading: Icon(NetworkSettings.isTestnet
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked),
            title: const Text('TN10 Testnet'),
            subtitle: const Text('Test KAS only · no monetary value'),
            onTap: () => Navigator.pop(context, KaspaNetwork.tn10),
          ),
          ListTile(
            leading: const Icon(Icons.layers_outlined),
            title: const Text('Kasplex zkEVM'),
            subtitle: const Text('Chain ID 202555 · KAS and ERC-20 assets'),
            onTap: () => Navigator.pop(context, KaspaNetwork.kasplex),
          ),
          ListTile(
            leading: const Icon(Icons.layers_outlined),
            title: const Text('Igra Network'),
            subtitle: const Text('Chain ID 38833 · iKAS and ERC-20 assets'),
            onTap: () => Navigator.pop(context, KaspaNetwork.igra),
          ),
        ],
      ),
    );
    if (selected == null || selected == NetworkSettings.network.value) return;
    if (selected != KaspaNetwork.mainnet) {
      await DappSessionService.instance.disconnectAll();
    }
    await NetworkSettings.setNetwork(selected);
  }

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
                    InkWell(
                      onTap: _chooseNetwork,
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: .14),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.circle,
                                size: 8,
                                color: Theme.of(context).colorScheme.primary),
                            const SizedBox(width: 7),
                            Text(
                              NetworkSettings.label,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                FutureBuilder<int>(
                  future: _kasBalance,
                  builder: (context, kasBalance) =>
                      FutureBuilder<WalletSnapshot>(
                    future: _balance,
                    builder: (context, balance) => FutureBuilder<String>(
                      future: _walletName,
                      builder: (context, name) => _BalanceCard(
                        snapshot: balance,
                        fastBalanceSompi: kasBalance.data,
                        hideAmounts: hideAmounts,
                        walletName: name.data ?? 'Wallet',
                        onTogglePrivacy: () =>
                            PrivacySettings.setHideAmounts(!hideAmounts),
                      ),
                    ),
                  ),
                ),
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
                        label: 'PAIR DAPP',
                        onTap: NetworkSettings.isTestnet
                            ? () => ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'dApp sessions are available on Mainnet.',
                                    ),
                                  ),
                                )
                            : widget.onPairDapps,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                if (snapshot.hasData) ...[
                  Text(
                    displayLabel('ASSETS & NAMES'),
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
                InkWell(
                  onTap: _toggleActivity,
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            displayLabel('ACTIVITY'),
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ),
                        Icon(
                          _activityExpanded
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                        ),
                      ],
                    ),
                  ),
                ),
                if (_activityExpanded) ...[
                  const SizedBox(height: 12),
                  FutureBuilder<List<WalletTransaction>>(
                    future: _activity,
                    builder: (context, activity) => Column(
                      children: [
                        if (activity.connectionState == ConnectionState.waiting)
                          const Padding(
                            padding: EdgeInsets.all(36),
                            child: CircularProgressIndicator(),
                          ),
                        if (activity.hasError)
                          _ErrorCard(error: activity.error, onRetry: _refresh),
                        if (activity.hasData && activity.data!.isEmpty)
                          const _EmptyActivity(),
                        if (activity.hasData)
                          ...activity.data!.map(
                            (tx) => _TransactionTile(
                              transaction: tx,
                              walletAddress: widget.address,
                              hideAmounts: hideAmounts,
                            ),
                          ),
                        if (activity.hasData &&
                            activity.data!.length >= _historyLimit)
                          OutlinedButton.icon(
                            onPressed: () => setState(() {
                              _historyLimit += 20;
                              _activity = _loadActivity();
                            }),
                            icon: const Icon(Icons.expand_more_rounded),
                            label: Text(buttonLabel('LOAD MORE ACTIVITY')),
                          ),
                      ],
                    ),
                  ),
                ],
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
          if (empty)
            const Text(
              'No KRC-20, KRC-721 or KNS assets found for this address.',
              style: TextStyle(color: KasVaultTheme.muted),
            ),
          if (data.krc20Tokens.isNotEmpty)
            _AssetSection(
              title: 'KRC-20 TOKENS',
              count: data.krc20Tokens.length,
              children: data.krc20Tokens
                  .map(
                    (asset) => _AssetRow(
                      asset: asset,
                      hideAmount: hideAmounts,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => Krc20TokenDetailScreen(
                            asset: asset,
                            usdToFiat: data.usdToFiat,
                            fiatCode: data.fiatCode,
                            fiatSymbol: data.fiatSymbol,
                            onSend: () => onSendAsset(
                              AssetSendIntent.krc20(asset.symbol),
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          if (data.kcc20Tokens.isNotEmpty)
            _AssetSection(
              title: 'KCC20 COVENANT TOKENS',
              count: data.kcc20Tokens.length,
              children: data.kcc20Tokens
                  .map(
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
                  )
                  .toList(),
            ),
          if (data.krc721Collections.isNotEmpty)
            _AssetSection(
              title: 'KRC-721 COLLECTIONS',
              count: data.krc721Collections.length,
              children: data.krc721Collections
                  .map(
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
                  )
                  .toList(),
            ),
          if (data.knsDomains.isNotEmpty)
            _AssetSection(
              title: 'KNS DOMAINS',
              count: data.knsDomains.length,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: data.knsDomains
                      .map(
                        (domain) => ActionChip(
                          avatar: Icon(
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
            ),
        ],
      ),
    );
  }
}

class _AssetSection extends StatelessWidget {
  const _AssetSection({
    required this.title,
    required this.count,
    required this.children,
  });

  final String title;
  final int count;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: PageStorageKey(title),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 10),
          leading: Icon(
            Icons.layers_outlined,
            color: KasVaultTheme.mint,
          ),
          title: Text(
            displayLabel(title),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w900,
              letterSpacing: .7,
            ),
          ),
          subtitle: Text('$count asset${count == 1 ? '' : 's'}'),
          children: children,
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
      color: KasVaultTheme.mint.withValues(alpha: .12),
      child: Center(
        child: Text(
          asset.symbol.isEmpty ? '?' : asset.symbol.substring(0, 1),
          style: TextStyle(
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
  const _BalanceCard({
    required this.snapshot,
    required this.fastBalanceSompi,
    required this.hideAmounts,
    required this.walletName,
    required this.onTogglePrivacy,
  });
  final AsyncSnapshot<WalletSnapshot> snapshot;
  final int? fastBalanceSompi;
  final bool hideAmounts;
  final String walletName;
  final VoidCallback onTogglePrivacy;
  @override
  Widget build(BuildContext context) {
    final data = snapshot.data;
    final balanceKas = data?.balanceKas ??
        (fastBalanceSompi == null ? null : fastBalanceSompi! / 100000000);
    final kas = hideAmounts
        ? '••••••'
        : balanceKas == null
            ? '—'
            : formatEnglishNumber(balanceKas, decimals: 4);
    final fiat = hideAmounts
        ? 'Amounts hidden'
        : data?.fiatValue == null
            ? 'Live balance'
            : '${data!.fiatSymbol}${formatEnglishNumber(data.fiatValue!, decimals: 2)} ${data.fiatCode}';
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Color.alphaBlend(
              KasVaultTheme.mint.withValues(alpha: .22),
              KasVaultTheme.panel,
            ),
            KasVaultTheme.panel,
          ],
        ),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: KasVaultTheme.mint.withValues(alpha: .4),
        ),
        boxShadow: [
          BoxShadow(
            color: KasVaultTheme.mint.withValues(alpha: .13),
            blurRadius: 34,
            spreadRadius: -8,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      walletName,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      displayLabel('TOTAL BALANCE'),
                      style: TextStyle(
                        color: KasVaultTheme.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: onTogglePrivacy,
                tooltip: hideAmounts ? 'Show balances' : 'Hide balances',
                icon: Icon(
                  hideAmounts
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                ),
              ),
            ],
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
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
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
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 7),
              Text(
                buttonLabel(label),
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
            CircleAvatar(
              backgroundColor: KasVaultTheme.mint.withValues(alpha: .13),
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
              label: Text(
                buttonLabel(working ? 'WORKING' : 'COMPOUND'),
              ),
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
            child: Text(buttonLabel('CANCEL')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(buttonLabel('AUTHORIZE')),
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
                            color: KasVaultTheme.mint.withValues(alpha: .13),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text(
                            transaction.assetKind,
                            style: TextStyle(
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
                                KasVaultTheme.mint.withValues(alpha: .13),
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
                        style: TextStyle(
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
