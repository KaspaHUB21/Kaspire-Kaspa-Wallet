import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/screens/kforge_screen.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';
import 'kforge_service_test.dart' show kforgeAddress, kforgeClient, kforgeToken;
import 'package:kasvault_wallet/src/services/kforge_service.dart';
import 'package:kasvault_wallet/src/services/kforge_trading.dart';

class EmptyKForgeTrading extends KForgeTrading {
  @override
  Future<Map<String, dynamic>?> pending(String address) async => null;
}

void main() {
  for (final theme in KaspireTheme.values) {
    testWidgets('KForge catalogue/trade/search fits narrow ${theme.name}',
        (tester) async {
      NetworkSettings.network.value = KaspaNetwork.tn10;
      AppSettings.theme.value = theme;
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final long = kforgeToken()
        ..['name'] =
            'A very long KForge token name that must wrap inside its own card';
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: KForgeScreen(
              address: kforgeAddress,
              trading: EmptyKForgeTrading(),
              service: KForgeService(client: kforgeClient(tokens: [long])))));
      await tester.pumpAndSettle();
      expect(find.text('KForge · Testnet 10'), findsOneWidget);
      expect(find.textContaining('Native Testnet 10 curve and pool swaps'),
          findsOneWidget);
      expect(find.textContaining('separate launchpad from KasForge'), findsNothing);
      await tester.enterText(find.byType(TextField), 'missing');
      await tester.pumpAndSettle();
      expect(find.text('No matching KForge tokens.'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'a' * 64);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ListTile));
      await tester.pumpAndSettle();
      expect(find.text('Indexed balance: 15,000,000 SAME'), findsOneWidget);
      expect(find.text('Copy covenant ID'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Review swap'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Review swap'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Sell'), -200,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Sell'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('MAX'), 200,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('MAX'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '15000000');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
