import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/kaspa_address.dart';
import 'package:kasvault_wallet/src/models/wallet_snapshot.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'kforge_service_test.dart'
    show kforgeAddress, kforgeRegistry, kforgeHoldings, kforgeToken;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => NetworkSettings.network.value = KaspaNetwork.tn10);
  test(
      'real wallet snapshot finds KForge KCC20 from a stored Mainnet-format address before other sources finish',
      () async {
    final slow = Completer<http.Response>(),
        metadata = Completer<http.Response>();
    final positive = Completer<WalletSnapshot>(), requested = <String>[];
    final body = kforgeHoldings();
    (body['holdings'] as List).single['ticker'] = 'NEW';
    final api = KaspaApi(client: MockClient((r) async {
      if (r.url.host == 'api-test.kforge.xyz') {
        if (r.url.path.endsWith('/registry'))
          return http.Response(jsonEncode(kforgeRegistry()), 200);
        if (r.url.path == '/v6/tokens') return metadata.future;
        requested.add(r.url.pathSegments.last);
        return http.Response(jsonEncode(body), 200);
      }
      if (r.url.path.endsWith('/balance'))
        return http.Response('{"balance":100000000}', 200);
      if (r.url.path.endsWith('/utxos')) return http.Response('[]', 200);
      return slow.future;
    }));
    final loaded = api.loadWallet(
        kaspaAddressWithPrefix(kforgeAddress, 'kaspa'),
        includeNativeTransactions: false,
        includeAssetHistory: false,
        includeMarketData: false, onProgress: (s) {
      if (s.kcc20Tokens.any((t) => t.standard == 'kforge-kcc20') &&
          !positive.isCompleted) positive.complete(s);
    });
    final early = await positive.future.timeout(const Duration(seconds: 2));
    expect(requested, [kforgeAddress]);
    expect(early.kcc20Tokens.single.symbol, 'NEW');
    expect(early.kcc20Tokens.single.rawBalance, '15000000');
    expect(early.kcc20Tokens.single.decimals, 0);
    metadata.complete(http.Response(jsonEncode([kforgeToken()]), 200));
    slow.complete(http.Response('{}', 503));
    final finalSnapshot = await loaded;
    expect(finalSnapshot.kcc20Tokens.single.standard, 'kforge-kcc20');
    expect(finalSnapshot.kcc20Tokens.single.symbol, 'SAME');
    expect(finalSnapshot.kcc20Tokens.single.imageUrl, isNotNull);
    expect(finalSnapshot.kcc20Tokens.single.discoveryComplete, false);
    expect(finalSnapshot.assetWarning, isNotEmpty);
  });
  test(
      'metadata outage preserves the indexed KCC20 balance in the final wallet snapshot',
      () async {
    final api = KaspaApi(client: MockClient((r) async {
      if (r.url.host == 'api-test.kforge.xyz') {
        if (r.url.path.endsWith('/registry'))
          return http.Response(jsonEncode(kforgeRegistry()), 200);
        if (r.url.path.contains('/holdings/'))
          return http.Response(jsonEncode(kforgeHoldings()), 200);
      }
      if (r.url.path.endsWith('/balance'))
        return http.Response('{"balance":0}', 200);
      if (r.url.path.endsWith('/utxos')) return http.Response('[]', 200);
      return http.Response('{}', 503);
    }));
    final s = await api.loadWallet(kforgeAddress,
        includeNativeTransactions: false,
        includeAssetHistory: false,
        includeMarketData: false);
    expect(s.kcc20Tokens.single.rawBalance, '15000000');
    expect(s.assetWarning, contains('KForge metadata'));
    expect(s.kcc20Tokens.single.priceKas, isNull);
  });
}
