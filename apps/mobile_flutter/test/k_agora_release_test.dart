import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kasvault_wallet/src/screens/k_agora_screen.dart';
import 'package:kasvault_wallet/src/screens/kaspacom_market_screen.dart';
import 'package:kasvault_wallet/src/services/kaspacom_market_service.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';

void main() {
  for (final theme in KaspireTheme.values) {
    testWidgets('KaspaCom is first and separated in narrow K-Agora: $theme',
        (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: const KAgoraScreen(address: 'kaspa:test')));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('KaspaCom Marketplace')).dy,
          lessThan(tester.getTopLeft(find.text('dot.k Market')).dy));
      expect(find.text('Kaspire Markets & Offers'), findsOneWidget);
      expect(
          find.byWidgetPredicate((w) =>
              w is Image &&
              w.image is AssetImage &&
              (w.image as AssetImage).assetName ==
                  'assets/branding/kaspacom.png'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('NFT collection cards show floor price without holder count',
      (tester) async {
    const wallet =
        'kaspa:qqnvxvumjvzwmn755v8nrp4jxm2w50dv9mr2u4qrfqpq3h2hzyjx7tgkdtdgs';
    SharedPreferences.setMockInitialValues({'watch_address_v1': wallet});
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    final service = KaspaComMarketService(wallet,
        client: MockClient((_) async => http.Response(
            jsonEncode({
              'items': [
                {'ticker': 'HASH', 'price': 12, 'totalHolders': 999}
              ],
              'nextOffset': null
            }),
            200)));
    await tester.pumpWidget(MaterialApp(
        home: KaspaComMarketScreen(address: wallet, service: service)));
    await tester.pumpAndSettle();
    expect(find.text('Floor Price: 12 KAS'), findsOneWidget);
    expect(find.textContaining('holders'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
