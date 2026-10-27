import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../number_format.dart';
import '../services/kasforge_trading.dart';
import 'kasparocket_screen.dart' show rocketListPadding;

class KasForgeOrderScreen extends StatefulWidget {
  const KasForgeOrderScreen(
      {super.key, required this.address, required this.receipt, this.trading});
  final String address;
  final Map<String, dynamic> receipt;
  final KasForgeTrading? trading;
  @override
  State<KasForgeOrderScreen> createState() => _KasForgeOrderScreenState();
}

class _KasForgeOrderScreenState extends State<KasForgeOrderScreen> {
  late final trading = widget.trading ?? KasForgeTrading();
  late final r = widget.receipt;
  bool busy = false;
  String? error;
  Future<void> run(Future<void> Function() f) async {
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
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> confirmCancel() async =>
      await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                  title: const Text('Cancel this Forge order?'),
                  content: const Text(
                      'Return the unfilled order to your wallet using the saved contract data and an independent node. Network fee: 0.1 KAS. No new swap is created.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Back')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Review cancellation'))
                  ])) ??
      false;
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
          if (!done) ...[
            if (!submitted)
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
            if (submitted)
              OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => run(() async {
                            await trading.status(widget.address, r);
                          }),
                  child: const Text('Check order status')),
            if (signed != null)
              OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => run(() async {
                            await trading.sign(widget.address, r);
                            await trading.submit(widget.address, r);
                          }),
                  child: const Text('Resubmit same saved order')),
            if (signed != null)
              OutlinedButton(
                  onPressed: busy
                      ? null
                      : () async {
                          if (!await confirmCancel()) return;
                          if (!mounted) return;
                          await run(() async {
                            await trading.cancelAndSubmit(widget.address, r);
                          });
                        },
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
