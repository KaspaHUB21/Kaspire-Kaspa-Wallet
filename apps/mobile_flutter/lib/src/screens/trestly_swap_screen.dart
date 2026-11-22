import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../services/trestly_service.dart';
import '../services/network_settings.dart';
import '../number_format.dart';
import '../widgets/transaction_fact_row.dart';

class TrestlySwapScreen extends StatefulWidget {
  const TrestlySwapScreen({super.key, required this.address, this.service});
  final String address;
  final TrestlyService? service;
  @override
  State<TrestlySwapScreen> createState() => _TrestlySwapState();
}

class _TrestlySwapState extends State<TrestlySwapScreen> {
  late final service = widget.service ?? TrestlyService(widget.address);
  final amount = TextEditingController();
  String side = 'buy', error = '';
  bool busy = false;
  TrestlyRow? quote, saved, receipt;
  TrestlySellBalance? sellBalance;
  bool balanceLoading = false;
  String balanceError = '';
  int balanceRevision = 0;
  bool get mainnet => NetworkSettings.network.value == KaspaNetwork.mainnet;
  @override
  void initState() {
    super.initState();
    NetworkSettings.network.addListener(changed);
    loadPending();
  }

  void changed() {
    balanceRevision++;
    if (mounted)
      setState(() {
        quote = null;
        sellBalance = null;
        balanceLoading = false;
        balanceError = '';
      });
    if (mainnet && side == 'sell') loadSellBalance();
  }

  Future<void> loadSellBalance() async {
    final revision = ++balanceRevision;
    if (!mounted || !mainnet || side != 'sell') return;
    setState(() {
      balanceLoading = true;
      balanceError = '';
    });
    try {
      final result = await service.sellBalance();
      if (mounted && revision == balanceRevision && mainnet && side == 'sell') {
        setState(() {
          sellBalance = result;
          balanceLoading = false;
        });
      }
    } catch (e) {
      if (mounted && revision == balanceRevision && mainnet && side == 'sell') {
        setState(() {
          balanceError = _message(e);
          balanceLoading = false;
        });
      }
    }
  }

  Future<void> loadPending() async {
    try {
      final p = await service.pending();
      if (mounted) setState(() => saved = p);
    } catch (e) {
      if (mounted) setState(() => error = _message(e));
    }
  }

  @override
  void dispose() {
    NetworkSettings.network.removeListener(changed);
    balanceRevision++;
    amount.dispose();
    super.dispose();
  }

  String units(Object? raw, int decimals) {
    final n = trestlyInt(raw);
    final scale = BigInt.from(10).pow(decimals);
    final v = BigInt.from(n),
        f = (v % scale)
            .toString()
            .padLeft(decimals, '0')
            .replaceFirst(RegExp(r'0+$'), '');
    return formatEnglishDecimal('${v ~/ scale}${f.isEmpty ? '' : '.$f'}');
  }

  String _message(Object error) => error is PlatformException
      ? error.message ??
          'The native swap could not be prepared. Please refresh.'
      : error is StateError
          ? error.message.toString()
          : error.toString();

