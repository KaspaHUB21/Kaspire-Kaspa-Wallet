import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/native_security.dart';
import '../services/kaspa_api.dart';
import '../services/hd_discovery_service.dart';
import '../services/network_settings.dart';
import '../services/privacy_settings.dart';
import '../services/app_settings.dart';
import '../services/update_service.dart';
import '../theme.dart';
import 'diagnostics_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.address,
    required this.onManageWallets,
    required this.onManageDapps,
    required this.onManageAddressBook,
  });
  final String address;
  final VoidCallback onManageWallets;
  final VoidCallback onManageDapps;
  final VoidCallback onManageAddressBook;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late Future<bool> _hardware;
  late Future<bool> _nativeWallet;
  late Future<bool> _pinEnabled;
  late Future<String> _version;
  late Future<String> _nodeEndpoint;
  final _security = NativeSecurity();

  @override
  void initState() {
    super.initState();
    _hardware = _security.isHardwareBacked();
    _nativeWallet = _security.hasNativeWalletFor(widget.address);
    _pinEnabled = _security.hasPin();
    _version = PackageInfo.fromPlatform().then(
      (info) => 'Kaspire ${info.version} (${info.buildNumber}) · Layer 1 + L2',
    );
    _nodeEndpoint = Future.value(NetworkSettings.kaspaRestUrl);
  }

  Future<void> _configurePin() async {
    final authenticated = await _security.authenticate(
      context,
      'Authorize Kaspire PIN setup',
    );
    if (!authenticated || !mounted) return;
    final saved = await _security.configurePin();
    if (saved && mounted) setState(() => _pinEnabled = Future.value(true));
  }

  Future<void> _removePin() async {
    final authenticated = await _security.authenticate(
      context,
      'Authorize Kaspire PIN removal',
    );
    if (!authenticated || !mounted) return;
    await _security.removePin();
    if (mounted) setState(() => _pinEnabled = Future.value(false));
  }

  Future<void> _export({required bool privateKey}) async {
    try {
      if (privateKey) {
        final keys = await _security.exportPrivateKeys(widget.address);
        if (!mounted) return;
        await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
                  title: const Text('Wallet private keys'),
                  content: SingleChildScrollView(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                        const Text('Kaspa private key',
                            style: TextStyle(fontWeight: FontWeight.w900)),
                        const SizedBox(height: 6),
                        SelectableText(keys['kaspaPrivateKey'] ?? ''),
                        const SizedBox(height: 20),
                        const Text('EVM private key · Kasplex & Igra',
                            style: TextStyle(fontWeight: FontWeight.w900)),
                        const SizedBox(height: 6),
                        SelectableText(keys['evmPrivateKey'] ?? ''),
                        const SizedBox(height: 18),
                        const Text(
                            'Keep both keys offline. Anyone with either key can spend assets controlled by that account.',
                            style: TextStyle(color: KasVaultTheme.muted)),
                      ])),
                  actions: [
                    FilledButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(buttonLabel('DONE')))
                  ],
                ));
      } else {
        await _security.exportRecoveryPhrase();
      }
    } on PlatformException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message ?? 'Export failed')),
      );
    }
  }

  Future<void> _portableBackup({required bool restore}) async {
    try {
      if (restore) {
        final authenticated = await _security.authenticate(
          context,
          'Authorize encrypted wallet restore',
        );
        if (!authenticated) return;
        final address = await _security.restoreEncryptedBackup();
        if (address != null) {
          await HdDiscoveryService().discoverAndRegister(address, _security);
        }
        if (address != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content:
                  Text('Encrypted wallet restored. Open Wallets to select it.'),
            ),
          );
        }
      } else {
        await _security.exportEncryptedBackup();
      }
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message ?? 'Backup operation failed')),
        );
      }
    }
  }

  Future<void> _configureNode() async {
    final controller =
        TextEditingController(text: NetworkSettings.kaspaRestUrl);
    String? error;
    final endpoint = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Kaspa REST endpoint'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Use an HTTPS REST gateway exposing the same Kaspa API routes. A raw kaspad wRPC address is not accepted here.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'HTTPS endpoint',
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    error!,
                    style: const TextStyle(color: Color(0xFFFF8A65)),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(buttonLabel('CANCEL')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(
                context,
                NetworkSettings.publicKaspaRestUrl,
              ),
              child: Text(buttonLabel('USE KASPIRE')),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  final value = controller.text.trim();
                  if (!NetworkSettings.isValidEndpoint(value)) {
                    throw const FormatException(
                        'Enter a valid HTTPS endpoint.');
                  }
                  await KaspaApi(baseUrl: value).loadFeeRate();
                  if (context.mounted) Navigator.pop(context, value);
                } catch (value) {
                  setDialogState(() =>
                      error = '$value'.replaceFirst('FormatException: ', ''));
                }
              },
              child: Text(buttonLabel('TEST & SAVE')),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (endpoint == null) return;
    if (endpoint == NetworkSettings.publicKaspaRestUrl) {
      await NetworkSettings.reset();
    } else {
      await NetworkSettings.save(endpoint);
    }
    if (mounted) {
      setState(
          () => _nodeEndpoint = Future.value(NetworkSettings.kaspaRestUrl));
    }
  }

  @override
  Widget build(BuildContext context) => _SettingsOverview(
        address: widget.address,
        hardware: _hardware,
        nativeWallet: _nativeWallet,
        pinEnabled: _pinEnabled,
        version: _version,
        nodeEndpoint: _nodeEndpoint,
        onConfigurePin: _configurePin,
        onRemovePin: _removePin,
        onConfigureNode: _configureNode,
        onManageDapps: widget.onManageDapps,
        onManageAddressBook: widget.onManageAddressBook,
        onManageWallets: widget.onManageWallets,
        onExportBackup: () => _portableBackup(restore: false),
        onRestoreBackup: () => _portableBackup(restore: true),
        onExportPrivateKey: () => _export(privateKey: true),
        onExportRecoveryPhrase: () => _export(privateKey: false),
      );

  // Kept temporarily as a layout reference while the categorized settings
  // screen is validated on different Android display sizes.
  // ignore: unused_element
  Widget _legacyBuild(BuildContext context) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    displayLabel('SETTINGS'),
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                InkWell(
                  onTap: () => launchUrl(
                    Uri.parse('https://kaslab.space/'),
                    mode: LaunchMode.externalApplication,
                  ),
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Image.asset(
                      'assets/branding/hub21_wordmark.png',
                      width: 92,
                      height: 36,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),
            const _Heading('SECURITY'),
            FutureBuilder<bool>(
              future: _hardware,
              builder: (context, snapshot) => _SettingTile(
                icon: Icons.memory_rounded,
                title: 'Hardware-backed vault',
                detail: snapshot.connectionState != ConnectionState.done
                    ? 'Checking…'
                    : snapshot.data == true
                        ? 'Available'
                        : 'Unavailable / emulator',
                color: snapshot.data == true
                    ? KasVaultTheme.mint
                    : const Color(0xFFFFB65C),
              ),
            ),
            FutureBuilder<bool>(
              future: _pinEnabled,
              builder: (context, snapshot) => _SettingTile(
                icon: snapshot.data == true
                    ? Icons.pin_rounded
                    : Icons.fingerprint_rounded,
                title: 'Transaction approval',
                detail: snapshot.data == true
                    ? 'Biometrics or 4–8 digit Kaspire PIN'
                    : 'Biometrics · optional Kaspire PIN available',
                color: KasVaultTheme.mint,
              ),
            ),
            FutureBuilder<bool>(
              future: _nativeWallet,
              builder: (context, snapshot) => _SettingTile(
                icon: snapshot.data == true
                    ? Icons.key_rounded
                    : Icons.visibility_outlined,
                title: 'Wallet mode',
                detail: snapshot.connectionState != ConnectionState.done
                    ? 'Checking…'
                    : snapshot.data == true
                        ? 'Native signing wallet · Rusty Kaspa v2.0.1'
                        : 'Watch-only · no signing key',
                color: snapshot.data == true
                    ? KasVaultTheme.mint
                    : const Color(0xFFFFB65C),
              ),
            ),
            const SizedBox(height: 24),
            const _Heading('PRIVACY'),
            ValueListenableBuilder<bool>(
              valueListenable: PrivacySettings.hideAmounts,
              builder: (context, hidden, _) => SwitchListTile(
                value: hidden,
                onChanged: PrivacySettings.setHideAmounts,
                secondary: Icon(
                  hidden
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                  color: KasVaultTheme.mint,
                ),
                title: const Text(
                  'Hide wallet amounts',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: const Text(
                  'Masks balances and activity amounts on wallet screens. '
                  'Confirmation dialogs still show exact values.',
                ),
                tileColor: KasVaultTheme.panel,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                  side: BorderSide(color: KasVaultTheme.line),
                ),
              ),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<int>(
              valueListenable: AppSettings.lockMinutes,
              builder: (context, minutes, _) => DropdownButtonFormField<int>(
                initialValue: minutes,
                decoration: const InputDecoration(
                  labelText: 'Automatic wallet lock',
                  prefixIcon: Icon(Icons.lock_clock_outlined),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 0,
                    child: Text('Immediately'),
                  ),
                  DropdownMenuItem(value: 5, child: Text('After 5 minutes')),
                  DropdownMenuItem(value: 10, child: Text('After 10 minutes')),
                  DropdownMenuItem(value: 15, child: Text('After 15 minutes')),
                ],
                onChanged: (value) {
                  if (value != null) AppSettings.setLockMinutes(value);
                },
              ),
            ),
            const SizedBox(height: 24),
            const _Heading('WALLET DISPLAY'),
            ValueListenableBuilder<bool>(
              valueListenable: AppSettings.showSubwallets,
              builder: (context, visible, _) => SwitchListTile(
                value: visible,
                onChanged: AppSettings.setShowSubwallets,
                secondary: Icon(
                  Icons.account_tree_outlined,
                  color: KasVaultTheme.mint,
                ),
                title: const Text(
                  'Show subwallets',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: const Text(
                  'Hide BIP-44 accounts and address-index subwallets from the '
                  'Wallets overview. They remain available when enabled again.',
                ),
                tileColor: KasVaultTheme.panel,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                  side: BorderSide(color: KasVaultTheme.line),
                ),
              ),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<KaspireTheme>(
              valueListenable: AppSettings.theme,
              builder: (context, selected, _) =>
                  DropdownButtonFormField<KaspireTheme>(
                initialValue: selected,
                decoration: const InputDecoration(
                  labelText: 'Kaspire design',
                  prefixIcon: Icon(Icons.palette_outlined),
                ),
                items: KaspireTheme.values
                    .map(
                      (theme) => DropdownMenuItem(
                        value: theme,
                        child: Text(
                          theme.name[0].toUpperCase() + theme.name.substring(1),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) AppSettings.setTheme(value);
                },
              ),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<bool>(
              valueListenable: AppSettings.uppercaseButtons,
              builder: (context, uppercase, _) => SwitchListTile(
                value: uppercase,
                onChanged: AppSettings.setUppercaseButtons,
                secondary: Icon(
                  Icons.text_fields_rounded,
                  color: KasVaultTheme.mint,
                ),
                title: const Text(
                  'Uppercase text',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: Text(
                  uppercase
                      ? 'Headings and controls use uppercase labels.'
                      : 'Headings and controls use conventional capitalization.',
                ),
                tileColor: KasVaultTheme.panel,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                  side: BorderSide(color: KasVaultTheme.line),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const _Heading('NETWORK'),
            InkWell(
              onTap: _configureNode,
              borderRadius: BorderRadius.circular(18),
              child: FutureBuilder<String>(
                future: _nodeEndpoint,
                builder: (context, snapshot) => _SettingTile(
                  icon: Icons.hub_outlined,
                  title: 'Kaspa Mainnet endpoint',
                  detail: snapshot.data ?? 'Loading…',
                  color: KasVaultTheme.cyan,
                ),
              ),
            ),
            InkWell(
              onTap: widget.onManageDapps,
              borderRadius: BorderRadius.circular(18),
              child: _SettingTile(
                icon: Icons.link_rounded,
                title: 'dApp sessions',
                detail: 'Reown WalletKit · Kaspa Mainnet',
                color: KasVaultTheme.cyan,
              ),
            ),
            InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => DiagnosticsScreen(address: widget.address),
                ),
              ),
              borderRadius: BorderRadius.circular(18),
              child: _SettingTile(
                icon: Icons.monitor_heart_outlined,
                title: 'Network diagnostics',
                detail: 'Node · indexers · WalletConnect',
                color: KasVaultTheme.cyan,
              ),
            ),
            const SizedBox(height: 28),
            FutureBuilder<bool>(
              future: _pinEnabled,
              builder: (context, snapshot) => Column(
                children: [
                  OutlinedButton.icon(
                    onPressed: snapshot.connectionState == ConnectionState.done
                        ? _configurePin
                        : null,
                    icon: const Icon(Icons.pin_rounded),
                    label: Text(
                      buttonLabel(
                        snapshot.data == true
                            ? 'CHANGE KASPIRE PIN'
                            : 'CREATE 4–8 DIGIT PIN',
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                  ),
                  if (snapshot.data == true) ...[
                    const SizedBox(height: 10),
                    TextButton.icon(
                      onPressed: _removePin,
                      icon: const Icon(Icons.remove_circle_outline_rounded),
                      label: Text(buttonLabel('REMOVE KASPIRE PIN')),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 18),
            FutureBuilder<bool>(
              future: _nativeWallet,
              builder: (context, snapshot) => OutlinedButton.icon(
                onPressed: snapshot.data == true
                    ? () => _portableBackup(restore: false)
                    : null,
                icon: const Icon(Icons.enhanced_encryption_rounded),
                label: Text(buttonLabel('EXPORT ENCRYPTED BACKUP')),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => _portableBackup(restore: true),
              icon: const Icon(Icons.restore_rounded),
              label: Text(buttonLabel('RESTORE ENCRYPTED BACKUP')),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
            ),
            const SizedBox(height: 18),
            FutureBuilder<bool>(
              future: _nativeWallet,
              builder: (context, snapshot) => Column(
                children: [
                  OutlinedButton.icon(
                    onPressed: snapshot.data == true
                        ? () => _export(privateKey: true)
                        : null,
                    icon: const Icon(Icons.key_rounded),
                    label: Text(buttonLabel('EXPORT PRIVATE KEY')),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: snapshot.data == true
                        ? () => _export(privateKey: false)
                        : null,
                    icon: const Icon(Icons.format_list_numbered_rounded),
                    label: Text(buttonLabel('EXPORT RECOVERY PHRASE')),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: widget.onManageDapps,
              icon: const Icon(Icons.language_rounded),
              label: Text(buttonLabel('MANAGE DAPP SESSIONS')),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: widget.onManageAddressBook,
              icon: const Icon(Icons.contacts_outlined),
              label: Text(buttonLabel('ADDRESS BOOK')),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: widget.onManageWallets,
              icon: const Icon(Icons.account_balance_wallet_rounded),
              label: Text(buttonLabel('MANAGE / SWITCH WALLETS')),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: FutureBuilder<String>(
                future: _version,
                builder: (context, snapshot) => Text(
                  snapshot.data ?? 'Kaspire · Layer 1 + L2',
                  style: const TextStyle(
                    color: KasVaultTheme.muted,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
            Center(
              child: TextButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse('https://t.me/kaspirewallet'),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.telegram, size: 18),
                label: const Text('Report a bug'),
              ),
            ),
          ],
        ),
      );
}

class _SettingsOverview extends StatelessWidget {
  const _SettingsOverview({
    required this.address,
    required this.hardware,
    required this.nativeWallet,
    required this.pinEnabled,
    required this.version,
    required this.nodeEndpoint,
    required this.onConfigurePin,
    required this.onRemovePin,
    required this.onConfigureNode,
    required this.onManageDapps,
    required this.onManageAddressBook,
    required this.onManageWallets,
    required this.onExportBackup,
    required this.onRestoreBackup,
    required this.onExportPrivateKey,
    required this.onExportRecoveryPhrase,
  });

  final String address;
  final Future<bool> hardware;
  final Future<bool> nativeWallet;
  final Future<bool> pinEnabled;
  final Future<String> version;
  final Future<String> nodeEndpoint;
  final VoidCallback onConfigurePin;
  final VoidCallback onRemovePin;
  final VoidCallback onConfigureNode;
  final VoidCallback onManageDapps;
  final VoidCallback onManageAddressBook;
  final VoidCallback onManageWallets;
  final VoidCallback onExportBackup;
  final VoidCallback onRestoreBackup;
  final VoidCallback onExportPrivateKey;
  final VoidCallback onExportRecoveryPhrase;

  Future<void> _open(String url) async {
    await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    displayLabel('SETTINGS'),
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                InkWell(
                  onTap: () => _open('https://kaslab.space/'),
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Image.asset(
                      'assets/branding/hub21_wordmark.png',
                      width: 92,
                      height: 36,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _SettingsSection(
              icon: Icons.shield_outlined,
              title: 'Security',
              subtitle: 'Locking, authorization and wallet mode',
              children: [
                ValueListenableBuilder<int>(
                  valueListenable: AppSettings.lockMinutes,
                  builder: (context, minutes, _) =>
                      DropdownButtonFormField<int>(
                    initialValue: minutes,
                    decoration: const InputDecoration(
                      labelText: 'Automatic wallet lock',
                      prefixIcon: Icon(Icons.lock_clock_outlined),
                    ),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('Immediately')),
                      DropdownMenuItem(
                          value: 5, child: Text('After 5 minutes')),
                      DropdownMenuItem(
                          value: 10, child: Text('After 10 minutes')),
                      DropdownMenuItem(
                          value: 15, child: Text('After 15 minutes')),
                    ],
                    onChanged: (value) {
                      if (value != null) AppSettings.setLockMinutes(value);
                    },
                  ),
                ),
                const SizedBox(height: 10),
                FutureBuilder<bool>(
                  future: hardware,
                  builder: (context, snapshot) => _SettingTile(
                    icon: Icons.memory_rounded,
                    title: 'Hardware-backed vault',
                    detail: snapshot.connectionState != ConnectionState.done
                        ? 'Checking…'
                        : snapshot.data == true
                            ? 'Available'
                            : 'Unavailable / emulator',
                    color: KasVaultTheme.mint,
                  ),
                ),
                FutureBuilder<bool>(
                  future: pinEnabled,
                  builder: (context, snapshot) => Column(
                    children: [
                      _SettingTile(
                        icon: snapshot.data == true
                            ? Icons.pin_rounded
                            : Icons.fingerprint_rounded,
                        title: 'Transaction approval',
                        detail: snapshot.data == true
                            ? 'Biometrics or Kaspire PIN'
                            : 'Biometrics · optional Kaspire PIN',
                        color: KasVaultTheme.mint,
                      ),
                      OutlinedButton.icon(
                        onPressed:
                            snapshot.connectionState == ConnectionState.done
                                ? onConfigurePin
                                : null,
                        icon: const Icon(Icons.pin_rounded),
                        label: Text(buttonLabel(
                          snapshot.data == true
                              ? 'CHANGE KASPIRE PIN'
                              : 'CREATE 4–8 DIGIT PIN',
                        )),
                      ),
                      if (snapshot.data == true)
                        TextButton.icon(
                          onPressed: onRemovePin,
                          icon: const Icon(Icons.remove_circle_outline_rounded),
                          label: Text(buttonLabel('REMOVE KASPIRE PIN')),
                        ),
                    ],
                  ),
                ),
                FutureBuilder<bool>(
                  future: nativeWallet,
                  builder: (context, snapshot) => _SettingTile(
                    icon: snapshot.data == true
                        ? Icons.key_rounded
                        : Icons.visibility_outlined,
                    title: 'Wallet mode',
                    detail: snapshot.data == true
                        ? 'Native signing wallet · Rusty Kaspa v2.0.1'
                        : 'Watch-only · no signing key',
                    color: KasVaultTheme.mint,
                  ),
                ),
              ],
            ),
            _SettingsSection(
              icon: Icons.palette_outlined,
              title: 'Wallet display',
              subtitle: 'Currency, theme, wallets and privacy',
              children: [
                ValueListenableBuilder<FiatCurrency>(
                  valueListenable: AppSettings.fiatCurrency,
                  builder: (context, selected, _) =>
                      DropdownButtonFormField<FiatCurrency>(
                    initialValue: selected,
                    decoration: const InputDecoration(
                      labelText: 'Currency',
                      prefixIcon: Icon(Icons.monetization_on_outlined),
                    ),
                    items: FiatCurrency.values
                        .map(
                          (currency) => DropdownMenuItem(
                            value: currency,
                            child: Text(
                              '${currency.symbol} ${currency.label} '
                              '(${currency.code})',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) AppSettings.setFiatCurrency(value);
                    },
                  ),
                ),
                const SizedBox(height: 10),
                ValueListenableBuilder<bool>(
                  valueListenable: AppSettings.showSubwallets,
                  builder: (context, visible, _) => SwitchListTile(
                    value: visible,
                    onChanged: AppSettings.setShowSubwallets,
                    secondary: Icon(
                      Icons.account_tree_outlined,
                      color: KasVaultTheme.mint,
                    ),
                    title: const Text('Show subwallets'),
                  ),
                ),
                ValueListenableBuilder<KaspireTheme>(
                  valueListenable: AppSettings.theme,
                  builder: (context, selected, _) =>
                      DropdownButtonFormField<KaspireTheme>(
                    initialValue: selected,
                    decoration: const InputDecoration(
                      labelText: 'Kaspire design',
                      prefixIcon: Icon(Icons.color_lens_outlined),
                    ),
                    items: KaspireTheme.values
                        .map(
                          (theme) => DropdownMenuItem(
                            value: theme,
                            child: Text(
                              theme.name[0].toUpperCase() +
                                  theme.name.substring(1),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) AppSettings.setTheme(value);
                    },
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: AppSettings.uppercaseButtons,
                  builder: (context, uppercase, _) => SwitchListTile(
                    value: uppercase,
                    onChanged: AppSettings.setUppercaseButtons,
                    secondary: Icon(
                      Icons.text_fields_rounded,
                      color: KasVaultTheme.mint,
                    ),
                    title: const Text('Uppercase text'),
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: PrivacySettings.hideAmounts,
                  builder: (context, hidden, _) => SwitchListTile(
                    value: hidden,
                    onChanged: PrivacySettings.setHideAmounts,
                    secondary: Icon(
                      hidden
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                      color: KasVaultTheme.mint,
                    ),
                    title: const Text('Hide wallet amounts'),
                    subtitle: const Text('Privacy'),
                  ),
                ),
              ],
            ),
            _SettingsSection(
              icon: Icons.language_rounded,
              title: 'Network',
              subtitle: 'Layer 1, dApps and diagnostics',
              children: [
                InkWell(
                  onTap: onConfigureNode,
                  child: FutureBuilder<String>(
                    future: nodeEndpoint,
                    builder: (context, snapshot) => _SettingTile(
                      icon: Icons.hub_outlined,
                      title: 'Kaspa Mainnet endpoint',
                      detail: snapshot.data ?? 'Loading…',
                      color: KasVaultTheme.cyan,
                    ),
                  ),
                ),
                InkWell(
                  onTap: onManageDapps,
                  child: _SettingTile(
                    icon: Icons.link_rounded,
                    title: 'dApp sessions',
                    detail: 'Reown WalletKit · Kaspa Mainnet',
                    color: KasVaultTheme.cyan,
                  ),
                ),
                InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => DiagnosticsScreen(address: address),
                    ),
                  ),
                  child: _SettingTile(
                    icon: Icons.monitor_heart_outlined,
                    title: 'Network diagnostics',
                    detail: 'Node · indexers · WalletConnect',
                    color: KasVaultTheme.cyan,
                  ),
                ),
              ],
            ),
            _NavigationSetting(
              icon: Icons.contacts_outlined,
              title: 'Address book',
              subtitle: 'Saved recipients',
              onTap: onManageAddressBook,
            ),
            _SettingsSection(
              icon: Icons.backup_outlined,
              title: 'Backups',
              subtitle: 'Encrypted backup and recovery exports',
              children: [
                FutureBuilder<bool>(
                  future: nativeWallet,
                  builder: (context, snapshot) => Column(
                    children: [
                      _FullAction(
                        icon: Icons.enhanced_encryption_rounded,
                        label: 'EXPORT ENCRYPTED BACKUP',
                        onPressed:
                            snapshot.data == true ? onExportBackup : null,
                      ),
                      _FullAction(
                        icon: Icons.restore_rounded,
                        label: 'RESTORE ENCRYPTED BACKUP',
                        onPressed: onRestoreBackup,
                      ),
                      _FullAction(
                        icon: Icons.key_rounded,
                        label: 'EXPORT PRIVATE KEY',
                        onPressed:
                            snapshot.data == true ? onExportPrivateKey : null,
                      ),
                      _FullAction(
                        icon: Icons.format_list_numbered_rounded,
                        label: 'EXPORT RECOVERY PHRASE',
                        onPressed: snapshot.data == true
                            ? onExportRecoveryPhrase
                            : null,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            _SettingsSection(
              icon: Icons.system_update_alt_rounded,
              title: 'Kaspire updates',
              subtitle: 'Signed in-app update checks',
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: UpdateService.instance.automaticChecks,
                  builder: (context, enabled, _) => SwitchListTile(
                    value: enabled,
                    onChanged: UpdateService.instance.setAutomaticChecks,
                    secondary: Icon(
                      Icons.update_rounded,
                      color: KasVaultTheme.mint,
                    ),
                    title: const Text('Automatic checks at startup'),
                    subtitle: const Text(
                      'Fetches and verifies the signed Kaspire release manifest.',
                    ),
                  ),
                ),
                ValueListenableBuilder<UpdateCheckState>(
                  valueListenable: UpdateService.instance.state,
                  builder: (context, state, _) {
                    final update = state.update;
                    final checked = state.lastCheckedAt?.toLocal();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _SettingTile(
                          icon: update == null
                              ? Icons.verified_outlined
                              : Icons.new_releases_outlined,
                          title: update == null
                              ? 'Installed version status'
                              : 'Kaspire ${update.version} available',
                          detail: state.checking
                              ? 'Checking signed manifest…'
                              : update != null
                                  ? 'Build ${update.build}${update.critical ? ' · Security update' : ''}'
                                  : state.error != null
                                      ? state.error!
                                      : checked == null
                                          ? 'Not checked yet'
                                          : 'Last checked ${checked.toString().split('.').first}',
                          color: update == null
                              ? KasVaultTheme.mint
                              : const Color(0xFFFFB65C),
                        ),
                        FilledButton.icon(
                          onPressed: state.checking
                              ? null
                              : () => UpdateService.instance.checkNow(),
                          icon: state.checking
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.refresh_rounded),
                          label: Text(buttonLabel('CHECK FOR UPDATES')),
                        ),
                        if (update != null) ...[
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: () => _open(update.apkUrl.toString()),
                            icon: const Icon(Icons.download_rounded),
                            label: Text(buttonLabel('DOWNLOAD UPDATE')),
                          ),
                          TextButton.icon(
                            onPressed: () =>
                                _open(update.releaseNotesUrl.toString()),
                            icon: const Icon(Icons.article_outlined),
                            label: Text(buttonLabel('VIEW CHANGES')),
                          ),
                          TextButton(
                            onPressed: () =>
                                UpdateService.instance.remindLater(update),
                            child: Text(buttonLabel('REMIND ME LATER')),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ],
            ),
            _SettingsSection(
              icon: Icons.build_circle_outlined,
              title: 'HUB21 Toolbox',
              subtitle: 'Explorers, vaults and developer tools',
              children: [
                _ToolLink(
                  icon: Icons.token_outlined,
                  title: 'Token Explorer',
                  url: 'https://kaspatoken.kaslab.space/',
                  onOpen: _open,
                ),
                _ToolLink(
                  icon: Icons.shield_outlined,
                  title: 'KasCoven Vaults',
                  url: 'https://vaults.kaslab.space/',
                  onOpen: _open,
                ),
                _ToolLink(
                  icon: Icons.code_rounded,
                  title: 'Kaspa Dev Tools',
                  url: 'https://devtools.kaslab.space/',
                  onOpen: _open,
                ),
                _ToolLink(
                  icon: Icons.dataset_linked_outlined,
                  title: 'KCC20 Indexer',
                  url: 'https://kcc20.info/',
                  onOpen: _open,
                ),
                _ToolLink(
                  icon: Icons.explore_outlined,
                  title: 'Discover more',
                  url: 'https://kaslab.space/',
                  onOpen: _open,
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onManageWallets,
              icon: const Icon(Icons.account_balance_wallet_rounded),
              label: Text(buttonLabel('MANAGE / SWITCH WALLETS')),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: FutureBuilder<String>(
                future: version,
                builder: (context, snapshot) => Text(
                  snapshot.data ?? 'Kaspire · Layer 1 + L2',
                  style: const TextStyle(
                    color: KasVaultTheme.muted,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
            Center(
              child: TextButton.icon(
                onPressed: () => _open('https://t.me/kaspirewallet'),
                icon: const Icon(Icons.telegram, size: 18),
                label: const Text('Report a bug'),
              ),
            ),
          ],
        ),
      );
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: KasVaultTheme.panel,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: KasVaultTheme.line),
        ),
        child: ExpansionTile(
          leading: Icon(icon, color: KasVaultTheme.mint),
          title: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          subtitle: Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          childrenPadding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
          children: children,
        ),
      );
}

class _NavigationSetting extends StatelessWidget {
  const _NavigationSetting({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: KasVaultTheme.panel,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: KasVaultTheme.line),
        ),
        child: ListTile(
          onTap: onTap,
          leading: Icon(icon, color: KasVaultTheme.mint),
          title: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right_rounded),
        ),
      );
}

class _FullAction extends StatelessWidget {
  const _FullAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon),
          label: Text(buttonLabel(label)),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(50),
          ),
        ),
      );
}

class _ToolLink extends StatelessWidget {
  const _ToolLink({
    required this.icon,
    required this.title,
    required this.url,
    required this.onOpen,
  });

  final IconData icon;
  final String title;
  final String url;
  final Future<void> Function(String) onOpen;

  @override
  Widget build(BuildContext context) => ListTile(
        onTap: () => onOpen(url),
        leading: Icon(icon, color: KasVaultTheme.cyan),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(
          Uri.parse(url).host,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.open_in_new_rounded, size: 19),
      );
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          displayLabel(text),
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.2,
            color: KasVaultTheme.muted,
          ),
        ),
      );
}

class _SettingTile extends StatelessWidget {
  const _SettingTile({
    required this.icon,
    required this.title,
    required this.detail,
    required this.color,
  });
  final IconData icon;
  final String title;
  final String detail;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: KasVaultTheme.panel,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: KasVaultTheme.line),
        ),
        child: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 3),
                  Text(
                    detail,
                    style: const TextStyle(
                      color: KasVaultTheme.muted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}
