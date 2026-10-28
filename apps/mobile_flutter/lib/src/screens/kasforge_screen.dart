import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/wallet_snapshot.dart';
import '../number_format.dart';
import '../services/kasforge_service.dart';
import '../services/kasforge_trading.dart';
import 'kasforge_order_screen.dart';
import '../widgets/sell_amount_buttons.dart';
import 'kasparocket_screen.dart' show rocketListPadding;

class KasForgeScreen extends StatefulWidget {
  const KasForgeScreen(
      {super.key,
      required this.address,
      this.initialTokenId,
      this.service,
      this.trading});
  final String address;
  final String? initialTokenId;
  final KasForgeService? service;
  final KasForgeTrading? trading;
  @override
  State<KasForgeScreen> createState() => _KasForgeScreenState();
}

class _KasForgeScreenState extends State<KasForgeScreen> {
  late final service = widget.service ?? KasForgeService();
  late Future<List<KasForgeToken>> tokens;
  late Future<Map<String, dynamic>> portfolio;
  final search = TextEditingController();
  var visible = 20;
  var openedInitial = false;
  late final trading = widget.trading ?? KasForgeTrading();
  late Future<List<Map<String, dynamic>>> savedOrders;

  @override
  void initState() {
    super.initState();
    reload();
  }

  void reload() {
    setState(() {
      tokens = service.catalogue();
      portfolio = service.portfolio(widget.address);
      // The activity tab may not mount until selected; still handle a failing
      // request immediately, while preserving its error for FutureBuilder.
      portfolio.ignore();
      savedOrders = trading.saved(widget.address);
      savedOrders.ignore();
      visible = 20;
    });
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Widget error(Object? value) => Padding(
      padding: const EdgeInsets.all(20),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('$value', textAlign: TextAlign.center),
        const SizedBox(height: 12),
        OutlinedButton.icon(
            onPressed: reload,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry')),
      ]));

