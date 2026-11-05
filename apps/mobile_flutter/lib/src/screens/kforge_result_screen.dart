import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../number_format.dart';
import '../services/kforge_service.dart';
import '../widgets/kforge_image.dart';
import 'kasparocket_screen.dart' show rocketListPadding;

/// Only independently confirmed receipts may render this success page. No
/// signing, broadcasting, changing a plan or marking success happens here.
class KForgeResultScreen extends StatelessWidget {
  const KForgeResultScreen(
      {super.key, required this.receipt, this.returnToDex});
  final Map<String, dynamic> receipt;
  final VoidCallback? returnToDex;

  @override
  Widget build(BuildContext context) {
    if (receipt['state'] != 'confirmed' ||
        !['mainnet', 'testnet-10'].contains(receipt['network'])) {
      return Scaffold(
          appBar: AppBar(title: const Text('KForge swap')),
          body: const Center(
              child: Text(
                  'This swap is not independently confirmed yet. Its saved transaction remains preserved.')));
    }
    final v = receipt['verified'] as Map;
    final buy = receipt['side'] == 'buy', token = '${receipt['symbol']}';
    final request = receipt['request'] as Map?;
    final market = (request?['tradeSummary'] as Map?)?['market'] as Map?;
    final date =
        DateTime.fromMillisecondsSinceEpoch(receipt['createdAt'] as int)
            .toLocal();
    String kas(Object? value) =>
        '${formatRawTokenAmount(BigInt.parse('$value'), 8)} KAS';
    Widget line(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          SelectableText(value)
        ]));
    Widget copy(String label, String value) => OutlinedButton.icon(
        onPressed: () => Clipboard.setData(ClipboardData(text: value)),
        icon: const Icon(Icons.copy),
        label: Text(label));
    return Scaffold(
        appBar: AppBar(title: const Text('KForge · Swap confirmed')),
        body: ListView(
            key: const Key('kforge-result-list'),
            padding: rocketListPadding(context),
            children: [
              Icon(Icons.check_circle_outline,
                  size: 64, color: Theme.of(context).colorScheme.primary),
              Text('Swap confirmed',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 16),
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(children: [
                              KForgeImage(
                                  url: KForgeToken.image(market?['image'],
                                      mainnet: receipt['network'] == 'mainnet'),
                                  size: 56),
                              const SizedBox(width: 14),
                              Expanded(
                                  child: Text('${buy ? 'Buy' : 'Sell'} $token',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge))
                            ]),
                            line('Status', 'Confirmed'),
                            line(
                                'Network',
                                receipt['network'] == 'mainnet'
                                    ? 'Kaspa Mainnet'
                                    : 'Kaspa Testnet 10'),
                            line(
                                'Market',
                                v['venue'] == 'pool'
                                    ? 'Pool'
                                    : 'Bonding curve'),
                            line('Token amount',
                                '${formatRawTokenAmount(BigInt.parse('${v['tokens']}'), 0)} $token'),
                            if (buy && v['buyBudgetSompi'] != null) ...[
                              line('KAS trade amount entered',
                                  kas(v['buyBudgetSompi'])),
                              if (BigInt.parse('${v['unspentBudgetSompi']}') >
                                  BigInt.zero)
                                line('Not used for tokens (lot rounding)',
                                    kas(v['unspentBudgetSompi'])),
                            ],
                            line(
                                buy
                                    ? 'Total KAS paid (all-in)'
                                    : 'Net KAS received',
                                kas(v['walletNet'])),
                            line(
                                buy
                                    ? 'Market cost'
                                    : 'Sale proceeds after protocol fee',
                                kas(v['marketKas'])),
                            line(
                                buy && v['venue'] == 'pool'
                                    ? 'Protocol fee (added)'
                                    : 'Protocol fee (included / deducted)',
                                kas(v['protocolFee'])),
                            line('Network fee', kas(v['networkFee'])),
                            line(
                                buy
                                    ? 'Token-cell reserve added'
                                    : 'Token-cell reserve returned',
                                kas(v['cellReserveChange'])),
                            line('Date', date.toString()),
                            line('Token covenant ID', '${receipt['tokenId']}'),
                            copy('Copy token covenant ID',
                                '${receipt['tokenId']}'),
                            if (request?['lpCovenantId'] != null) ...[
                              line('Market covenant ID',
                                  '${request!['lpCovenantId']}'),
                              copy('Copy market covenant ID',
                                  '${request['lpCovenantId']}')
                            ],
                            line('Transaction ID', '${receipt['id']}'),
                            copy('Copy transaction ID', '${receipt['id']}'),
                          ]))),
              const SizedBox(height: 16),
              FilledButton(
                  onPressed: () => returnToDex != null
                      ? returnToDex!()
                      : Navigator.pop(context),
                  child: const Text('Return to KForge DEX')),
            ]));
  }
}
