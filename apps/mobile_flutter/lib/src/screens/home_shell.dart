import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/asset_send_intent.dart';
import 'receive_screen.dart';
import 'send_screen.dart';
import 'settings_screen.dart';
import 'dapp_sessions_screen.dart';
import 'wallet_screen.dart';
import 'wallet_manager_screen.dart';
import 'address_book_screen.dart';
import '../services/update_service.dart';
import '../services/app_settings.dart';
import '../services/network_settings.dart';
import '../theme.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.address,
    required this.onDisconnect,
    required this.onSwitchWallet,
  });
  final String address;
  final VoidCallback onDisconnect;
  final ValueChanged<String> onSwitchWallet;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  int _sendRevision = 0;
  int _walletRevision = 0;
  AssetSendIntent? _sendIntent;
  DateTime? _exitRequestedAt;

  void _openKasSend() => setState(() {
        _sendIntent = null;
        _sendRevision++;
        _index = 1;
      });

  void _openAssetSend(AssetSendIntent intent) => setState(() {
        _sendIntent = intent;
        _sendRevision++;
        _index = 1;
      });

  Future<void> _openWalletManager() async {
    final selected = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => WalletManagerScreen(
          currentAddress: NetworkSettings.storageAddress(widget.address),
          onWalletChanged: () {
            if (mounted) setState(() => _walletRevision++);
          },
        ),
      ),
    );
    if (!mounted || selected == null) return;
    if (selected.isEmpty) {
      widget.onDisconnect();
    } else {
      widget.onSwitchWallet(selected);
    }
  }

  void _openDappSessions() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const DappSessionsScreen()),
    );
  }

  void _openAddressBook() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const AddressBookScreen()),
    );
  }

  void _selectDestination(int value) => setState(() {
        if (value == 1 && _index != 1) {
          _sendIntent = null;
          _sendRevision++;
        }
        _index = value;
      });

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<KaspaNetwork>(
        valueListenable: NetworkSettings.network,
        builder: (context, _, __) => _buildNetwork(context),
      );

  Widget _buildNetwork(BuildContext context) {
    final activeAddress = NetworkSettings.addressForNetwork(widget.address);
    final pages = [
      WalletScreen(
        key: ValueKey('$_walletRevision-${NetworkSettings.network.value.name}'),
        address: activeAddress,
        onSend: _openKasSend,
        onSendAsset: _openAssetSend,
        onReceive: () => setState(() => _index = 2),
        onPairDapps: _openDappSessions,
        onSwitchWallet: _openWalletManager,
      ),
      SendScreen(
        key: ValueKey('$_sendRevision-${NetworkSettings.network.value.name}'),
        address: activeAddress,
        initialAsset: _sendIntent,
        onDone: () => setState(() {
          _walletRevision++;
          _index = 0;
        }),
      ),
      ReceiveScreen(address: activeAddress),
      SettingsScreen(
        address: activeAddress,
        onManageWallets: _openWalletManager,
        onManageDapps: _openDappSessions,
        onManageAddressBook: _openAddressBook,
      ),
    ];
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_index != 0) {
          setState(() => _index = 0);
          return;
        }
        final now = DateTime.now();
        if (_exitRequestedAt == null ||
            now.difference(_exitRequestedAt!) > const Duration(seconds: 2)) {
          _exitRequestedAt = now;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Press back again to exit Kaspire')),
          );
          return;
        }
        SystemNavigator.pop();
      },
      child: Scaffold(
        body: Column(
          children: [
            if (_index == 0)
              ValueListenableBuilder<UpdateCheckState>(
                valueListenable: UpdateService.instance.state,
                builder: (context, state, _) {
                  final update = state.update;
                  if (update == null) return const SizedBox.shrink();
                  return SafeArea(
                    bottom: false,
                    child: Container(
                      width: double.infinity,
                      margin: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                      decoration: BoxDecoration(
                        color: update.critical
                            ? const Color(0xFF4A1717)
                            : KasVaultTheme.mint.withValues(alpha: .12),
                        border: Border.all(
                          color: update.critical
                              ? const Color(0xFFFF8A65)
                              : KasVaultTheme.mint,
                        ),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            update.critical
                                ? Icons.warning_amber_rounded
                                : Icons.system_update_alt_rounded,
                            color: update.critical
                                ? const Color(0xFFFF8A65)
                                : KasVaultTheme.mint,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Kaspire ${update.version} is available',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                Text(
                                  'Build ${update.build}${update.critical ? ' · Security update' : ''}',
                                  style: const TextStyle(
                                    color: KasVaultTheme.muted,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          TextButton(
                            onPressed: () => launchUrl(
                              update.apkUrl,
                              mode: LaunchMode.externalApplication,
                            ),
                            child: Text(buttonLabel('DOWNLOAD')),
                          ),
                          IconButton(
                            tooltip: 'Remind me tomorrow',
                            onPressed: () =>
                                UpdateService.instance.remindLater(update),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            Expanded(child: IndexedStack(index: _index, children: pages)),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: _selectDestination,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.account_balance_wallet_outlined),
              selectedIcon: Icon(Icons.account_balance_wallet),
              label: 'Wallet',
            ),
            NavigationDestination(
              icon: Icon(Icons.arrow_upward_rounded),
              label: 'Send',
            ),
            NavigationDestination(
              icon: Icon(Icons.qr_code_2_rounded),
              label: 'Receive',
            ),
            NavigationDestination(
              icon: Icon(Icons.tune_rounded),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}
