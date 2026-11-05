import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../number_format.dart';
import '../services/kforge_service.dart';
import '../services/kforge_trading.dart';
import '../widgets/kforge_image.dart';
import 'kforge_result_screen.dart';
import 'kasparocket_screen.dart' show rocketListPadding;

String _kas(Object? raw) =>
    '${formatRawTokenAmount(BigInt.parse('$raw'), 8)} KAS';
String _tokens(Object? raw) => formatRawTokenAmount(BigInt.parse('$raw'), 0);

class KForgeTradeScreen extends StatefulWidget {
  const KForgeTradeScreen(
      {super.key,
      required this.address,
      required this.token,
      required this.balance,
      this.trading});
  final String address, balance;
  final KForgeToken token;
  final KForgeTrading? trading;
  @override
  State<KForgeTradeScreen> createState() => _KForgeTradeScreenState();
}

class _KForgeTradeScreenState extends State<KForgeTradeScreen> {
  late final trading = widget.trading ?? KForgeTrading();
  final amount = TextEditingController();
  String side = 'buy';
  String? error;
  bool busy = false;
  int generation = 0;
  Map<String, dynamic>? plan;
  late Future<Map<String, dynamic>?> pending;
  late String balance = widget.balance;
  bool balanceUnavailable = false;
  @override
  void initState() {
    super.initState();
    pending = trading.pending(widget.address);
    pending.ignore();
    // Reopening only checks acceptance. It NEVER calls resume/submit/broadcast.
    // Sending saved bytes requires the explicit recovery button below.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final saved = await pending;
        if (saved != null && await trading.accepted('${saved['id']}')) {
          saved['state'] = 'confirmed';
          await trading.retain(widget.address, saved);
          if (mounted) showConfirmed(saved);
        }
      } catch (_) {/* Unavailable does not mean failed or zero. */}
    });
  }

  @override
  void dispose() {
    generation++;
    amount.dispose();
    super.dispose();
  }

  void invalidate() {
    generation++;
    plan = null;
    error = null;
  }

  void showConfirmed(Map<String, dynamic> receipt) {
    if (!mounted || receipt['state'] != 'confirmed') return;
    // Replace the trade route so Return goes straight back to the DEX, not to
    // a stale amount field or a second payment review.
    unawaited(Navigator.of(context).pushReplacement<void, void>(
        MaterialPageRoute<void>(
            builder: (_) => KForgeResultScreen(receipt: receipt))));
  }

  Future<void> refreshBalance() async {
    try {
      final rows =
          await KForgeService(client: trading.client, mainnet: trading.mainnet)
              .walletAssets(widget.address);
      final current =
          rows.where((a) => a.covenantId == widget.token.id).firstOrNull;
      if (mounted)
        setState(() {
          balance = current?.rawBalance ?? '0';
          balanceUnavailable = false;
        });
    } catch (_) {
      if (mounted) setState(() => balanceUnavailable = true);
    }
  }

  Future<void> action(Future<void> Function() run) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await trading.exclusive(widget.address, run);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted)
        setState(() {
          busy = false;
          pending = trading.pending(widget.address);
          pending.ignore();
        });
    }
  }

  BigInt parseAmount() {
    final text = amount.text.trim();
    final kas = side == 'buy';
    if (!RegExp(kas ? r'^[0-9]+(?:\.[0-9]{1,8})?$' : r'^[0-9]+$')
        .hasMatch(text))
      throw StateError(kas
          ? 'Enter KAS with up to 8 decimals.'
          : 'Enter a whole token amount.');
    if (!kas) return BigInt.parse(text);
    final parts = text.split('.');
    return BigInt.parse(parts[0]) * BigInt.from(100000000) +
        BigInt.parse((parts.length == 2 ? parts[1] : '').padRight(8, '0'));
  }

  Future<void> quote() => action(() async {
        final current = ++generation;
        setState(() => plan = null);
        final result = await trading.quote(
            widget.address, widget.token, side, parseAmount());
        if (mounted && current == generation) setState(() => plan = result);
      });
  Future<void> resume(Map<String, dynamic> r) => action(() async {
        final result = await trading.resume(widget.address, r);
        if (mounted && result['state'] != 'pending') {
          setState(() => plan = null);
          if (result['state'] == 'confirmed') {
            showConfirmed(result);
          } else {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text(
                    'The previous swap cannot execute. Refresh quote for a new trade.')));
          }
        }
      });
  Future<void> review() => action(() async {
        final q = plan;
        if (q == null) return;
        if (await trading.pending(widget.address) != null)
          throw StateError('Check the saved swap before continuing.');
        final verified =
            ((q['review'] as Map)['tradeSummary'] as Map)['verified'] as Map;
        if (!mounted) return;
        final approve = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
                    title: const Text('Review KForge swap'),
                    content: SingleChildScrollView(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                          Text(
                              '${side == 'buy' ? 'Buy' : 'Sell'} ${_tokens(verified['tokens'])} ${widget.token.symbol}'),
                          if (side == 'buy' &&
                              verified['buyBudgetSompi'] != null) ...[
                            Text(
                                'KAS trade amount entered: ${_kas(verified['buyBudgetSompi'])}'),
                            Text(
                                'KAS used for the trade: ${_kas(verified['marketKas'])}'),
                            if (BigInt.parse(
                                    '${verified['unspentBudgetSompi']}') >
                                BigInt.zero)
                              Text(
                                  'Not used for tokens (lot rounding): ${_kas(verified['unspentBudgetSompi'])}'),
                            const Text(
                                'Network fees and any new token-cell reserves are added to the trade amount used. The total wallet payment is shown below.'),
                          ],
                          Text(
                              'Wallet ${side == 'buy' ? 'pays' : 'receives'}: ${_kas(verified['walletNet'])}'),
                          Text(
                              'Market ${side == 'buy' ? 'cost' : 'payout'}: ${_kas(verified['marketKas'])}'),
                          Text('Network fee: ${_kas(verified['networkFee'])}'),
                          Text(
                              'Token-cell reserve ${side == 'buy' ? 'added' : 'released'}: ${_kas(verified['cellReserveChange'])}'),
                          const SizedBox(height: 12),
                          Text('${trading.service.label} · Token covenant ID'),
                          SelectableText(widget.token.id),
                          const SizedBox(height: 12),
                          const Text(
                              'The shared Rust core independently rebuilds the contracts and executes every signed input locally before submission. These third-party contracts have not been independently audited.')
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Approve swap'))
                    ]));
        if (approve != true || !mounted) return;
        if (!await trading.security
                .authenticate(context, 'Approve KForge swap') ||
            !mounted) return;
        final receipt = await trading.sign(widget.address, q);
        if (mounted) setState(() => plan = null);
        final result = await trading.resume(widget.address, receipt);
        if (mounted && result['state'] == 'confirmed') {
          showConfirmed(result);
        }
      });
  @override
  Widget build(BuildContext context) {
    final v = plan == null
        ? null
        : (((plan!['review'] as Map)['tradeSummary'] as Map)['verified']
            as Map);
    return Scaffold(
        appBar:
            AppBar(title: Text('${widget.token.symbol} · KForge'), actions: [
          IconButton(
              onPressed: busy
                  ? null
                  : () {
                      setState(() {
                        invalidate();
                        pending = trading.pending(widget.address);
                        pending.ignore();
                      });
                      unawaited(refreshBalance());
                    },
              tooltip: 'Reload',
              icon: const Icon(Icons.refresh))
        ]),
        body: ListView(
            key: const Key('kforge-trade-list'),
            padding: rocketListPadding(context),
            children: [
              FutureBuilder<Map<String, dynamic>?>(
                  future: pending,
                  builder: (context, s) {
                    if (s.hasError)
                      return Card(
                          child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text('${s.error}')));
                    final r = s.data;
                    if (r == null) return const SizedBox.shrink();
                    return Card(
                        child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const Text(
                                      'Saved KForge swap awaiting confirmation',
                                      style: TextStyle(
                                          fontWeight: FontWeight.bold)),
                                  const Text(
                                      'The exact signed transaction is saved. Check it before creating another trade. A missing lookup does not mean failure.'),
                                  SelectableText('${r['id']}'),
                                  OutlinedButton(
                                      onPressed: busy ? null : () => resume(r),
                                      child: const Text(
                                          'Check / resume same saved swap')),
                                  OutlinedButton(
                                      onPressed: () =>
                                          KForgeHistoryScreen.export(r),
                                      child: const Text(
                                          'Export public recovery receipt')),
                                ])));
                  }),
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              KForgeImage(url: widget.token.logo, size: 56),
                              const SizedBox(width: 12),
                              Expanded(
                                  child: Text(widget.token.name,
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineSmall))
                            ]),
                            Text(
                                '${trading.service.label} · ${widget.token.graduated ? 'Pool' : 'Bonding curve'}'),
                            Text(
                                'Indexed balance: ${_tokens(balance)} ${widget.token.symbol}'),
                            if (balanceUnavailable)
                              const Text(
                                  'Balance refresh unavailable; the previous balance is retained.'),
                            Text(
                                'Price per token: ${formatEnglishNumber(widget.token.priceKas, decimals: 12, trimTrailingZeros: true)} KAS'),
                            const SizedBox(height: 12),
                            const Text('Token covenant ID'),
                            SelectableText(widget.token.id),
                            OutlinedButton.icon(
                                onPressed: () => Clipboard.setData(
                                    ClipboardData(text: widget.token.id)),
                                icon: const Icon(Icons.copy),
                                label: const Text('Copy covenant ID')),
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
                            amount.clear();
                            invalidate();
                          })),
              const SizedBox(height: 16),
              TextField(
                  controller: amount,
                  enabled: !busy,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(invalidate),
                  decoration: InputDecoration(
                      labelText: side == 'buy'
                          ? 'KAS trade amount (fees and cell reserve added)'
                          : 'Token amount (whole tokens)',
                      suffixText: side == 'buy' ? 'KAS' : widget.token.symbol)),
              if (!widget.token.graduated)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(side == 'buy'
                        ? 'Enter the KAS amount you want to trade. Kaspire calculates the token amount using whole curve lots; unused trade budget is not spent on tokens. Fees and any new cell reserves are added.'
                        : 'Curve sells use whole lots of 1,000,000 tokens. Pool swaps allow any whole token amount.')),
              if (side == 'sell')
                Row(children: [
                  for (final p in [25, 50, 75, 100])
                    Expanded(
                        child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: OutlinedButton(
                                onPressed: busy
                                    ? null
                                    : () {
                                        var n = BigInt.parse(balance) *
                                            BigInt.from(p) ~/
                                            BigInt.from(100);
                                        if (!widget.token.graduated)
                                          n = n ~/
                                              BigInt.from(1000000) *
                                              BigInt.from(1000000);
                                        setState(() {
                                          amount.text = '$n';
                                          invalidate();
                                        });
                                      },
                                child: Text(p == 100 ? 'MAX' : '$p%'))))
                ]),
              const SizedBox(height: 12),
              OutlinedButton(
                  onPressed: busy ? null : quote,
                  child: const Text('Refresh quote')),
              if (v != null)
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  'Token amount: ${_tokens(v['tokens'])} ${widget.token.symbol}'),
                              if (side == 'buy' &&
                                  v['buyBudgetSompi'] != null) ...[
                                Text(
                                    'KAS trade amount entered: ${_kas(v['buyBudgetSompi'])}'),
                                Text(
                                    'KAS used for the trade: ${_kas(v['marketKas'])}'),
                                if (BigInt.parse('${v['unspentBudgetSompi']}') >
                                    BigInt.zero)
                                  Text(
                                      'Not used for tokens (lot rounding): ${_kas(v['unspentBudgetSompi'])}'),
                              ],
                              Text(
                                  'Wallet ${side == 'buy' ? 'pays (all-in)' : 'receives (net)'}: ${_kas(v['walletNet'])}'),
                              Text('Network fee: ${_kas(v['networkFee'])}'),
                              Text(
                                  'Token-cell reserve ${side == 'buy' ? 'added' : 'released'}: ${_kas(v['cellReserveChange'])}'),
                            ]))),
              if (error != null)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error))),
              ValueListenableBuilder<String?>(
                  valueListenable: trading.progress,
                  builder: (_, value, __) => value == null
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(value))),
              if (busy) const LinearProgressIndicator(),
              FilledButton.icon(
                  onPressed: busy || plan == null ? null : review,
                  icon: const Icon(Icons.shield_outlined),
                  label: const Text('Review swap')),
              TextButton(
                  onPressed: busy ? null : () => Navigator.pop(context),
                  child: const Text('Return to KForge DEX')),
            ]));
  }
}

