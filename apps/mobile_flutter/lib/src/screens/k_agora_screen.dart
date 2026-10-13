import 'package:flutter/material.dart';
import 'dotk_market_screen.dart';
import 'nft_market_screen.dart';
import 'nexus_screen.dart';
import 'kaspacom_market_screen.dart';

class KAgoraScreen extends StatelessWidget {
  const KAgoraScreen({super.key, required this.address});
  final String address;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('K-Agora')),
        body: SafeArea(
            child: ListView(padding: const EdgeInsets.all(20), children: [
          Card(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                  side: BorderSide(
                      color: Theme.of(context).colorScheme.primary, width: 2)),
              child: ListTile(
                  contentPadding: const EdgeInsets.all(20),
                  leading: Image.asset('assets/branding/kaspacom.png',
                      width: 52, height: 52, fit: BoxFit.contain),
                  title: const Text('KaspaCom Marketplace'),
                  subtitle: const Text('KRC-721 · KRC-20 · KNS'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) =>
                              KaspaComMarketScreen(address: address))))),
          const SizedBox(height: 20),
          const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Text('Kaspire Markets & Offers')),
          Card(
              child: ListTile(
                  contentPadding: const EdgeInsets.all(20),
                  leading: const Icon(Icons.alternate_email, size: 32),
                  title: const Text('dot.k Market'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) =>
                              DotkMarketScreen(address: address))))),
          Card(
              child: ListTile(
                  contentPadding: const EdgeInsets.all(20),
                  leading: const Icon(Icons.collections_outlined, size: 32),
                  title: const Text('NFT Market'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => NftMarketScreen(address: address))))),
          Card(
              child: ListTile(
                  contentPadding: const EdgeInsets.all(20),
                  leading: const Icon(Icons.hub_outlined, size: 32),
                  title: const Text('Nexus Offers'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => NexusScreen(address: address))))),
        ])),
      );
}
