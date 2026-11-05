import 'package:flutter/material.dart';
import '../models/wallet_snapshot.dart';
import '../number_format.dart';
import '../services/kforge_service.dart';
import '../services/kforge_trading.dart';
import '../widgets/kforge_image.dart';
import 'kasparocket_screen.dart' show rocketListPadding;
import 'kforge_trade_screen.dart';

class KForgeScreen extends StatefulWidget {
  const KForgeScreen(
      {super.key,
      required this.address,
      this.initialTokenId,
      this.service,
      this.trading});
  final String address;
  final String? initialTokenId;
  final KForgeService? service;
  final KForgeTrading? trading;
  @override
  State<KForgeScreen> createState() => _KForgeScreenState();
}

class _KForgeScreenState extends State<KForgeScreen>
    with SingleTickerProviderStateMixin {
  late final service = widget.service ?? KForgeService();
  late final trading = widget.trading ?? KForgeTrading();
  late final tabs = TabController(length: 2, vsync: this);
  late Future<KForgeSnapshot> data;
  final search = TextEditingController();
  int visible = 20;
  bool opened = false;
  int revision = 0;
  @override
  void initState() {
    super.initState();
    reload();
  }

  void reload() {
    setState(() {
      data = service.load(widget.address);
      visible = 20;
      revision++;
    });
  }

  @override
  void dispose() {
    search.dispose();
    tabs.dispose();
    super.dispose();
  }

  Future<void> open(KForgeToken token, List<WalletAsset> assets) async {
    final held = assets.where((a) => a.covenantId == token.id).firstOrNull;
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => KForgeTradeScreen(
            address: widget.address,
            token: token,
            balance: held?.rawBalance ?? '0',
            trading: trading)));
    if (mounted) reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(
          title: Text('KForge · ${service.label}'),
          actions: [
            IconButton(
                onPressed: reload,
                tooltip: 'Reload',
                icon: const Icon(Icons.refresh))
          ],
          bottom: TabBar(
              controller: tabs,
              tabs: const [Tab(text: 'DEX swaps'), Tab(text: 'My activity')])),
      body: TabBarView(controller: tabs, children: [
        browse(),
        KForgeActivity(
            key: ValueKey(revision),
            address: widget.address,
            trading: trading,
            onReturnToDex: () {
              tabs.animateTo(0);
              reload();
            })
      ]));

  Widget browse() => FutureBuilder<KForgeSnapshot>(
      future: data,
      builder: (context, s) {
        if (s.hasError) {
          return Center(
              child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('${s.error}', textAlign: TextAlign.center),
                    OutlinedButton(
                        onPressed: reload, child: const Text('Retry'))
                  ])));
        }
        if (!s.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final value = s.data!, q = search.text.trim().toLowerCase();
        if (!opened && widget.initialTokenId != null) {
          opened = true;
          final token = value.tokens
              .where((t) => t.id == widget.initialTokenId)
              .firstOrNull;
          if (token != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) open(token, value.assets);
            });
          }
        }
        final rows = value.tokens
            .where((t) => [t.name, t.symbol, t.id, t.curve]
                .any((v) => v.toLowerCase().contains(q)))
            .toList();
        return ListView(
            key: const Key('kforge-browse-list'),
            padding: rocketListPadding(context),
            children: [
              if (s.connectionState == ConnectionState.waiting)
                const LinearProgressIndicator(),
              Card(
                  child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Row(children: [
                        const KForgeImage(),
                        const SizedBox(width: 12),
                        Expanded(
                            child: Text(
                                'Native ${service.mainnet ? 'Mainnet' : 'Testnet 10'} curve and pool swaps are independently verified by the shared Rust core.'))
                      ]))),
              TextField(
                  controller: search,
                  onChanged: (_) => setState(() => visible = 20),
                  decoration: const InputDecoration(
                      labelText: 'Search ticker, name or covenant ID',
                      prefixIcon: Icon(Icons.search))),
              const SizedBox(height: 12),
              for (final token in rows.take(visible))
                Card(
                    child: ListTile(
                        leading: KForgeImage(url: token.logo),
                        title: Text('${token.symbol} · ${token.name}',
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                            '${token.graduated ? "Pool" : "Curve"} · ${formatEnglishNumber(token.priceKas, decimals: 12, trimTrailingZeros: true)} KAS/token\nMarket cap: ${formatEnglishNumber(token.marketCapKas, decimals: 2)} KAS'),
                        isThreeLine: true,
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => open(token, value.assets))),
              if (rows.isEmpty)
                const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('No matching KForge tokens.')),
              if (rows.length > visible)
                OutlinedButton(
                    onPressed: () => setState(() => visible += 20),
                    child: const Text('Load more')),
            ]);
      });
}
