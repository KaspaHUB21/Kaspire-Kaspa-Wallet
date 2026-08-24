import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_settings.dart';
import '../services/evm_api.dart';
import '../services/native_security.dart';
import '../services/network_settings.dart';
import '../services/preferences_service.dart';
import '../services/privacy_settings.dart';
import '../theme.dart';
import '../widgets/kaspire_brand.dart';

class EvmWalletScreen extends StatefulWidget {
  const EvmWalletScreen(
      {super.key,
      required this.kaspaWalletAddress,
      required this.onChooseNetwork,
      required this.onSwitchWallet,
      required this.onPairDapps,
      required this.onSend,
      required this.onReceive});
  final String kaspaWalletAddress;
  final VoidCallback onChooseNetwork;
  final VoidCallback onSwitchWallet;
  final VoidCallback onPairDapps;
  final ValueChanged<EvmToken?> onSend;
  final VoidCallback onReceive;
  @override
  State<EvmWalletScreen> createState() => _EvmWalletScreenState();
}

class _EvmWalletScreenState extends State<EvmWalletScreen> {
  final _security = NativeSecurity();
  final _api = EvmApi();
  late Future<String> _address;
  late Future<EvmSnapshot> _snapshot;
  late Future<String> _walletName;
  Future<List<EvmActivity>>? _activity;
  bool _assetsExpanded = true;
  bool _activityExpanded = false;
  bool _showUnknown = false;

  @override
  void initState() {
    super.initState();
    _address = _security.getEvmAddress();
    _snapshot = _address.then(_api.loadWallet);
    _walletName = _loadWalletName();
    _activity = Future<void>.delayed(const Duration(milliseconds: 500))
        .then((_) => _address.then(_api.loadActivity));
  }

  Future<String> _loadWalletName() async {
    final names = await PreferencesService().getSubwalletNames();
    final saved = names[widget.kaspaWalletAddress.toLowerCase()];
    if (saved != null && saved.trim().isNotEmpty) return saved;
    for (final wallet in await _security.listWallets()) {
      if (wallet.address == widget.kaspaWalletAddress ||
          wallet.addresses
              .any((item) => item.address == widget.kaspaWalletAddress)) {
        return wallet.name;
      }
    }
    return 'Wallet';
  }

