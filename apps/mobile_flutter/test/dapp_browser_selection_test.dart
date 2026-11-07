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
  test('Kasseal is second and the complete approved order matches the release',
      () {
    expect(browserDapps.map((dapp) => dapp.name).toList(), [
      'Kasvio',
      'Kasseal',
      'GothDAG',
      'Braid',
      'dot.k',
      'Kaspa News',
      'Kaspa Dev Tools',
      'KasForge',
      'KasForge Vaults',
      'Jeetslab',
      'ANTX Universe',
      'KasCoven Vaults',
    ]);
    expect(browserDapps[1].url, 'https://app.kasseal.com/');
    expect(browserDapps[1].walletConnectEnabled, isTrue);
    expect(browserDapps[1].logo, 'assets/browser/kasseal-browser.png');
  });
  test('Kaspa News retains its local logo and read-only role', () {
    final news =
        browserDapps.indexWhere((site) => site.home.host == 'kaspa.news');
    expect(news, greaterThanOrEqualTo(0));
    expect(browserDapps[news].url, 'https://kaspa.news/');
    expect(browserDapps[news].logo, 'assets/browser/kaspa-news.png');
    expect(browserDapps[news].walletConnectEnabled, isFalse);
    expect(browserDapps.last.name, 'KasCoven Vaults');
  });
  test('Jeetslab retains the supplied image and exact wallet URL', () {
    final jeetslab = browserDapps[9];
    expect(jeetslab.name, 'Jeetslab');
    expect(jeetslab.url,
        'https://jeetslab-staging.kaspajeets.workers.dev/wallet');
    expect(jeetslab.logo, 'assets/browser/jeetslab.jpg');
    expect(jeetslab.walletConnectEnabled, isTrue);
  });
  test('new dApps use exact official origins and bundled official icons', () {
    for (final entry in [
      (7, 'https://kaspa.pumpforge.tech/', 'assets/browser/kasforge.png'),
      (8, 'https://vault.pumpforge.tech/', 'assets/browser/kasforge-vaults.svg'),
      (10, 'https://universe.antx.world/', 'assets/browser/antx-universe.svg'),
    ]) {
      final dapp = browserDapps[entry.$1];
      expect(dapp.url, entry.$2);
      expect(dapp.logo, entry.$3);
      expect(dapp.walletConnectEnabled, isTrue);
    }
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
      expect(find.text('Kasseal'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Kaspa Dev Tools'), 160);
      expect(find.text('Kaspa Dev Tools'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('KasForge'), 160);
      expect(find.text('KasForge'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('KasForge Vaults'), 160);
      expect(find.text('KasForge Vaults'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Jeetslab'), 160);
      expect(find.text('Jeetslab'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('ANTX Universe'), 160);
      expect(find.text('ANTX Universe'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('KasCoven Vaults'), 160);
      expect(find.text('KasCoven Vaults'), findsOneWidget);
      await tester.scrollUntilVisible(
          find.text('Integrate your dApp into Kaspire Browser'), 160);
      await tester.pumpAndSettle();
      expect(find.text('https://x.com/kaspirewallet'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: theme.name);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
