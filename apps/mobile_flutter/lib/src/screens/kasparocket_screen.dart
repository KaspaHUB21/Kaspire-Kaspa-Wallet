import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/kasparocket_service.dart';
import '../services/kaspa_api.dart';
import '../services/native_security.dart';

class KaspaRocketScreen extends StatefulWidget {
  const KaspaRocketScreen(
      {super.key, required this.address, this.initialTokenId});
  final String address;
  final String? initialTokenId;
  @override
  State<KaspaRocketScreen> createState() => _KaspaRocketScreenState();
}

class _KaspaRocketScreenState extends State<KaspaRocketScreen>
    with SingleTickerProviderStateMixin {
  final service = KaspaRocketService(), search = TextEditingController();
  late final TabController tabs;
  late Future<List<KaspaRocketToken>> tokens;
  late Future<Map<String, Object?>> activity;
  bool openedInitialToken = false;
  @override
  void initState() {
    super.initState();
    tabs = TabController(length: 2, vsync: this);
    search.addListener(() => setState(() {}));
    reload();
  }

  void reload() {
    setState(() {
      tokens = service.tokens();
      activity = service.activity(widget.address);
    });
  }

  @override
  void dispose() {
    tabs.dispose();
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(
          title: const Text('K-Agora · TN10'),
          actions: [
            IconButton(
                onPressed: reload, icon: const Icon(Icons.refresh_rounded))
          ],
          bottom: TabBar(
              controller: tabs,
              tabs: const [Tab(text: 'DEX SWAPS'), Tab(text: 'MY ACTIVITY')])),
      body: TabBarView(controller: tabs, children: [browse(), history()]));
  Widget browse() => FutureBuilder<List<KaspaRocketToken>>(
      future: tokens,
      builder: (context, snap) {
        if (!snap.hasData && !snap.hasError) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) return error(snap.error);
        if (!openedInitialToken && widget.initialTokenId != null) {
          openedInitialToken = true;
          final initial = snap.data!.where((token) =>
              token.tokenId.toLowerCase() ==
              widget.initialTokenId!.toLowerCase());
          if (initial.isNotEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => KaspaRocketTradeScreen(
                      address: widget.address,
                      token: initial.first,
                      service: service)));
            });
          }
        }
        final q = search.text.toLowerCase(),
            items = snap.data!
                .where((t) =>
                    q.isEmpty ||
                    t.ticker.toLowerCase().contains(q) ||
                    t.name.toLowerCase().contains(q) ||
                    t.tokenId.contains(q))
                .toList();
        return RefreshIndicator(
            onRefresh: () async => reload(),
            child: ListView(padding: rocketListPadding(context), children: [
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(children: [
                              Icon(Icons.rocket_launch_rounded),
                              SizedBox(width: 10),
                              Text('KaspaRocket',
                                  style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w900))
                            ]),
                            const SizedBox(height: 6),
                            const Text(
                                'Internal TN10 integration. Routes market '
                                'swaps across the bonding curve, AMM and order book.'),
                            Text('${items.length} covenant tokens')
                          ]))),
              const SizedBox(height: 10),
              TextField(
                  controller: search,
                  decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search_rounded),
                      hintText: 'Ticker, name or covenant ID')),
              const SizedBox(height: 10),
              ...items.map((t) => Card(
                  child: ListTile(
                      contentPadding: const EdgeInsets.all(12),
                      leading: image(t.image, 50),
                      title: Text(t.ticker,
                          style: const TextStyle(fontWeight: FontWeight.w900)),
                      subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t.name),
                            Text(t.tokenId,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontFamily: 'monospace', fontSize: 10)),
                            Text(
                                'Price ${kas(t.priceKas)} · Pool ${kas(t.poolValueKas)} · ${(t.phase ?? 'unknown').toUpperCase()}')
                          ]),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                              builder: (_) => KaspaRocketTradeScreen(
                                  address: widget.address,
                                  token: t,
                                  service: service)))))),
              const SizedBox(height: 30)
            ]));
      });
  Widget history() => FutureBuilder<Map<String, Object?>>(
      future: activity,
      builder: (context, snap) {
        if (!snap.hasData && !snap.hasError) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) return error(snap.error);
        final root = snap.data!,
            raw = root['activity'] ?? root['items'] ?? root['data'] ?? const [];
        final items = raw is List ? raw.whereType<Map>().toList() : <Map>[];
        if (items.isEmpty) {
          return const Center(child: Text('No KaspaRocket swaps yet.'));
        }
        return ListView.builder(
            padding: rocketListPadding(context),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final item = items[i],
                  ticker = (item['ticker'] ?? item['token_ticker'] ?? 'TOKEN')
                      .toString()
                      .toUpperCase(),
                  id = (item['token_id'] ?? item['kcc20_covenant_id'] ?? '')
                      .toString();
              return Card(
                  child: ExpansionTile(
                      title: Text(
                          '${(item['side'] ?? item['type'] ?? 'swap').toString().toUpperCase()} $ticker'),
                      subtitle: Text(id,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      children: [
                    Padding(
                        padding: const EdgeInsets.all(12),
                        child: SelectableText(
                            const JsonEncoder.withIndent('  ').convert(item)))
                  ]));
            });
      });
  Widget error(Object? value) => Center(
      child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(value.toString()),
            const SizedBox(height: 12),
            FilledButton(onPressed: reload, child: const Text('Try again'))
          ])));
}

