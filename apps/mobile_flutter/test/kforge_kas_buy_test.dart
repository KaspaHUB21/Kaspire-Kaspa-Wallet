import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/kaspa_address.dart';
import 'package:kasvault_wallet/src/screens/kforge_trade_screen.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/services/kforge_service.dart';
import 'package:kasvault_wallet/src/services/kforge_trading.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';
import 'kforge_result_test.dart' show ScreenTrading;
import 'kforge_service_test.dart' show kforgeAddress, kforgeToken;

class KasInputTrading extends ScreenTrading {
  BigInt? entered;
  @override
  Future<Map<String, dynamic>> quote(
      String a, KForgeToken t, String side, BigInt amount) async {
    entered = amount;
    final q = await super.quote(a, t, side, amount);
    if (side == 'buy') {
      final v = q['review']['tradeSummary']['verified'] as Map;
      v['buyBudgetSompi'] = '$amount';
      v['unspentBudgetSompi'] = '1';
      v['marketKas'] = '${amount - BigInt.one}';
    }
    return q;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mainnet in [false, true]) {
    test(
        'curve KAS budget uses exact integer lots and boundaries, Mainnet=$mainnet',
        () {
      NetworkSettings.network.value =
          mainnet ? KaspaNetwork.mainnet : KaspaNetwork.tn10;
      for (final sold in [0, 1, 99, 349, 648, 649]) {
        final t = KForgeToken.fromJson({
          ...kforgeToken(),
          'base': mainnet ? 6249997720 : 624999772,
          'slope': mainnet ? 15644550 : 1564455,
          'sold': sold
        });
        for (var n = 1; n <= math.min(650 - sold, 12); n++) {
          final cost = KForgeTrading.curveBuyCost(t, n);
          expect(KForgeTrading.curveBuyLots(t, cost), n);
          if (n == 1) {
            expect(() => KForgeTrading.curveBuyLots(t, cost - BigInt.one),
                throwsStateError);
          } else {
            expect(KForgeTrading.curveBuyLots(t, cost - BigInt.one), n - 1);
          }
          if (n < 650 - sold) {
            final next = KForgeTrading.curveBuyCost(t, n + 1);
            expect(KForgeTrading.curveBuyLots(t, next - BigInt.one), n);
          }
        }
        expect(KForgeTrading.curveBuyLots(t, BigInt.one << 52), 650 - sold);
      }
    });
    for (final theme in KaspireTheme.values) {
      for (final pool in [false, true]) {
        testWidgets(
            'Buy accepts KAS, never tokens: ${theme.name}, pool=$pool, Mainnet=$mainnet',
            (tester) async {
          NetworkSettings.network.value =
              mainnet ? KaspaNetwork.mainnet : KaspaNetwork.tn10;
          AppSettings.theme.value = theme;
          tester.view.physicalSize = const Size(320, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final trading = KasInputTrading();
          final token = KForgeToken.fromJson({
            ...kforgeToken(),
            if (pool) 'phase': 'pool',
            if (pool) 'pool': {'poolCovId': 'f' * 64}
          });
          await tester.pumpWidget(MaterialApp(
              theme: KasVaultTheme.forTheme(theme),
              home: KForgeTradeScreen(
                  address: kaspaAddressWithPrefix(
                      kforgeAddress, mainnet ? 'kaspa' : 'kaspatest'),
                  token: token,
                  balance: '15000000',
                  trading: trading)));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.byType(TextField));
          final field = tester.widget<TextField>(find.byType(TextField));
          expect(field.decoration?.suffixText, 'KAS');
          expect(field.decoration?.labelText,
              'KAS trade amount (fees and cell reserve added)');
          await tester.enterText(find.byType(TextField), '123.45678901');
          await tester.ensureVisible(find.text('Refresh quote'));
          await tester.tap(find.text('Refresh quote'));
          await tester.pumpAndSettle();
          expect(trading.entered, BigInt.parse('12345678901'));
          await tester.ensureVisible(find.text('Sell'));
          await tester.tap(find.text('Sell'));
          await tester.pumpAndSettle();
          expect(
              tester
                  .widget<TextField>(find.byType(TextField))
                  .decoration
                  ?.suffixText,
              token.symbol);
          expect(
              tester.widget<TextField>(find.byType(TextField)).controller!.text,
              isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  }
}
