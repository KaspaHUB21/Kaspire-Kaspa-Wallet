import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kasvault_wallet/src/screens/settings_screen.dart';
import 'package:kasvault_wallet/src/screens/k_agora_screen.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';

void main() {
  for (final theme in [
    KaspireTheme.midnight,
    KaspireTheme.hub21,
    KaspireTheme.glacier,
    KaspireTheme.neptune
  ]) {
    testWidgets(
        'public toolbox retains Covenant Vaults but no dot.k marketplace in $theme',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      PackageInfo.setMockInitialValues(
          appName: 'Kaspire',
          packageName: 'space.kaspire.wallet',
          version: '0.11.53',
          buildNumber: '188',
          buildSignature: '');
      final previous = AppSettings.theme.value;
      AppSettings.theme.value = theme;
      addTearDown(() => AppSettings.theme.value = previous);
      const channel = MethodChannel('space.kasvault/security');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => false);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: Scaffold(
              body: SettingsScreen(
                  address: 'kaspa:test',
                  onManageWallets: () {},
                  onManageDapps: () {},
                  onManageAddressBook: () {}))));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('HUB21 Toolbox'), 350);
      await tester.ensureVisible(find.text('HUB21 Toolbox'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('HUB21 Toolbox'));
      await tester.pumpAndSettle();
      expect(find.text('Kaspire Covenant Vaults'), findsOneWidget);
      expect(find.text('dot.k Marketplace'), findsNothing);
      expect(find.textContaining('Internal test'), findsNothing);
      expect(find.textContaining('P2SH'), findsNothing);
      final obscured = <String>[];
      for (final tile in tester.elementList(find.byType(ListTile))) {
        tile.visitAncestorElements((ancestor) {
          if (ancestor.widget is Material) return false;
          final w = ancestor.widget;
          if (w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              ((w.decoration as BoxDecoration).color?.a ?? 0) > 0) {
            final title = (tile.widget as ListTile).title;
            obscured.add(title is Text ? title.data ?? '' : '$title');
            return false;
          }
          return true;
        });
      }
      expect(obscured, isEmpty,
          reason: 'Settings ink must paint above its background');
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('dot.k Market remains in K-Agora', (tester) async {
    await tester.pumpWidget(
        const MaterialApp(home: KAgoraScreen(address: 'kaspa:test')));
    await tester.pumpAndSettle();
    expect(find.text('dot.k Market'), findsOneWidget);
    expect(find.text('KaspaCom Marketplace'), findsOneWidget);
    expect(find.text('NFT Market'), findsOneWidget);
  });
}