  Future<void> action(Future<void> Function() run) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await run();
    } catch (e) {
      if (mounted) setState(() => error = _message(e));
    } finally {
      await loadPending();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> getQuote() => action(() async {
        final parsed = parseTrestlyAmount(amount.text, side == 'buy' ? 8 : 6);
        if (parsed <= 0) throw StateError('Enter an amount above zero.');
        final result = await service.quote(side, amount.text);
        if (mounted) setState(() => quote = result);
      });
  Future<void> reviewSwap() => action(() async {
        final q = quote!;
        final r = trestlyMap(q['review']);
        final approved = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    title: const Text('Review KAS / kUSDT swap'),
                    content: SingleChildScrollView(
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text(
                              'You pay ${units(r['amountIn'], side == 'buy' ? 8 : 6)} ${side == 'buy' ? 'KAS' : 'kUSDT'}',
                              style: const TextStyle(
                                  fontSize: 19, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 12),
                          Text(
                              'You receive ${units(r['amountOut'], side == 'buy' ? 6 : 8)} ${side == 'buy' ? 'kUSDT' : 'KAS'}',
                              style: const TextStyle(
                                  fontSize: 19, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 12),
                          Text(
                              'Network fee: up to ${formatSompi(trestlyInt(r['maxFeeSompi']))} KAS. The actual fee may be lower.'),
                          if (side == 'buy')
                            const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Text(
                                    'An additional 1.5 KAS remains in your new kUSDT UTXO. This is recoverable storage, not a fee.')),
                          const SizedBox(height: 12),
                          const Text(
                              'Pool fee 0.50% is already included in this quote. The exact pool state and receive amount are signed. A changed pool requires a new quote and approval.'),
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel')),
                      FilledButton.icon(
                          onPressed: () => Navigator.pop(context, true),
                          icon: const Icon(Icons.shield_outlined),
                          label: const Text('Confirm swap'))
                    ]));
        if (approved != true) return;
        final result = await service.execute(q);
        if (mounted)
          setState(() {
            receipt = result;
            quote = null;
          });
        if (mounted && side == 'sell') await loadSellBalance();
      });
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('KAS / kUSDT'), actions: [
        IconButton(
            tooltip: 'Refresh',
            onPressed: busy
                ? null
                : () => action(() async {
                      setState(() => quote = null);
                      await loadPending();
                      if (side == 'sell') await loadSellBalance();
                    }),
            icon: const Icon(Icons.refresh))
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
            child: Padding(
                padding: const EdgeInsets.all(18),
                child: Row(children: [
                  SvgPicture.asset('assets/browser/trestly.svg',
                      width: 44, height: 44),
                  const SizedBox(width: 14),
                  const Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text('KAS ↔ kUSDT',
                            style: TextStyle(
                                fontSize: 23, fontWeight: FontWeight.w800)),
                        Text('Trestly KasPool · Kaspa Layer 1'),
                        Text('Native swap · no dApp connection')
                      ]))
                ]))),
        if (!mainnet)
          const Card(
              child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Switch to Kaspa Mainnet to use this pool.'))),
        if (saved != null)
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Saved swap · check status',
                            style: TextStyle(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 8),
                        const Text(
                            'Keep the same signed transaction until its result is confirmed. Do not create another swap.'),
                        SelectableText(saved!['transactionId'].toString()),
                        FilledButton(
                            onPressed: busy || !mainnet
                                ? null
                                : () => action(() async {
                                      final r = await service.resume();
                                      if (mounted) setState(() => receipt = r);
                                      if (mounted && side == 'sell')
                                        await loadSellBalance();
                                    }),
                            child: const Text('Check / resend saved swap'))
                      ]))),
        if (saved == null) ...[
          const SizedBox(height: 12),
          SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'buy', label: Text('Buy kUSDT')),
                ButtonSegment(value: 'sell', label: Text('Sell kUSDT'))
              ],
              selected: {
                side
              },
              onSelectionChanged: busy
                  ? null
                  : (v) {
                      balanceRevision++;
                      setState(() {
                        side = v.single;
                        quote = null;
                        error = '';
                        receipt = null;
                        amount.clear();
                        balanceLoading = false;
                        balanceError = '';
                      });
                      if (side == 'sell') loadSellBalance();
                    }),
          const SizedBox(height: 18),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
                child: TextField(
                    controller: amount,
                    enabled: !busy && mainnet,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                        labelText:
                            side == 'buy' ? 'You pay KAS' : 'You pay kUSDT',
                        suffixText: side == 'buy' ? 'KAS' : 'kUSDT',
                        border: const OutlineInputBorder()),
                    onChanged: (_) => setState(() => quote = null))),
            if (side == 'sell') ...[
              const SizedBox(width: 12),
              SizedBox(
                  height: 56,
                  child: OutlinedButton(
                      onPressed: busy ||
                              !mainnet ||
                              balanceLoading ||
                              balanceError.isNotEmpty ||
                              sellBalance?.complete != true ||
                              sellBalance!.maximumRaw == BigInt.zero
                          ? null
                          : () => setState(() {
                                amount.text = sellBalance!.maximumAmount;
                                quote = null;
                              }),
                      child: const Text('MAX'))),
            ]
          ]),
          if (side == 'sell') ...[
            const SizedBox(height: 10),
            Row(children: [
              Text(
                  sellBalance?.complete == false
                      ? 'Verified available:'
                      : 'Available:',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              Expanded(
                  child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                              balanceLoading
                                  ? 'Loading…'
                                  : balanceError.isNotEmpty ||
                                          sellBalance == null ||
                                          !sellBalance!.complete &&
                                              sellBalance!.cells.isEmpty
                                      ? 'Unavailable'
                                      : '${units(sellBalance!.verifiedRaw, 6)} kUSDT',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700)))))
            ]),
            if (balanceError.isNotEmpty) ...[
              Text(balanceError,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              if (sellBalance != null && sellBalance!.cells.isNotEmpty)
                Text(
                    'Last verified: ${units(sellBalance!.verifiedRaw, 6)} kUSDT'),
              TextButton(
                  onPressed: balanceLoading || busy ? null : loadSellBalance,
                  child: const Text('Retry balance')),
            ],
            if (!balanceLoading &&
                balanceError.isEmpty &&
                sellBalance?.complete == false)
              const Text(
                  'Balance is incomplete. Some token coins could not be verified. Refresh before using MAX.'),
            if (!balanceLoading &&
                sellBalance != null &&
                sellBalance!.cells.length > 1)
              Text(
                  'Balance is split across ${sellBalance!.cells.length} token UTXOs. MAX per swap: ${units(sellBalance!.maximumRaw, 6)} kUSDT. This swap currently spends one token UTXO.'),
          ],
          const SizedBox(height: 14),
          OutlinedButton.icon(
              onPressed: busy || !mainnet ? null : getQuote,
              icon: const Icon(Icons.refresh),
              label: Text(quote == null ? 'Get live quote' : 'Refresh quote')),
          if (quote != null)
            Builder(builder: (context) {
              final r = trestlyMap(quote!['review']);
              return Card(
                  child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(children: [
                        TransactionFactRow('You pay',
                            '${units(r['amountIn'], side == 'buy' ? 8 : 6)} ${side == 'buy' ? 'KAS' : 'kUSDT'}'),
                        TransactionFactRow('You receive',
                            '${units(r['amountOut'], side == 'buy' ? 6 : 8)} ${side == 'buy' ? 'kUSDT' : 'KAS'}'),
                        const TransactionFactRow(
                            'Pool fee', '0.50% · included'),
                        TransactionFactRow('Network fee',
                            'Up to ${formatSompi(trestlyInt(r['maxFeeSompi']))} KAS'),
                        if (side == 'buy')
                          const TransactionFactRow(
                              'Your token storage', '1.5 KAS · not a fee'),
                        const SizedBox(height: 12),
                        SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                                onPressed: busy || !mainnet ? null : reviewSwap,
                                icon: const Icon(Icons.shield_outlined),
                                label: const Text('Review swap'))),
                      ])));
            }),
        ],
        if (busy)
          const Padding(
              padding: EdgeInsets.all(18),
              child: Column(children: [
                LinearProgressIndicator(),
                SizedBox(height: 8),
                Text('Checking pool and wallet coins on the Kaspa node…')
              ])),
        if (error.isNotEmpty)
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(error,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)))),
        if (receipt != null)
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Swap confirmed',
                            style: TextStyle(
                                fontSize: 22, fontWeight: FontWeight.w800)),
                        Text(
                            'Network fee ${formatSompi(trestlyInt(receipt!['feeSompi']))} KAS'),
                        SelectableText(receipt!['transactionId'].toString())
                      ]))),
        const SizedBox(height: 18),
        const Text(
            'kUSDT is backed through Trestly’s USDT bridge. This swap stays on Kaspa L1; it does not bridge to Ethereum or BNB Chain.',
            style: TextStyle(fontSize: 12)),
        const SizedBox(height: 24),
      ]));
}
