import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kasvault_wallet/src/services/kaspacom_market_service.dart';
import 'package:kasvault_wallet/src/services/nft_market_service.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/screens/kaspacom_market_screen.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';
import 'package:kasvault_wallet/src/models/wallet_snapshot.dart';

const wallet =
    'kaspa:qqnvxvumjvzwmn755v8nrp4jxm2w50dv9mr2u4qrfqpq3h2hzyjx7tgkdtdgs';
void main() {
  testWidgets(
      'already listed NFT has a disabled status instead of another listing button',
      (tester) async {
    SharedPreferences.setMockInitialValues({'watch_address_v1': wallet});
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    final service = KaspaComMarketService(wallet, client: MockClient((r) async {
      if (r.url.path.contains('/nfts/')) {
        return http.Response(
            jsonEncode({
              'result': {
                'owner': wallet,
                'status': {
                  'state': r.url.path.endsWith('/48') ? 'listed' : 'unlisted'
                }
              }
            }),
            200);
      }
      return http.Response('{"items":[]}', 200);
    }));
    await tester.pumpWidget(MaterialApp(
        home: KaspaComMarketScreen(
            address: wallet, service: service, nftService: _ListingNfts())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My assets'));
    await tester.pumpAndSettle();
    expect(find.text('Already listed'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(find.ancestor(
        of: find.text('Already listed'),
        matching: find.byType(OutlinedButton)));
    expect(button.onPressed, isNull);
    expect(find.text('List on KaspaCom'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('KNS holdings use Already listed instead of a second list action',
      (tester) async {
    SharedPreferences.setMockInitialValues({'watch_address_v1': wallet});
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    final service = KaspaComMarketService(wallet,
        api: _KnsApi(),
        client: MockClient((_) async => http.Response('{"items":[]}', 200)));
    await tester.pumpWidget(MaterialApp(
        home: KaspaComMarketScreen(address: wallet, service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('KNS'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My assets'));
    await tester.pumpAndSettle();
    expect(find.text('Already listed'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(find.ancestor(
        of: find.text('Already listed'),
        matching: find.byType(OutlinedButton)));
    expect(button.onPressed, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  for (final kind in ['krc20', 'krc721', 'kns']) {
    testWidgets(
        '$kind verified purchase opens success and returns to marketplace',
        (tester) async {
      SharedPreferences.setMockInitialValues({'watch_address_v1': wallet});
      NetworkSettings.network.value = KaspaNetwork.mainnet;
      final service = _CompletedPurchaseService();
      await tester.pumpWidget(MaterialApp(
          home: KaspaComMarketScreen(address: wallet, service: service)));
      await tester.pumpAndSettle();
      if (kind != 'krc721') {
        await tester.tap(find.text(kind == 'krc20' ? 'KRC-20' : 'KNS'));
        await tester.pumpAndSettle();
      }
      await tester.enterText(find.byType(TextField).first, 'HASH');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('View order'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('View order'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review purchase'));
      await tester.pumpAndSettle();
      expect(find.text('Purchase successful'), findsOneWidget);
      expect(find.text('Return to marketplace'), findsOneWidget);
      await tester.ensureVisible(find.text('Return to marketplace'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Return to marketplace'));
      await tester.pumpAndSettle();
      expect(find.text('KaspaCom Marketplace'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

class _KnsApi extends KaspaApi {
  @override
  Future<WalletSnapshot> loadWallet(String address,
          {int transactionLimit = 20,
          bool includeNativeTransactions = true,
          void Function(WalletSnapshot)? onProgress}) async =>
      const WalletSnapshot(
          balanceSompi: 1000000000,
          kasUsd: 0.03,
          transactions: [],
          krc20Tokens: [],
          krc721Collections: [],
          knsDomains: [
            KnsDomain(name: 'example.kas', status: 'listed', assetId: 'id')
          ]);
}

class _CompletedPurchaseService extends KaspaComMarketService {
  _CompletedPurchaseService()
      : super(wallet,
            client: MockClient((_) async => http.Response('{}', 200)));
  Map<String, Object?> row(String kind) => {
        'orderId': 'a' * 24,
        'ticker': 'HASH',
        'tokenId': '48',
        'asset': 'example.kas',
        'sellerWalletAddress': 'another-wallet',
        'status': 'LISTED_FOR_SALE',
        'totalPrice': 11,
        'quantity': 1,
        'currentFee': 0.5
      };
  @override
  Future<Map<String, Object?>> catalog(String kind, int offset) async =>
      {'items': []};
  @override
  Future<Map<String, Object?>> browse(
          String kind, String search, String sort, int offset,
          {Map<String, String> traits = const {}}) async =>
      {
        'orders': [row(kind)],
        'nextOffset': null
      };
  @override
  Future<Map<String, Object?>> detail(String kind, String id,
          {bool quote = false}) async =>
      row(kind);
  @override
  Future<Map<String, Object?>> tokenSummary(String ticker) async =>
      {'floorPrice': 11};
  @override
  Future<Map<String, Object?>> traitCatalog(String ticker) async => {};
  @override
  Future<KaspaComPurchaseResult?> transact(String kind,
      Map<String, Object?> order, bool buy, KaspaComReview approve) async {
    lastPurchaseReceipt =
        null; // UI must honor the explicit result for every kind.
    return KaspaComPurchaseResult({
      'Asset': kind == 'kns'
          ? 'example.kas'
          : kind == 'krc721'
              ? 'HASH #48'
              : 'HASH',
      'Transaction ID': 'b' * 64
    });
  }
}

class _ListingNfts extends NftMarketService {
  @override
  Future<List<String>> ownedCollections(String address) async => ['21MCOVEN'];
  @override
  Future<Map<String, Object?>> owned(String address,
          {String? cursor, String? collection}) async =>
      {
        'items': [
          <String, Object?>{'ticker': '21MCOVEN', 'tokenId': '48'},
          <String, Object?>{'ticker': '21MCOVEN', 'tokenId': '49'}
        ],
        'next': null
      };
}
