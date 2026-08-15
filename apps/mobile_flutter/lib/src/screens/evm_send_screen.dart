import 'package:flutter/material.dart';

import '../decimal_input_formatter.dart';
import '../services/app_settings.dart';
import '../services/evm_api.dart';
import '../services/native_security.dart';
import '../theme.dart';
import 'qr_scanner_screen.dart';

class EvmSendScreen extends StatefulWidget {
  const EvmSendScreen(
      {super.key, required this.initialToken, required this.onDone});
  final EvmToken? initialToken;
  final VoidCallback onDone;
  @override
  State<EvmSendScreen> createState() => _EvmSendScreenState();
}

class _EvmSendScreenState extends State<EvmSendScreen> {
  final _security = NativeSecurity();
  final _api = EvmApi();
  late Future<String> _address;
  late Future<EvmSnapshot> _snapshot;

  @override
  void initState() {
    super.initState();
    _address = _security.getEvmAddress();
    _snapshot = _address.then(_api.loadWallet);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
        future: _address,
        builder: (context, address) => FutureBuilder<EvmSnapshot>(
          future: _snapshot,
          builder: (context, snapshot) {
            if (!address.hasData || !snapshot.hasData) {
              if (address.hasError || snapshot.hasError) {
                return Center(
                    child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text('${address.error ?? snapshot.error}')));
              }
              return const Center(child: CircularProgressIndicator());
            }
            return DefaultTabController(
              length: 2,
              initialIndex: widget.initialToken == null ? 0 : 1,
              child: Column(children: [
                SafeArea(
                    bottom: false,
                    child: TabBar(tabs: [
                      Tab(text: EvmNetworkConfig.current.nativeSymbol),
                      const Tab(text: 'ASSETS')
                    ])),
                Expanded(
                    child: TabBarView(children: [
                  _EvmSendPanel(
                      address: address.data!,
                      snapshot: snapshot.data!,
                      onDone: widget.onDone),
                  _EvmAssetPanel(
                      address: address.data!,
                      snapshot: snapshot.data!,
                      initialToken: widget.initialToken,
                      onDone: widget.onDone),
                ])),
              ]),
            );
          },
        ),
      );
}

class _EvmAssetPanel extends StatefulWidget {
  const _EvmAssetPanel(
      {required this.address,
      required this.snapshot,
      required this.initialToken,
      required this.onDone});
  final String address;
  final EvmSnapshot snapshot;
  final EvmToken? initialToken;
  final VoidCallback onDone;
  @override
  State<_EvmAssetPanel> createState() => _EvmAssetPanelState();
}

class _EvmAssetPanelState extends State<_EvmAssetPanel> {
  EvmToken? _selected;
  @override
  void initState() {
    super.initState();
    _selected = widget.initialToken ??
        widget.snapshot.tokens.where((t) => t.trusted).firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final tokens =
        widget.snapshot.tokens.where((token) => token.trusted).toList();
    if (tokens.isEmpty) {
      return const Center(child: Text('No supported assets found.'));
    }
    return Column(children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
          child: DropdownButtonFormField<EvmToken>(
              initialValue: _selected,
              decoration: const InputDecoration(labelText: 'Asset'),
              items: tokens
                  .map((token) => DropdownMenuItem(
                      value: token,
                      child: Text(
                          '${token.symbol} · ${formatUnits(token.rawBalance, token.decimals)}')))
                  .toList(),
              onChanged: (token) => setState(() => _selected = token))),
      Expanded(
          child: _EvmSendPanel(
              key: ValueKey(_selected?.contract),
              address: widget.address,
              snapshot: widget.snapshot,
              token: _selected,
              onDone: widget.onDone)),
    ]);
  }
}

class _EvmSendPanel extends StatefulWidget {
  const _EvmSendPanel(
      {super.key,
      required this.address,
      required this.snapshot,
      required this.onDone,
      this.token});
  final String address;
  final EvmSnapshot snapshot;
  final EvmToken? token;
  final VoidCallback onDone;
  @override
  State<_EvmSendPanel> createState() => _EvmSendPanelState();
}

