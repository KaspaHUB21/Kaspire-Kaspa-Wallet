import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/native_security.dart';
import '../services/kaspa_api.dart';
import '../services/hd_discovery_service.dart';
import '../services/network_settings.dart';
import '../services/privacy_settings.dart';
import '../services/app_settings.dart';
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
      (info) => 'Kaspire ${info.version} (${info.buildNumber}) · Mainnet',
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
        await _security.exportPrivateKey(widget.address);
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
              child: const Text('CANCEL'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(
                context,
                NetworkSettings.publicKaspaRestUrl,
              ),
              child: const Text('USE KASPIRE'),
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
              child: const Text('TEST & SAVE'),
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
  Widget build(BuildContext context) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const SizedBox(height: 8),
            const Text(
              'SETTINGS',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900),
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
                  'Hide address-index subwallets from the Wallets overview. '
                  'BIP-44 accounts remain available.',
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
                      snapshot.data == true
                          ? 'CHANGE KASPIRE PIN'
                          : 'CREATE 4–8 DIGIT PIN',
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
                      label: const Text('REMOVE KASPIRE PIN'),
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
                label: const Text('EXPORT ENCRYPTED BACKUP'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => _portableBackup(restore: true),
              icon: const Icon(Icons.restore_rounded),
              label: const Text('RESTORE ENCRYPTED BACKUP'),
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
                    label: const Text('EXPORT PRIVATE KEY'),
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
                    label: const Text('EXPORT RECOVERY PHRASE'),
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
              label: const Text('MANAGE DAPP SESSIONS'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: widget.onManageAddressBook,
              icon: const Icon(Icons.contacts_outlined),
              label: const Text('ADDRESS BOOK'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: widget.onManageWallets,
              icon: const Icon(Icons.account_balance_wallet_rounded),
              label: const Text('MANAGE / SWITCH WALLETS'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: FutureBuilder<String>(
                future: _version,
                builder: (context, snapshot) => Text(
                  snapshot.data ?? 'Kaspire · Mainnet',
                  style: const TextStyle(
                    color: KasVaultTheme.muted,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          text,
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
