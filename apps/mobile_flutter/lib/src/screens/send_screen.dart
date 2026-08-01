import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/asset_send_intent.dart';
import '../decimal_input_formatter.dart';
import '../models/kaspa_payment_request.dart';
import '../models/wallet_snapshot.dart';
import '../number_format.dart';
import '../services/kaspa_api.dart';
import '../services/native_security.dart';
import '../services/signer_service.dart';
import '../services/activity_store.dart';
import '../theme.dart';
import '../services/app_settings.dart';
import '../services/preferences_service.dart';
import 'asset_send_screen.dart';
import 'qr_scanner_screen.dart';
import 'address_book_screen.dart';

class SendScreen extends StatefulWidget {
  const SendScreen({
    super.key,
    required this.address,
    required this.onDone,
    this.initialAsset,
  });
  final String address;
  final VoidCallback onDone;
  final AssetSendIntent? initialAsset;

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        initialIndex: widget.initialAsset == null ? 0 : 1,
        child: Column(
          children: [
            const SafeArea(
              bottom: false,
              child: TabBar(tabs: [Tab(text: 'KAS'), Tab(text: 'ASSETS')]),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _KasSendPanel(address: widget.address, onDone: widget.onDone),
                  AssetSendScreen(
                    address: widget.address,
                    onDone: widget.onDone,
                    initialAsset: widget.initialAsset,
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}

class _KasSendPanel extends StatefulWidget {
  const _KasSendPanel({required this.address, required this.onDone});
  final String address;
  final VoidCallback onDone;
  @override
  State<_KasSendPanel> createState() => _KasSendPanelState();
}

class _KasSendPanelState extends State<_KasSendPanel> {
  final _recipient = TextEditingController();
  final _amount = TextEditingController();
  final _api = KaspaApi();
  final _signer = SignerService();
  final _security = NativeSecurity();
  final _preferences = PreferencesService();
  String? _error;
  _PaymentReceipt? _receipt;
  bool _working = false;
  bool _sendAll = false;
  late final Future<WalletSnapshot> _wallet = _api.loadWallet(widget.address);

  @override
  void dispose() {
    _recipient.dispose();
    _amount.dispose();
    super.dispose();
  }

  int? _sompi(String raw) {
    final normalized = raw.trim().replaceAll(',', '.');
    if (!RegExp(r'^\d+(\.\d{1,8})?$').hasMatch(normalized)) return null;
    final parts = normalized.split('.');
    final whole = int.tryParse(parts[0]);
    if (whole == null) return null;
    final fraction = parts.length == 2 ? parts[1].padRight(8, '0') : '00000000';
    return whole * 100000000 + int.parse(fraction);
  }

  Future<void> _scanPayment() async {
    final value = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );
    if (value == null) return;
    final request = KaspaPaymentRequest.tryParse(value);
    if (request == null) return;
    setState(() {
      _recipient.text = request.address;
      if (request.amount != null) {
        _amount.text = request.amount!;
        _sendAll = false;
      }
    });
  }

  Future<void> _chooseContact() async {
    final address = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => const AddressBookScreen(selectAddress: true),
      ),
    );
    if (address != null) _recipient.text = address;
  }

  Future<void> _review() async {
    final paymentRequest = KaspaPaymentRequest.tryParse(_recipient.text);
    if (paymentRequest?.amount != null && _amount.text.trim().isEmpty) {
      _amount.text = paymentRequest!.amount!;
    }
    final amountSompi = _sendAll ? 0 : _sompi(_amount.text);
    if (!_sendAll && (amountSompi == null || amountSompi <= 0)) {
      setState(
        () => _error = 'Enter an amount with no more than 8 decimal places.',
      );
      return;
    }
    setState(() {
      _working = true;
      _error = null;
      _receipt = null;
    });
    final String recipient;
    try {
      recipient = paymentRequest?.address ??
          await _api.resolveWalletInput(_recipient.text);
      if (AppSettings.recipientAllowlist.value &&
          !await _preferences.isAddressBookRecipient(recipient)) {
        throw StateError(
          'This recipient is not in your address book. Add it first or '
          'disable the recipient allowlist.',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _working = false;
          _error = error.toString();
        });
      }
      return;
    }
    if (!await _security.hasNativeWalletFor(widget.address)) {
      setState(
        () {
          _working = false;
          _error =
              'This is a watch-only address. Import or create the matching native wallet first.';
        },
      );
      return;
    }
    String? trackedTransactionId;
    try {
      final results = await Future.wait([
        _api.loadUtxos(widget.address),
        _api.loadFeeRate(),
      ]);
      final prepared = await _signer.prepare(
        sender: widget.address,
        recipient: recipient,
        amountSompi: amountSompi!,
        feeRate: results[1] as double,
        utxosJson: results[0] as String,
        sendAll: _sendAll,
      );
      if (!mounted) return;
      final approved = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) =>
            _ConfirmPayment(recipient: recipient, payment: prepared),
      );
      if (approved != true) return;
      if (!mounted) return;
      final signed = await _signer.sign(prepared);
      trackedTransactionId = signed.transactionId;
      await ActivityStore().recordKasTransfer(
        wallet: widget.address,
        recipient: recipient,
        transactionId: signed.transactionId,
        amountSompi: prepared.amountSompi,
        timestamp: DateTime.now(),
        status: TransactionStatus.pending,
      );
      final broadcastId = await _api.broadcast(signed.submitJson);
      if (broadcastId.isNotEmpty && broadcastId != signed.transactionId) {
        throw StateError('Node returned a mismatching transaction ID.');
      }
      await ActivityStore().updateStatus(
        signed.transactionId,
        TransactionStatus.accepted,
      );
      if (mounted) {
        setState(
          () => _receipt = _PaymentReceipt(
            transactionId: signed.transactionId,
            sender: widget.address,
            recipient: recipient,
            amountSompi: prepared.amountSompi,
            feeSompi: prepared.feeSompi,
            changeSompi: prepared.changeSompi,
            mass: prepared.mass,
            inputCount: prepared.inputCount,
            outputCount: prepared.outputCount,
            sentAt: DateTime.now(),
          ),
        );
        _recipient.clear();
        _amount.clear();
      }
    } catch (error) {
      if (trackedTransactionId != null) {
        await ActivityStore().updateStatus(
          trackedTransactionId,
          TransactionStatus.failed,
        );
      }
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final receipt = _receipt;
    if (receipt != null) {
      return _PaymentSuccess(
        receipt: receipt,
        onDone: () {
          setState(() => _receipt = null);
          widget.onDone();
        },
      );
    }
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 8),
          Text(
            displayLabel('SEND KAS'),
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w900,
              letterSpacing: -.8,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'The native Rust core independently verifies UTXOs, outputs, change, fee and the approved review hash.',
            style: TextStyle(color: KasVaultTheme.muted, height: 1.4),
          ),
          const SizedBox(height: 28),
          TextField(
            controller: _recipient,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Address / KNS name',
              hintText: 'Long press to paste',
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    onPressed: _chooseContact,
                    tooltip: 'Address book',
                    icon: const Icon(Icons.contacts_outlined),
                  ),
                  IconButton(
                    onPressed: _scanPayment,
                    tooltip: 'Scan payment QR',
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _amount,
                  enabled: !_sendAll,
                  onChanged: (_) {
                    if (_sendAll) setState(() => _sendAll = false);
                  },
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [DecimalInputFormatter(decimalPlaces: 8)],
                  decoration: InputDecoration(
                    labelText: 'Amount',
                    hintText: _sendAll ? 'Entire spendable balance' : '0.00',
                    suffixText: 'KAS',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: () async {
                  if (_sendAll) {
                    setState(() {
                      _sendAll = false;
                      _amount.clear();
                    });
                    return;
                  }
                  try {
                    final wallet = await _wallet;
                    if (!mounted) return;
                    setState(() {
                      _sendAll = true;
                      _amount.text = formatEnglishNumber(
                        wallet.balanceKas,
                        decimals: 8,
                        trimTrailingZeros: true,
                      );
                    });
                  } catch (error) {
                    if (mounted) setState(() => _error = '$error');
                  }
                },
                child: Text(buttonLabel(_sendAll ? 'CANCEL' : 'MAX')),
              ),
            ],
          ),
          const SizedBox(height: 5),
          FutureBuilder<WalletSnapshot>(
            future: _wallet,
            builder: (context, snapshot) => Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Available',
                  style: TextStyle(color: KasVaultTheme.muted, fontSize: 12),
                ),
                Text(
                  snapshot.hasData
                      ? '${formatEnglishNumber(snapshot.data!.balanceKas, decimals: 8, trimTrailingZeros: true)} KAS'
                      : '— KAS',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(17),
            decoration: BoxDecoration(
              color: KasVaultTheme.panel,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: KasVaultTheme.line),
            ),
            child: const Column(
              children: [
                _SendFact(label: 'Network', value: 'Kaspa Mainnet'),
                SizedBox(height: 12),
                _SendFact(label: 'Fee', value: 'Live node estimate'),
                SizedBox(height: 12),
                _SendFact(label: 'Signer', value: 'Rusty Kaspa v2.0.1'),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                _error!,
                style: const TextStyle(color: Color(0xFFFF8A65), height: 1.35),
              ),
            ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _working ? null : _review,
            icon: _working
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.shield_outlined),
            label: Text(buttonLabel(
              _working ? 'PREPARING…' : 'REVIEW TRANSACTION',
            )),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(58),
              backgroundColor: KasVaultTheme.mint,
              foregroundColor: KasVaultTheme.ink,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'For the first Mainnet test, send the smallest practical amount to an address you control.',
            textAlign: TextAlign.center,
            style: TextStyle(color: KasVaultTheme.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _PaymentReceipt {
  const _PaymentReceipt({
    required this.transactionId,
    required this.sender,
    required this.recipient,
    required this.amountSompi,
    required this.feeSompi,
    required this.changeSompi,
    required this.mass,
    required this.inputCount,
    required this.outputCount,
    required this.sentAt,
  });

  final String transactionId;
  final String sender;
  final String recipient;
  final int amountSompi;
  final int feeSompi;
  final int changeSompi;
  final int mass;
  final int inputCount;
  final int outputCount;
  final DateTime sentAt;

  String kas(int sompi) => formatSompi(sompi);
}

class _PaymentSuccess extends StatelessWidget {
  const _PaymentSuccess({required this.receipt, required this.onDone});
  final _PaymentReceipt receipt;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 32),
          children: [
            Center(
              child: CircleAvatar(
                radius: 38,
                backgroundColor: KasVaultTheme.mint.withValues(alpha: .13),
                child: Icon(
                  Icons.check_rounded,
                  size: 48,
                  color: KasVaultTheme.mint,
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'PAYMENT SENT',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 7),
            Text(
              'Broadcast accepted by the Kaspa Mainnet node',
              textAlign: TextAlign.center,
              style: TextStyle(color: KasVaultTheme.mint),
            ),
            const SizedBox(height: 26),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: KasVaultTheme.panel,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: KasVaultTheme.mint.withValues(alpha: .4),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ReceiptAddress('FROM WALLET', receipt.sender),
                  const Divider(height: 28),
                  _ReceiptAddress('RECIPIENT', receipt.recipient),
                  const Divider(height: 28),
                  _ReviewRow(
                    'Amount sent',
                    '${receipt.kas(receipt.amountSompi)} KAS',
                  ),
                  const SizedBox(height: 11),
                  _ReviewRow(
                    'Network fee',
                    '${receipt.kas(receipt.feeSompi)} KAS',
                  ),
                  const SizedBox(height: 11),
                  _ReviewRow(
                    'Total debit',
                    '${receipt.kas(receipt.amountSompi + receipt.feeSompi)} KAS',
                  ),
                  const SizedBox(height: 11),
                  _ReviewRow(
                    'Change',
                    '${receipt.kas(receipt.changeSompi)} KAS',
                  ),
                  const SizedBox(height: 11),
                  _ReviewRow('Network', 'Kaspa Mainnet'),
                  const SizedBox(height: 11),
                  _ReviewRow(
                    'Inputs / outputs',
                    '${receipt.inputCount} / ${receipt.outputCount}',
                  ),
                  const SizedBox(height: 11),
                  _ReviewRow('Mass', '${receipt.mass}'),
                  const SizedBox(height: 11),
                  _ReviewRow(
                    'Time',
                    receipt.sentAt.toLocal().toString().split('.').first,
                  ),
                  const Divider(height: 28),
                  _ReceiptAddress('TRANSACTION ID', receipt.transactionId),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: receipt.transactionId),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Transaction ID copied')),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded),
                    label: Text(buttonLabel('COPY TX ID')),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onDone,
              icon: const Icon(Icons.account_balance_wallet_rounded),
              label: Text(buttonLabel('BACK TO WALLET')),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(58),
                backgroundColor: KasVaultTheme.mint,
                foregroundColor: KasVaultTheme.ink,
              ),
            ),
          ],
        ),
      );
}