class KForgeHistoryScreen extends StatelessWidget {
  const KForgeHistoryScreen({super.key, required this.address, this.trading});
  final String address;
  final KForgeTrading? trading;
  static Future<void> export(Map r) => Share.shareXFiles([
        XFile.fromData(utf8.encode(jsonEncode(r)),
            mimeType: 'application/json',
            name: 'kaspire-kforge-${r['id']}.json')
      ]);
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('KForge · My activity')),
      body: KForgeActivity(address: address, trading: trading));
}

class KForgeActivity extends StatefulWidget {
  const KForgeActivity(
      {super.key, required this.address, this.trading, this.onReturnToDex});
  final String address;
  final KForgeTrading? trading;
  final VoidCallback? onReturnToDex;
  @override
  State<KForgeActivity> createState() => _KForgeActivityState();
}

class _KForgeActivityState extends State<KForgeActivity> {
  late final trading = widget.trading ?? KForgeTrading();
  late Future<List<Map<String, dynamic>>> data;
  bool busy = false;
  String? error;
  int visible = 50;
  @override
  void initState() {
    super.initState();
    reload();
  }

  void reload() => setState(() {
        data = trading.saved(widget.address);
        data.ignore();
      });
  Future<void> check(Map<String, dynamic> r) async {
    setState(() => busy = true);
    try {
      final result = await trading.exclusive(
          widget.address, () => trading.resume(widget.address, r));
      if (mounted && result['state'] == 'confirmed') await details(result);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) {
        setState(() => busy = false);
        reload();
      }
    }
  }

  Future<void> details(Map<String, dynamic> r) =>
      Navigator.of(context).push<void>(MaterialPageRoute<void>(
          builder: (_) => KForgeResultScreen(
              receipt: r,
              returnToDex: () {
                Navigator.of(context).pop();
                widget.onReturnToDex?.call();
              })));

  @override
  Widget build(BuildContext context) => FutureBuilder<
          List<Map<String, dynamic>>>(
      future: data,
      builder: (context, s) {
        if (s.hasError) return Center(child: Text('${s.error}'));
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        final rows = s.data!.reversed.toList();
        return ListView(
            key: const Key('kforge-activity-list'),
            padding: rocketListPadding(context),
            children: [
              Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                      onPressed: busy ? null : reload,
                      tooltip: 'Reload activity',
                      icon: const Icon(Icons.refresh))),
              if (error != null)
                Text(error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              if (busy) const LinearProgressIndicator(),
              if (rows.isEmpty) const Text('No KForge swaps on this device.'),
              for (final pending in [true, false]) ...[
                if (rows.any((r) => (r['state'] == 'pending') == pending))
                  Text(
                      pending
                          ? 'Saved swaps awaiting confirmation'
                          : 'Activity',
                      style: Theme.of(context).textTheme.titleLarge),
                for (final r in rows
                    .where((r) => (r['state'] == 'pending') == pending)
                    .take(pending ? 200 : visible))
                  Card(
                      child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                    '${r['state'] == 'obsolete' ? 'Obsolete · ' : ''}${r['side'] == 'buy' ? 'Buy' : 'Sell'} ${_tokens(r['verified']['tokens'])} ${r['symbol']}'),
                                Text(
                                    '${r['state'] == 'confirmed' ? 'Wallet ${r['side'] == 'buy' ? 'paid' : 'received'}' : 'Planned wallet amount'}: ${_kas(r['verified']['walletNet'])} · ${r['state']}'),
                                Text(DateTime.fromMillisecondsSinceEpoch(
                                        r['createdAt'] as int)
                                    .toLocal()
                                    .toString()),
                                SelectableText('${r['id']}'),
                                OutlinedButton.icon(
                                    onPressed: () => Clipboard.setData(
                                        ClipboardData(text: '${r['id']}')),
                                    icon: const Icon(Icons.copy),
                                    label: const Text('Copy transaction ID')),
                                if (pending)
                                  OutlinedButton(
                                      onPressed: busy ? null : () => check(r),
                                      child: const Text(
                                          'Check / resume same saved swap')),
                                if (r['state'] == 'confirmed')
                                  OutlinedButton(
                                      onPressed: busy ? null : () => details(r),
                                      child: const Text('View trade details')),
                                OutlinedButton(
                                    onPressed: () =>
                                        KForgeHistoryScreen.export(r),
                                    child: const Text(
                                        'Export public recovery receipt')),
                              ]))),
              ],
              if (rows.where((r) => r['state'] != 'pending').length > visible)
                OutlinedButton(
                    onPressed: () => setState(() => visible += 50),
                    child: const Text('Load more')),
            ]);
      });
}