class _EvmSendPanelState extends State<_EvmSendPanel> {
  final _recipient = TextEditingController();
  final _amount = TextEditingController();
  final _api = EvmApi();
  final _security = NativeSecurity();
  String? _error;
  bool _working = false;
  _EvmReceipt? _receipt;

  String get _symbol =>
      widget.token?.symbol ?? EvmNetworkConfig.current.nativeSymbol;
  BigInt get _balance =>
      widget.token?.rawBalance ?? widget.snapshot.nativeBalance;
  int get _decimals => widget.token?.decimals ?? 18;

  @override
  void dispose() {
    _recipient.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final value = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const QrScannerScreen()));
    if (value != null &&
        RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(value.trim())) {
      _recipient.text = value.trim();
    }
  }

  Future<void> _max() async {
    var maximum = _balance;
    if (widget.token == null) {
      try {
        final fee = await _api.gasPrice() * BigInt.from(21000);
        maximum = maximum > fee ? maximum - fee : BigInt.zero;
      } catch (_) {}
    }
    _amount.text = formatUnits(maximum, _decimals, visible: _decimals);
  }

  Future<void> _review() async {
    setState(() {
      _working = true;
      _error = null;
      _receipt = null;
    });
    try {
      final to = _recipient.text.trim();
      if (!RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(to)) {
        throw const FormatException('Enter a valid 0x address.');
      }
      final amount = parseUnits(_amount.text, _decimals);
      if (amount <= BigInt.zero || amount > _balance) {
        throw StateError('Insufficient balance.');
      }
      final data =
          widget.token == null ? '' : EvmApi.erc20TransferData(to, amount);
      final transactionTo = widget.token?.contract ?? to;
      final value = widget.token == null ? amount : BigInt.zero;
      final results = await Future.wait([
        _api.nonce(widget.address),
        _api.gasPrice(),
        _api.estimateGas(widget.address, transactionTo, value.toString(), data)
      ]);
      final fee = results[1] * results[2];
      if (fee + (widget.token == null ? amount : BigInt.zero) >
          widget.snapshot.nativeBalance) {
        throw StateError(
            'Insufficient ${EvmNetworkConfig.current.nativeSymbol} for amount and network fee.');
      }
      final request = <String, Object?>{
        'walletAddress': '',
        'from': widget.address,
        'to': transactionTo,
        'recipient': to,
        'valueWei': value.toString(),
        'nonce': results[0].toInt(),
        'gasLimit': results[2].toInt(),
        'gasPriceWei': results[1].toString(),
        'chainId': EvmNetworkConfig.current.chainId,
        'data': data,
        'tokenSymbol': _symbol,
        'displayAmount': _amount.text.trim(),
      };
      final prepared = await _security.prepareEvmTransaction(request);
      if (!mounted) return;
      final approved = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
                  title: Text('Review $_symbol transfer'),
                  content: SelectableText(
                      'From\n${widget.address}\n\nTo\n$to\n\nAmount\n${_amount.text.trim()} $_symbol\n\nNetwork\n${EvmNetworkConfig.current.name}\n\nNetwork fee (maximum)\n${formatUnits(fee, 18, visible: 18)} ${EvmNetworkConfig.current.nativeSymbol}\n\nGas limit\n${prepared['gasLimit']}\n\nGas price\n${prepared['gasPriceWei']} wei\n\nNonce\n${prepared['nonce']}'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(buttonLabel('CANCEL'))),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: Text(buttonLabel('SIGN & SEND')))
                  ]));
      if (approved != true) return;
      final signed = await _security.signEvmTransaction(
          request, '${prepared['reviewHash']}');
      final txid = await _api.broadcast('${signed['rawTransaction']}');
      final receipt = await _api.waitForReceipt(txid);
      if (!mounted) return;
      setState(() => _receipt = _EvmReceipt(
          txid: txid,
          from: widget.address,
          to: to,
          amount: _amount.text.trim(),
          symbol: _symbol,
          fee: fee,
          block: '${receipt['blockNumber']}'));
    } catch (error) {
      if (mounted) {
        setState(() => _error = error
            .toString()
            .replaceFirst('Bad state: ', '')
            .replaceFirst('FormatException: ', ''));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      ListView(padding: const EdgeInsets.fromLTRB(20, 22, 20, 40), children: [
        Text('SEND $_symbol',
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
        const SizedBox(height: 18),
        TextField(
            controller: _recipient,
            autocorrect: false,
            decoration: InputDecoration(
                labelText: 'Address',
                hintText: '0x…',
                suffixIcon: IconButton(
                    onPressed: _scan,
                    icon: const Icon(Icons.qr_code_scanner_rounded)))),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
              child: TextField(
                  controller: _amount,
                  inputFormatters: [
                    DecimalInputFormatter(decimalPlaces: _decimals)
                  ],
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'Amount', hintText: '0.00'))),
          const SizedBox(width: 12),
          OutlinedButton(onPressed: _max, child: const Text('MAX'))
        ]),
        const SizedBox(height: 7),
        Text(
            'Available ${formatUnits(_balance, _decimals, visible: _decimals)} $_symbol',
            textAlign: TextAlign.right,
            style: const TextStyle(color: KasVaultTheme.muted, fontSize: 12)),
        const SizedBox(height: 20),
        Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
                color: KasVaultTheme.panel,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: KasVaultTheme.line)),
            child: Column(children: [
              _InfoRow(label: 'Network', value: EvmNetworkConfig.current.name),
              const SizedBox(height: 10),
              const _InfoRow(label: 'Fee', value: 'Live RPC estimate'),
              const SizedBox(height: 10),
              const _InfoRow(label: 'Signer', value: 'Native Rust EIP-155'),
            ])),
        if (_error != null)
          Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(_error!,
                  style: const TextStyle(color: Colors.orangeAccent))),
        const SizedBox(height: 18),
        FilledButton.icon(
            onPressed: _working ? null : _review,
            icon: _working
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.verified_user_outlined),
            label: Text(buttonLabel('REVIEW TRANSFER'))),
        if (_receipt != null) ...[
          const SizedBox(height: 20),
          _ReceiptCard(receipt: _receipt!, onDone: widget.onDone)
        ],
      ]);
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Row(children: [
        Text(label, style: const TextStyle(color: KasVaultTheme.muted)),
        const Spacer(),
        Flexible(
            child: Text(value,
                textAlign: TextAlign.right,
                style: const TextStyle(fontWeight: FontWeight.w800)))
      ]);
}

