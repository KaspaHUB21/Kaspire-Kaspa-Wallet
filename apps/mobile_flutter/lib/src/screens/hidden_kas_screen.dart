import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/wallet_snapshot.dart';
import '../number_format.dart';
import '../services/app_settings.dart';
import '../services/hidden_kas_service.dart';
import '../services/kaspa_api.dart';
import '../theme.dart';
import '../widgets/hub21_material.dart';
import '../widgets/kas_receive_request.dart';

const hiddenKasHdRequired =
    'P2SH requires a seed-based HD wallet. An imported private key cannot generate this account. '
    'Create or restore an HD wallet using a recovery phrase (seed), then open P2SH again. '
    'Your existing private-key wallet remains unchanged.';

String hiddenKasUserMessage(Object error) {
  String message;
  if (error is PlatformException) {
    if (['AUTH_CANCELLED', 'AUTH_FAILED', 'USER_CANCELLED']
        .contains(error.code)) {
      return 'Authorization was cancelled. No new payment was submitted.';
    }
    message = error.message ??
        'This action could not be completed. Please try again.';
  } else if (error is StateError) {
    message = error.message;
  } else if (error is KaspaApiException) {
    message = error.message;
  } else {
    return 'The account could not be checked. Please refresh and try again. Saved data remains preserved.';
  }
  if (message.contains('requires a root mnemonic wallet')) {
    return hiddenKasHdRequired;
  }
  return message
      .replaceFirst(RegExp(r'^(?:java\.lang\.)?IllegalStateException:\s*'), '')
      .replaceFirst(RegExp(r'^invalid transaction request:\s*'), '');
}

String hiddenKasAmount(Object? value) =>
    '${formatRawTokenAmount(BigInt.from(hiddenInt(value)), 8)} KAS';
int parseHiddenKasAmount(String value) {
  if (!RegExp(r'^\d+(\.\d{1,8})?$').hasMatch(value.trim())) {
    throw StateError(
        'Enter a positive KAS amount with at most 8 decimal places.');
  }
  final parts = value.trim().split('.');
  final raw = BigInt.parse(parts.first) * BigInt.from(100000000) +
      BigInt.parse(parts.length == 1 ? '0' : parts[1].padRight(8, '0'));
  if (raw < BigInt.from(10000) || raw > BigInt.parse('2870000000000000000')) {
    throw StateError('Amount is outside the allowed range.');
  }
  return raw.toInt();
}

class HiddenKasScreen extends StatefulWidget {
  const HiddenKasScreen(
      {super.key, required this.address, this.service, this.embedded = false});
  final bool embedded;
  final String address;
  final HiddenKasService? service;
  @override
  State<HiddenKasScreen> createState() => _HiddenKasScreenState();
}

enum _AccountView { receive, send, activity }

class _HiddenKasScreenState extends State<HiddenKasScreen> {
  late final service = widget.service ?? HiddenKasService(widget.address);
  final recipient = TextEditingController(), amount = TextEditingController();
  final scroll = ScrollController();
  Map<String, Object?>? snapshot, receive, prepared;
  List<WalletTransaction> transactions = [];
  String? error, paymentProgress;
  bool busy = false, accepted = false, completed = false, sendAll = false;
  bool eligibilityChecked = false, requiresHd = false;
  int checked = 0;
  _AccountView view = _AccountView.receive;
  @override
  void initState() {
    super.initState();
    service.onPaymentProgress = (message) {
      if (mounted) setState(() => paymentProgress = message);
    };
    run(checkWalletSupport);
  }

  Future<void> checkWalletSupport() async {
    final supported = await service.supportsHdWallet();
    if (mounted) {
      setState(() {
        eligibilityChecked = true;
        requiresHd = !supported;
      });
    }
  }

