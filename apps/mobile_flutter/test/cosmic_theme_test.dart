import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';
import 'package:kasvault_wallet/src/screens/wallet_screen.dart';
import 'package:kasvault_wallet/src/screens/receive_screen.dart';
import 'package:kasvault_wallet/src/widgets/hub21_material.dart';
import 'package:kasvault_wallet/src/widgets/transaction_fact_row.dart';
import 'package:kasvault_wallet/src/widgets/cosmic_material.dart';

void main() {
  setUp(() => AppSettings.theme.value = KaspireTheme.cosmic);
  tearDown(() => AppSettings.theme.value = KaspireTheme.midnight);
  test('Cosmic persists by name and does not replace the default theme',
      () async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.initialize();
    expect(AppSettings.theme.value, KaspireTheme.midnight);
    await AppSettings.setTheme(KaspireTheme.cosmic);
    AppSettings.theme.value = KaspireTheme.midnight;
    await AppSettings.initialize();
    expect(AppSettings.theme.value, KaspireTheme.cosmic);
    expect(KaspireTheme.cosmic.label, 'Cosmic');
    expect(KasVaultTheme.isDecorative, isTrue);
  });
  for (final size in [
    const Size(280, 640),
    const Size(320, 720),
    const Size(412, 820),
    const Size(600, 960),
    const Size(1120, 840),
    const Size(900, 412)
  ]) {
    for (final scale in [1.0, 1.8]) {
      testWidgets('Cosmic wallet ${size.width}x${size.height} scale $scale',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);
        await tester.pumpWidget(_Fixture(scale: scale));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final planet = find.byKey(const ValueKey('cosmic-planet-artwork'));
        expect(planet, findsOneWidget);
        final bounds = tester.getRect(planet);
        expect(bounds.width, closeTo(bounds.height, .001));
        expect(bounds.width, lessThanOrEqualTo(168.001));
        expect(tester.widget<Image>(planet).fit, BoxFit.contain);
        expect(find.byKey(const ValueKey('cosmic-planet-logo')), findsNothing);
        expect(
            find.byIcon(Icons.account_balance_wallet_outlined), findsWidgets);
        await tester.tap(find.byTooltip('Switch wallet'));
        await tester.pumpAndSettle();
        expect(find.text('Wallet picker opened'), findsOneWidget);
        await tester.ensureVisible(find.byTooltip('Hide balances'));
        await tester.tap(find.byTooltip('Hide balances'));
        await tester.pumpAndSettle();
        expect(find.text('45,649.5568 KAS'), findsNothing);
        expect(find.text(r'$1,165.95 USD'), findsNothing);
        expect(find.byTooltip('Show balances'), findsOneWidget);
        await tester.scrollUntilVisible(find.byType(CosmicAction).first, 100,
            scrollable: find.byType(Scrollable).first);
        expect(find.byType(CosmicAction), findsNWidgets(8));
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('Cosmic receive preserves high-contrast QR and copy action',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: KasVaultTheme.forTheme(KaspireTheme.cosmic),
        builder: (context, child) => Hub21Backdrop(child: child!),
        home: const Scaffold(
            body: ReceiveScreen(
                address:
                    'kaspa:qp0mtdvzscrkfft702j85s8yzdl8a87n5d6pgtm8vrxg6hqu0wywzvwkevdk3'))));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<QrImageView>(find.byType(QrImageView))
            .dataModuleStyle
            .color,
        const Color(0xFF020415));
    await tester.drag(find.byType(ListView).first, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Cosmic real-widget visual previews', (tester) async {
    final output = Platform.environment['LOCKSCREEN_PREVIEW_DIR'];
    if (output == null) return;
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = true);
    await tester.runAsync(() async {
      for (final font in {
        'sans-serif': 'Roboto-Regular.ttf',
        'MaterialIcons': 'MaterialIcons-Regular.otf'
      }.entries) {
        final bytes = await File(
                '/srv/kaspire/toolchains/flutter/bin/cache/artifacts/material_fonts/${font.value}')
            .readAsBytes();
        await (FontLoader(font.key)
              ..addFont(Future.value(ByteData.sublistView(bytes))))
            .load();
      }
    });
    for (final width in [412.0, 320.0, 1120.0]) {
      tester.view.physicalSize = Size(width, width > 1000 ? 840 : 820);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      await tester.pumpWidget(const _Fixture());
      await tester.runAsync(() async {
        final context = tester.element(find.byType(Scaffold).first);
        await precacheImage(
            const AssetImage('assets/themes/cosmic/nebula.png'), context);
        await precacheImage(
            const AssetImage('assets/themes/cosmic/planet-cutout.png'),
            context);
        await precacheImage(
            const AssetImage('assets/themes/cosmic/surface-nebula.png'),
            context);
      });
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('cosmic-preview')));
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$output/cosmic-${width.toInt()}.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
    }
    debugDisableShadows = true;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.view.resetPadding();
  });
}

