import 'package:flutter/material.dart';
import '../widgets/hub21_material.dart';
import '../widgets/kas_receive_request.dart';

import '../theme.dart';
import '../services/network_settings.dart';
import '../services/app_settings.dart';
import '../services/hd_wallet_structure.dart';
import "../services/hd_discovery_service.dart";
import '../services/native_security.dart';
import '../services/kaspa_api.dart';
import '../services/preferences_service.dart';
import '../platform.dart';
import 'hidden_kas_screen.dart';

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
  final _security = NativeSecurity();
  final _api = KaspaApi();
  final _preferences = PreferencesService();
  NativeWalletInfo? _wallet;
  NativeHdAddress? _selected;
  List<NativeHdAddress> _receiveAddresses = const [];
  bool _loadingAddresses = true;
  bool _rotating = false;
  bool _p2sh = false;
  String? _rotationError;
  Map<String, String> _receiveAddressNames = const {};
  Map<String, bool> _receiveAddressUsageKnown = const {};

  String get _selectedAddress => _selected == null
      ? widget.address
      : NetworkSettings.addressForNetwork(_selected!.address);

  @override
  void initState() {
    super.initState();
    _loadReceiveAddresses();
  }

  @override
  void didUpdateWidget(covariant ReceiveScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameAddress(oldWidget.address, widget.address)) {
      _p2sh = false;
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
      var addresses = wallet.addresses
          .where((item) =>
              item.coinType == current.coinType &&
              item.account == current.account &&
              item.change == 0 &&
              (item.index == 0 || item.receiveRotation))
          .toList()
        ..sort((left, right) => left.index.compareTo(right.index));
      final names = await _preferences.getSubwalletNames();
      final activity = await Future.wait<bool?>(
        addresses.map(
          (item) async {
            if (item.used) return true;
            try {
              return await _api
                  .addressHasActivity(item.address)
                  .timeout(const Duration(seconds: 8));
            } catch (_) {
              return null;
            }
          },
        ),
      );
      addresses = List<NativeHdAddress>.generate(
        addresses.length,
        (index) => addresses[index].copyWith(
          used: addresses[index].used || activity[index] == true,
        ),
      );
      if (mounted) {
        setState(() {
          _wallet = wallet;
          _selected = current;
          _receiveAddresses = addresses;
          _receiveAddressNames = names;
          _receiveAddressUsageKnown = {
            for (var index = 0; index < addresses.length; index++)
              addresses[index].address.toLowerCase():
                  addresses[index].used || activity[index] != null,
          };
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

  String _addressLabel(NativeHdAddress address) =>
      _receiveAddressNames[address.address.toLowerCase()] ??
      (address.index == 0
          ? 'Primary receive address'
          : 'Receive address ${address.index}');

  Future<void> _renameReceiveAddress(NativeHdAddress address) async {
    if (address.index == 0) return;
    final controller = TextEditingController(text: _addressLabel(address));
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename receive address'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(labelText: 'Address name'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(buttonLabel('CANCEL')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(buttonLabel('SAVE')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    try {
      await _preferences.renameSubwallet(address.address, name);
      await _loadReceiveAddresses(selectAddress: _selectedAddress);
    } catch (error) {
      if (mounted) {
        setState(() =>
            _rotationError = error.toString().replaceFirst('Bad state: ', ''));
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
      isScrollControlled: true,
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
                title: Row(
                  children: [
                    Expanded(child: Text(_addressLabel(address))),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 96,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Chip(
                          visualDensity: VisualDensity.compact,
                          label: Text(
                            address.used
                                ? 'Used'
                                : (_receiveAddressUsageKnown[
                                            address.address.toLowerCase()] ??
                                        false)
                                    ? 'Unused'
                                    : 'Not checked',
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(address.derivationPath),
                    const SizedBox(height: 3),
                    SelectableText(
                      NetworkSettings.addressForNetwork(address.address),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (address.index > 0)
                      IconButton(
                        tooltip: 'Rename receive address',
                        onPressed: () async {
                          Navigator.pop(context);
                          await _renameReceiveAddress(address);
                        },
                        icon: const Icon(Icons.edit_outlined),
                      ),
                    if (_selected?.derivationPath == address.derivationPath)
                      const Icon(Icons.check_circle_rounded),
                  ],
                ),
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
  Widget build(BuildContext context) => SafeArea(
        child: Column(children: [
          if (!isWindowsDesktop &&
              NetworkSettings.network.value == KaspaNetwork.mainnet)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Receive KAS')),
                    ButtonSegment(value: true, label: Text('P2SH account')),
                  ],
                  selected: {_p2sh},
                  onSelectionChanged: (selection) =>
                      setState(() => _p2sh = selection.single),
                ),
              ),
            ),
          Expanded(
              child: _p2sh &&
                      NetworkSettings.network.value == KaspaNetwork.mainnet
                  ? HiddenKasScreen(
                      key: ValueKey(widget.address),
                      address: widget.address,
                      embedded: true)
                  : ListView(
                      padding: const EdgeInsets.all(20),
                      children: [
                        const SizedBox(height: 8),
                        Hub21Readable(
                          child: const Text(
                            'Receive KAS',
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
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _addressLabel(_selected!),
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w900),
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
                        KasReceiveRequest(address: _selectedAddress),
                        if (_wallet != null && _selected != null) ...[
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: _rotating ? null : _rotateAddress,
                            icon: _rotating
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.autorenew_rounded),
                            label: Text(
                                buttonLabel('GENERATE NEW RECEIVE ADDRESS')),
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
                    )),
        ]),
      );
}
