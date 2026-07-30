import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/kaspa_api.dart';
import '../services/hd_discovery_service.dart';
import '../services/hd_wallet_structure.dart';
import '../services/native_security.dart';
import '../services/preferences_service.dart';
import '../services/app_settings.dart';
import '../theme.dart';

class WalletManagerScreen extends StatefulWidget {
  const WalletManagerScreen({
    super.key,
    required this.currentAddress,
    required this.onWalletChanged,
  });
  final String currentAddress;
  final VoidCallback onWalletChanged;

  @override
  State<WalletManagerScreen> createState() => _WalletManagerScreenState();
}

class _WalletManagerScreenState extends State<WalletManagerScreen> {
  final _security = NativeSecurity();
  final _preferences = PreferencesService();
  List<NativeWalletInfo> _native = const [];
  List<WatchWalletInfo> _watch = const [];
  bool _loading = true;
  bool _working = false;
  String? _workingLabel;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        _security.listWallets(),
        _preferences.getWatchWallets(),
      ]);
      if (mounted) {
        setState(() {
          _native = results[0] as List<NativeWalletInfo>;
          _watch = results[1] as List<WatchWalletInfo>;
          _loading = false;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$error';
        });
      }
    }
  }

  Future<void> _selectNative(
    NativeWalletInfo wallet, {
    String? address,
  }) async {
    await _security.selectWallet(wallet.id);
    await _selectAddress(address ?? wallet.address);
  }

  Future<void> _selectAddress(String address) async {
    await _preferences.setAddress(address);
    if (mounted) Navigator.pop(context, address);
  }

  Future<void> _addNative(String mode) async {
    try {
      final authenticated = await _security.authenticate(
        context,
        mode == 'create'
            ? 'Create another Kaspire wallet'
            : 'Import another Kaspire wallet',
      );
      if (!authenticated) return;
      if (mounted) {
        setState(() {
          _working = true;
          _workingLabel =
              mode == 'create' ? 'Creating wallet…' : 'Importing wallet…';
          _error = null;
        });
      }
      var address = mode == 'create'
          ? await _security.createWallet()
          : mode == 'private'
              ? await _security.importPrivateKey()
              : await _security.importWallet();
      if (mode == 'mnemonic') {
        if (mounted) {
          setState(() => _workingLabel = 'Scanning wallet addresses…');
        }
        address = await HdDiscoveryService().discoverAndRegister(
          address,
          _security,
          onProgress: (status) {
            if (mounted) setState(() => _workingLabel = status);
          },
        );
      }
      final wallets = await _security.listWallets();
      if (!wallets.any(
        (wallet) =>
            wallet.address == address ||
            wallet.addresses.any((item) => item.address == address),
      )) {
        throw StateError(
          'The imported wallet was encrypted but could not be selected. '
          'Reload Wallets and select it manually.',
        );
      }
      await _selectAddress(address);
    } catch (error) {
      if (mounted) {
        setState(() {
          _working = false;
          _workingLabel = null;
          _error = error.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  Future<void> _addWatch() async {
    final controller = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add watch wallet'),
        content: TextField(
          controller: controller,
          autocorrect: false,
          decoration:
              const InputDecoration(labelText: 'Kaspa address or name.kas'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(buttonLabel('CANCEL'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: Text(buttonLabel('ADD'))),
        ],
      ),
    );
    controller.dispose();
    if (input == null || input.trim().isEmpty) return;
    try {
      final address = await KaspaApi().resolveWalletInput(input);
      await _preferences.addWatchWallet(address);
      await _selectAddress(address);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _addAccount(NativeWalletInfo wallet) async {
    try {
      final authenticated = await _security.authenticate(
        context,
        'Create another account under ${wallet.name}',
      );
      if (!authenticated) return;
      await _security.selectWallet(wallet.id);
      final modernAccounts = HdWalletStructure.receiveGroups(wallet.addresses)
          .where((item) => item.coinType == 111111)
          .map((item) => item.account);
      final account = modernAccounts.isEmpty
          ? 0
          : modernAccounts.reduce((a, b) => a > b ? a : b) + 1;
      if (account > 100) {
        throw StateError('The maximum BIP-44 account number is 100.');
      }
      final created = <NativeHdAddress>[];
      for (final change in const [0, 1]) {
        created.addAll((await _security.deriveAddresses(
          coinType: 111111,
          account: account,
          change: change,
          start: 0,
          count: 1,
        ))
            .map((item) => item.copyWith(explicit: true)));
      }
      final combined = <String, NativeHdAddress>{
        for (final item in wallet.addresses) item.derivationPath: item,
        for (final item in created) item.derivationPath: item,
      }.values.toList();
      await _security.registerHdAddresses(combined);
      final receive = created.firstWhere(
        (item) => item.change == 0 && item.index == 0,
      );
      await _selectAddress(receive.address);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    }
  }

  Future<void> _addSubwallet(
    NativeWalletInfo wallet,
    HdReceiveGroup group,
  ) async {
    try {
      final authenticated = await _security.authenticate(
        context,
        'Create a subwallet under account ${group.account}',
      );
      if (!authenticated) return;
      await _security.selectWallet(wallet.id);
      final index = HdWalletStructure.nextSubwalletIndex(
        wallet.addresses,
        coinType: group.coinType,
        account: group.account,
      );
      final created = await _security.deriveAddresses(
        coinType: group.coinType,
        account: group.account,
        change: 0,
        start: index,
        count: 1,
      );
      if (created.isEmpty) {
        throw StateError('Subwallet derivation returned no address.');
      }
      final subwallet = created.single.copyWith(explicit: true);
      final combined = <String, NativeHdAddress>{
        for (final item in wallet.addresses) item.derivationPath: item,
        subwallet.derivationPath: subwallet,
      }.values.toList();
      await _security.registerHdAddresses(combined);
      await _selectAddress(subwallet.address);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    }
  }

  Future<void> _delete(
      {NativeWalletInfo? native, WatchWalletInfo? watch}) async {
    final name = native?.name ?? watch!.name;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete $name?'),
        content: Text(native != null
            ? 'This removes this encrypted signing wallet from the device. Verify its offline backup first.'
            : 'This removes only the watch-wallet entry.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(buttonLabel('CANCEL'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(buttonLabel('DELETE'))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (native != null) {
      await _security.deleteWalletById(native.id);
    } else {
      await _preferences.removeWatchWallet(watch!.id);
    }
    final deletedCurrent = native != null
        ? native.addresses.any(
              (item) => item.address == widget.currentAddress,
            ) ||
            native.address == widget.currentAddress
        : watch?.address == widget.currentAddress;
    await _load();
    if (!deletedCurrent) return;
    if (_native.isNotEmpty) {
      await _selectNative(_native.first);
    } else if (_watch.isNotEmpty) {
      await _selectAddress(_watch.first.address);
    } else {
      await _preferences.clearAddress();
      if (mounted) Navigator.pop(context, '');
    }
  }

  Future<void> _rename(
      {NativeWalletInfo? native, WatchWalletInfo? watch}) async {
    final currentName = native?.name ?? watch!.name;
    final controller = TextEditingController(text: currentName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename wallet'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Wallet name'),
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
    if (name == null || name.trim().isEmpty || name.trim() == currentName) {
      return;
    }
    try {
      if (native != null) {
        await _security.renameWallet(native.id, name);
      } else {
        await _preferences.renameWatchWallet(watch!.id, name);
      }
      await _load();
      widget.onWalletChanged();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Wallets')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Stack(
                children: [
                  ListView(
                    padding: EdgeInsets.fromLTRB(
                      20,
                      20,
                      20,
                      36 + MediaQuery.viewPaddingOf(context).bottom,
                    ),
                    children: [
                      Text(displayLabel('SIGNING WALLETS'),
                          style: TextStyle(
                              color: KasVaultTheme.muted,
                              fontWeight: FontWeight.w900)),
                      const SizedBox(height: 8),
                      ..._native.expand(
                        (wallet) => [
                          _WalletTile(
                            name: wallet.name,
                            detail: wallet.kind,
                            address: wallet.address,
                            selected: wallet.address == widget.currentAddress ||
                                wallet.addresses.any((item) =>
                                    item.address == widget.currentAddress),
                            icon: Icons.key_rounded,
                            onTap: () => _selectNative(wallet),
                            onRename: () => _rename(native: wallet),
                            onDelete: () => _delete(native: wallet),
                            onAddAccount: wallet.kind == 'mnemonic'
                                ? () => _addAccount(wallet)
                                : null,
                          ),
                          ..._accountEntries(wallet),
                        ],
                      ),
                      if (_native.isEmpty)
                        const Text('No signing wallets stored.',
                            style: TextStyle(color: KasVaultTheme.muted)),
                      const SizedBox(height: 22),
                      Text(displayLabel('WATCH WALLETS'),
                          style: TextStyle(
                              color: KasVaultTheme.muted,
                              fontWeight: FontWeight.w900)),
                      const SizedBox(height: 8),
                      ..._watch.map((wallet) => _WalletTile(
                            name: wallet.name,
                            detail: 'Watch wallet',
                            address: wallet.address,
                            selected: wallet.address == widget.currentAddress,
                            icon: Icons.visibility_outlined,
                            onTap: () => _selectAddress(wallet.address),
                            onRename: () => _rename(watch: wallet),
                            onDelete: () => _delete(watch: wallet),
                          )),
                      if (_watch.isEmpty)
                        const Text('No watch wallets stored.',
                            style: TextStyle(color: KasVaultTheme.muted)),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 14),
                          child: Text(_error!,
                              style: const TextStyle(color: Color(0xFFFF8A65))),
                        ),
                      const SizedBox(height: 28),
                      FilledButton.icon(
                          onPressed:
                              _working ? null : () => _addNative('create'),
                          icon: const Icon(Icons.add_rounded),
                          label: Text(buttonLabel('CREATE WALLET'))),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                          onPressed:
                              _working ? null : () => _addNative('mnemonic'),
                          icon: const Icon(Icons.format_list_numbered_rounded),
                          label: Text(buttonLabel('IMPORT 12 / 24 WORDS'))),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                          onPressed:
                              _working ? null : () => _addNative('private'),
                          icon: const Icon(Icons.password_rounded),
                          label: Text(buttonLabel('IMPORT PRIVATE KEY'))),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                          onPressed: _working ? null : _addWatch,
                          icon: const Icon(Icons.visibility_outlined),
                          label: Text(buttonLabel('ADD WATCH WALLET'))),
                    ],
                  ),
                  if (_working)
                    Positioned.fill(
                      child: ColoredBox(
                        color: const Color(0xB000090C),
                        child: Center(
                          child: Container(
                            margin: const EdgeInsets.all(28),
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: KasVaultTheme.panel,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: KasVaultTheme.line),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const CircularProgressIndicator(),
                                const SizedBox(height: 16),
                                Text(
                                  _workingLabel ?? 'Loading wallet…',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                const Text(
                                  'Discovering accounts and subwallets. This can take a moment.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: KasVaultTheme.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
      );

  List<Widget> _accountEntries(NativeWalletInfo wallet) {
    if (wallet.kind != 'mnemonic' || !AppSettings.showSubwallets.value) {
      return const [];
    }
    return HdWalletStructure.receiveGroups(wallet.addresses).expand((group) {
      final legacy = group.coinType == 972;
      return group.addresses.map((address) {
        final selected = address.address == widget.currentAddress;
        return Padding(
          padding: EdgeInsets.only(
            left: address.index == 0 ? 28 : 48,
            bottom: 4,
          ),
          child: ListTile(
            dense: true,
            selected: selected,
            selectedColor: KasVaultTheme.mint,
            leading: Icon(
              address.index == 0
                  ? Icons.account_tree_outlined
                  : Icons.account_balance_wallet_outlined,
              size: 20,
            ),
            title: Text(
              address.index == 0
                  ? '${legacy ? 'Legacy account' : 'Account'} '
                      '${group.account} · Subwallet 0'
                  : 'Subwallet ${address.index}',
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(address.derivationPath),
                _AddressLine(address: address.address),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (address.index == 0 && !legacy)
                  IconButton(
                    tooltip: 'Add address-index subwallet',
                    onPressed: () => _addSubwallet(wallet, group),
                    icon: const Icon(Icons.add_rounded),
                  ),
              ],
            ),
            onTap: () => _selectNative(wallet, address: address.address),
          ),
        );
      });
    }).toList();
  }
}

class _WalletTile extends StatelessWidget {
  const _WalletTile(
      {required this.name,
      required this.detail,
      required this.address,
      required this.selected,
      required this.icon,
      required this.onTap,
      required this.onRename,
      required this.onDelete,
      this.onAddAccount});
  final String name;
  final String detail;
  final String address;
  final bool selected;
  final IconData icon;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback? onAddAccount;
  @override
  Widget build(BuildContext context) => Card(
        color: selected
            ? KasVaultTheme.mint.withValues(alpha: .13)
            : KasVaultTheme.panel,
        child: ListTile(
          onTap: onTap,
          leading: Icon(icon,
              color: selected ? KasVaultTheme.mint : KasVaultTheme.muted),
          title:
              Text(name, style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(detail),
              _AddressLine(address: address),
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Add BIP-44 account',
                onPressed: onAddAccount,
                icon: const Icon(Icons.add_card_outlined),
              ),
              IconButton(
                tooltip: 'Rename wallet',
                onPressed: onRename,
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                tooltip: 'Delete wallet',
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ],
          ),
        ),
      );
}

String _compactAddress(String address) {
  if (address.length <= 12) return address;
  final prefix = address.startsWith('kaspa:') ? 'kaspa:' : '';
  return '$prefix…${address.substring(address.length - 6)}';
}

Future<void> _copyAddress(BuildContext context, String address) async {
  await Clipboard.setData(ClipboardData(text: address));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Address copied')),
  );
}

class _AddressLine extends StatelessWidget {
  const _AddressLine({required this.address});

  final String address;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _compactAddress(address),
            style: TextStyle(color: Theme.of(context).colorScheme.primary),
          ),
          const SizedBox(width: 2),
          InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => _copyAddress(context, address),
            child: const Padding(
              padding: EdgeInsets.all(5),
              child: Icon(Icons.copy_rounded, size: 16),
            ),
          ),
        ],
      );
}