  Future<void> _refresh() async {
    setState(() {
      _snapshot = _address.then(_api.loadWallet);
      if (_activityExpanded) {
        _activity = _address.then(_api.loadActivity);
      }
      _walletName = _loadWalletName();
    });
    await _snapshot;
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Address copied')));
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: PrivacySettings.hideAmounts,
        builder: (context, hideAmounts, _) => SafeArea(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: FutureBuilder<String>(
                future: _address,
                builder: (context, address) => FutureBuilder<EvmSnapshot>(
                    future: _snapshot,
                    builder: (context, snapshot) => ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                          children: [
                            Row(children: [
                              const Expanded(
                                  child: KaspireWordmark(height: 19)),
                              IconButton(
                                  onPressed: widget.onSwitchWallet,
                                  tooltip: 'Switch wallet',
                                  icon: const Icon(
                                      Icons.account_balance_wallet_outlined)),
                              Tooltip(
                                message: 'Switch network',
                                child: InkWell(
                                  onTap: widget.onChooseNetwork,
                                  borderRadius: BorderRadius.circular(20),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 7),
                                    decoration: BoxDecoration(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary
                                            .withValues(alpha: .14),
                                        borderRadius:
                                            BorderRadius.circular(20)),
                                    child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.circle,
                                              size: 8,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .primary),
                                          const SizedBox(width: 7),
                                          Text(NetworkSettings.label,
                                              style: const TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w800)),
                                          const SizedBox(width: 3),
                                          const Icon(Icons.expand_more_rounded,
                                              size: 16),
                                        ]),
                                  ),
                                ),
                              ),
                            ]),
                            const SizedBox(height: 28),
                            FutureBuilder<String>(
                                future: _walletName,
                                builder: (context, name) => _EvmBalanceCard(
                                    walletName: name.data ?? 'Wallet',
                                    balance: snapshot.data?.nativeBalance,
                                    hideAmounts: hideAmounts,
                                    onTogglePrivacy: () =>
                                        PrivacySettings.setHideAmounts(
                                            !hideAmounts))),
                            const SizedBox(height: 16),
                            Row(children: [
                              Expanded(
                                  child: _EvmAction(
                                      icon: Icons.arrow_upward_rounded,
                                      label: 'SEND',
                                      onTap: () => widget.onSend(null))),
                              const SizedBox(width: 12),
                              Expanded(
                                  child: _EvmAction(
                                      icon: Icons.arrow_downward_rounded,
                                      label: 'RECEIVE',
                                      onTap: widget.onReceive)),
                              const SizedBox(width: 12),
                              Expanded(
                                  child: _EvmAction(
                                      icon: Icons.qr_code_scanner_rounded,
                                      label: 'PAIR DAPP',
                                      onTap: widget.onPairDapps)),
                            ]),
                            const SizedBox(height: 32),
                            _SectionHeader(
                                label: 'ASSETS',
                                expanded: _assetsExpanded,
                                onTap: () => setState(
                                    () => _assetsExpanded = !_assetsExpanded)),
                            if (_assetsExpanded) ...[
                              const SizedBox(height: 8),
                              if (snapshot.connectionState ==
                                  ConnectionState.waiting)
                                const Padding(
                                    padding: EdgeInsets.all(30),
                                    child: Center(
                                        child: CircularProgressIndicator())),
                              if (snapshot.hasError)
                                Card(
                                    child: Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: Text('${snapshot.error}'))),
                              if (snapshot.hasData)
                                ...snapshot.data!.tokens
                                    .where((token) =>
                                        token.trusted || _showUnknown)
                                    .map((token) => Card(
                                        color: KasVaultTheme.panel,
                                        child: ListTile(
                                          leading: token.iconUrl == null
                                              ? const CircleAvatar(
                                                  child:
                                                      Icon(Icons.token_rounded))
                                              : CircleAvatar(
                                                  backgroundImage: NetworkImage(
                                                      token.iconUrl!)),
                                          title: Text(token.symbol,
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.w900)),
                                          subtitle: Text(token.name),
                                          trailing: Text(hideAmounts
                                              ? '••••'
                                              : formatUnits(token.rawBalance,
                                                  token.decimals)),
                                          onTap: () => widget.onSend(token),
                                        ))),
                              if (snapshot.hasData &&
                                  snapshot.data!.tokens
                                      .any((token) => !token.trusted))
                                TextButton.icon(
                                    onPressed: () => setState(
                                        () => _showUnknown = !_showUnknown),
                                    icon: Icon(_showUnknown
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined),
                                    label: Text(_showUnknown
                                        ? 'Hide unknown tokens'
                                        : 'Show unknown tokens (${snapshot.data!.tokens.where((token) => !token.trusted).length})')),
                              const SizedBox(height: 24),
                            ],
                            _SectionHeader(
                                label: 'ACTIVITY',
                                expanded: _activityExpanded,
                                onTap: () => setState(() {
                                      _activityExpanded = !_activityExpanded;
                                      if (_activityExpanded) {
                                        _activity ??=
                                            _address.then(_api.loadActivity);
                                      }
                                    })),
                            if (_activityExpanded)
                              FutureBuilder<List<EvmActivity>>(
                                  future: _activity,
                                  builder: (context, activity) {
                                    if (activity.connectionState ==
                                        ConnectionState.waiting) {
                                      return const Padding(
                                          padding: EdgeInsets.all(30),
                                          child: Center(
                                              child:
                                                  CircularProgressIndicator()));
                                    }
                                    if (activity.hasError) {
                                      return Card(
                                          child: Padding(
                                              padding: const EdgeInsets.all(16),
                                              child:
                                                  Text('${activity.error}')));
                                    }
                                    if (!activity.hasData ||
                                        activity.data!.isEmpty) {
                                      return const Padding(
                                          padding: EdgeInsets.all(20),
                                          child: Text('No activity found.'));
                                    }
                                    return Column(
                                        children: activity.data!
                                            .map((tx) => _EvmActivityTile(
                                                transaction: tx,
                                                walletAddress:
                                                    address.data ?? ''))
                                            .toList());
                                  }),
                            if (address.hasData)
                              Padding(
                                padding: const EdgeInsets.only(top: 22),
                                child: Row(children: [
                                  Expanded(
                                      child: Text(address.data!,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontFamily: 'monospace',
                                              color: KasVaultTheme.muted))),
                                  IconButton(
                                      onPressed: () => _copy(address.data!),
                                      icon: const Icon(Icons.copy_rounded)),
                                ]),
                              ),
                          ],
                        ))),
          ),
        ),
      );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(
      {required this.label, required this.expanded, required this.onTap});
  final String label;
  final bool expanded;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(children: [
            Expanded(
                child: Text(displayLabel(label),
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2))),
            Icon(expanded
                ? Icons.expand_less_rounded
                : Icons.expand_more_rounded),
          ])));
}