  @override
  Widget build(BuildContext context) => DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
            title: const Text('KasForge · Testnet 10'),
            actions: [
              IconButton(
                  onPressed: reload,
                  tooltip: 'Reload',
                  icon: const Icon(Icons.refresh)),
            ],
            bottom: const TabBar(
                tabs: [Tab(text: 'DEX swaps'), Tab(text: 'My activity')])),
        body: TabBarView(children: [
          browse(),
          ListView(padding: rocketListPadding(context), children: [
            _SavedForgeOrders(
                address: widget.address,
                future: savedOrders,
                trading: trading,
                reload: reload),
            history(),
          ])
        ]),
      ));

  Future<void> open(KasForgeToken token) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => KasForgeTradeScreen(
            address: widget.address,
            token: token,
            service: service,
            trading: trading)));
    if (mounted) reload();
  }

  Widget browse() => FutureBuilder<List<KasForgeToken>>(
      future: tokens,
      builder: (context, snapshot) {
        if (!snapshot.hasData && !snapshot.hasError) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) return error(snapshot.error);
        if (!openedInitial && widget.initialTokenId != null) {
          openedInitial = true;
          final initial =
              snapshot.data!.where((t) => t.id == widget.initialTokenId);
          if (initial.isNotEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) open(initial.first);
            });
          }
        }
        final q = search.text.trim().toLowerCase();
        final rows = snapshot.data!
            .where((t) => [t.symbol, t.name, t.id]
                .any((s) => s.toLowerCase().contains(q)))
            .toList();
        return ListView(padding: rocketListPadding(context), children: [
          _SavedForgeOrders(
              address: widget.address,
              future: savedOrders,
              trading: trading,
              reload: reload,
              pendingOnly: true),
          const Card(
              child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('KasForge',
                            style: TextStyle(
                                fontSize: 22, fontWeight: FontWeight.bold)),
                        Text('Testnet 10 · Bonding curves and graduated pools'),
                        SizedBox(height: 8),
                        Text(
                            'Testnet trades use locally verified covenant orders. A deposit is not a completed swap.'),
                      ]))),
          const SizedBox(height: 12),
          TextField(
              controller: search,
              onChanged: (_) => setState(() => visible = 20),
              decoration: const InputDecoration(
                  labelText: 'Ticker, name or covenant ID',
                  prefixIcon: Icon(Icons.search))),
          const SizedBox(height: 12),
          if (rows.isEmpty)
            const Padding(
                padding: EdgeInsets.all(20),
                child: Text('No matching KasForge tokens.')),
          for (final token in rows.take(visible))
            Card(
                child: ListTile(
              leading: kasForgeImage(token.logo),
              title: Text(token.symbol,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(token.name,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    Text(token.graduated ? 'Pool' : 'Bonding curve'),
                    if (token.marketCapKas != null)
                      Text(
                          'Market cap: ${formatEnglishNumber(token.marketCapKas!, decimals: 2)} KAS'),
                    Text(token.id,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ]),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => open(token),
            )),
          if (rows.length > visible)
            OutlinedButton(
                onPressed: () => setState(() => visible += 20),
                child: const Text('Load more')),
        ]);
      });

  Widget history() => FutureBuilder<List<Map<String, dynamic>>>(
      future: savedOrders,
      builder: (context, local) => FutureBuilder<Map<String, dynamic>>(
          future: portfolio,
          builder: (context, snapshot) {
            final data =
                snapshot.data ?? {'orders': <Map>[], 'activity': <Map>[]};
            final orders = (data['orders'] as List).whereType<Map>().toList();
            final activity = KasForgeService.activityRows(
                (data['activity'] as List).whereType<Map>().toList(),
                local.data ?? []);
            return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (snapshot.hasError)
                    Text(
                        'Forge history temporarily unavailable. Local completed orders are retained. ${snapshot.error}'),
                  if (!snapshot.hasData && !snapshot.hasError)
                    const Text('Loading Forge history…'),
                  const Text('Open orders',
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const Text(
                      'An open order is not a completed swap. Unfilled orders may wait until cancellation or expiry.'),
                  if (orders.isEmpty && snapshot.hasData)
                    const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                            'No open orders reported by Forge. Local recovery orders are shown separately above.')),
                  for (final order in orders)
                    Card(
                        child: ListTile(
                      title: Text(
                          '${order['side'] ?? order['type'] ?? 'Order'} · ${order['tick'] ?? order['name'] ?? ''}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                          '${order['status'] ?? 'Open'} · ${order['id'] ?? order['txid'] ?? ''}',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis),
                    )),
                  const SizedBox(height: 20),
                  const Text('Activity',
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  if (activity.isEmpty && snapshot.hasData)
                    const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('No KasForge activity.')),
                  for (final row in activity.take(50))
                    Card(
                        child: ExpansionTile(
                      title: Text(
                          '${row['state'] == 'filled' ? row['side'] ?? row['type'] ?? 'Trade' : row['state']} · ${row['tick'] ?? row['name'] ?? ''}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                      subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (row['tokens'] != null)
                              Text(
                                  'Tokens: ${forgeTokenQuantity(row['tokens'])} ${row['tick'] ?? ''}'),
                            if (KasForgeService.nonnegativeNumber(row['kas']) !=
                                null)
                              Text(
                                  'Trade value: ${formatEnglishNumber(KasForgeService.nonnegativeNumber(row['kas'])!, decimals: 8, trimTrailingZeros: true)} KAS')
                            else if (row['kasSompi'] != null)
                              Text(
                                  'Wallet KAS returned: ${formatRawTokenAmount(BigInt.parse('${row['kasSompi']}'), 8)} KAS'),
                            if (row['orderAmount'] != null)
                              Text(
                                  'Order amount: ${row['orderAmount']} ${row['orderAsset']}'),
                            if (row['kind'] != null)
                              Text('Market: ${row['kind']}'),
                          ]),
                      children: [
                        Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (row['tokens'] == null)
                                    const Text(
                                        'Executed token amount unavailable.'),
                                  if (KasForgeService.nonnegativeNumber(
                                          row['priceKas']) !=
                                      null)
                                    Text(
                                        'Price per token: ${formatEnglishNumber(KasForgeService.nonnegativeNumber(row['priceKas'])!, decimals: 8, trimTrailingZeros: true)} KAS'),
                                  if ((KasForgeService.nonnegativeNumber(
                                              row['ts']) ??
                                          0) >
                                      0)
                                    Text(
                                        'Date: ${DateTime.fromMillisecondsSinceEpoch((KasForgeService.nonnegativeNumber(row['ts'])! * 1000).toInt()).toLocal()}'),
                                  if (row['token'] != null)
                                    SelectableText(
                                        'Token covenant ID: ${row['token']}'),
                                  SelectableText(
                                      '${row['txid'] ?? 'No confirmed settlement transaction'}'),
                                  if (row['txid'] is String)
                                    OutlinedButton.icon(
                                        onPressed: () => Clipboard.setData(
                                            ClipboardData(
                                                text: '${row['txid']}')),
                                        icon: const Icon(Icons.copy),
                                        label:
                                            const Text('Copy transaction ID')),
                                  if (row['receipt'] is Map)
                                    OutlinedButton(
                                        onPressed: () async {
                                          await Navigator.push(
                                              context,
                                              MaterialPageRoute<void>(
                                                  builder: (_) =>
                                                      KasForgeOrderScreen(
                                                          address:
                                                              widget.address,
                                                          receipt: Map<String,
                                                                  dynamic>.from(
                                                              row['receipt']
                                                                  as Map),
                                                          trading: trading)));
                                          if (mounted) reload();
                                        },
                                        child:
                                            const Text('View completed order')),
                                ]))
                      ],
                    )),
                  if (activity.length > 50)
                    const Text(
                        'Showing the latest 50 KasForge activity entries.'),
                ]);
          }));
}

