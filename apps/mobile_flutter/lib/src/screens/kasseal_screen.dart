import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/kasseal_service.dart';
import '../services/kron_dex_service.dart' show KronDexService;
import '../services/native_security.dart';
import '../services/network_settings.dart';
import 'kasparocket_screen.dart' show rocketListPadding;

class KassealScreen extends StatefulWidget {
  const KassealScreen(
      {super.key, required this.address, this.tokenId, this.service});
  final String address;
  final String? tokenId;
  final KassealService? service;
  @override
  State<KassealScreen> createState() => _KassealScreenState();
}

class _KassealScreenState extends State<KassealScreen>
    with SingleTickerProviderStateMixin {
  late final service = widget.service ?? KassealService();
  final search = TextEditingController();
  final rows = <Map<String, dynamic>>[];
  String? cursor;
  String error = '';
  bool loading = false;
  late final TabController tabs;
  late Future<List<Map<String, dynamic>>> history;
  int historyLimit = 20;
  String get address => NetworkSettings.addressForNetwork(widget.address);
  @override
  void initState() {
    super.initState();
    tabs = TabController(length: 2, vsync: this);
    load();
  }

  @override
  void dispose() {
    search.dispose();
    tabs.dispose();
    super.dispose();
  }

  Future<void> load({bool more = false}) async {
    if (loading) return;
    setState(() {
      loading = true;
      error = '';
      if (!more) history = service.history(address);
    });
    try {
      service.guard(address);
      final data = await service.tokens(more ? cursor : null);
      if (!mounted) return;
      setState(() {
        if (!more) rows.clear();
        final ids = rows.map((t) => (t['meta'] as Map)['covenantId']).toSet();
        rows.addAll((data['tokens'] as List)
            .whereType<Map>()
            .where((t) =>
                t['verification'] == 'verified' &&
                !ids.contains(t['meta']['covenantId']))
            .map((t) => Map<String, dynamic>.from(t)));
        cursor = data['nextCursor'] as String?;
      });
      if (widget.tokenId != null) {
        final selected =
            rows.where((t) => t['meta']['covenantId'] == widget.tokenId);
        if (selected.isNotEmpty && mounted) await open(selected.first);
      }
    } catch (e) {
      if (mounted) setState(() => error = _readable(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> open(Map<String, dynamic> token) async {
    await Navigator.push<void>(
        context,
        MaterialPageRoute(
            builder: (_) => KassealTradeScreen(
                address: address, token: token, service: service)));
    if (mounted) setState(() => history = service.history(address));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(
          title: Text('Kasseal DEX · ${service.networkLabel}'),
          actions: [
            IconButton(
                onPressed: loading ? null : load,
                icon: const Icon(Icons.refresh))
          ],
          bottom: TabBar(
              controller: tabs,
              tabs: const [Tab(text: 'DEX swaps'), Tab(text: 'Swap history')])),
      body: TabBarView(controller: tabs, children: [browse(), swapHistory()]));

  Widget swapHistory() => FutureBuilder<List<Map<String, dynamic>>>(
      future: history,
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text(_readable(snap.error!)));
        if (!snap.hasData)
          return const Center(child: CircularProgressIndicator());
        final rows = snap.data!;
        return ListView(padding: rocketListPadding(context), children: [
          Text(
              'Swaps completed in Kaspire on this device · ${service.networkLabel}'),
          if (rows.isEmpty)
            const ListTile(title: Text('No Kasseal swaps yet.')),
          for (final row in rows.take(historyLimit))
            Card(
                child: ExpansionTile(
                    title: Text(
                        '${row['summary']['side'] == 'buy' ? 'Buy' : 'Sell'} ${row['ticker']}'),
                    subtitle: Text(
                        '${KronDexService.display(row['summary']['tokenAmount'], 0)} ${row['ticker']}'),
                    children: [
                  Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(children: [
                        Text('${row['timestamp']}'),
                        if (row['summary']['kasSompi'] != null)
                          Text(
                              '${KronDexService.display(row['summary']['kasSompi'], 8)} KAS'),
                        SelectableText('${row['transactionId']}'),
                        TextButton.icon(
                            onPressed: () => Clipboard.setData(
                                ClipboardData(text: '${row['transactionId']}')),
                            icon: const Icon(Icons.copy),
                            label: const Text('Copy transaction ID'))
                      ]))
                ])),
          if (rows.length > historyLimit)
            OutlinedButton(
                onPressed: () => setState(() => historyLimit += 20),
                child: const Text('Load more'))
        ]);
      });

  Widget browse() => ListView(padding: rocketListPadding(context), children: [
        Card(
            child: Padding(
                padding: const EdgeInsets.all(18),
                child: Text(
                    '${service.networkLabel} · Bonding curves & pool swaps\nToken amounts are whole tokens. A new token cell locks a refundable deposit, shown in the review; this is not a fee.'))),
        const SizedBox(height: 12),
        TextField(
            controller: search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
                labelText: 'Search ticker, name or covenant ID',
                prefixIcon: Icon(Icons.search))),
        if (error.isNotEmpty)
          Padding(padding: const EdgeInsets.all(16), child: Text(error)),
        ...rows
            .where((t) => '${t['meta']}'
                .toLowerCase()
                .contains(search.text.trim().toLowerCase()))
            .map((t) {
          final m = t['meta'] as Map, image = service.image(m);
          return Card(
              child: ListTile(
                  leading: image == null
                      ? const Icon(Icons.token)
                      : Image.network(image,
                          width: 48,
                          height: 48,
                          errorBuilder: (_, e, s) => const Icon(Icons.token)),
                  title: Text('${m['ticker'] ?? m['name'] ?? 'Token'}'),
                  subtitle: Text(
                      '${t['phase'] == 'bonding' ? 'Launchpad' : 'Pool'} · ${m['covenantId']}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => open(t)));
        }),
        if (loading)
          const Center(
              child: Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator())),
        if (cursor != null && !loading)
          OutlinedButton(
              onPressed: () => load(more: true),
              child: const Text('Load more')),
        if (rows.isEmpty && !loading && error.isEmpty)
          const Padding(
              padding: EdgeInsets.all(20),
              child: Text('No verified Kasseal tokens found.')),
      ]);
}

String _readable(Object e) => e
    .toString()
    .replaceFirst('Bad state: ', '')
    .replaceFirst('StateError: ', '');

class KassealTradeScreen extends StatefulWidget {
  const KassealTradeScreen(
      {super.key,
      required this.address,
      required this.token,
      required this.service});
  final String address;
  final Map<String, dynamic> token;
  final KassealService service;
  @override
  State<KassealTradeScreen> createState() => _KassealTradeScreenState();
}

class _KassealTradeScreenState extends State<KassealTradeScreen> {
  final amount = TextEditingController(), security = NativeSecurity();
  String side = 'buy', error = '';
  bool busy = false;
  Map<String, dynamic>? quote, recovery, completed;
  BigInt? held;
  BigInt? kasBalance;
  String get id => '${widget.token['meta']['covenantId']}';
  String get ticker =>
      '${widget.token['meta']['ticker'] ?? widget.token['meta']['name'] ?? id.substring(0, 8)}';
  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    try {
      final balance = await widget.service.kasBalance(widget.address);
      if (mounted) setState(() => kasBalance = balance);
    } catch (_) {
      if (mounted) setState(() => kasBalance = null);
    }
    try {
      final saved = await widget.service.pending(widget.address);
      if (mounted) setState(() => recovery = saved);
      final data = await widget.service.wallet(widget.address);
      final rows = (data['holdings'] as List? ?? const [])
          .whereType<Map>()
          .where((t) => t['tokenId'] == id);
      if (mounted)
        setState(() => held = rows.isEmpty
            ? BigInt.zero
            : BigInt.parse('${rows.first['balance']}'));
    } catch (e) {
      if (mounted) setState(() => error = _readable(e));
    }
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = _readable(e));
      await refresh();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> getQuote() async {
    final raw = KronDexService.parseAmount(amount.text, side == 'buy' ? 8 : 0);
    if (side == 'sell' && (held == null || raw > held!))
      throw StateError(
          'Insufficient $ticker. Available: ${held ?? 'unknown'}.');
    final next =
        await widget.service.quote(widget.address, id, side, raw.toString());
    if (mounted)
      setState(() {
        quote = next;
        recovery = null;
      });
  }

  Future<void> swap({int preparations = 0}) async {
    if (recovery != null)
      throw StateError('Check the saved swap before starting another trade.');
    final q = quote;
    if (q == null) throw StateError('Get a live quote first.');
    final request = await widget.service.plan(widget.address, q);
    await widget.service.verifyInputs(widget.address, request);
    final review = await security.preparePskt(request);
    await widget.service.verifyInputs(widget.address, request, review);
    if (!mounted) return;
    final terms = Map<String, dynamic>.from(request['tradeSummary'] as Map);
    final preparing = terms['stage'] == 'preparation';
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text(preparing
                    ? 'Prepare $ticker for sale'
                    : '${side == 'buy' ? 'Buy' : 'Sell'} $ticker · ${widget.service.networkLabel}'),
                content: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  ...details(terms),
                  line('Token covenant', id),
                  line('Market covenant', '${request['lpCovenantId']}'),
                  const Text(
                      'Token tickers are not unique. Verify the covenant IDs. The Rust core checks the transaction and executes its contracts before returning signatures.')
                ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(preparing
                          ? 'Authorize preparation'
                          : 'Authorize & swap'))
                ]));
    if (ok != true || !mounted) return;
    await widget.service.verifyInputs(widget.address, request, review);
    final signed = await security.signPskt(request, '${review['reviewHash']}');
    final receipt = <String, dynamic>{
      'network': widget.service.network,
      'address': widget.address,
      'signedTxJson': signed['signedTxJson'],
      'transactionId': signed['transactionId'],
      'timestamp': DateTime.now().toIso8601String(),
      'ticker': ticker,
      'summary': terms
    };
    // Durably save before the first network submission. Recovery never signs a replacement.
    await widget.service.retain(widget.address, receipt);
    if (mounted) setState(() => recovery = receipt);
    await widget.service.resume(widget.address);
    await finish(receipt, preparations: preparations);
  }

  Future<void> finish(Map<String, dynamic> receipt,
      {int preparations = 0}) async {
    if (!mounted) return;
    if ((receipt['summary'] as Map)['stage'] == 'preparation') {
      setState(() {
        recovery = null;
        quote = null;
      });
      await refresh();
      if (!mounted) return;
      if (preparations >= 7)
        throw StateError(
            'Token preparation is complete for this step. Continue with a fresh quote to finish the remaining preparation and sale.');
      await getQuote();
      if (mounted) await swap(preparations: preparations + 1);
      return;
    }
    if (mounted)
      setState(() {
        completed = receipt;
        recovery = null;
        quote = null;
      });
  }

  Widget line(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        SelectableText(value)
      ]));
  String kas(Object? value) => '${KronDexService.display(value, 8)} KAS';
  List<Widget> details(Map q) => [
        if (q['stage'] == 'preparation') ...[
          const Text(
              'Your tokens stay in your wallet. This transaction only prepares the exact sale amount; it does not sell tokens. A separate refreshed sale review follows.'),
          line(
              'Preparation',
              q['operation'] == 'split'
                  ? 'Split your token cell'
                  : 'Merge your token cells'),
          line('Sale amount to prepare',
              '${KronDexService.display(q['tokenAmount'], 0)} $ticker'),
          line('Network fee', kas(q['networkFeeSompi'])),
          line('Change in spendable KAS', kas(q['walletNetSompi'])),
        ] else ...[
          line('Token amount',
              '${KronDexService.display(q['tokenAmount'], 0)} $ticker'),
          line(
              side == 'buy'
                  ? 'Trade including protocol fee'
                  : 'Token sale proceeds (after protocol fee)',
              kas(q['kasSompi'])),
          line(
              side == 'buy'
                  ? 'Protocol fee (included)'
                  : 'Protocol fee (already deducted)',
              kas(q['protocolFeeSompi'])),
          if (side == 'sell' && q['depositRefundSompi'] != null)
            line('Your token-cell deposit returned',
                kas(q['depositRefundSompi'])),
          if (side == 'buy')
            line('Refundable token-cell deposit', kas(q['depositSompi'])),
          if (side == 'buy')
            line('Maximum all-in cost', kas(q['maxSpendSompi'])),
          if (q['minimumReceive'] != null)
            line(
                'Minimum received',
                side == 'buy'
                    ? '${KronDexService.display(q['minimumReceive'], 0)} $ticker'
                    : kas(q['minimumReceive'])),
          if (q['networkFeeSompi'] != null)
            line('Network fee', kas(q['networkFeeSompi'])),
          if (side == 'sell' && q['walletNetSompi'] != null)
            line('Net KAS from this sale (deposit included)',
                kas(q['walletNetSompi'])),
          if (side == 'sell' && q['walletNetSompi'] == null)
            const Text(
                'The exact deposit refund, network fee and net wallet increase are calculated in Review swap. Existing KAS funding/change is not sale income.'),
        ]
      ];
  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !busy,
      child: Scaffold(
          appBar: AppBar(title: Text('$ticker · Kasseal'), actions: [
            IconButton(
                onPressed: busy ? null : refresh,
                icon: const Icon(Icons.refresh))
          ]),
          body: ListView(padding: rocketListPadding(context), children: [
            if (completed != null) ...[
              const Icon(Icons.check_circle_outline, size: 64),
              const Text('Swap confirmed', textAlign: TextAlign.center),
              line('Transaction ID', '${completed!['transactionId']}'),
              OutlinedButton.icon(
                  onPressed: () => Clipboard.setData(
                      ClipboardData(text: '${completed!['transactionId']}')),
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy transaction ID')),
              FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Return to Kasseal DEX'))
            ] else ...[
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(ticker,
                                style:
                                    Theme.of(context).textTheme.headlineSmall),
                            line('Token covenant', id),
                            Text(side == 'buy'
                                ? 'Available to buy: ${kasBalance == null ? 'KAS balance unavailable' : '${KronDexService.display(kasBalance, 8)} KAS'}'
                                : 'Available to sell: ${held == null ? '…' : KronDexService.display(held, 0)} $ticker'),
                            if (side == 'buy')
                              Text(
                                  'Your token balance: ${held == null ? '…' : KronDexService.display(held, 0)} $ticker'),
                            if (widget.token['phase'] == 'bonding' &&
                                widget.token['curve'] is Map)
                              Text(
                                  'Curve: ${KronDexService.display(widget.token['curve']['lotSize'], 0)}-token lots · exact whole-sompi prices'),
                            if (widget.token['phase'] != 'bonding')
                              const Text(
                                  'Constant-product pool · any whole number of tokens')
                          ]))),
              if (recovery != null)
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  (recovery!['summary'] as Map)['stage'] ==
                                          'preparation'
                                      ? 'Token preparation saved'
                                      : 'Signed swap saved',
                                  style:
                                      TextStyle(fontWeight: FontWeight.bold)),
                              const Text(
                                  'Check this payment before starting another trade. Recovery uses exactly the same signed transaction.'),
                              line('Transaction ID',
                                  '${recovery!['transactionId']}'),
                              FilledButton(
                                  onPressed: busy
                                      ? null
                                      : () => run(() async {
                                            final saved = recovery!;
                                            await widget.service
                                                .resume(widget.address);
                                            await finish(saved);
                                          }),
                                  child: Text(
                                      (recovery!['summary'] as Map)['stage'] ==
                                              'preparation'
                                          ? 'Check saved preparation'
                                          : 'Check saved swap'))
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
                      : (s) => setState(() {
                            side = s.first;
                            quote = null;
                            amount.clear();
                            error = '';
                          })),
              const SizedBox(height: 16),
              TextField(
                  controller: amount,
                  enabled: !busy,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() => quote = null),
                  decoration: InputDecoration(
                      labelText: side == 'buy'
                          ? 'KAS trade amount (deposit and network fee added)'
                          : 'Token amount (whole tokens)',
                      suffixText: side == 'buy' ? 'KAS' : ticker)),
              const SizedBox(height: 12),
              OutlinedButton(
                  onPressed: busy ? null : () => run(getQuote),
                  child: Text(
                      quote != null || recovery != null || error.isNotEmpty
                          ? 'Refresh quote'
                          : 'Get live quote')),
              if (quote != null)
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: details(quote!)))),
              if (error.isNotEmpty)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(error,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error))),
              FilledButton(
                  onPressed: busy || quote == null || recovery != null
                      ? null
                      : () => run(swap),
                  child: const Text('Review swap')),
              if (busy)
                const Padding(
                    padding: EdgeInsets.all(18),
                    child: Center(child: CircularProgressIndicator())),
            ]
          ])));
}
