import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../number_format.dart';
import '../services/kasforge_trading.dart';
import 'kasparocket_screen.dart' show rocketListPadding;

class KasForgeOrderScreen extends StatefulWidget {
  const KasForgeOrderScreen(
      {super.key,
      required this.address,
      required this.receipt,
      this.trading,
      this.autoCheck = true});
  final String address;
  final Map<String, dynamic> receipt;
  final KasForgeTrading? trading;
  final bool autoCheck;
  @override
  State<KasForgeOrderScreen> createState() => _KasForgeOrderScreenState();
}

class _KasForgeOrderScreenState extends State<KasForgeOrderScreen>
    with WidgetsBindingObserver {
  late final trading = widget.trading ?? KasForgeTrading();
  late final r = widget.receipt;
  bool busy = false;
  String? error;
  Timer? _checkTimer;
  bool _foreground = true;
  int _checks = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleCheck(immediate: true);
  }

  @override
  void dispose() {
    _checkTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _scheduleCheck(immediate: true);
    } else {
      _checkTimer?.cancel();
    }
  }

  void _scheduleCheck({bool immediate = false}) {
    _checkTimer?.cancel();
    final signed = r['signed'] as List?;
    if (!widget.autoCheck ||
        !mounted ||
        !_foreground ||
        busy ||
        r['finalVerified'] == true ||
        (signed?.isNotEmpty != true && r['cancelId'] == null)) {
      return;
    }
    _checkTimer = Timer(
        immediate
            ? Duration.zero
            : Duration(
                seconds: _checks < 4
                    ? 2
                    : _checks < 15
                        ? 6
                        : 15), () {
      if (!mounted || !_foreground || busy) return;
      _checks++;
      unawaited(run(() async {
        await trading.status(widget.address, r);
      }));
    });
  }

  Future<void> run(Future<void> Function() f) async {
    _checkTimer?.cancel();
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await trading.exclusive(widget.address, f);
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
        _scheduleCheck();
      }
    }
  }

  Future<bool> confirmCancel() async =>
      await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                  scrollable: true,
                  title: const Text('Recover this saved Forge order?'),
                  content: const Text(
                      'Return a confirmed deposit through its contract. Otherwise invalidate the saved order by returning its wallet-owned KAS funding to the same wallet; tokens are not sold. Recovery fee: 0.1 KAS, plus any already-approved preparation fees if consolidation must finish first. No new swap is created. Nothing is cleared until independently verified.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Back')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Review cancellation'))
                  ])) ??
      false;
  Future<void> recover() async {
    _checkTimer?.cancel();
    if (!await confirmCancel()) {
      _scheduleCheck();
      return;
    }
    if (!mounted) return;
    await run(() async {
      await trading.cancelAndSubmit(widget.address, r);
      await trading.status(widget.address, r);
    });
  }

  Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        SelectableText(value)
      ]));
  @override
  Widget build(BuildContext context) {
    final signed = r['signed'] as List?;
    final submitted = r['state'] != 'prepared' && signed != null;
    final order = r['order'] as Map, st = order['state'] as Map;
    final done = r['finalVerified'] == true;
    final expired = r['requestExpired'] == true ||
        '${r['submissionError'] ?? ''}'.toLowerCase().contains('expired');
    return Scaffold(
        appBar: AppBar(title: const Text('KasForge order')),
        body: ListView(padding: rocketListPadding(context), children: [
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            done
                                ? 'Order ${r['state']}'
                                : r['state'] == 'deposited-untracked'
                                    ? 'Deposit confirmed · swap not registered'
                                    : submitted
                                        ? 'Order awaiting settlement'
                                        : 'Review Forge order',
                            style: Theme.of(context).textTheme.headlineSmall),
                        const Text(
                            'Testnet 10 · covenant order. A deposit is not a completed swap. The owner can cancel an unfilled order at any time.'),
                        row('Direction', '${r['side']} · ${r['symbol']}'),
                        row('You pay',
                            '${r['amount']} ${r['side'] == 'buy' ? 'KAS' : r['symbol']}'),
                        row(
                            'Guaranteed minimum',
                            r['side'] == 'buy'
                                ? '${formatRawTokenAmount(BigInt.parse('${r['minimumOut']}'), 0)} ${r['symbol']}'
                                : '${formatRawTokenAmount(BigInt.parse('${r['minimumOut']}'), 8)} KAS'),
                        row('Order expiry (DAA score)', '${st['expiryDaa']}'),
                        row('Order address', '${order['address']}'),
                        row('Token covenant ID', '${r['tokenId']}'),
                        for (final review
                            in (r['reviews'] as List? ?? []).whereType<Map>())
                          row('Deposit network fee',
                              '${formatRawTokenAmount(BigInt.parse('${review['feeSompi']}'), 8)} KAS'),
                        if (r['transactionIds'] is List)
                          for (final id in r['transactionIds'] as List) ...[
                            row('Transaction ID', '$id'),
                            OutlinedButton.icon(
                                onPressed: () => Clipboard.setData(
                                    ClipboardData(text: '$id')),
                                icon: const Icon(Icons.copy),
                                label: const Text('Copy transaction ID')),
                          ],
                        if (r['status'] is Map) ...[
                          row('Latest status',
                              '${r['status']['order'] is Map ? r['status']['order']['status'] : r['status']['status']}'),
                          if (r['status']['message'] is String)
                            Text('${r['status']['message']}'),
                        ],
                        if (!done && r['submissionError'] is String)
                          row('Last Forge submission error',
                              '${r['submissionError']}'),
                      ]))),
          if (error != null)
            Padding(
                padding: const EdgeInsets.all(12),
                child: Text(error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
          if (!done && signed?.isNotEmpty == true)
            Padding(
                padding: const EdgeInsets.all(12),
                child: Text(busy
                    ? 'Checking saved order…'
                    : 'Status is checked automatically while this screen is open. A delayed confirmation is not a failed trade.')),
          if (!done) ...[
            if (!submitted && !expired)
              FilledButton(
                  onPressed: busy
                      ? null
                      : () => run(() async {
                            await trading.sign(widget.address, r);
                            await trading.submit(widget.address, r);
                            await trading.status(widget.address, r);
                          }),
                  child: Text(busy
                      ? 'Checking…'
                      : signed == null
                          ? 'Authorize and place order'
                          : 'Resume saved order')),
            if (expired)
              FilledButton(
                  onPressed: busy ? null : recover,
                  child: const Text('Recover expired request')),
            if (signed != null)
              OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => run(() async {
                            await trading.status(widget.address, r);
                          }),
                  child: const Text('Check order status')),
            if (signed != null && !expired)
              OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => run(() async {
                            await trading.sign(widget.address, r);
                            await trading.submit(widget.address, r);
                            await trading.status(widget.address, r);
                          }),
                  child: const Text('Resubmit same saved order')),
            if (signed != null)
              OutlinedButton(
                  onPressed: busy ? null : recover,
                  child: const Text('Cancel / recover unfilled order')),
          ],
          if (signed != null)
            OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () => Share.shareXFiles([
                          XFile.fromData(utf8.encode(jsonEncode(r)),
                              mimeType: 'application/json',
                              name: 'kaspire-forge-${r['buildId']}.json')
                        ]),
                icon: const Icon(Icons.save_alt),
                label: const Text('Export public recovery receipt')),
          if (done)
            FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Return to marketplace')),
          if (signed != null && !done)
            const Text(
                'Signed order data is saved. Resume uses the same transactions; do not create a second order while its status is unknown.'),
        ]));
  }
}
