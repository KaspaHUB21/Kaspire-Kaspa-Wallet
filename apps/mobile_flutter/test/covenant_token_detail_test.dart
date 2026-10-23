import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/models/wallet_snapshot.dart';
import 'package:kasvault_wallet/src/screens/krc20_token_detail_screen.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';

void main() {
  for (final theme in KaspireTheme.values) {
    testWidgets(
        'Rocket detail keeps price, grouped balance and explicit Swap in $theme',
        (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var swaps = 0;
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: Krc20TokenDetailScreen(
              asset: const WalletAsset(
                  symbol: 'LKAS',
                  balance: 8485.263,
                  kind: 'KCC20',
                  rawBalance: '8485263',
                  decimals: 3,
                  priceKas: 0.06399286,
                  standard: 'kasparocket-kcc20'),
              usdToFiat: 1,
              fiatCode: 'USD',
              fiatSymbol: r'$',
              onSend: () {},
              onSwap: () {
                swaps++;
              })));
      await tester.pump();
      expect(find.text('8,485.263 LKAS'), findsOneWidget);
      expect(find.text('Price per token'), findsOneWidget);
      expect(find.text('0.06399286 KAS'), findsOneWidget);
      await tester.ensureVisible(find.text('Swap'));
      await tester.tap(find.text('Swap'));
      await tester.pump();
      expect(swaps, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });
  }
}