Widget kasForgeImage(String? url) => ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: url == null
        ? const SizedBox(width: 44, height: 44, child: Icon(Icons.token))
        : Image.network(
            url,
            width: 44,
            height: 44,
            cacheWidth: 128,
            errorBuilder: (_, __, ___) =>
                const SizedBox(width: 44, height: 44, child: Icon(Icons.token)),
          ));

String forgeTokenQuantity(Object? value) {
  try {
    return formatRawTokenAmount(KasForgeService.exactUnsigned(value), 0);
  } catch (_) {
    return 'unavailable';
  }
}

class _SavedForgeOrders extends StatelessWidget {
  const _SavedForgeOrders(
      {required this.address,
      required this.future,
      required this.trading,
      required this.reload,
      this.pendingOnly = false});
  final String address;
  final Future<List<Map<String, dynamic>>> future;
  final KasForgeTrading trading;
  final VoidCallback reload;
  final bool pendingOnly;

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<List<Map<String, dynamic>>>(
          future: future,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Card(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                                'Saved Forge orders could not be loaded. Recovery data must not be treated as empty.'),
                            Text('${snapshot.error}'),
                            OutlinedButton(
                                onPressed: reload,
                                child: const Text('Retry saved orders')),
                          ])));
            }
            if (!snapshot.hasData) {
              return const Card(
                  child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Row(children: [
                        SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator()),
                        SizedBox(width: 12),
                        Expanded(child: Text('Loading saved Forge orders…'))
                      ])));
            }
            final rows = snapshot.data!.reversed
                .where((r) =>
                    r['finalVerified'] != true &&
                    (!pendingOnly || r['signed'] is List))
                .toList();
            if (rows.isEmpty) return const SizedBox.shrink();
            return Card(
                child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              pendingOnly
                                  ? 'Saved Forge order needs attention'
                                  : 'Saved orders on this device',
                              style: Theme.of(context).textTheme.titleMedium),
                          if (rows.isEmpty)
                            const Text(
                                'No saved orders for this wallet on this device.'),
                          for (final r in rows)
                            ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(r['finalVerified'] == true
                                    ? Icons.check_circle_outline
                                    : Icons.warning_amber_rounded),
                                title: Text('${r['symbol']} · ${r['state']}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis),
                                subtitle:
                                    const Text('Open saved order / recovery'),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () async {
                                  await Navigator.push(
                                      context,
                                      MaterialPageRoute<void>(
                                          builder: (_) => KasForgeOrderScreen(
                                              address: address,
                                              receipt: r,
                                              trading: trading)));
                                  if (context.mounted) reload();
                                }),
                        ])));
          });
}

class KasForgeTradeScreen extends StatefulWidget {
  const KasForgeTradeScreen(
      {super.key,
      required this.address,
      required this.token,
      required this.service,
      this.trading});
  final String address;
  final KasForgeToken token;
  final KasForgeService service;
  final KasForgeTrading? trading;
  @override
  State<KasForgeTradeScreen> createState() => _KasForgeTradeScreenState();
}

class _KasForgeTradeScreenState extends State<KasForgeTradeScreen> {
  late final trading = widget.trading ?? KasForgeTrading();
  final amount = TextEditingController();
  late Future<List<WalletAsset>> holdings;
  late Future<List<Map<String, dynamic>>> savedOrders;
  String side = 'buy';
  bool busy = false;
  int generation = 0;
  Map<String, dynamic>? quoted;
  String? error;
  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void dispose() {
    generation++;
    amount.dispose();
    super.dispose();
  }

  void reload() => setState(() {
        generation++;
        quoted = null;
        error = null;
        holdings = widget.service.walletAssets(widget.address);
        holdings.ignore();
        savedOrders = trading.saved(widget.address);
        savedOrders.ignore();
      });

  Future<void> quote() async {
    final current = ++generation;
    setState(() {
      busy = true;
      quoted = null;
      error = null;
    });
    try {
      final result =
          await widget.service.quote(widget.token, side, amount.text.trim());
      if (mounted && current == generation) setState(() => quoted = result);
    } catch (e) {
      if (mounted && current == generation) setState(() => error = '$e');
    } finally {
      if (mounted && current == generation) setState(() => busy = false);
    }
  }

