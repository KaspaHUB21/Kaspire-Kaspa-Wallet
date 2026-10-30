import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/screens/kasseal_screen.dart';
import 'package:kasvault_wallet/src/screens/kasparocket_screen.dart';
import 'package:kasvault_wallet/src/services/dex_display_price.dart';
import 'package:kasvault_wallet/src/services/kasseal_service.dart';
import 'package:kasvault_wallet/src/services/kasparocket_service.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';

class DisplayRate extends DexDisplayPrice {
  final pending = Completer<double?>();
  int calls = 0;
  @override
  Future<double?> kasUsd({required bool kasseal}) {
    calls++;
    return pending.future;
  }
}

class SealCatalogue extends KassealService {
  @override
  Future<List<Map<String, dynamic>>> history(String _) async => [];
  @override
  Future<Map<String, dynamic>> tokens([String? cursor]) async => {
        'tokens': [
          {
            'meta': {'covenantId': 'a' * 64, 'ticker': 'TEK'},
            'verification': 'verified',
            'phase': 'bonding',
            'marketCapSompi': '76128931200000',
            'supply': {'total': '1200000000'},
            'volume24hSompi': '12345678900000'
          }
        ],
        'nextCursor': null
      };
}

class RocketCatalogue extends KaspaRocketService {
  RocketCatalogue() : super(mainnet: true);
  @override
  Future<List<KaspaRocketToken>> tokens() async => [
        KaspaRocketToken(
            tokenId: 'b' * 64,
            ticker: 'ROCKET',
            name: 'Rocket token',
            image: '',
            description: '',
            marketCapKas: 761289.312,
            priceKas: .00063440776,
            volume24hKas: 123456.789,
            phase: 'amm')
      ];
  @override
  Future<Map<String, Object?>> activity(String _) async => {'activity': []};
}

void main() {
  setUp(() => NetworkSettings.network.value = KaspaNetwork.mainnet);
  for (final seal in [true, false]) {
    testWidgets(
        '${seal ? 'Kasseal' : 'Rocket'} catalogue stays usable before display rate, then shows all three metrics',
        (tester) async {
      final price = DisplayRate();
      await tester.pumpWidget(MaterialApp(
          home: seal
              ? KassealScreen(
                  address: 'kaspa:qfixture',
                  service: SealCatalogue(),
                  displayPrice: price)
              : KaspaRocketScreen(
                  address: 'kaspa:qfixture',
                  service: RocketCatalogue(),
                  displayPrice: price)));
      await tester.pump();
      await tester.pump();
      expect(find.text(seal ? 'TEK' : 'ROCKET'), findsOneWidget);
      final scroll = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
          find.text('24h volume: 123,456.789 KAS'), 100,
          scrollable: scroll);
      expect(find.text('Market cap: Unavailable'), findsOneWidget);
      expect(find.text('Price: 0.00063441 KAS / token'), findsOneWidget);
      price.pending.complete(.04);
      await tester.pumpAndSettle();
      expect(find.text('Market cap: 30,451.57 USD'), findsOneWidget);
      expect(price.calls, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
