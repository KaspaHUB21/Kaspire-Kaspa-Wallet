import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/screens/wallet_screen.dart';
import 'package:kasvault_wallet/src/theme.dart';
import 'package:kasvault_wallet/src/widgets/hub21_material.dart';
import 'package:kasvault_wallet/src/services/glacier_glaze_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Glacier shares exactly three preloaded veils and rapid theme changes keep the latest choice', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() async {
      await GlacierGlazeCache.instance.ensure();
      expect(GlacierGlazeCache.instance.ready,isTrue);
      expect(GlacierGlazeCache.assets.length,3);
      final first=GlacierGlazeCache.instance.imageFor(const Size(100,100));
      expect(GlacierGlazeCache.instance.imageFor(const Size(80,76)),same(first));
      final pending=AppSettings.setTheme(KaspireTheme.glacier);
      await AppSettings.setTheme(KaspireTheme.midnight);
      await pending;
      expect(AppSettings.theme.value,KaspireTheme.midnight);
      await AppSettings.initialize();
      expect(AppSettings.theme.value,KaspireTheme.midnight);
    });
  });
  test('Glacier static glass decoration is paint-cache eligible', () {
    AppSettings.theme.value = KaspireTheme.glacier;
    addTearDown(() => AppSettings.theme.value = KaspireTheme.midnight);
    expect(kaspireDecorativeDecoration(radius: 24).isComplex, isTrue);
  });
  for (final width in [320.0, 600.0, 1120.0]) {
    for (final scale in [1.0, 1.8]) {
      testWidgets('Glacier responsive cached panels $width at $scale', (tester) async {
        AppSettings.theme.value = KaspireTheme.glacier;
        addTearDown(() => AppSettings.theme.value = KaspireTheme.midnight);
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var taps = 0;
        void action() { taps++; }
        await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(KaspireTheme.glacier),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: Hub21Backdrop(child: child!),
          ),
          home: Scaffold(body: ListView(children: [
            WalletDashboardActions(onSend: action, onReceive: action,
              onVaults: action, onSwap: action, onBrowser: action,
              onPairDapp: action, onAgora: action, onSettings: action,
              onAssets: action, onActivity: action, onUtxos: action),
            for (var i=0;i<15;i++) Hub21Panel(child: Padding(
              padding: const EdgeInsets.all(20), child: Text('Reading surface $i'))),
          ])),
        ));
        await tester.pumpAndSettle();
        expect(find.byType(BackdropFilter), findsNothing);
        expect(find.descendant(of: find.byType(Hub21Panel).first,
            matching: find.byType(RepaintBoundary)), findsWidgets);
        final send = find.textContaining(RegExp(r'^send$', caseSensitive: false));
        await tester.tap(send);
        await tester.pumpAndSettle();
        expect(taps, 1);
        await tester.drag(find.byType(ListView), const Offset(0, -600));
        await tester.pumpAndSettle();
        await tester.fling(find.byType(ListView), const Offset(0,-900),6000);
        await tester.pumpAndSettle();
        await tester.fling(find.byType(ListView), const Offset(0,1400),6000);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