class _ReceiptAddress extends StatelessWidget {
  const _ReceiptAddress(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: KasVaultTheme.muted,
              fontSize: 11,
              fontWeight: FontWeight.w900,
              letterSpacing: .8,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            value,
            style: TextStyle(
              color: KasVaultTheme.mint,
              fontFamily: 'monospace',
              fontSize: 12,
            ),
          ),
        ],
      );
}

class _ConfirmPayment extends StatelessWidget {
  const _ConfirmPayment({required this.recipient, required this.payment});
  final String recipient;
  final PreparedPayment payment;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.shield_outlined, color: KasVaultTheme.mint),
            const SizedBox(width: 10),
            const Text('Confirm payment'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'RECIPIENT',
                style: TextStyle(
                  color: KasVaultTheme.muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 7),
              SelectableText(
                recipient,
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: KasVaultTheme.mint,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 20),
              _ReviewRow(
                  'Amount', '${formatEnglishNumber(payment.amountKas)} KAS'),
              const SizedBox(height: 10),
              _ReviewRow(
                  'Network fee', '${formatEnglishNumber(payment.feeKas)} KAS'),
              const SizedBox(height: 10),
              _ReviewRow(
                  'Change', '${formatEnglishNumber(payment.changeKas)} KAS'),
              const SizedBox(height: 10),
              _ReviewRow(
                'Inputs / outputs',
                '${payment.inputCount} / ${payment.outputCount}',
              ),
              const SizedBox(height: 10),
              _ReviewRow('Mass', '${payment.mass}'),
              const SizedBox(height: 18),
              Text(
                'Review ID ${payment.reviewHash.substring(0, 12)}…',
                style:
                    const TextStyle(color: KasVaultTheme.muted, fontSize: 11),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(buttonLabel('CANCEL')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(buttonLabel('AUTHORIZE')),
          ),
        ],
      );
}

class _ReviewRow extends StatelessWidget {
  const _ReviewRow(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Row(
        children: [
          Text(label, style: const TextStyle(color: KasVaultTheme.muted)),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      );
}

class _SendFact extends StatelessWidget {
  const _SendFact({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: KasVaultTheme.muted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      );
}
