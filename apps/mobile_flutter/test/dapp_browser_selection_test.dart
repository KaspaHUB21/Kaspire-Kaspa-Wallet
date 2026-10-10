import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/screens/dapp_browser_selection_screen.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/services/dapp_browser_catalog.dart';
import 'package:kasvault_wallet/src/theme.dart';

void main() {
  test('Kasvio is the first approved browser dApp', () {
    expect(browserDapps.first.name, 'Kasvio');
    expect(browserDapps.first.url, 'https://kasvio.network/');
  });
  testWidgets('dApp selection and invitation fit narrow screens in every theme',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final previous = AppSettings.theme.value;
    addTearDown(() => AppSettings.theme.value = previous);
    for (final theme in KaspireTheme.values) {
      AppSettings.theme.value = theme;
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: const DappBrowserSelectionScreen()));
      await tester.pumpAndSettle();
      expect(find.text('GothDAG'), findsOneWidget);
      expect(find.text('Kasvio'), findsOneWidget);
      expect(find.text('Kaspa Dev Tools'), findsOneWidget);
      await tester.scrollUntilVisible(
          find.text('Integrate your dApp into Kaspire Browser'), 160);
      await tester.pumpAndSettle();
      expect(find.text('https://x.com/kaspirewallet'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: theme.name);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
