import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/screens/kasseal_screen.dart';
import 'package:kasvault_wallet/src/services/kasseal_service.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';

class FakeKasseal extends KassealService {
  @override
  Future<BigInt> kasBalance(String address) async => BigInt.from(10000000000);
  @override
  Future<Map<String, dynamic>?> pending(String address) async => null;
  @override
  Future<Map<String, dynamic>> wallet(String address) async => {'holdings': []};
  @override
  Future<Map<String, dynamic>> tokens([String? cursor]) async =>
      {'tokens': [], 'nextCursor': null};
  @override
  Future<List<Map<String, dynamic>>> history(String address) async => [
        {
          'transactionId': 'a' * 64,
          'ticker': 'WALLET',
          'timestamp': '2026-10-23T00:00:00Z',
          'summary': {
            'side': 'buy',
            'tokenAmount': '1000',
            'kasSompi': '100000000'
          }
        }
      ];
}

void main() {
  for (final theme in [
    KaspireTheme.midnight,
    KaspireTheme.hub21,
    KaspireTheme.glacier,
    KaspireTheme.neptune
  ]) {
    testWidgets(
        'Buying shows KAS budget, selling shows token holdings at 320px in $theme',
        (tester) async {
      NetworkSettings.network.value = KaspaNetwork.tn10;
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: KassealTradeScreen(
              address: 'kaspatest:qfixture',
              token: {
                'meta': {'covenantId': 'a' * 64, 'ticker': 'WALLET'}
              },
              service: FakeKasseal())));
      await tester.pumpAndSettle();
      expect(find.text('Available to buy: 100 KAS'), findsOneWidget);
      expect(find.text('Your token balance: 0 WALLET'), findsOneWidget);
      await tester.tap(find.text('Sell'));
      await tester.pumpAndSettle();
      expect(find.text('Available to sell: 0 WALLET'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('Swap history is a separate tab with earlier swaps',
      (tester) async {
    NetworkSettings.network.value = KaspaNetwork.tn10;
    await tester.pumpWidget(MaterialApp(
        home: KassealScreen(
            address: 'kaspatest:qfixture', service: FakeKasseal())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Swap history'));
    await tester.pumpAndSettle();
    expect(find.text('Buy WALLET'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
