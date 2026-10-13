import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kasvault_wallet/src/models/wallet_snapshot.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';
import 'package:kasvault_wallet/src/services/kaspacom_market_service.dart';
import 'package:kasvault_wallet/src/screens/kaspacom_market_screen.dart';

const wallet =
    'kaspa:qqnvxvumjvzwmn755v8nrp4jxm2w50dv9mr2u4qrfqpq3h2hzyjx7tgkdtdgs';

class HoldingsApi extends KaspaApi {
  int tokenReads = 0, nameReads = 0;
  @override
  Future<WalletSnapshot> loadWallet(String address,
          {int transactionLimit = 20,
          bool includeNativeTransactions = true,
          bool includeAssetHistory = true,
          bool includeMarketData = true,
          void Function(WalletSnapshot)? onProgress}) =>
      Future.error(StateError('Marketplace must not scan the complete wallet'));
  @override
  Future<List<WalletAsset>> loadKrc20Holdings(String address) async {
    tokenReads++;
    return List.generate(
        12,
        (i) => WalletAsset(
            symbol: 'TOKEN${i.toString().padLeft(2, '0')}',
            balance: 1,
            kind: 'KRC-20',
            decimals: 8,
            rawBalance: '100000000'));
  }

  @override
  Future<List<KnsDomain>> loadKnsHoldings(String address,
      {void Function(List<KnsDomain>)? onProgress,
      void Function(String)? onWarning}) async {
    nameReads++;
    return [
      const KnsDomain(
          name: 'example.kas', status: 'unlisted', assetId: 'name-id')
    ];
  }
}

class SlowExtrasMarket extends KaspaComMarketService {
  SlowExtrasMarket(this.holdings) : super(wallet, api: holdings);
  final HoldingsApi holdings;
  final logos = Completer<Map<String, Object?>>();
  final status = Completer<void>();
  @override
  Future<Map<String, Object?>> catalog(String kind, int offset) async =>
      {'items': []};
  @override
  Future<Map<String, Object?>> browse(
          String kind, String search, String sort, int offset,
          {Map<String, String> traits = const {}}) async =>
      {'orders': []};
  @override
  Future<Map<String, Object?>> tokenSummary(String ticker) => logos.future;
  @override
  Future<void> decorateKnsListingStates(
      List<Map<String, Object?>> items) async {
    await status.future;
    for (final item in items) {
      item['marketplaceListed'] = true;
    }
  }
}

void main() {
  setUp(() =>
      SharedPreferences.setMockInitialValues({'watch_address_v1': wallet}));
  testWidgets(
      'KRC20 holdings and pagination do not wait for logos or any full-wallet scan',
      (tester) async {
    final api = HoldingsApi();
    final actual = SlowExtrasMarket(api);
    await tester.pumpWidget(MaterialApp(
        home: KaspaComMarketScreen(address: wallet, service: actual)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('KRC-20'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My assets'));
    await tester.pumpAndSettle();
    expect(find.text('TOKEN00'), findsOneWidget);
    expect(actual.logos.isCompleted, isFalse);
    expect(api.tokenReads, 1);
    await tester.scrollUntilVisible(find.text('Load more'), 400,
        scrollable: find
            .descendant(
                of: find.byType(ListView), matching: find.byType(Scrollable))
            .first);
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    expect(api.tokenReads, 1);
    expect(find.text('Load more'), findsNothing);
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    expect(api.tokenReads, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    actual.logos.complete({});
  });
  testWidgets(
      'KNS holdings appear while listing status is pending, without allowing duplicate listing',
      (tester) async {
    final actual = SlowExtrasMarket(HoldingsApi());
    await tester.pumpWidget(MaterialApp(
        home: KaspaComMarketScreen(address: wallet, service: actual)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('KNS'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My assets'));
    await tester.pumpAndSettle();
    expect(find.text('example.kas'), findsOneWidget);
    expect(find.text('Checking listing status…'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(find.ancestor(
        of: find.text('Checking listing status…'),
        matching: find.byType(OutlinedButton)));
    expect(button.onPressed, isNull);
    actual.status.complete();
    await tester.pumpAndSettle();
    expect(find.text('Already listed'), findsOneWidget);
    expect(find.text('Checking listing status…'), findsNothing);
    expect(actual.holdings.nameReads, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
