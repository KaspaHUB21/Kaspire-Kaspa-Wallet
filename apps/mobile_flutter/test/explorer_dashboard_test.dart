import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/screens/wallet_screen.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';

void main() {
  for (final theme in KaspireTheme.values) {
    testWidgets('Explorer replaces action eight in ${theme.name}',
        (tester) async {
      AppSettings.theme.value = theme;
      addTearDown(() => AppSettings.theme.value = KaspireTheme.midnight);
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      void noop() {}
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: Scaffold(
              body: WalletDashboardActions(
                  onSend: noop,
                  onReceive: noop,
                  onVaults: noop,
                  onSwap: noop,
                  onBrowser: noop,
                  onPairDapp: noop,
                  onAgora: noop,
                  onSettings: noop,
                  onAssets: noop,
                  onActivity: noop,
                  onUtxos: noop))));
      await tester.pumpAndSettle();
      final explorer =
          find.textContaining(RegExp('explorer', caseSensitive: false));
      expect(explorer, findsOneWidget);
      expect(find.textContaining(RegExp('settings', caseSensitive: false)),
          findsNothing);
      expect(find.byIcon(Icons.travel_explore_rounded), findsOneWidget);
      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data?.toUpperCase())
          .whereType<String>()
          .toList();
      expect(labels.last, 'EXPLORER');
      expect(labels.length, 8);
      expect(tester.takeException(), isNull);
    });
  }
}