class _EvmReceipt {
  const _EvmReceipt(
      {required this.txid,
      required this.from,
      required this.to,
      required this.amount,
      required this.symbol,
      required this.fee,
      required this.block});
  final String txid, from, to, amount, symbol, block;
  final BigInt fee;
}

class _ReceiptCard extends StatelessWidget {
  const _ReceiptCard({required this.receipt, required this.onDone});
  final _EvmReceipt receipt;
  final VoidCallback onDone;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
          color: KasVaultTheme.panel,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Theme.of(context).colorScheme.primary)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('TRANSACTION CONFIRMED',
            style: TextStyle(fontWeight: FontWeight.w900)),
        const SizedBox(height: 12),
        SelectableText(
            'Transaction ID\n${receipt.txid}\n\nFrom\n${receipt.from}\n\nTo\n${receipt.to}\n\nAmount\n${receipt.amount} ${receipt.symbol}\n\nMaximum fee\n${formatUnits(receipt.fee, 18, visible: 18)} ${EvmNetworkConfig.current.nativeSymbol}\n\nBlock\n${receipt.block}'),
        const SizedBox(height: 14),
        SizedBox(
            width: double.infinity,
            child: FilledButton(
                onPressed: onDone, child: Text(buttonLabel('DONE')))),
      ]));
}
