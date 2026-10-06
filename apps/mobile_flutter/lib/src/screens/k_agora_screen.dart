import 'package:flutter/material.dart';
import 'dotk_market_screen.dart';
import 'nft_market_screen.dart';

class KAgoraScreen extends StatelessWidget {
  const KAgoraScreen({super.key, required this.address});
  final String address;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('K-Agora')),
        body: SafeArea(
            child: ListView(padding: const EdgeInsets.all(20), children: [
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
        ])),
      );
}
