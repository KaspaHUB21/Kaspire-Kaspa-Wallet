import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/kasforge_service.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';

// Explicitly opt-in public READS, never build/sign/submit or private wallets.
// flutter test --dart-define=KASPIRE_KASFORGE_LIVE=true test/kasforge_live_test.dart
void main() {
  test('real KasForge TN10 catalogue, public-holder balances and pool quote',
      () async {
    NetworkSettings.network.value = KaspaNetwork.tn10;
    final service = KasForgeService();
    final tokens = await service.catalogue();
    expect(tokens, isNotEmpty);
    final assets = await service.walletAssets(
        'kaspatest:qp2srppaehqgjxxw4fyf2ckdzha9nz573eapxw0acg4ntc27cy2w23jck27ql');
    expect(assets, isNotEmpty);
    expect(assets.every((a) => a.decimals == 0 && a.balance > 0), true);
    final coin = tokens.firstWhere((t) => t.graduated);
    final quote = await service.quote(coin, 'buy', '10');
    expect(quote['marketId'], coin.pool);
    expect(KasForgeService.exactUnsigned(quote['receiveTokens']) > BigInt.zero,
        true);
    service.client.close();
  },
      skip: !const bool.fromEnvironment('KASPIRE_KASFORGE_LIVE'),
      timeout: const Timeout(Duration(seconds: 65)));
}
