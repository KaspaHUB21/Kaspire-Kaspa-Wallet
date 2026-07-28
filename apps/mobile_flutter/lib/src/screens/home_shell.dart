import 'package:flutter/material.dart';

import '../models/asset_send_intent.dart';
import 'receive_screen.dart';
import 'send_screen.dart';
import 'settings_screen.dart';
import 'dapp_sessions_screen.dart';
import 'wallet_screen.dart';
import 'wallet_manager_screen.dart';
import 'address_book_screen.dart';

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
          currentAddress: widget.address,
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
  Widget build(BuildContext context) {
    final pages = [
      WalletScreen(
        key: ValueKey(_walletRevision),
        address: widget.address,
        onSend: _openKasSend,
        onSendAsset: _openAssetSend,
        onReceive: () => setState(() => _index = 2),
        onPairDapps: _openDappSessions,
        onSwitchWallet: _openWalletManager,
      ),
      SendScreen(
        key: ValueKey(_sendRevision),
        address: widget.address,
        initialAsset: _sendIntent,
        onDone: () => setState(() {
          _walletRevision++;
          _index = 0;
        }),
      ),
      ReceiveScreen(address: widget.address),
      SettingsScreen(
        address: widget.address,
        onManageWallets: _openWalletManager,
        onManageDapps: _openDappSessions,
        onManageAddressBook: _openAddressBook,
      ),
    ];
    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
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
    );
  }
}
