import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../number_format.dart';
import '../services/braid_service.dart';
import '../services/native_security.dart';
import '../widgets/sell_amount_buttons.dart';
import 'kasparocket_screen.dart' show rocketListPadding;

class BraidScreen extends StatefulWidget {
  const BraidScreen(
      {super.key, required this.address, this.service, this.security});
  final String address;
  final BraidService? service;
  final NativeSecurity? security;
  @override
  State<BraidScreen> createState() => _BraidScreenState();
}

class _BraidScreenState extends State<BraidScreen> {
  late final service = widget.service ?? BraidService();
  late final security = widget.security ?? NativeSecurity();
  final amount = TextEditingController(text: '30');
  BraidToken from = BraidService.tokens[0], to = BraidService.tokens[1];
  Map<String, dynamic>? quoted, receipt;
  List<Map<String, dynamic>> history = [];
  BigInt? balance;
  String? error;
  String statusText = '';
  bool busy = false, checking = false;
  int revision = 0;
  Timer? poll;
  @override
  void initState() {
    super.initState();
    unawaited(reload());
    poll = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted &&
          !busy &&
          !checking &&
          receipt != null &&
          receipt!['verifiedFinal'] != true) {
        unawaited(check());
      }
    });
  }

  @override
  void dispose() {
    revision++;
    poll?.cancel();
    amount.dispose();
    super.dispose();
  }

  String message(Object e) => e is PlatformException
      ? e.message ?? 'Wallet authorization failed.'
      : e.toString().replaceFirst('Bad state: ', '');
  void fail(Object e) {
    if (mounted) setState(() => error = message(e));
  }

  Future<void> reload() async {
    final generation = ++revision;
    try {
      service.guard(widget.address);
      final pending = await service.pending(widget.address);
      final rows = await service.saved(widget.address);
      if (mounted && generation == revision) {
        setState(() {
          receipt = pending;
          history =
              rows.where((r) => r['signed'] is Map).toList().reversed.toList();
          error = null;
        });
      }
      if (!from.isKas) {
        final notes = await service.notes(widget.address, from);
        final sum = (notes['notes'] as List).whereType<Map>().fold<BigInt>(
            BigInt.zero,
            (n, r) =>
                n +
                BraidService.integer(
                    r['amount'] ?? (r['state'] as Map?)?['amount']));
        if (mounted && generation == revision) setState(() => balance = sum);
      }
    } catch (e) {
      if (generation == revision) fail(e);
    }
  }

  void changed() {
    revision++;
    setState(() {
      quoted = null;
      balance = null;
      error = null;
    });
    unawaited(reload());
  }

  Future<void> selectToken(bool input) async {
    var query = '';
    final selected = await showDialog<BraidToken>(
        context: context,
        builder: (dialogContext) =>
            StatefulBuilder(builder: (context, refresh) {
              final matches = BraidService.tokens
                  .where((token) =>
                      token.symbol.toLowerCase().contains(query) ||
                      (!token.isKas && token.id.contains(query)))
                  .toList();
              return AlertDialog(
                  title:
                      Text(input ? 'From · Select token' : 'To · Select token'),
                  content: SizedBox(
                      width: 480,
                      height: MediaQuery.sizeOf(context).height * 0.55,
                      child: Column(children: [
                        TextField(
                            key: const Key('braid-token-search'),
                            autofocus: true,
                            autocorrect: false,
                            enableSuggestions: false,
                            onChanged: (text) => refresh(
                                () => query = text.trim().toLowerCase()),
                            decoration: const InputDecoration(
                                hintText: 'Search ticker or covenant ID',
                                prefixIcon: Icon(Icons.search))),
                        const SizedBox(height: 12),
                        Expanded(
                            child: matches.isEmpty
                                ? const Center(
                                    child: Text('No matching tokens.'))
                                : ListView.builder(
                                    itemCount: matches.length,
                                    itemBuilder: (context, index) {
                                      final token = matches[index];
                                      return ListTile(
                                          key: Key('braid-token-${token.id}'),
                                          title: Text(token.symbol,
                                              overflow: TextOverflow.ellipsis),
                                          subtitle: Text(
                                              token.isKas
                                                  ? 'Kaspa · native KAS'
                                                  : token.id,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis),
                                          onTap: () => Navigator.pop(
                                              dialogContext, token));
                                    }))
                      ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('Cancel'))
                  ]);
            }));
    if (!mounted || selected == null || busy) return;
    if (input) {
      if (from.id == selected.id) return;
      from = selected;
      amount.clear();
    } else {
      if (to.id == selected.id) return;
      to = selected;
    }
    changed();
  }

  Widget tokenSelector(String label, BraidToken token, bool input) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        OutlinedButton(
            key: Key('braid-select-${input ? 'from' : 'to'}'),
            onPressed: busy ? null : () => selectToken(input),
            child: Row(children: [
              Text(label),
              const SizedBox(width: 12),
              Expanded(
                  child: Text(token.symbol,
                      textAlign: TextAlign.end,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis)),
              const Icon(Icons.expand_more)
            ])),
        if (!token.isKas)
          Padding(
              padding: const EdgeInsets.only(left: 8, top: 4),
              child:
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text('Covenant ID',
                          style: Theme.of(context).textTheme.labelSmall),
                      SelectableText(token.id,
                          style: Theme.of(context).textTheme.bodySmall)
                    ])),
                IconButton(
                    key: Key('braid-copy-${input ? 'from' : 'to'}'),
                    tooltip: 'Copy covenant ID',
                    icon: const Icon(Icons.copy, size: 20),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: token.id));
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Covenant ID copied')));
                      }
                    })
              ]))
      ]);

  String rawInput() {
    final s = amount.text.trim();
    if (!from.isKas) return BraidService.integer(s).toString();
    if (!RegExp(r'^(0|[1-9][0-9]{0,9})(\.[0-9]{1,8})?$').hasMatch(s)) {
      throw StateError('Enter a KAS amount with at most 8 decimal places.');
    }
    final parts = s.split('.');
    return (BigInt.parse(parts[0]) * BigInt.from(100000000) +
            (parts.length == 2
                ? BigInt.parse(parts[1].padRight(8, '0'))
                : BigInt.zero))
        .toString();
  }

  Future<void> quote() async {
    final generation = ++revision;
    setState(() {
      busy = true;
      error = null;
      quoted = null;
    });
    try {
      final q = await service.quote(widget.address, from, to, rawInput(), 100);
      if (mounted && generation == revision) setState(() => quoted = q);
    } catch (e) {
      if (generation == revision) fail(e);
    } finally {
      if (mounted && generation == revision) setState(() => busy = false);
    }
  }

  Future<bool> confirm(String title, List<Widget> lines) async =>
      await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                  title: Text(title),
                  content: SizedBox(
                      width: 480,
                      child: SingleChildScrollView(
                          child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: lines))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Confirm'))
                  ])) ??
      false;
  Widget line(String title, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        SelectableText(value)
      ]));
  String quantity(Object? n, BraidToken token) => token.isKas
      ? '${formatRawTokenAmount(BraidService.integer(n), 8)} KAS'
      : '${formatEnglishDecimal('$n')} ${token.symbol} base units';
  Future<void> trade() async {
    final q = quoted;
    if (q == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await service.exclusive(widget.address, () async {
        final next = await service.build(widget.address, q);
        final request = Map<String, Object?>.from(next['request'] as Map);
        final review = await security.preparePskt(request);
        final b = next['build'] as Map;
        if (b['depositTxid'] != null &&
            b['depositTxid'] != review['transactionId']) {
          throw StateError(
              'Braid deposit ID differs from the native transaction. Nothing was signed.');
        }
        if (!mounted) return;
        if (!await confirm('Review Braid deposit', [
          const Text(
              'Testnet 10 · one signed deposit. Completion is separate and is checked on chain. Tokens use raw base units in this preview.'),
          line('You pay', quantity(q['localAmount'], from)),
          line('Guaranteed minimum', quantity(q['localFloor'], to)),
          line('Deposit network fee',
              quantity('${review['feeSompi']}', BraidService.tokens.first)),
          const Text(
              'Integrator fee: 0% during this TN10 preview. Unfilled deposits can be recovered after their on-chain deadline. Recovery may cost up to 0.05 KAS.'),
          for (final output in (review['outputs'] as List).whereType<Map>())
            line('Output ${output['index']}',
                '${formatRawTokenAmount(BraidService.integer('${output['amountSompi']}'), 8)} KAS\n${output['address'] ?? output['scriptPublicKey']}'),
        ])) {
          return;
        }
        await service.beforeSigning(widget.address, next);
        await service.retain(widget.address, next);
        final signed =
            await security.signPskt(request, '${review['reviewHash']}');
        final tx = jsonDecode('${signed['signedTxJson']}') as Map;
        final signatures = <String, String>{};
        for (final selector in request['signInputs'] as List) {
          final i = (selector as Map)['index'] as int;
          final script = '${(tx['inputs'] as List)[i]['signatureScript']}';
          final templates = (request['scripts'] as List)
              .whereType<Map>()
              .where((r) => r['inputIndex'] == i)
              .toList();
          final bytes = BraidService.bytes(script);
          final List<int> sig;
          if (templates.isNotEmpty &&
              templates.single['signatureOffsets'] is List) {
            final at =
                (templates.single['signatureOffsets'] as List).single as int;
            sig = bytes.sublist(at, at + 65);
          } else {
            final pushes = BraidService.pushes(script);
            if (pushes.isEmpty) {
              throw StateError('Native signature is missing.');
            }
            sig = pushes.first.data;
          }
          if (sig.length != 65 || sig.last != 1) {
            throw StateError('Native signer did not return SIGHASH_ALL.');
          }
          signatures['$i'] = BraidService.hex(sig);
        }
        final raw = jsonDecode('${request['txJsonString']}') as Map;
        next.addAll({
          'signed': signatures,
          'signedTransaction': signed['wrpcJson'],
          'transactionId': signed['transactionId'],
          'depositCoinIndex': b['coinIdx'],
          'depositCoinValue':
              '${(raw['outputs'] as List)[b['coinIdx'] as int]['value']}',
          'depositNoteIndex': b['noteIdx'],
          'depositNoteValue': b['noteValue'],
          'depositNoteRedeem': (b['tokRedeems'] as Map?)?['note'],
          'state': 'signed'
        });
        await service.retain(widget.address, next);
        if (mounted) {
          setState(() {
            receipt = next;
            quoted = null;
            statusText =
                'Signed deposit saved. Submitting the same transaction…';
          });
        }
        await service.submit(widget.address, next);
        if (mounted) {
          setState(() => statusText =
              'Deposit submitted. Waiting for swap execution or refund…');
        }
      });
    } catch (e) {
      fail(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (receipt != null) await check();
  }

  Future<void> check() async {
    if (checking || receipt == null) return;
    checking = true;
    try {
      final r = receipt!;
      if (r['recoverySigned'] is Map) {
        final id = '${(r['recoverySigned'] as Map)['transactionId']}';
        try {
          await service.verifyFinal(widget.address, r, {
            'state': 'reclaimed',
            'reclaim': {'txid': id}
          });
          r['verifiedFinal'] = true;
          r['state'] = 'reclaimed';
          await service.retain(widget.address, r);
          if (mounted) {
            setState(() => statusText = 'Recovery confirmed on chain.');
          }
          return;
        } catch (_) {/* An unconfirmed recovery is never discarded. */}
      }
      final result = await service.status(widget.address, r);
      if (mounted) {
        setState(() => statusText = r['verifiedFinal'] == true
            ? '${result['state'] == 'done' ? 'Swap completed' : 'Funds returned'} · independently verified on chain'
            : 'Swap status: ${result['state']} · receipt retained');
      }
    } catch (e) {
      fail(e);
    } finally {
      checking = false;
    }
  }

  Future<void> resume() async {
    if (receipt == null) return;
    setState(() => busy = true);
    try {
      await service.exclusive(widget.address, () async {
        await service.submit(widget.address, receipt!);
      });
    } catch (e) {
      fail(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
    await check();
  }

  Future<void> recover() async {
    final r = receipt;
    if (r == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await service.exclusive(widget.address, () async {
        if (r['recoverySigned'] == null) {
          final request = await service.reclaim(widget.address, r);
          final review = await security.preparePskt(request);
          if (!mounted ||
              !await confirm('Recover expired Braid deposit', [
                const Text(
                    'This recovery uses your saved receipt and independent public nodes. Braid does not need to be available.'),
                line(
                    'Network fee',
                    quantity(
                        '${review['feeSompi']}', BraidService.tokens.first)),
                for (final o in (review['outputs'] as List).whereType<Map>())
                  line('Return output ${o['index']}',
                      '${o['amountSompi']} sompi\n${o['address'] ?? o['scriptPublicKey']}'),
              ])) {
            return;
          }
          final signed =
              await security.signPskt(request, '${review['reviewHash']}');
          r['recoverySigned'] = signed;
          await service.retain(widget.address, r);
        }
        await service.submitRecovery(widget.address, r);
        if (mounted) {
          setState(() => statusText =
              'Recovery submitted. Waiting for independent confirmation…');
        }
      });
    } catch (e) {
      fail(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
    await check();
  }

  Future<void> export(Map<String, dynamic> r) async {
    final file = XFile.fromData(utf8.encode(jsonEncode(r)),
        mimeType: 'application/json', name: 'kaspire-braid-${r['ref']}.json');
    await Share.shareXFiles([file],
        text:
            'Braid TN10 recovery receipt. Contains public swap data and signed transactions, not wallet private keys.');
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !busy,
      child: DefaultTabController(
          length: 2,
          child: Scaffold(
            appBar: AppBar(
                title: const Text('Braid · Testnet 10'),
                actions: [
                  IconButton(
                      onPressed: busy ? null : reload,
                      icon: const Icon(Icons.refresh))
                ],
                bottom: const TabBar(
                    tabs: [Tab(text: 'Swap'), Tab(text: 'My activity')])),
            body: Builder(
                builder: (tabContext) =>
                    TabBarView(children: [swap(), activity(tabContext)])),
          )));
  Widget swap() => ListView(padding: rocketListPadding(context), children: [
        const Card(
            child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Braid Aggregator',
                          style: TextStyle(
                              fontSize: 22, fontWeight: FontWeight.bold)),
                      Text(
                          'Testnet 10 · Best-route quotes across available venues'),
                      SizedBox(height: 8),
                      Text(
                          'One covenant deposit, then execution or refund. This preview uses pinned TN10 tokens and displays token quantities in base units. No Mainnet funds or integrator fees.')
                    ]))),
        if (error != null)
          Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
        if (receipt != null)
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                            receipt!['verifiedFinal'] == true
                                ? 'Swap finished'
                                : 'Saved swap · action/status',
                            style: const TextStyle(
                                fontSize: 20, fontWeight: FontWeight.bold)),
                        Text(statusText.isEmpty
                            ? '${receipt!['state']}'
                            : statusText),
                        if (receipt!['quote'] is Map) ...[
                          line(
                              'You paid',
                              quantity(
                                  (receipt!['quote'] as Map)['localAmount'],
                                  BraidService.tokens.singleWhere(
                                      (t) => t.symbol == receipt!['from']))),
                          line(
                              'Guaranteed minimum',
                              quantity(
                                  (receipt!['quote'] as Map)['localFloor'],
                                  BraidService.tokens.singleWhere(
                                      (t) => t.symbol == receipt!['to']))),
                          for (final tx
                              in ((receipt!['quote'] as Map)['txs'] as List? ??
                                      [])
                                  .whereType<Map>())
                            for (final leg
                                in (tx['legs'] as List? ?? []).whereType<Map>())
                              Text(
                                  '${leg['venue']}: ${leg['from']} → ${leg['to']}'),
                        ],
                        line('Deposit transaction',
                            '${receipt!['transactionId']}'),
                        OutlinedButton.icon(
                            onPressed: () => Clipboard.setData(ClipboardData(
                                text: '${receipt!['transactionId']}')),
                            icon: const Icon(Icons.copy),
                            label: const Text('Copy transaction ID')),
                        OutlinedButton(
                            onPressed: busy ? null : () => export(receipt!),
                            child: const Text('Export recovery receipt')),
                        if (receipt!['verifiedFinal'] != true) ...[
                          OutlinedButton(
                              onPressed: busy ? null : check,
                              child: const Text('Check swap status')),
                          OutlinedButton(
                              onPressed: busy ? null : resume,
                              child: const Text('Resubmit same saved deposit')),
                          OutlinedButton(
                              onPressed: busy ? null : recover,
                              child: Text(receipt!['recoverySigned'] == null
                                  ? 'Recover after deadline'
                                  : 'Resubmit saved recovery')),
                        ] else
                          FilledButton(
                              onPressed: () => setState(() {
                                    receipt = null;
                                    quoted = null;
                                    error = null;
                                    unawaited(reload());
                                  }),
                              child: const Text('Return to swaps')),
                      ]))),
        if (receipt == null) ...[
          tokenSelector('From', from, true),
          const SizedBox(height: 12),
          tokenSelector('To', to, false),
          const SizedBox(height: 12),
          if (!from.isKas) ...[
            Text(balance == null
                ? 'Token balance unavailable / loading'
                : 'Token balance: ${formatEnglishDecimal('$balance')} ${from.symbol} base units'),
            SellAmountButtons(
                balance: balance,
                decimals: 0,
                enabled: !busy,
                onSelected: (v) {
                  setState(() {
                    amount.text = v;
                    quoted = null;
                  });
                })
          ],
          TextField(
              controller: amount,
              enabled: !busy,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() => quoted = null),
              decoration: InputDecoration(
                  labelText: from.isKas
                      ? 'Total KAS to pay (all-in)'
                      : 'Token amount in base units')),
          const SizedBox(height: 12),
          OutlinedButton(
              onPressed: busy ? null : quote,
              child: const Text('Refresh quote')),
          if (quoted != null)
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          line('Estimated received',
                              quantity(quoted!['amountOut'], to)),
                          line('Guaranteed minimum · 1% slippage',
                              quantity(quoted!['localFloor'], to)),
                          if (!from.isKas && to.isKas)
                            const Text(
                                'KAS output includes the returned router coin/token-note carrier. This is not all trading profit.'),
                          const Text(
                              'Integrator fee: 0%. Braid fee cap is verified separately. Deposit network fee is shown before signing.'),
                          for (final tx in (quoted!['txs'] as List? ?? [])
                              .whereType<Map>())
                            for (final leg
                                in (tx['legs'] as List? ?? []).whereType<Map>())
                              Text(
                                  '${leg['venue']}: ${leg['from']} → ${leg['to']}'),
                        ]))),
          FilledButton(
              onPressed: busy || quoted == null ? null : trade,
              child: Text(busy ? 'Checking…' : 'Review swap deposit')),
        ],
      ]);
  Widget activity(BuildContext tabContext) =>
      ListView(padding: rocketListPadding(context), children: [
        if (history.isEmpty) const Text('No saved Braid swaps on this device.'),
        for (final r in history)
          Card(
              child: ListTile(
                  title: Text('${r['from']} → ${r['to']}'),
                  subtitle: Text(
                      '${r['state']} · ${r['verifiedFinal'] == true ? 'verified' : 'pending/unverified'}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    setState(() {
                      receipt = r;
                      statusText = '';
                      error = null;
                    });
                    DefaultTabController.of(tabContext).animateTo(0);
                  })),
      ]);
}
