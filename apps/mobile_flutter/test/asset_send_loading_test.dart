import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kasvault_wallet/src/models/asset_send_intent.dart';
import 'package:kasvault_wallet/src/models/wallet_snapshot.dart';
import 'package:kasvault_wallet/src/screens/asset_send_screen.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';

const snapshot = WalletSnapshot(
    balanceSompi: 100000000,
    kasUsd: null,
    transactions: [],
    krc20Tokens: [
      WalletAsset(symbol: 'TEST', balance: 12, kind: 'KRC-20')
    ],
    krc721Collections: [
      WalletAsset(symbol: 'NFT', balance: 1, kind: 'KRC-721')
    ],
    knsDomains: [],
    kcc20Tokens: [
      WalletAsset(
          symbol: 'SAME', balance: 1, kind: 'KCC20', covenantId: 'first'),
      WalletAsset(
          symbol: 'SAME', balance: 2, kind: 'KCC20', covenantId: 'second')
    ]);

class SlowApi extends KaspaApi {
  final result = Completer<WalletSnapshot>();
  bool holdingsOnly = false;
  @override
  Future<WalletSnapshot> loadWallet(String address,
      {int transactionLimit = 20,
      bool includeNativeTransactions = true,
      bool includeAssetHistory = true,
      bool includeMarketData = true,
      void Function(WalletSnapshot)? onProgress}) {
    holdingsOnly = !includeNativeTransactions &&
        !includeAssetHistory &&
        !includeMarketData;
    return result.future;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
      'pending KCC20 compound survives closing the view without implying recipient payment',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'kaspire_pending_kcc20_compound_kaspa:test': jsonEncode({
        'operation': {
          'kind': 'kcc20',
          'covenantId': 'second',
          'intendedRecipient': 'kaspa:recipient',
          'intendedAmount': '2',
          'intendedDisplayAmount': '2',
          'standard': 'kcc20'
        },
        'transactionId': 'a' * 64,
      })
    });
    final api = SlowApi();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AssetSendScreen(
                address: 'kaspa:test', onDone: () {}, api: api))));
    await tester.pump();
    expect(find.text('KCC20 TRANSFER NOT COMPLETED'), findsOneWidget);
    expect(find.textContaining('recipient has NOT been paid'), findsOneWidget);
    expect(find.text('Continue KCC20 transfer'), findsOneWidget);
    api.result.complete(snapshot);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('selected asset is usable before the refresh finishes',
      (tester) async {
    final api = SlowApi();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AssetSendScreen(
                address: 'kaspa:test',
                onDone: () {},
                api: api,
                initialAsset:
                    const AssetSendIntent.krc20('TEST', wallet: snapshot)))));
    await tester.pump();
    expect(find.text('TEST'), findsWidgets);
    expect(api.holdingsOnly, isTrue);
    expect(api.result.isCompleted, isFalse);
    api.result.complete(WalletSnapshot(
        balanceSompi: 100000000,
        kasUsd: null,
        transactions: [],
        krc20Tokens: [
          const WalletAsset(symbol: 'TEST', balance: 10, kind: 'KRC-20')
        ],
        krc721Collections: snapshot.krc721Collections,
        knsDomains: [],
        kcc20Tokens: snapshot.kcc20Tokens));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('same ticker does not select the wrong covenant', (tester) async {
    final api = SlowApi();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AssetSendScreen(
                address: 'kaspa:test',
                onDone: () {},
                api: api,
                initialAsset: const AssetSendIntent.kcc20('SAME', 'second',
                    wallet: snapshot)))));
    await tester.pump();
    final field = tester.widget<DropdownButtonFormField<WalletAsset>>(
        find.byType(DropdownButtonFormField<WalletAsset>));
    expect(field.initialValue?.covenantId, 'second');
    api.result.complete(snapshot);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