class _EvmBalanceCard extends StatelessWidget {
  const _EvmBalanceCard(
      {required this.walletName,
      required this.balance,
      required this.hideAmounts,
      required this.onTogglePrivacy});
  final String walletName;
  final BigInt? balance;
  final bool hideAmounts;
  final VoidCallback onTogglePrivacy;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
            gradient: LinearGradient(colors: [
              Color.alphaBlend(KasVaultTheme.mint.withValues(alpha: .22),
                  KasVaultTheme.panel),
              KasVaultTheme.panel
            ]),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: KasVaultTheme.mint.withValues(alpha: .4)),
            boxShadow: [
              BoxShadow(
                  color: KasVaultTheme.mint.withValues(alpha: .13),
                  blurRadius: 34,
                  spreadRadius: -8)
            ]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(walletName,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w900))),
            IconButton(
                onPressed: onTogglePrivacy,
                tooltip: hideAmounts ? 'Show balances' : 'Hide balances',
                icon: Icon(hideAmounts
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded)),
          ]),
          const SizedBox(height: 12),
          FittedBox(
              child: Text(
                  hideAmounts
                      ? '••••••'
                      : balance == null
                          ? '—'
                          : '${formatUnits(balance!, 18)} ${EvmNetworkConfig.current.nativeSymbol}',
                  style: const TextStyle(
                      fontSize: 38,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1.5))),
        ]),
      );
}

class _EvmAction extends StatelessWidget {
  const _EvmAction(
      {required this.icon, required this.label, required this.onTap});
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
              border: Border.all(color: KasVaultTheme.line)),
          child: Column(children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 7),
            Text(buttonLabel(label),
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: .7)),
          ])));
}

class _EvmActivityTile extends StatelessWidget {
  const _EvmActivityTile(
      {required this.transaction, required this.walletAddress});
  final EvmActivity transaction;
  final String walletAddress;
  @override
  Widget build(BuildContext context) {
    final sent = transaction.from.toLowerCase() == walletAddress.toLowerCase();
    final symbol =
        transaction.assetSymbol ?? EvmNetworkConfig.current.nativeSymbol;
    return Card(
        color: KasVaultTheme.panel,
        child: ListTile(
            leading: Icon(sent
                ? Icons.arrow_upward_rounded
                : Icons.arrow_downward_rounded),
            title: Text(sent ? 'Sent' : 'Received'),
            subtitle: Text(transaction.method ?? 'Native transfer'),
            trailing: Text(
                '${formatUnits(transaction.value, transaction.decimals)} $symbol'),
            onTap: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                        title: const Text('Transaction details'),
                        content: SelectableText(
                            'Transaction ID\n${transaction.hash}\n\nFrom\n${transaction.from}\n\nTo\n${transaction.to}\n\nValue\n${formatUnits(transaction.value, transaction.decimals, visible: transaction.decimals)} $symbol\n\nNetwork fee\n${transaction.assetSymbol == null ? '${formatUnits(transaction.fee, 18, visible: 18)} ${EvmNetworkConfig.current.nativeSymbol}' : 'See associated network transaction'}\n\nStatus\n${transaction.success ? 'Confirmed' : 'Failed'}'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Close'))
                        ]))));
  }
}
