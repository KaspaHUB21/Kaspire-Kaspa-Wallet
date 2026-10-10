import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/screens/wallet_screen.dart';
import 'package:kasvault_wallet/src/screens/upcoming_feature_screen.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';

void main() {
  testWidgets(
      'dashboard has two ordered rows and working actions in every theme',
      (tester) async {
    tester.view.physicalSize = const Size(280, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final previous = AppSettings.theme.value;
    addTearDown(() {
      AppSettings.theme.value = previous;
    });
    for (final theme in KaspireTheme.values) {
      AppSettings.theme.value = theme;
      var selected = '';
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: Scaffold(
              body: MediaQuery(
                  data:
                      const MediaQueryData(textScaler: TextScaler.linear(1.6)),
                  child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: WalletDashboardActions(
                        onSend: () => selected = 'Send',
                        onReceive: () => selected = 'Receive',
                        onVaults: () => selected = 'Vaults',
                        onSwap: () => selected = 'Swap',
                        onBrowser: () => selected = 'Browser',
                        onPairDapp: () => selected = 'Pair dApp',
                        onAgora: () => selected = 'K-Agora',
                        onSettings: () => selected = 'Settings',
                      ))))));
      await tester.pumpAndSettle();
      const labels = [
        'Send',
        'Receive',
        'Vaults',
        'Swap',
        'Browser',
        'Pair dApp',
        'K-Agora',
        'Settings'
      ];
      final topY = tester.getTopLeft(find.text('Send')).dy;
      final bottomY = tester.getTopLeft(find.text('Browser')).dy;
      expect(bottomY, greaterThan(topY));
      for (var index = 0; index < labels.length; index++) {
        expect(find.text(labels[index]), findsOneWidget);
        final button = find.ancestor(
            of: find.text(labels[index]), matching: find.byType(InkWell));
        final bounds = tester.getRect(button);
        final icon = tester
            .getRect(find.descendant(of: button, matching: find.byType(Icon)));
        final text = tester.getRect(find.text(labels[index]));
        expect(bounds.height, 76);
        expect(icon.center.dx, closeTo(bounds.center.dx, 1));
        expect(text.center.dx, closeTo(bounds.center.dx, 1));
        expect(icon.top - bounds.top, closeTo(bounds.bottom - text.bottom, 1));
        expect(text.left, greaterThanOrEqualTo(bounds.left));
        expect(text.right, lessThanOrEqualTo(bounds.right));
        await tester.tap(find.text(labels[index]));
        expect(selected, labels[index]);
        if (index % 4 > 0) {
          expect(tester.getTopLeft(find.text(labels[index])).dx,
              greaterThan(tester.getTopLeft(find.text(labels[index - 1])).dx));
        }
      }
      expect(tester.takeException(), isNull, reason: theme.name);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
  testWidgets('Swap and Vaults copy is visible and scrollable in every theme',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final previous = AppSettings.theme.value;
    addTearDown(() => AppSettings.theme.value = previous);
    for (final theme in KaspireTheme.values) {
      AppSettings.theme.value = theme;
      for (final vaults in [false, true]) {
        await tester.pumpWidget(MaterialApp(
            theme: KasVaultTheme.forTheme(theme),
            home: UpcomingFeatureScreen(vaults: vaults)));
        await tester.pumpAndSettle();
        expect(
            find.text(vaults ? 'Your money. Your rules.' : 'KCC20 DEX Swaps'),
            findsOneWidget);
        if (vaults) {
          await tester.scrollUntilVisible(
              find.text('Open KasCoven Vaults'), 100);
        } else {
          expect(find.text('Available very soon'), findsOneWidget);
        }
        expect(tester.takeException(), isNull, reason: theme.name);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });
}
