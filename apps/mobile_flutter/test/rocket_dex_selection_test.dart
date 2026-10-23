import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/screens/kron_dex_screen.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';

void main() {
  for (final theme in KaspireTheme.values) {
    testWidgets('Mainnet Swap places KaspaRocket before KRON at 320px: $theme',
        (tester) async {
      NetworkSettings.network.value = KaspaNetwork.mainnet;
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: const DexSelectionScreen(address: 'kaspa:qfixture')));
      await tester.pumpAndSettle();
      expect(find.text('Kasseal DEX'), findsOneWidget);
      expect(tester.getTopLeft(find.text('KaspaRocket')).dy,
          lessThan(tester.getTopLeft(find.text('Kasseal DEX')).dy));
      expect(tester.getTopLeft(find.text('Kasseal DEX')).dy,
          lessThan(tester.getTopLeft(find.text('Kron DEX')).dy));
      expect(tester.getTopLeft(find.text('KaspaRocket')).dy,
          lessThan(tester.getTopLeft(find.text('Kron DEX')).dy));
      expect(tester.takeException(), isNull);
    });
  }
  for (final theme in KaspireTheme.values) {
    testWidgets('TN10 exposes Kasseal without affecting Mainnet: $theme',
        (tester) async {
      NetworkSettings.network.value = KaspaNetwork.tn10;
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: const DexSelectionScreen(address: 'kaspatest:qfixture')));
      await tester.pumpAndSettle();
      expect(find.text('Kasseal DEX'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
