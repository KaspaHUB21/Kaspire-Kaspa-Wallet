import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';
import 'package:kasvault_wallet/src/screens/receive_screen.dart';
import 'package:kasvault_wallet/src/widgets/hub21_material.dart';
import 'package:kasvault_wallet/src/widgets/neptune_material.dart';
import 'package:kasvault_wallet/src/widgets/kaspire_brand.dart';

void main() {
  setUp(() => AppSettings.theme.value = KaspireTheme.neptune);
  tearDown(() => AppSettings.theme.value = KaspireTheme.midnight);
  testWidgets('Neptune logo centers in globe, not asymmetric ornament',
      (tester) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const _Fixture());
    await tester.pumpAndSettle();
    final orb = tester.getRect(find.byKey(const ValueKey('neptune-orb')));
    final logo = tester.getRect(find.byKey(const ValueKey('neptune-orb-logo')));
    expect(logo.center.dx, closeTo(orb.left + orb.width * .55, .01));
    expect(logo.center.dy, closeTo(orb.top + orb.height * .40, .01));
    expect(logo.width, closeTo(orb.width * .42, .01));
    expect(tester.takeException(), isNull);
  });
  test('Neptune preference persists without changing defaults', () async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.initialize();
    expect(AppSettings.theme.value, KaspireTheme.midnight);
    await AppSettings.setTheme(KaspireTheme.neptune);
    AppSettings.theme.value = KaspireTheme.midnight;
    await AppSettings.initialize();
    expect(AppSettings.theme.value, KaspireTheme.neptune);
    expect(KaspireTheme.neptune.label, 'Neptune');
    expect(KasVaultTheme.isDecorative, isTrue);
  });
  for (final size in [
    const Size(360, 800),
    const Size(412, 900),
    const Size(800, 1280),
    const Size(900, 412)
  ]) {
    for (final scale in [1.0, 1.8]) {
      testWidgets('Neptune ${size.width}x${size.height} scale $scale',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(_Fixture(scale: scale));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Hide balances'));
        await tester.pumpAndSettle();
        expect(find.text('49,675.1326 KAS'), findsNothing);
        expect(find.text(r'$2,176.52 USD'), findsNothing);
        expect(find.byTooltip('Show balances'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('Neptune receive QR keeps dark modules and scrollable actions',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: KasVaultTheme.forTheme(KaspireTheme.neptune),
        builder: (context, child) => Hub21Backdrop(child: child!),
        home: const Scaffold(
            body: ReceiveScreen(
                address:
                    'kaspa:qp0mtdvzscrkfft702j85s8yzdl8a87n5d6pgtm8vrxg6hqu0wywzvwkevdk3'))));
    await tester.pumpAndSettle();
    final qr = tester.widget<QrImageView>(find.byType(QrImageView));
    expect(qr.dataModuleStyle.color, const Color(0xFF031D29));
    await tester.drag(find.byType(ListView).first, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.text('COPY'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Neptune footer stays above Android system navigation',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 24);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    await tester.pumpWidget(const _Fixture());
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('—  K A S P A   L I V E S  —')).bottom,
        lessThanOrEqualTo(776));
    expect(tester.takeException(), isNull);
  });
  if (const bool.fromEnvironment('NEPTUNE_PREVIEW')) {
    testWidgets('Neptune rendered visual preview', (tester) async {
      final sdk = Platform.environment['FLUTTER_ROOT']!;
      await tester.runAsync(() async {
        await (FontLoader('sans-serif')
              ..addFont(File(
                      '$sdk/bin/cache/dart-sdk/bin/resources/devtools/assets/packages/devtools_app_shared/fonts/Roboto/Roboto-Regular.ttf')
                  .readAsBytes()
                  .then(ByteData.sublistView)))
            .load();
        await (FontLoader('NeptuneScript')
              ..addFont(
                  rootBundle.load('assets/themes/neptune/Allura-Regular.ttf')))
            .load();
        await (FontLoader('MaterialIcons')
              ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
            .load();
      });
      tester.view.physicalSize = const Size(412, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const _Fixture());
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('goldens/neptune-phone.png'));
    });
  }
}

class _Fixture extends StatefulWidget {
  const _Fixture({this.scale = 1});
  final double scale;
  @override
  State<_Fixture> createState() => _FixtureState();
}

class _FixtureState extends State<_Fixture> {
  bool hidden = false;
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: KasVaultTheme.forTheme(KaspireTheme.neptune),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(widget.scale)),
            child: Hub21Backdrop(child: child!)),
        home: Scaffold(
            body: SafeArea(
                child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 30, 16, 32),
                    children: [
                  Row(children: [
                    const Expanded(child: KaspireWordmark(height: 19)),
                    IconButton(
                        onPressed: () {},
                        icon:
                            const Icon(Icons.account_balance_wallet_outlined)),
                    const Hub21Panel(
                        radius: 20,
                        padding:
                            EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.circle, size: 8),
                          SizedBox(width: 6),
                          Text('LAYER 1', style: TextStyle(fontSize: 11)),
                          Icon(Icons.expand_more, size: 16)
                        ]))
                  ]),
                  const SizedBox(height: 20),
                  Hub21BalanceCard(
                      walletName: 'Wallet 1',
                      amount: '49,675.1326',
                      symbol: 'KAS',
                      fiat: r'$2,176.52 USD',
                      hideAmounts: hidden,
                      onTogglePrivacy: () => setState(() => hidden = !hidden)),
                  const SizedBox(height: 12),
                  Row(children: [
                    for (final action in [
                      (Icons.arrow_upward, 'SEND'),
                      (Icons.arrow_downward, 'RECEIVE'),
                      (Icons.qr_code_scanner, 'PAIR DAPP'),
                      (Icons.account_balance, 'K-AGORA')
                    ])
                      Expanded(
                          child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 2),
                              child: Hub21Action(
                                  icon: action.$1,
                                  label: action.$2,
                                  onTap: () {})))
                  ]),
                  const SizedBox(height: 22),
                  const Text('ASSETS & NAMES',
                      style: TextStyle(
                          fontWeight: FontWeight.w800, letterSpacing: 1.3)),
                  const SizedBox(height: 12),
                  Hub21Panel(
                      padding: const EdgeInsets.all(12),
                      child: NeptuneAssetArtwork(
                          child: Column(children: [
                        for (final section in [
                          ('KRC-20 TOKENS', 3),
                          ('KCC20 COVENANT TOKENS', 4),
                          ('KRC-721 COLLECTIONS', 8),
                          ('KNS DOMAINS', 4)
                        ])
                          ExpansionTile(
                              tilePadding: EdgeInsets.zero,
                              leading: const Icon(Icons.layers_outlined),
                              title: Text(section.$1,
                                  style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800)),
                              subtitle: Text('${section.$2} assets'),
                              children: const [Text('Asset details')]),
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
                      icon: Icon(Icons.arrow_upward), label: 'Send'),
                  NavigationDestination(
                      icon: Icon(Icons.qr_code), label: 'Receive'),
                  NavigationDestination(
                      icon: Icon(Icons.tune), label: 'Settings'),
                ])),
      );
}