class _Fixture extends StatefulWidget {
  const _Fixture({this.scale = 1});
  final double scale;
  @override
  State<_Fixture> createState() => _FixtureState();
}

class _FixtureState extends State<_Fixture> {
  bool hidden = false, switched = false;
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: KasVaultTheme.forTheme(KaspireTheme.cosmic),
        builder: (context, child) => RepaintBoundary(
            key: const ValueKey('cosmic-preview'),
            child: MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(widget.scale)),
                child: Hub21Backdrop(child: child!))),
        home: Scaffold(
          body: SafeArea(
              child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 26, 16, 30),
                  children: [
                WalletDashboardHeader(
                    onSwitchWallet: () => setState(() => switched = true),
                    onReload: () {},
                    networkSelector: Hub21Panel(
                        radius: 99,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 9),
                        child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.circle, size: 8),
                              SizedBox(width: 5),
                              Text('LAYER 1', style: TextStyle(fontSize: 11)),
                              Icon(Icons.expand_more, size: 16)
                            ])),
                    notifications: KaspireHeaderIconFrame(
                        child: IconButton(
                            onPressed: () {},
                            icon: const Icon(Icons.notifications_outlined)))),
                if (switched) const Text('Wallet picker opened'),
                const SizedBox(height: 42),
                Hub21BalanceCard(
                    walletName: 'Goat milk',
                    amount: '45,649.5568',
                    symbol: 'KAS',
                    fiat: r'$1,165.95 USD',
                    hideAmounts: hidden,
                    onTogglePrivacy: () => setState(() => hidden = !hidden)),
                const SizedBox(height: 12),
                WalletDashboardActions(
                    onSend: () {},
                    onReceive: () {},
                    onVaults: () {},
                    onSwap: () {},
                    onBrowser: () {},
                    onPairDapp: () {},
                    onAgora: () {},
                    onSettings: () {},
                    onAssets: () {},
                    onActivity: () {},
                    onUtxos: () {}),
                const SizedBox(height: 16),
                const Hub21Readable(
                    child: Text('Assets & Names',
                        style: TextStyle(fontWeight: FontWeight.w800))),
                const SizedBox(height: 12),
                const Card(
                    child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Column(children: [
                          ListTile(
                              leading: Icon(Icons.layers_outlined),
                              title: Text('KRC-20 Tokens'),
                              subtitle: Text('17 assets'),
                              trailing: Icon(Icons.expand_more)),
                          ListTile(
                              leading: Icon(Icons.layers_outlined),
                              title: Text('KCC20 Covenant Tokens'),
                              subtitle: Text('5 assets'),
                              trailing: Icon(Icons.expand_more)),
                        ]))),
                const Card(
                    child: Padding(
                        padding: EdgeInsets.all(14),
                        child: Column(children: [
                          TransactionFactRow(
                              'Amount sent', '4,287.00000000 KAS'),
                          TransactionFactRow('Network fee', '0.00203600 KAS'),
                          TransactionFactRow('Time', '2026-11-21 18:50:45'),
                        ]))),
              ])),
          bottomNavigationBar: KaspireNavigationBar(
              selectedIndex: 0,
              onDestinationSelected: (_) {},
              destinations: const [
                NavigationDestination(
                    icon: Icon(Icons.account_balance_wallet_outlined),
                    label: 'Wallet'),
                NavigationDestination(
                    icon: Icon(Icons.arrow_upward_rounded), label: 'Send'),
                NavigationDestination(
                    icon: Icon(Icons.qr_code_2_rounded), label: 'Receive'),
                NavigationDestination(
                    icon: Icon(Icons.tune_rounded), label: 'Settings'),
              ]),
        ),
      );
}