class KaspaRocketTradeScreen extends StatefulWidget {
  const KaspaRocketTradeScreen(
      {super.key,
      required this.address,
      required this.token,
      required this.service});
  final String address;
  final KaspaRocketToken token;
  final KaspaRocketService service;
  @override
  State<KaspaRocketTradeScreen> createState() => _KaspaRocketTradeScreenState();
}

class _KaspaRocketTradeScreenState extends State<KaspaRocketTradeScreen> {
  final amount = TextEditingController(), security = NativeSecurity();
  final kaspaApi = KaspaApi();
  String side = 'buy';
  String? pool, errorText;
  Map<String, Object?>? quote, holding;
  int? kasBalanceSompi;
  Map<String, Object?>? completedSwap;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final data = await Future.wait([
        widget.service.poolCovenant(widget.token.tokenId),
        widget.service.holding(widget.address, widget.token.tokenId),
        kaspaApi.loadBalanceSompi(widget.address),
      ]);
      if (mounted) {
        setState(() {
          pool = data[0] as String;
          holding = (data[1] as Map).cast();
          kasBalanceSompi = data[2] as int;
        });
      }
    } catch (e) {
      if (mounted) setState(() => errorText = e.toString());
    }
  }

  String raw() => KaspaRocketService.rawFromDisplay(
      amount.text, side == 'buy' ? 8 : KaspaRocketService.tokenDecimals);

  BigInt get holdingRaw => KaspaRocketService.holdingRaw(holding);
  String get holdingDisplay => KaspaRocketService.displayRaw(
      holdingRaw, KaspaRocketService.tokenDecimals);

  void validateAvailable(String rawAmount, {Map<String, Object?>? liveQuote}) {
    final requested = BigInt.parse(rawAmount);
    if (side == 'sell' && requested > holdingRaw) {
      throw StateError(
          'Insufficient ${widget.token.ticker}. Available: $holdingDisplay ${widget.token.ticker}.');
    }
    if (side == 'buy' && kasBalanceSompi != null) {
      var required = requested;
      final quoted =
          BigInt.tryParse(liveQuote?['net_kas_sompi']?.toString() ?? '');
      if (quoted != null && quoted.abs() > required) required = quoted.abs();
      if (required > BigInt.from(kasBalanceSompi!)) {
        throw StateError(
            'Insufficient test KAS. Available: ${sompi(kasBalanceSompi)}. Reduce the trade amount to leave room for DEX and network fees.');
      }
    }
  }

  String readableError(Object error) =>
      error.toString().replaceFirst(RegExp(r'^(Bad state: |Exception: )'), '');
  Future<void> getQuote() async {
    setState(() {
      busy = true;
      errorText = null;
    });
    try {
      final rawAmount = raw();
      validateAvailable(rawAmount);
      final result = await widget.service.quote(
          tokenId: widget.token.tokenId,
          poolId: pool!,
          side: side,
          rawAmount: rawAmount);
      validateAvailable(rawAmount, liveQuote: result);
      if (result['uneconomic'] == true) {
        throw StateError(
            'This sell is uneconomic after fees. Increase the amount.');
      }
      if (mounted) setState(() => quote = result);
    } catch (e) {
      if (mounted) setState(() => errorText = readableError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> swap() async {
    setState(() {
      busy = true;
      errorText = null;
    });
    try {
      final rawAmount = raw(),
          fresh = await widget.service.quote(
              tokenId: widget.token.tokenId,
              poolId: pool!,
              side: side,
              rawAmount: rawAmount);
      validateAvailable(rawAmount, liveQuote: fresh);
      if (fresh['uneconomic'] == true) {
        throw StateError('Uneconomic sell; nothing was signed.');
      }
      final plan = await widget.service.plan(
          address: widget.address,
          tokenId: widget.token.tokenId,
          poolId: pool!,
          side: side,
          rawAmount: rawAmount);
      final summary = (plan['summary'] as Map).cast<String, Object?>(),
          planned = (plan['transactions'] as List)
              .whereType<Map>()
              .map((v) => v.cast<String, Object?>())
              .toList();
      final requests = <Map<String, Object?>>[],
          reviews = <Map<String, Object?>>[];
      for (final tx in planned) {
        final request = widget.service.signingRequest(
            address: widget.address,
            token: widget.token,
            poolId: pool!,
            side: side,
            summary: summary,
            planned: tx);
        requests.add(request);
        reviews.add(await security.preparePskt(request));
      }
      if (!mounted) return;
      final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                  title: Text('${side.toUpperCase()} ${widget.token.ticker}'),
                  content: SingleChildScrollView(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        line('Token covenant', widget.token.tokenId),
                        line('Pool covenant', pool),
                        line('Quoted token amount',
                            '${KaspaRocketService.amountTokensDisplay(summary)} ${widget.token.ticker}'),
                        line('Quoted KAS flow', sompi(summary['kasFlowSompi'])),
                        line('Quoted treasury fee',
                            sompi(summary['platformFeeSompi'])),
                        line('Quoted partner fee',
                            sompi(summary['partnerFeeSompi'])),
                        line('Total DEX fee',
                            sompi(summary['totalPlatformFeeSompi'])),
                        line('Transactions', planned.length),
                        ...reviews.asMap().entries.expand((entry) => [
                              line('Transaction ${entry.key + 1}',
                                  entry.value['transactionId']),
                              line('Wallet input',
                                  sompi(entry.value['walletInputSompi'])),
                              line('Wallet output',
                                  sompi(entry.value['walletOutputSompi'])),
                              line('Wallet net',
                                  sompiSigned(entry.value['walletNetSompi'])),
                              line('Network fee',
                                  sompi(entry.value['feeSompi'])),
                            ]),
                        const Text(
                            'TN10 only. Verify both covenant IDs; tickers are not unique.',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        ExpansionTile(
                            title: const Text('Raw plan JSON'),
                            children: [
                              SelectableText(const JsonEncoder.withIndent('  ')
                                  .convert(plan))
                            ])
                      ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Authorize & swap'))
                  ]));
      if (ok != true) return;
      final signed = <Map<String, Object?>>[];
      for (var i = 0; i < planned.length; i++) {
        final result = await security.signPskt(
            requests[i], reviews[i]['reviewHash'].toString());
        signed.add(widget.service.mergeSignedTransaction(
            (planned[i]['tx'] as Map).cast<String, Object?>(),
            result['signedTxJson'].toString()));
      }
      final order = plan['order_row'] is Map
          ? (plan['order_row'] as Map).cast<String, Object?>()
          : null;
      final receipts = <Map<String, Object?>>[];
      for (var i = 0; i < signed.length; i++) {
        receipts.add(await widget.service.submit(signed[i],
            orderRow: i == signed.length - 1 ? order : null));
      }
      if (!mounted) return;
      setState(() {
        completedSwap = {
          'side': side,
          'token': widget.token.ticker,
          'tokenCovenant': widget.token.tokenId,
          'poolCovenant': pool,
          'summary': summary,
          'networkFeesSompi': reviews
              .map((review) => review['feeSompi']?.toString() ?? '0')
              .toList(),
          'receipts': receipts,
          'plan': plan,
        };
      });
    } catch (e) {
      if (mounted) setState(() => errorText = readableError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final receipt = completedSwap;
    if (receipt != null) {
      final summary = (receipt['summary'] as Map).cast<String, Object?>();
      final receipts = (receipt['receipts'] as List).whereType<Map>().toList();
      final fees = (receipt['networkFeesSompi'] as List)
          .map((value) => BigInt.tryParse(value.toString()) ?? BigInt.zero)
          .fold<BigInt>(BigInt.zero, (total, value) => total + value);
      return Scaffold(
          appBar: AppBar(title: const Text('Swap complete')),
          body: ListView(padding: rocketListPadding(context), children: [
            const Icon(Icons.check_circle_rounded,
                size: 72, color: Colors.greenAccent),
            const SizedBox(height: 12),
            Text(
                '${receipt['side'].toString().toUpperCase()} ${widget.token.ticker}',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 16),
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(children: [
                      line('Status', 'Submitted successfully'),
                      line('Token amount',
                          '${KaspaRocketService.amountTokensDisplay(summary)} ${widget.token.ticker}'),
                      line('KAS flow', sompi(summary['kasFlowSompi'])),
                      line('Treasury fee', sompi(summary['platformFeeSompi'])),
                      line('Partner fee', sompi(summary['partnerFeeSompi'])),
                      line('Network fees', sompi(fees)),
                      line('Transactions', receipts.length),
                    ]))),
            idCard('Token covenant', widget.token.tokenId),
            idCard('Pool covenant', pool ?? ''),
            ExpansionTile(title: const Text('Transaction receipts'), children: [
              Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                      const JsonEncoder.withIndent('  ').convert(receipts)))
            ]),
            ExpansionTile(title: const Text('Raw swap JSON'), children: [
              Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                      const JsonEncoder.withIndent('  ').convert(receipt)))
            ]),
            const SizedBox(height: 16),
            FilledButton.icon(
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(Icons.arrow_back_rounded),
                label: const Text('Back to DEX swaps')),
            const SizedBox(height: 24),
          ]));
    }
    return Scaffold(
        appBar: AppBar(title: Text(widget.token.ticker)),
        body: ListView(padding: rocketListPadding(context), children: [
          Center(child: image(widget.token.image, 96)),
          const SizedBox(height: 10),
          Text(widget.token.ticker,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w900)),
          Text(widget.token.name, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          idCard('Token covenant', widget.token.tokenId),
          idCard('Pool covenant', pool ?? 'Loading…'),
          Wrap(spacing: 6, children: [
            Chip(label: Text('Price ${kas(widget.token.priceKas)}')),
            Chip(label: Text('24h ${kas(widget.token.volume24hKas)}')),
            Chip(label: Text('Pool ${kas(widget.token.poolValueKas)}')),
          ]),
          SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'buy', label: Text('Buy')),
                ButtonSegment(value: 'sell', label: Text('Sell'))
              ],
              selected: {
                side
              },
              onSelectionChanged: (v) => setState(() {
                    side = v.first;
                    quote = null;
                    amount.clear();
                  })),
          const SizedBox(height: 10),
          Text(
              side == 'buy'
                  ? 'Available: ${kasBalanceSompi == null ? '…' : sompi(kasBalanceSompi)}'
                  : 'Available: $holdingDisplay ${widget.token.ticker}',
              style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          TextField(
              controller: amount,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: side == 'buy'
                      ? 'KAS trade amount (DEX fees added)'
                      : 'Token amount',
                  suffixText: side == 'buy' ? 'KAS' : widget.token.ticker)),
          const SizedBox(height: 10),
          OutlinedButton(
              onPressed: busy || pool == null ? null : getQuote,
              child: const Text('Get live quote')),
          if (quote != null)
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(children: [
                      line('Token amount',
                          '${KaspaRocketService.amountTokensDisplay(quote!)} ${widget.token.ticker}'),
                      line(
                          side == 'buy'
                              ? 'KAS into swap'
                              : 'Gross KAS returned',
                          sompiMagnitude(quote!['kas_flow_sompi'])),
                      line(
                          side == 'buy'
                              ? 'Total KAS spent'
                              : 'Net KAS received',
                          sompiMagnitude(quote!['net_kas_sompi'])),
                      line('Treasury fee', sompi(quote!['platform_fee_sompi'])),
                      line('Partner fee', sompi(quote!['partner_fee_sompi'])),
                      line('Spot before', quote!['spot_before_sompi']),
                      line('Spot after', quote!['spot_after_sompi'])
                    ]))),
          if (errorText != null)
            Padding(
                padding: const EdgeInsets.all(8),
                child: Text(errorText!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
          FilledButton.icon(
              onPressed: busy || pool == null ? null : swap,
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.shield_rounded),
              label: const Text('Review swap')),
          const SizedBox(height: 24)
        ]));
  }
}

