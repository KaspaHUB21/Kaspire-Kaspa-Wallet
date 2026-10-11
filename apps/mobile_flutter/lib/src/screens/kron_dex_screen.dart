import 'package:flutter/material.dart';
import '../services/kron_dex_service.dart';
import '../services/kron_holdings.dart';
import '../services/kaspa_api.dart';
import '../services/native_security.dart';
import '../services/network_settings.dart';
import 'kasparocket_screen.dart' show rocketListPadding;

class DexSelectionScreen extends StatelessWidget {
  const DexSelectionScreen({super.key, required this.address});
  final String address;
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('KCC20 DEX Swaps')),
      body: ListView(padding: rocketListPadding(context), children: [
        Card(
            child: ListTile(
                contentPadding: const EdgeInsets.all(18),
                leading: Image.network('https://kron.technology/icon-512.png',
                    width: 48,
                    height: 48,
                    errorBuilder: (_, e, s) =>
                        const Icon(Icons.swap_horiz, size: 40)),
                title: const Text('Kron DEX'),
                subtitle: const Text('Kaspa Mainnet · DEX & Launchpad'),
                trailing: const Icon(Icons.chevron_right),
                onTap: NetworkSettings.isTestnet
                    ? null
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                            builder: (_) => KronDexScreen(address: address))))),
        const SizedBox(height: 16),
        const Text('More KCC20 DEXes are coming soon.',
            textAlign: TextAlign.center)
      ]));
}

class KronDexScreen extends StatefulWidget {
  const KronDexScreen({super.key, required this.address});
  final String address;
  @override
  State<KronDexScreen> createState() => _KronDexScreenState();
}

class _KronDexScreenState extends State<KronDexScreen> {
  final service = KronDexService(), search = TextEditingController();
  late Future<List<Map<String, dynamic>>> tokens;
  @override
  void initState() {
    super.initState();
    tokens = service.tokens();
    search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Kron DEX'), actions: [
        IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() => tokens = service.tokens()))
      ]),
      body: FutureBuilder<List<Map<String, dynamic>>>(
          future: tokens,
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(child: Text(snap.error.toString()));
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final query = search.text.trim().toLowerCase();
            final rows = snap.data!.where((t) =>
                query.isEmpty ||
                '${t['ticker']} ${t['name']} ${t['covenantId']}'
                    .toLowerCase()
                    .contains(query));
            return ListView(padding: rocketListPadding(context), children: [
              TextField(
                  controller: search,
                  decoration: const InputDecoration(
                      labelText: 'Search ticker, name or covenant ID',
                      prefixIcon: Icon(Icons.search))),
              const SizedBox(height: 16),
              ...rows.map((t) => Card(
                  child: ListTile(
                      leading: Image.network(t['image'],
                          width: 48,
                          height: 48,
                          errorBuilder: (_, e, s) => const Icon(Icons.token)),
                      title: Text('${t['ticker']} · ${t['name']}'),
                      subtitle: Text(
                          '${t['phase'] == 'pool' ? 'DEX' : 'Launchpad'} · Price ${t['priceKas'] ?? '–'} KAS\n${t['covenantId']}'),
                      isThreeLine: true,
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                              builder: (_) => KronTradeScreen(
                                  address: widget.address,
                                  token: t,
                                  service: service))))))
            ]);
          }));
}

class KronTradeScreen extends StatefulWidget {
  const KronTradeScreen(
      {super.key,
      required this.address,
      required this.token,
      required this.service});
  final String address;
  final Map<String, dynamic> token;
  final KronDexService service;
  @override
  State<KronTradeScreen> createState() => _KronTradeScreenState();
}