  @override
  void dispose() {
    service.close();
    recipient.dispose();
    amount.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() work) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await work();
    } catch (e) {
      if (mounted) {
        setState(() {
          final message = hiddenKasUserMessage(e);
          if (message == hiddenKasHdRequired) {
            requiresHd = true;
            eligibilityChecked = true;
            error = null;
            snapshot = null;
          } else {
            error = completed
                ? 'Your payment is confirmed. The account refresh is temporarily unavailable. Do not repeat the payment.\n$message'
                : message;
          }
          prepared = null;
          receive = null;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> completePayment(Future<void> Function() submit) async {
    setState(() => paymentProgress = 'Authorizing and sending payment…');
    try {
      await submit(); // Completes only after native own-node confirmation.
    } catch (_) {
      // Reveal a saved payment even when the network is unavailable. Never
      // replace the original submit/signing error with a failed refresh.
      try {
        final saved = await service.security.hiddenKasState();
        if (mounted) {
          setState(() => snapshot = {
                'state': saved,
                'addresses': const [],
                'utxos': const [],
                'balanceSompi': null
              });
        }
      } catch (_) {}
      rethrow;
    } finally {
      if (mounted) setState(() => paymentProgress = null);
    }
    if (!mounted) return;
    setState(() {
      completed = true;
      prepared = null;
      receive = null;
      snapshot = null;
      transactions = [];
    });
    // No full discovery here: a read failure must never mask confirmed payment.
  }

  Future<void> refresh() async {
    await service.guard();
    // Show the native saved-payment notice even if discovery is offline.
    final savedState = await service.security.hiddenKasState();
    if (!mounted) return;
    setState(() {
      snapshot = {
        'state': savedState,
        'addresses': const [],
        'utxos': const [],
        'balanceSompi': null
      };
      receive = null;
      prepared = null;
    });
    if (savedState['pending'] != null) {
      // Recover an interrupted send automatically before any expensive scan.
      // Already accepted payments are cleared by native proof, without POST.
      await completePayment(service.resume);
      return;
    }
    final next = await service.scan(progress: (count) {
      if (mounted) setState(() => checked = count);
    });
    if (!mounted) return;
    setState(() {
      snapshot = next;
      receive = null;
      prepared = null;
    });
    if (hiddenMap(next['state'])['pending'] == null) {
      final address = await service.receive(next);
      if (mounted) setState(() => receive = address);
    }
    try {
      final history = await service.activity(next);
      if (mounted) setState(() => transactions = history);
    } catch (e) {
      if (mounted) {
        setState(() =>
            error = 'Activity lookup unavailable: ${hiddenKasUserMessage(e)}');
      }
    }
  }

  Widget panel(List<Widget> children) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
          padding: const EdgeInsets.all(18),
          decoration: KasVaultTheme.isDecorative
              ? kaspireDecorativeDecoration(radius: 18, rim: 2.5)
              : BoxDecoration(
                  color: KasVaultTheme.panel,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: KasVaultTheme.line)),
          child: Material(
              color: Colors.transparent,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children))));
  Widget line(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label),
        SelectableText(value,
            style: const TextStyle(fontWeight: FontWeight.w600))
      ]));
  Widget fact(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Text(label, style: TextStyle(color: KasVaultTheme.detailText)),
        const SizedBox(width: 12),
        Expanded(
            child: Text(value,
                textAlign: TextAlign.right,
                style: const TextStyle(fontWeight: FontWeight.w700))),
      ]));
  List<Widget> accountInformation(BuildContext context) => [
        if (!accepted)
          Text('P2SH account', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        const Text(
            'Receive KAS without publishing the spending public key to aid in quantum resistance. Signing reveals that key.'),
        const SizedBox(height: 10),
        const Text(
            'Separate KAS balance · no assets or dApps · Mainnet only. Existing wallet accounts remain unchanged.'),
        const ExpansionTile(
            title: Text('KIP-22 recovery details'),
            tilePadding: EdgeInsets.zero,
            children: [
              Text(
                  'KIP-22 · PR #48\nDescriptor: kip22-p2sh-v1\nDerivation: m/22\'/111111\'/0\'/branch/index\nReceive branch 0 · change branch 1 · discovery gap 20.\nRedeem script: <x-only public key> OP_CHECKSIG.\n\nRecovery in another wallet requires KIP-22 support. Seed discovery finds used addresses, but a seed alone cannot recover the history of signatures never broadcast. Keep a current Kaspire encrypted backup, which includes issued/retired addresses and saved transactions. Never use the same P2SH account on multiple devices at once. Never disclose an account xpub or reuse a spending key elsewhere.\n\nAll available account outputs are spent together, with fresh P2SH change. Retired addresses still track late payments, but must not be reused for receiving. A network failure never means "safe" or "zero balance".'),
            ]),
      ];

  @override
  Widget build(BuildContext context) => Theme(
      // The embedded account must not mix default controls with decorative
      // surfaces, even when its hosting route supplies a different theme.
      data: KasVaultTheme.forTheme(AppSettings.theme.value),
      child: Builder(builder: buildAccount));

  Widget buildAccount(BuildContext context) {
    final state = snapshot == null ? null : hiddenMap(snapshot!['state']);
    final pending = state?['pending'];
    final review = prepared == null ? null : hiddenMap(prepared!['review']);
    return Scaffold(
        appBar: widget.embedded
            ? null
            : AppBar(
                automaticallyImplyLeading: !widget.embedded,
                title: const Text('P2SH account'),
                actions: [
                    IconButton(
                        tooltip: 'Refresh account',
                        onPressed: busy || !accepted || completed
                            ? null
                            : () => run(refresh),
                        icon: const Icon(Icons.refresh)),
                  ]),
        body: Hub21Backdrop(
            child: SafeArea(
                child: ListView(
                    controller: scroll,
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 48),
                    children: [
              if (widget.embedded) ...[
                Hub21Readable(
                    child: Row(children: [
                  const Expanded(
                      child: Text('P2SH account',
                          style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -.8))),
                  IconButton(
                      tooltip: 'Refresh account',
                      onPressed: busy || !accepted || completed
                          ? null
                          : () => run(refresh),
                      icon: const Icon(Icons.refresh)),
                ])),
                const SizedBox(height: 16),
              ],
              panel([
                if (accepted)
                  ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('Recovery and key exposure'),
                      children: accountInformation(context)),
                if (!accepted) ...accountInformation(context),
                if (requiresHd) ...[
                  const SizedBox(height: 16),
                  const Icon(Icons.account_tree_outlined, size: 36),
                  Text('Seed-based HD wallet required',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 10),
                  const Text(hiddenKasHdRequired),
                ] else if (eligibilityChecked && !accepted) ...[
                  CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                          'I understand the P2SH format and want to continue'),
                      value: accepted,
                      onChanged: busy
                          ? null
                          : (v) {
                              if (v == true) {
                                setState(() => accepted = true);
                                run(refresh);
                              }
                            }),
                ],
              ]),
              if (busy) ...[
                const LinearProgressIndicator(),
                Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(paymentProgress ??
                        'Checking account · $checked addresses'))
              ],
              if (error != null)
                panel([
                  SelectableText(error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                  if (!error!.contains(
                      'Saved addresses and signed payments remain preserved.'))
                    const Text(
                        'Saved addresses and signed payments remain preserved. Refresh before trying again.'),
                  if (!eligibilityChecked)
                    OutlinedButton(
                        onPressed: busy ? null : () => run(checkWalletSupport),
                        child: const Text('Check wallet again')),
                ]),
              if (pending != null)
                panel([
                  const Icon(Icons.schedule, size: 38),
                  Text('Payment awaiting confirmation',
                      style: Theme.of(context).textTheme.titleLarge),
                  const Text(
                      'The signed payment is safely saved. Kaspire checks it automatically before submitting the same bytes. Do not create another payment. Input keys are already retired.'),
                  SelectableText(
                      hiddenMap(pending)['transactionId'].toString()),
                  FilledButton.icon(
                      onPressed: busy
                          ? null
                          : () => run(() => completePayment(service.resume)),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Check payment status')),
                ]),
              if (completed)
                panel([
                  const Icon(Icons.check_circle_outline, size: 40),
                  const Text('Payment confirmed by the Kaspire node.'),
                  FilledButton(
                      onPressed: busy
                          ? null
                          : () => run(() async {
                                await refresh();
                                if (mounted) setState(() => completed = false);
                              }),
                      child: const Text('Return to account')),
                ]),
              if (view == _AccountView.receive &&
                  snapshot != null &&
                  !completed)
                panel([
                  Text('Separate KAS account balance',
                      style: Theme.of(context).textTheme.titleMedium),
                  Text(
                      snapshot!['balanceSompi'] == null
                          ? 'Unavailable'
                          : hiddenKasAmount(snapshot!['balanceSompi']),
                      style: Theme.of(context).textTheme.headlineMedium),
                  const Text(
                      'This balance is not part of your ordinary wallet balance.'),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                      style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(54)),
                      onPressed: busy
                          ? null
                          : () => run(() async {
                                final location = await service.security
                                    .exportEncryptedBackup();
                                if (!context.mounted || location == null) {
                                  return;
                                }
                                await showDialog<void>(
                                    context: context,
                                    builder: (c) => AlertDialog(
                                            title: const Text(
                                                'Encrypted backup saved'),
                                            content: Text(location),
                                            actions: [
                                              TextButton(
                                                  onPressed: () =>
                                                      Navigator.pop(c),
                                                  child: const Text('Done'))
                                            ]));
                              }),
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('Save encrypted recovery backup')),
                ]),
              if (snapshot != null && pending == null && !completed) ...[
                SegmentedButton<_AccountView>(
                    segments: const [
                      ButtonSegment(
                          value: _AccountView.receive, label: Text('Receive')),
                      ButtonSegment(
                          value: _AccountView.send, label: Text('Send')),
                      ButtonSegment(
                          value: _AccountView.activity,
                          label: Text('Activity')),
                    ],
                    showSelectedIcon: false,
                    selected: {view},
                    onSelectionChanged: busy
                        ? null
                        : (selection) {
                            setState(() => view = selection.single);
                            if (scroll.hasClients) scroll.jumpTo(0);
                          }),
                const SizedBox(height: 24),
              ],
              if (view == _AccountView.receive &&
                  receive != null &&
                  pending == null &&
                  !busy) ...[
                Hub21Readable(
                    child: Text('Receive KAS',
                        style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -.8))),
                const SizedBox(height: 8),
                const Hub21Readable(
                    child: Text(
                        'P2SH address · public key not published by this account')),
                const SizedBox(height: 34),
                KasReceiveRequest(address: receive!['address'].toString()),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(54)),
                    onPressed: busy
                        ? null
                        : () => run(() async {
                              await refresh();
                              final next =
                                  await service.security.issueHiddenKas(0);
                              if (mounted) setState(() => receive = next);
                            }),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Generate fresh receive address')),
              ],
              if (view == _AccountView.send &&
                  snapshot != null &&
                  pending == null &&
                  !completed) ...[
                Hub21Readable(
                    child: Text('Send KAS',
                        style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -.8))),
                const SizedBox(height: 8),
                const Hub21Readable(
                    child: Text(
                        'The native Rust core independently verifies UTXOs, outputs, change, fee and the approved review hash.')),
                const SizedBox(height: 28),
                TextField(
                    controller: recipient,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !busy,
                    onChanged: (_) => setState(() => prepared = null),
                    decoration: const InputDecoration(
                        labelText: 'Kaspa Mainnet address',
                        hintText: 'Long press to paste')),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(
                      child: TextField(
                          controller: amount,
                          enabled: !busy,
                          readOnly: sendAll,
                          onChanged: (_) => setState(() => prepared = null),
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: InputDecoration(
                              labelText: sendAll ? 'Amount (Max)' : 'Amount',
                              suffixText: 'KAS',
                              hintText: sendAll ? 'All spendable KAS' : null))),
                  const SizedBox(width: 10),
                  OutlinedButton(
                      onPressed: busy
                          ? null
                          : () => setState(() {
                                sendAll = !sendAll;
                                prepared = null;
                                amount.clear();
                              }),
                      child: Text(sendAll ? 'Cancel' : 'Max')),
                ]),
                const SizedBox(height: 5),
                Hub21Readable(
                    child: Row(children: [
                  const Text('Available', style: TextStyle(fontSize: 12)),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(
                          snapshot!['balanceSompi'] == null
                              ? 'Unavailable'
                              : hiddenKasAmount(snapshot!['balanceSompi']),
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 12))),
                ])),
                if (sendAll) ...[
                  const SizedBox(height: 8),
                  const Text(
                      'The network fee is deducted automatically. Review shows the exact amount; no change output is created.'),
                ],
                const SizedBox(height: 16),
                panel([
                  fact('Network', 'Kaspa Mainnet'),
                  fact('Fee', 'Live node estimate'),
                  fact('Signer', 'Rusty Kaspa v2.1.0'),
                ]),
                FilledButton.icon(
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(58)),
                    onPressed: busy
                        ? null
                        : () => run(() async {
                              final result = await service.prepare(
                                  recipient.text,
                                  sendAll
                                      ? 0
                                      : parseHiddenKasAmount(amount.text),
                                  sendAll: sendAll);
                              if (mounted) {
                                setState(() {
                                  prepared = result;
                                  if (sendAll) {
                                    amount.text = formatRawTokenAmount(
                                        BigInt.from(hiddenInt(hiddenMap(
                                            result['review'])['amountSompi'])),
                                        8);
                                  }
                                });
                              }
                            }),
                    icon: const Icon(Icons.shield_outlined),
                    label: const Text('Review transaction')),
                const SizedBox(height: 16),
              ],
              if (view == _AccountView.send && review != null)
                panel([
                  Text('Review payment',
                      style: Theme.of(context).textTheme.titleLarge),
                  line('Recipient', review['recipient'].toString()),
                  line(review['sendAll'] == true ? 'Amount (Max)' : 'Amount',
                      hiddenKasAmount(review['amountSompi'])),
                  line('Network fee', hiddenKasAmount(review['feeSompi'])),
                  if (hiddenInt(review['changeSompi']) > 0) ...[
                    line('Fresh P2SH change',
                        hiddenKasAmount(review['changeSompi'])),
                    line('Change address', review['changeAddress'].toString()),
                  ] else
                    const Text(
                        'No change output · entire spendable balance minus the network fee.'),
                  line('Inputs', review['inputCount'].toString()),
                  const Text(
                      'Signing reveals input public keys and permanently retires those addresses. All currently available account outputs are spent together.'),
                  FilledButton(
                      onPressed: busy
                          ? null
                          : () => run(() => completePayment(
                              () => service.signAndSubmit(prepared!))),
                      child: const Text('Authenticate, sign and send')),
                ]),
              if (view == _AccountView.activity &&
                  snapshot != null &&
                  pending == null &&
                  !completed)
                panel([
                  Text('Account activity',
                      style: Theme.of(context).textTheme.titleLarge),
                  if (transactions.isEmpty)
                    const Text('No confirmed activity found.'),
                  ...transactions.map((t) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                          t.incoming ? Icons.south_west : Icons.north_east),
                      title: Text(hiddenKasAmount(t.amountSompi.abs())),
                      subtitle: Text(t.id,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: IconButton(
                          tooltip: 'Copy transaction ID',
                          icon: const Icon(Icons.copy_outlined),
                          onPressed: () async {
                            await Clipboard.setData(ClipboardData(text: t.id));
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('Transaction ID copied')));
                          }))),
                ]),
            ]))));
  }
}
