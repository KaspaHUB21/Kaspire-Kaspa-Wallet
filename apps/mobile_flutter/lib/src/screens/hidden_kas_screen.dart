import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../models/wallet_snapshot.dart';
import '../number_format.dart';
import '../services/hidden_kas_service.dart';
import '../services/kaspa_api.dart';
import '../widgets/hub21_material.dart';

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
  const HiddenKasScreen({super.key, required this.address, this.service});
  final String address;
  final HiddenKasService? service;
  @override
  State<HiddenKasScreen> createState() => _HiddenKasScreenState();
}

class _HiddenKasScreenState extends State<HiddenKasScreen> {
  late final service = widget.service ?? HiddenKasService(widget.address);
  final recipient = TextEditingController(), amount = TextEditingController();
  Map<String, Object?>? snapshot, receive, prepared;
  List<WalletTransaction> transactions = [];
  String? error;
  bool busy = false, accepted = false, completed = false;
  bool eligibilityChecked = false, requiresHd = false;
  int checked = 0;
  @override
  void initState() {
    super.initState();
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
            error = message;
          }
          prepared = null;
          receive = null;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> refresh() async {
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
      child: Hub21Panel(
          child: Padding(
              padding: const EdgeInsets.all(18),
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
  @override
  Widget build(BuildContext context) {
    final state = snapshot == null ? null : hiddenMap(snapshot!['state']);
    final pending = state?['pending'];
    final review = prepared == null ? null : hiddenMap(prepared!['review']);
    return Scaffold(
        appBar: AppBar(title: const Text('Public-key-hidden KAS'), actions: [
          IconButton(
              tooltip: 'Refresh account',
              onPressed: busy || !accepted ? null : () => run(refresh),
              icon: const Icon(Icons.refresh)),
        ]),
        body: Hub21Backdrop(
            child: SafeArea(
                child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
                    children: [
              panel([
                Text('Experimental P2SH account',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 10),
                const Text(
                    'Receive KAS without publishing the spending public key. Signing reveals that key. This is NOT a post-quantum signature scheme.'),
                const SizedBox(height: 10),
                const Text(
                    'Separate KAS balance · no assets or dApps · Mainnet only. Existing wallet accounts remain unchanged. Test with small amounts only.'),
                const ExpansionTile(
                    title: Text('Recovery and key exposure'),
                    tilePadding: EdgeInsets.zero,
                    children: [
                      Text(
                          'Descriptor: kaspire-hidden-kas-v1\nDerivation: m/1214346033\'/111111\'/0\'/branch\'/index\'\nReceive branch 0 · change branch 1 · discovery gap 20.\n\nThis experimental format is not supported by other wallets. Seed discovery finds used addresses, but a seed alone cannot recover the history of signatures never broadcast. Keep a current Kaspire encrypted backup, which includes issued/retired addresses and saved transactions. Never use the same account on multiple devices at once.\n\nAll available account outputs are spent together, with fresh P2SH change. Retired addresses still track late payments, but must not be reused for receiving. A network failure never means “safe” or “zero balance”.'),
                    ]),
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
                          'I understand the experimental format and backup requirement.'),
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
                    child: Text('Checking account · $checked addresses'))
              ],
              if (error != null)
                panel([
                  SelectableText(error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                  const Text(
                      'Saved addresses and signed payments remain preserved. Refresh before trying again.'),
                  if (!eligibilityChecked)
                    OutlinedButton(
                        onPressed: busy ? null : () => run(checkWalletSupport),
                        child: const Text('Check wallet again')),
                ]),
              if (pending != null)
                panel([
                  const Icon(Icons.warning_amber_rounded, size: 38),
                  Text('Payment incomplete — action required',
                      style: Theme.of(context).textTheme.titleLarge),
                  const Text(
                      'Signed transaction saved. Resume sends the exact same bytes. Do not create another payment. Input keys are already retired.'),
                  SelectableText(
                      hiddenMap(pending)['transactionId'].toString()),
                  FilledButton.icon(
                      onPressed: busy
                          ? null
                          : () => run(() async {
                                await service.resume();
                                completed = true;
                                await refresh();
                              }),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Resume / check saved payment')),
                ]),
              if (completed)
                panel([
                  const Icon(Icons.check_circle_outline, size: 40),
                  const Text('Payment confirmed by the Kaspire node.'),
                  FilledButton(
                      onPressed: () => setState(() => completed = false),
                      child: const Text('Return to account')),
                ]),
              if (snapshot != null)
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
                  FilledButton.icon(
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
              if (receive != null && pending == null && !busy)
                panel([
                  Text('Receive KAS',
                      style: Theme.of(context).textTheme.titleLarge),
                  const Text(
                      'P2SH address · public key not published by this account'),
                  Center(
                      child: Container(
                          color: Colors.white,
                          padding: const EdgeInsets.all(12),
                          child: QrImageView(
                              data: receive!['address'].toString(),
                              size: 220,
                              eyeStyle: const QrEyeStyle(
                                  eyeShape: QrEyeShape.square,
                                  color: Colors.black),
                              dataModuleStyle: const QrDataModuleStyle(
                                  dataModuleShape: QrDataModuleShape.square,
                                  color: Colors.black)))),
                  SelectableText(receive!['address'].toString()),
                  OutlinedButton.icon(
                      onPressed: () => Clipboard.setData(
                          ClipboardData(text: receive!['address'].toString())),
                      icon: const Icon(Icons.copy),
                      label: const Text('Copy address')),
                  OutlinedButton.icon(
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
                ]),
              if (snapshot != null && pending == null && !completed)
                panel([
                  Text('Send KAS',
                      style: Theme.of(context).textTheme.titleLarge),
                  TextField(
                      controller: recipient,
                      enabled: !busy,
                      decoration: const InputDecoration(
                          labelText: 'Kaspa Mainnet address')),
                  const SizedBox(height: 12),
                  TextField(
                      controller: amount,
                      enabled: !busy,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration:
                          const InputDecoration(labelText: 'Amount in KAS')),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                      onPressed: busy
                          ? null
                          : () => run(() async {
                                final result = await service.prepare(
                                    recipient.text,
                                    parseHiddenKasAmount(amount.text));
                                if (mounted) setState(() => prepared = result);
                              }),
                      icon: const Icon(Icons.shield_outlined),
                      label: const Text('Review payment')),
                ]),
              if (review != null)
                panel([
                  Text('Review payment',
                      style: Theme.of(context).textTheme.titleLarge),
                  line('Recipient', review['recipient'].toString()),
                  line('Amount', hiddenKasAmount(review['amountSompi'])),
                  line('Network fee', hiddenKasAmount(review['feeSompi'])),
                  line('Fresh P2SH change',
                      hiddenKasAmount(review['changeSompi'])),
                  line('Change address', review['changeAddress'].toString()),
                  line('Inputs', review['inputCount'].toString()),
                  const Text(
                      'Signing reveals input public keys and permanently retires those addresses. All currently available account outputs are spent together.'),
                  FilledButton(
                      onPressed: busy
                          ? null
                          : () => run(() async {
                                try {
                                  await service.signAndSubmit(prepared!);
                                  completed = true;
                                } finally {
                                  await refresh();
                                }
                              }),
                      child: const Text('Authenticate, sign and send')),
                ]),
              if (snapshot != null)
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
                          maxLines: 2, overflow: TextOverflow.ellipsis))),
                ]),
            ]))));
  }
}