EdgeInsets rocketListPadding(BuildContext context) =>
    EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.paddingOf(context).bottom + 40);

Widget image(String url, double size) => ClipRRect(
    borderRadius: BorderRadius.circular(14),
    child: url.isEmpty
        ? Container(
            width: size,
            height: size,
            color: Colors.white10,
            child: const Icon(Icons.token))
        : Image.network(url,
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
                width: size,
                height: size,
                color: Colors.white10,
                child: const Icon(Icons.token))));
Widget line(String name, Object? value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: Text(name)),
      Flexible(
          child: SelectableText(value?.toString() ?? '—',
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.bold)))
    ]));
Widget idCard(String name, String value) => Card(
    child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
          SelectableText(value, style: const TextStyle(fontFamily: 'monospace'))
        ])));
String kas(double? value) => value == null
    ? '—'
    : '${value.toStringAsFixed(value.abs() < 1 ? 8 : 2)} KAS';
String sompi(Object? value) {
  final raw = BigInt.tryParse(value?.toString() ?? '');
  if (raw == null) return '—';
  final base = BigInt.from(100000000), whole = raw ~/ base;
  final fraction =
      (raw % base).toString().padLeft(8, '0').replaceFirst(RegExp(r'0+$'), '');
  return fraction.isEmpty ? '$whole KAS' : '$whole.$fraction KAS';
}

String sompiSigned(Object? value) {
  final raw = BigInt.tryParse(value?.toString() ?? '');
  if (raw == null) return '—';
  return '${raw.isNegative ? '-' : ''}${sompi(raw.abs())}';
}

String sompiMagnitude(Object? value) {
  final raw = BigInt.tryParse(value?.toString() ?? '');
  if (raw == null) return '—';
  return sompi(raw.abs());
}