class _KronTradeScreenState extends State<KronTradeScreen> {
  final amount = TextEditingController(), security = NativeSecurity();
  String side = 'buy', error = '';
  bool busy = false;
  BigInt? kas, held;
  Map<String, dynamic>? quote, completed, recovery;
  int get decimals => (widget.token['decimals'] as num).toInt();
  String get id => widget.token['covenantId'];
  String get ticker => widget.token['ticker'];
  @override
  void initState() {
    super.initState();
    amount.addListener(() => setState(() => quote = null));
    loadBalances();
  }

  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  Future<void> loadBalances() async {
    try {
      final values = await Future.wait<dynamic>([
        KaspaApi().loadBalanceSompi(widget.address),
        KronHoldings(widget.service.client).balances(widget.address),
        widget.service.pending(widget.address)
      ]);
      final rows = values[1] as List;
      final matches = rows.where((r) => r['covenantId'] == id);
      if (mounted) {
        setState(() {
          kas = BigInt.from(values[0] as int);
          held = matches.isEmpty
              ? BigInt.zero
              : BigInt.parse(matches.first['balance'].toString());
          recovery = values[2];
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = readable(e));
    }
  }

  String readable(Object e) => e
      .toString()
      .replaceFirst('Bad state: ', '')
      .replaceFirst('StateError: ', '');
  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = readable(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> getQuote() async {
    final raw =
        KronDexService.parseAmount(amount.text, side == 'buy' ? 8 : decimals);
    if (side == 'sell' && (held == null || raw > held!)) {
      throw StateError(
          'Insufficient $ticker balance. Available: ${KronDexService.display(held, decimals)} $ticker.');
    }
    if (side == 'buy' && (kas == null || raw >= kas!)) {
      throw StateError(
          'Insufficient KAS. Leave room for protocol fees, token deposits and the network fee.');
    }
    final next = await widget.service.quote(id, side, raw.toString());
    if (side == 'buy' &&
        BigInt.parse(next['netKasSompi']) + BigInt.from(50000000) > kas!) {
      throw StateError(
          'Insufficient KAS for the trade, protocol fees and token deposit.');
    }
    if (mounted) setState(() => quote = {...next, 'rawAmount': raw.toString()});
  }

  Future<void> swap() async {
    if (recovery != null) {
      throw StateError('Resume the saved swap before starting another trade.');
    }
    final q = quote;
    if (q == null) throw StateError('Get a live quote first.');
    if (DateTime.now().millisecondsSinceEpoch > (q['quoteExpiresAt'] as num)) {
      throw StateError('Quote expired. Get a fresh quote.');
    }
    final expected =
        BigInt.parse(q[side == 'buy' ? 'tokenAmount' : 'netKasSompi']);
    final minimum = expected * BigInt.from(99) ~/ BigInt.from(100);
    final request = await widget.service
        .plan(widget.address, id, side, q['rawAmount'], minimum.toString());
    await widget.service.verifyInputs(request);
    final review = await security.preparePskt(request);
    final summary = Map<String, dynamic>.from(request['tradeSummary'] as Map);
    final nativeFee = review['feeSompi'];
    final funding = (review['inputs'] as List)
        .whereType<Map>()
        .where((i) => i['selected'] == true)
        .fold<BigInt>(BigInt.zero,
            (s, i) => s + BigInt.parse(i['amountSompi'].toString()));
    final returned = (review['outputs'] as List)
        .whereType<Map>()
        .where((o) => o['returnsToWallet'] == true)
        .fold<BigInt>(BigInt.zero,
            (s, o) => s + BigInt.parse(o['amountSompi'].toString()));
    summary['walletKasChangeSompi'] = (returned - funding).toString();
    summary['networkFeeSompi'] = nativeFee.toString();
    if (!mounted) return;
    final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text('${side == 'buy' ? 'Buy' : 'Sell'} $ticker'),
                content: SingleChildScrollView(
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      ...details(summary),
                      const SizedBox(height: 12),
                      const Text(
                          'Slippage limit: 1%. Partner attribution does not add a fee.'),
                      const SizedBox(height: 12),
                      SelectableText('Token covenant\n$id'),
                      const SizedBox(height: 12),
                      SelectableText('Market covenant\n${summary['marketId']}')
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Authorize & swap'))
                ]));
    if (accepted != true) return;
    await widget.service.verifyInputs(request);
    final signed =
        await security.signPskt(request, review['reviewHash'].toString());
    final receipt = <String, dynamic>{
      'timestamp': DateTime.now().toIso8601String(),
      'signedTxJson': signed['wrpcJson'],
      'transactionId': signed['transactionId'],
      'summary': summary,
      'ticker': ticker,
      'decimals': decimals,
      'tokenId': id
    };
    await widget.service.retain(widget.address, receipt);
    if (mounted) setState(() => recovery = receipt);
    await widget.service.submit(widget.address, receipt);
    if (mounted) {
      setState(() {
        completed = receipt;
        recovery = null;
      });
    }
  }

  List<Widget> details(Map<String, dynamic> q) => [
        line('Token amount',
            '${KronDexService.display(q['tokenAmount'], (q['decimals'] as num?)?.toInt() ?? decimals)} ${q['ticker'] ?? ticker}'),
        line(q['side'] == 'buy' ? 'KAS into swap' : 'Gross KAS returned',
            '${KronDexService.display(q['grossKasSompi'], 8)} KAS'),
        line(q['side'] == 'buy' ? 'Trade + protocol fees' : 'Net KAS returned',
            '${KronDexService.display(q['netKasSompi'], 8)} KAS'),
        line('Creator fee',
            '${KronDexService.display(q['creatorFeeSompi'], 8)} KAS'),
        line('Protocol fee',
            '${KronDexService.display(q['platformFeeSompi'], 8)} KAS'),
        if (q['devFundFeeSompi'] != '0')
          line('Dev fund fee',
              '${KronDexService.display(q['devFundFeeSompi'], 8)} KAS'),
        if (q['lpFeeSompi'] != '0')
          line('LP fee (included)',
              '${KronDexService.display(q['lpFeeSompi'], 8)} KAS'),
        if (q['networkFeeSompi'] != null)
          line('Network fee',
              '${KronDexService.display(q['networkFeeSompi'], 8)} KAS'),
        if (q['walletKasChangeSompi'] != null)
          line('Wallet KAS change',
              '${KronDexService.display(q['walletKasChangeSompi'], 8)} KAS')
      ];
  Widget line(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Text(label)),
        const SizedBox(width: 8),
        Flexible(
            child: Text(value,
                textAlign: TextAlign.right,
                style: const TextStyle(fontWeight: FontWeight.bold)))
      ]));
  @override
  Widget build(BuildContext context) {
    if (completed != null) {
      return Scaffold(
          appBar: AppBar(title: const Text('Swap submitted')),
          body: ListView(padding: rocketListPadding(context), children: [
            const Icon(Icons.check_circle_outline, size: 72),
            const SizedBox(height: 16),
            Text(
                '${completed!['summary']['side'] == 'buy' ? 'Bought' : 'Sold'} ${completed!['ticker']}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall),
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        children: details(Map<String, dynamic>.from(
                            completed!['summary']))))),
            SelectableText('Transaction ID\n${completed!['transactionId']}'),
            const SizedBox(height: 20),
            FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Return to Kron DEX'))
          ]));
    }
    return Scaffold(
        appBar: AppBar(title: Text(ticker)),
        body: ListView(padding: rocketListPadding(context), children: [
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Image.network(widget.token['image'],
                              width: 48,
                              height: 48,
                              errorBuilder: (_, e, s) =>
                                  const Icon(Icons.token)),
                          const SizedBox(width: 12),
                          Expanded(
                              child: Text(widget.token['name'],
                                  style:
                                      Theme.of(context).textTheme.titleLarge))
                        ]),
                        const SizedBox(height: 10),
                        SelectableText('Token covenant\n$id'),
                        const SizedBox(height: 12),
                        Text(widget.token['phase'] == 'pool'
                            ? 'DEX pool'
                            : 'Launchpad bonding curve'),
                        line('Price', '${widget.token['priceKas'] ?? '–'} KAS'),
                        line('24h volume',
                            '${widget.token['volume24hKas'] ?? '–'} KAS'),
                        line('Pool liquidity',
                            '${widget.token['poolKas'] ?? '–'} KAS')
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
                        side = s.single;
                        quote = null;
                        amount.clear();
                      })),
          const SizedBox(height: 16),
          Text(
              'Available: ${side == 'buy' ? KronDexService.display(kas, 8) : KronDexService.display(held, decimals)} ${side == 'buy' ? 'KAS' : ticker}',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
              controller: amount,
              enabled: !busy && recovery == null,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: side == 'buy'
                      ? 'KAS trade amount (fees added)'
                      : 'Token amount',
                  suffixText: side == 'buy' ? 'KAS' : ticker)),
          const SizedBox(height: 12),
          FilledButton(
              onPressed: busy || recovery != null ? null : () => run(getQuote),
              child: const Text('Get live quote')),
          if (quote != null)
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(children: details(quote!)))),
          if (error.isNotEmpty)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(error,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
          if (recovery != null)
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(children: [
                      const Text(
                          'Signed swap saved. Retry the same transaction; do not create a second purchase.'),
                      const SizedBox(height: 8),
                      FilledButton(
                          onPressed: busy
                              ? null
                              : () => run(() async {
                                    await widget.service
                                        .submit(widget.address, recovery!);
                                    if (mounted) {
                                      setState(() {
                                        completed = recovery;
                                        recovery = null;
                                      });
                                    }
                                  }),
                          child: const Text('Resume saved swap'))
                    ]))),
          const SizedBox(height: 12),
          FilledButton.icon(
              onPressed: busy || quote == null || recovery != null
                  ? null
                  : () => run(swap),
              icon: const Icon(Icons.shield_outlined),
              label: Text(busy ? 'Please wait…' : 'Review swap'))
        ]));
  }
}
