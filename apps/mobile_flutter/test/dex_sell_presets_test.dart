import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/screens/kasseal_screen.dart';
import 'package:kasvault_wallet/src/screens/kasparocket_screen.dart';
import 'package:kasvault_wallet/src/screens/kron_dex_screen.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';
import 'package:kasvault_wallet/src/services/kasparocket_service.dart';
import 'package:kasvault_wallet/src/services/kasseal_service.dart';
import 'package:kasvault_wallet/src/services/kron_dex_service.dart';
import 'package:kasvault_wallet/src/services/kron_holdings.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';
import 'package:kasvault_wallet/src/widgets/sell_amount_buttons.dart';

final id = 'a' * 64;

class Api extends KaspaApi {
  @override
  Future<int> loadBalanceSompi(String address) async => 10000000000;
}

class Rocket extends KaspaRocketService {
  @override
  Future<Map<String, Object?>?> pending(String address) async => null;
  @override
  Future<String> poolCovenant(String token) async => 'b' * 64;
  @override
  Future<Map<String, Object?>> holding(String address, String token) async =>
      {'balance_tokens': '1234567'};
}

class Kron extends KronDexService {
  @override
  Future<Map<String, dynamic>?> pending(String address) async => null;
}

class Holdings extends KronHoldings {
  Holdings() : super(MockClient((_) async => http.Response('{}', 500)));
  @override
  Future<List<Map<String, dynamic>>> balances(String address) async => [
        {'covenantId': id, 'balance': '123456789'}
      ];
}

class Seal extends KassealService {
  @override
  Future<BigInt> kasBalance(String address) async => BigInt.from(10000000000);
  @override
  Future<Map<String, dynamic>?> pending(String address) async => null;
  @override
  Future<Map<String, dynamic>> wallet(String address) async => {
        'holdings': [
          {'tokenId': id, 'balance': '12345'}
        ]
      };
}

void main() {
  setUp(() => NetworkSettings.network.value = KaspaNetwork.mainnet);
  for (final theme in [
    KaspireTheme.midnight,
    KaspireTheme.hub21,
    KaspireTheme.glacier,
    KaspireTheme.neptune
  ]) {
    for (final venue in ['Rocket', 'KRON', 'Kasseal pool', 'Kasseal curve']) {
      testWidgets(
          '$venue sell presets fill the real field exactly and stay in one row at 320px in $theme',
          (tester) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final Widget screen;
        final List<String> expected;
        if (venue == 'Rocket') {
          screen = KaspaRocketTradeScreen(
              address: 'kaspa:qfixture',
              token: KaspaRocketToken(
                  tokenId: id,
                  ticker: 'TEST',
                  name: 'Test',
                  image: '',
                  description: ''),
              service: Rocket(),
              api: Api());
          expected = ['308.641', '617.283', '925.925', '1234.567'];
        } else if (venue == 'KRON') {
          screen = KronTradeScreen(
              address: 'kaspa:qfixture',
              token: {
                'covenantId': id,
                'ticker': 'TEST',
                'name': 'Test',
              'image': 'https://example.invalid/token.png',
                'decimals': 8
              },
              service: Kron(),
              api: Api(),
              holdings: Holdings());
          expected = ['0.30864197', '0.61728394', '0.92592591', '1.23456789'];
        } else {
          screen = KassealTradeScreen(
              address: 'kaspa:qfixture',
              token: {
                'meta': {'covenantId': id, 'ticker': 'TEST'},
                'phase': venue.endsWith('curve') ? 'bonding' : 'graduated',
                'curve': {'lotSize': '1000'}
              },
              service: Seal());
          expected = venue.endsWith('curve')
              ? ['3000', '6000', '9000', '12000']
              : ['3086', '6172', '9258', '12345'];
        }
        await tester.pumpWidget(
            MaterialApp(theme: KasVaultTheme.forTheme(theme), home: screen));
        await tester.pumpAndSettle();
        expect(find.byType(SellAmountButtons), findsNothing);
        await tester.scrollUntilVisible(find.text('Sell'), 150,
            scrollable: find.byType(Scrollable).first);
        await tester.tap(find.text('Sell'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.byType(SellAmountButtons), 100,
            scrollable: find.byType(Scrollable).first);
        await tester.pumpAndSettle();
        for (var i = 0; i < 4; i++) {
          await tester.tap(find.text(['25%', '50%', '75%', 'MAX'][i]));
          await tester.pump();
          expect(
              tester
                  .widget<TextField>(find.byType(TextField).first)
                  .controller!
                  .text,
              expected[i]);
        }
        final tops = [
          for (final label in ['25%', '50%', '75%', 'MAX'])
            tester.getTopLeft(find.text(label)).dy
        ];
        expect(tops.every((top) => (top - tops.first).abs() < 1), isTrue);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
