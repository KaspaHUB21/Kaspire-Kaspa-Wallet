import 'package:flutter/material.dart';
import '../widgets/hub21_material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../theme.dart';
import '../services/network_settings.dart';
import '../services/app_settings.dart';
import '../services/hd_wallet_structure.dart';
import "../services/hd_discovery_service.dart";
import '../services/native_security.dart';
import '../models/kaspa_payment_request.dart';

class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({
    super.key,
    required this.address,
    this.onAccountChanged,
  });

  final String address;
  final VoidCallback? onAccountChanged;

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  final _amount = TextEditingController();
  final _security = NativeSecurity();
  NativeWalletInfo? _wallet;
  NativeHdAddress? _selected;
  List<NativeHdAddress> _receiveAddresses = const [];
  bool _loadingAddresses = true;
  bool _rotating = false;
  String? _rotationError;

  String get _selectedAddress => _selected == null
      ? widget.address
      : NetworkSettings.addressForNetwork(_selected!.address);

  String get paymentUri => KaspaPaymentRequest.encode(
        _selectedAddress,
        amount: _amount.text,
      );

  @override
  void initState() {
    super.initState();
    _loadReceiveAddresses();
  }

  @override
  void didUpdateWidget(covariant ReceiveScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameAddress(oldWidget.address, widget.address)) {
      _loadReceiveAddresses();
    }
  }

  bool _sameAddress(String left, String right) =>
      NetworkSettings.storageAddress(left).toLowerCase() ==
      NetworkSettings.storageAddress(right).toLowerCase();

  Future<void> _loadReceiveAddresses({String? selectAddress}) async {
    if (mounted) setState(() => _loadingAddresses = true);
    try {
      final target = selectAddress ?? widget.address;
      NativeWalletInfo? matchedWallet;
      NativeHdAddress? matchedAddress;
      for (final wallet in await _security.listWallets()) {
        if (_sameAddress(wallet.address, target)) {
          matchedWallet = wallet;
        }
        for (final address in wallet.addresses) {
          if (_sameAddress(address.address, target)) {
            matchedWallet = wallet;
            matchedAddress = address;
            break;
          }
        }
        if (matchedWallet != null) break;
      }
      if (matchedWallet == null || matchedWallet.kind != 'mnemonic') {
        if (mounted) {
          setState(() {
            _wallet = null;
            _selected = null;
            _receiveAddresses = const [];
            _loadingAddresses = false;
          });
        }
        return;
      }
      final wallet = matchedWallet;
      if (matchedAddress == null) {
        for (final address in wallet.addresses) {
          if (_sameAddress(address.address, wallet.address)) {
            matchedAddress = address;
            break;
          }
        }
      }
      final current = matchedAddress;
      if (current == null ||
          current.change != 0 ||
          (current.index != 0 && !current.receiveRotation)) {
        throw StateError(
            "Select the account primary address to rotate KAS receive addresses.");
      }
      final addresses = wallet.addresses
          .where((item) =>
              item.coinType == current.coinType &&
              item.account == current.account &&
              item.change == 0 &&
              (item.index == 0 || item.receiveRotation))
          .toList()
        ..sort((left, right) => left.index.compareTo(right.index));
      if (mounted) {
        setState(() {
          _wallet = wallet;
          _selected = current;
          _receiveAddresses = addresses;
          _loadingAddresses = false;
          _rotationError = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _loadingAddresses = false;
          _rotationError = error.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  Future<void> _rotateAddress() async {
    final wallet = _wallet;
    final selected = _selected;
    if (_rotating || wallet == null || selected == null) return;
    final authenticated = await _security.authenticate(
      context,
      'Generate a new receive address',
    );
    if (!authenticated || !mounted) return;
    setState(() {
      _rotating = true;
      _rotationError = null;
    });
    try {
      await _security.selectWallet(wallet.id);
      final freshWallet = (await _security.listWallets())
          .firstWhere((item) => item.id == wallet.id);
      final nextIndex = HdWalletStructure.nextSubwalletIndex(
        freshWallet.addresses,
        coinType: selected.coinType,
        account: selected.account,
      );
      if (!HdWalletStructure.isWithinDiscoveryGap(
        freshWallet.addresses,
        coinType: selected.coinType,
        account: selected.account,
        nextIndex: nextIndex,
        gapLimit: HdDiscoveryService.gapLimit,
      )) {
        throw StateError(
          "The safe unused-address limit has been reached. Receive funds on "
          "an existing address, then run Scan wallet before rotating again.",
        );
      }
      final derived = await _security.deriveAddresses(
        coinType: selected.coinType,
        account: selected.account,
        change: 0,
        start: nextIndex,
        count: 1,
      );
      if (derived.length != 1) {
        throw StateError('Address derivation returned no receive address.');
      }
      final rotated = derived.single.copyWith(
        explicit: true,
        receiveRotation: true,
      );
      final combined = <String, NativeHdAddress>{
        for (final item in freshWallet.addresses) item.derivationPath: item,
        rotated.derivationPath: rotated,
      }.values.toList();
      await _security.registerHdAddresses(combined);
      widget.onAccountChanged?.call();
      await _loadReceiveAddresses(selectAddress: rotated.address);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Receive address $nextIndex is ready.',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() =>
            _rotationError = error.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => _rotating = false);
    }
  }

  Future<void> _chooseReceiveAddress() async {
    if (_receiveAddresses.isEmpty) return;
    final chosen = await showModalBottomSheet<NativeHdAddress>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          children: [
            const ListTile(
              title: Text(
                'Receive addresses',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
              subtitle:
                  Text('All addresses belong to the same recovery phrase.'),
            ),
            ..._receiveAddresses.reversed.map(
              (address) => ListTile(
                leading: Icon(
                  address.receiveRotation
                      ? Icons.autorenew_rounded
                      : Icons.account_balance_wallet_outlined,
                ),
                title: Text(
                  address.index == 0
                      ? 'Primary receive address'
                      : 'Receive address ${address.index}',
                ),
                subtitle: Text(
                  '${address.derivationPath}\n${NetworkSettings.addressForNetwork(address.address)}',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: _selected?.derivationPath == address.derivationPath
                    ? const Icon(Icons.check_circle_rounded)
                    : null,
                onTap: () => Navigator.pop(context, address),
              ),
            ),
          ],
        ),
      ),
    );
    if (chosen != null && mounted) setState(() => _selected = chosen);
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const SizedBox(height: 8),
            Hub21Readable(
              child: const Text(
                'RECEIVE KAS',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -.8,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Hub21Readable(
              child: Text(
                NetworkSettings.isTestnet
                    ? 'Share this address for TN10 test KAS payments.'
                    : 'Share this address for Kaspa mainnet payments.',
                style: const TextStyle(color: KasVaultTheme.muted),
              ),
            ),
            if (_loadingAddresses) ...[
              const SizedBox(height: 18),
              const Hub21Readable(
                child: Text(
                  'Loading receive addresses…',
                  style: TextStyle(color: KasVaultTheme.muted),
                ),
              ),
            ],
            if (_wallet != null && _selected != null) ...[
              const SizedBox(height: 18),
              InkWell(
                onTap: _chooseReceiveAddress,
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: KasVaultTheme.panel,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: KasVaultTheme.line),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.account_tree_outlined),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _selected!.index == 0
                                  ? 'Primary receive address'
                                  : 'Receive address ${_selected!.index}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w900),
                            ),
                            Text(
                              _selected!.derivationPath,
                              style: const TextStyle(
                                color: KasVaultTheme.muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.expand_more_rounded),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 34),
            Center(
              child: Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: KasVaultTheme.mint.withValues(alpha: .33),
                      blurRadius: 40,
                    ),
                  ],
                ),
                child: QrImageView(
                  data: paymentUri,
                  size: 238,
                  eyeStyle: QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: KasVaultTheme.qrInk,
                  ),
                  dataModuleStyle: QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: KasVaultTheme.qrInk,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 30),
            TextField(
              controller: _amount,
              onChanged: (_) => setState(() {}),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Requested amount (optional)',
                suffixText: 'KAS',
                hintText: '0.00',
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(17),
              decoration: KasVaultTheme.isDecorative
                  ? kaspireDecorativeDecoration(radius: 18, rim: 2.5)
                  : BoxDecoration(
                      color: KasVaultTheme.panel,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: KasVaultTheme.line),
                    ),
              child: Text(
                _selectedAddress,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: KasVaultTheme.mint,
                  height: 1.45,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: paymentUri));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Payment request copied')),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded),
                    label: Text(buttonLabel('COPY')),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(54),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => Share.share(
                      paymentUri,
                      subject: 'Kaspa payment request',
                    ),
                    icon: const Icon(Icons.ios_share_rounded),
                    label: Text(buttonLabel('SHARE')),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(54),
                      backgroundColor: KasVaultTheme.mint,
                      foregroundColor: KasVaultTheme.filledButtonText,
                    ),
                  ),
                ),
              ],
            ),
            if (_wallet != null && _selected != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _rotating ? null : _rotateAddress,
                icon: _rotating
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.autorenew_rounded),
                label: Text(buttonLabel('GENERATE NEW RECEIVE ADDRESS')),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(54),
                ),
              ),
            ],
            if (_rotationError != null) ...[
              const SizedBox(height: 12),
              Text(
                _rotationError!,
                style: const TextStyle(color: Color(0xFFFF8A65)),
              ),
            ],
            const SizedBox(height: 20),
            Hub21Readable(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.info_outline,
                    size: 18,
                    color: KasVaultTheme.muted,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      NetworkSettings.isTestnet
                          ? 'Only send TN10 test KAS to this kaspatest: address.'
                          : _wallet == null
                              ? 'Only send Kaspa mainnet assets to this address. Always verify the first and last characters.'
                              : 'Rotated addresses are combined into one KAS account balance and activity history. Use the primary address for KRC20, KRC721, KNS and KCC20 assets while account-level asset spending remains under testing.',
                      style: const TextStyle(
                        color: KasVaultTheme.muted,
                        height: 1.4,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}