  Future<void> reviewOrder() async {
    final q = quoted;
    if (q == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final receipt = await trading.exclusive(
          widget.address,
          () async =>
              await trading.pending(widget.address) ??
              await trading.build(
                  widget.address, widget.token, side, amount.text.trim(), q));
      if (!mounted) return;
      await Navigator.push(
          context,
          MaterialPageRoute<void>(
              builder: (_) => KasForgeOrderScreen(
                  address: widget.address,
                  receipt: receipt,
                  trading: trading)));
      if (mounted) reload();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: Text('${widget.token.symbol} · KasForge'),
            actions: [
              IconButton(
                  onPressed: busy ? null : reload,
                  icon: const Icon(Icons.refresh))
            ]),
        body: ListView(padding: rocketListPadding(context), children: [
          _SavedForgeOrders(
              address: widget.address,
              future: savedOrders,
              trading: trading,
              reload: reload,
              pendingOnly: true),
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          kasForgeImage(widget.token.logo),
                          const SizedBox(width: 12),
                          Expanded(
                              child: Text(widget.token.name,
                                  style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold)))
                        ]),
                        const SizedBox(height: 12),
                        Text(widget.token.graduated
                            ? 'Testnet 10 · Pool'
                            : 'Testnet 10 · Bonding curve'),
                        SelectableText(widget.token.id),
                        if (widget.token.priceKas != null)
                          Text(
                              'Price per token: ${formatEnglishNumber(widget.token.priceKas!, trimTrailingZeros: true)} KAS'),
                      ]))),
          const SizedBox(height: 12),
          SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'buy', label: Text('Buy')),
                ButtonSegment(value: 'sell', label: Text('Sell'))
              ],
              selected: {
                side
              },
              onSelectionChanged: busy
                  ? null
                  : (value) => setState(() {
                        generation++;
                        side = value.single;
                        amount.clear();
                        quoted = null;
                        error = null;
                      })),
          const SizedBox(height: 12),
          FutureBuilder<List<WalletAsset>>(
              future: holdings,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Text('Wallet balance unavailable. ${snapshot.error}');
                }
                if (!snapshot.hasData) {
                  return const Text('Loading wallet token balance…');
                }
                final own = snapshot.data!
                    .where((asset) => asset.covenantId == widget.token.id);
                final raw = own.isEmpty
                    ? BigInt.zero
                    : BigInt.parse(own.single.rawBalance!);
                return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          'Wallet token balance: ${formatRawTokenAmount(raw, widget.token.decimals)} ${widget.token.symbol}'),
                      if (side == 'sell')
                        SellAmountButtons(
                            balance: raw,
                            decimals: widget.token.decimals,
                            enabled: !busy,
                            onSelected: (value) => setState(() {
                                  generation++;
                                  amount.text = value;
                                  quoted = null;
                                  error = null;
                                })),
                    ]);
              }),
          const SizedBox(height: 12),
          TextField(
              controller: amount,
              enabled: !busy,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() {
                    generation++;
                    quoted = null;
                    error = null;
                  }),
              decoration: InputDecoration(
                  labelText: side == 'buy'
                      ? 'Trade amount in KAS'
                      : 'Token amount (whole tokens)',
                  suffixText: side == 'buy' ? 'KAS' : null)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
              onPressed: busy ? null : quote,
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
              label: const Text('Preview quote')),
          if (error != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
          if (quoted != null)
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                              'Estimate only · no order has been submitted',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          Text(
                              'Route: ${widget.token.graduated ? 'Pool' : 'Bonding curve'}'),
                          Text(side == 'buy'
                              ? 'Estimated tokens: ${formatRawTokenAmount(KasForgeService.exactUnsigned(quoted!['receiveTokens']), 0)} ${widget.token.symbol}'
                              : 'Estimated proceeds: ${formatEnglishNumber(quoted!['receiveKas'] as num, trimTrailingZeros: true)} KAS'),
                          for (final field in const {
                            'swapFeeKas': 'Protocol fee',
                            'settleTipKas': 'Settlement tip',
                            'tokenDepositKas': 'Token deposit'
                          }.entries)
                            if (quoted![field.key] is num)
                              Text(
                                  '${field.value}: ${formatEnglishNumber(quoted![field.key] as num, trimTrailingZeros: true)} KAS'),
                        ]))),
          const SizedBox(height: 16),
          FilledButton(
              onPressed: busy || quoted == null ? null : reviewOrder,
              child: const Text('Review Forge order')),
        ]),
      );
}
