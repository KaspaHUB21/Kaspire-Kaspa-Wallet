import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/screens/settings_screen.dart';
import 'package:kasvault_wallet/src/screens/receive_screen.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:kasvault_wallet/src/theme.dart';
import 'package:kasvault_wallet/src/widgets/hub21_material.dart';
import 'package:kasvault_wallet/src/widgets/kaspire_brand.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    AppSettings.theme.value = KaspireTheme.hub21;
    AppSettings.uppercaseButtons.value = true;
  });
  tearDown(() => AppSettings.theme.value = KaspireTheme.midnight);

  testWidgets('const wordmark reacts immediately to theme changes',
      (tester) async {
    AppSettings.theme.value = KaspireTheme.midnight;
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: KaspireWordmark()))));
    await tester.pumpAndSettle();
    expect(find.byType(ShaderMask), findsNothing);
    AppSettings.theme.value = KaspireTheme.hub21;
    await tester.pumpAndSettle();
    expect(find.byType(ShaderMask), findsOneWidget);
    expect(find.byType(ImageFiltered), findsOneWidget);
    AppSettings.theme.value = KaspireTheme.midnight;
    await tester.pumpAndSettle();
    expect(find.byType(ShaderMask), findsNothing);
  });

  testWidgets('reading surface only appears in HUB21', (tester) async {
    Widget screen() => MaterialApp(
        theme: KasVaultTheme.forTheme(AppSettings.theme.value),
        home: const Scaffold(
            body: Hub21Readable(child: Text('Important information'))));
    await tester.pumpWidget(screen());
    expect(
        find.descendant(
            of: find.byType(Hub21Readable), matching: find.byType(Container)),
        findsOneWidget);
    AppSettings.theme.value = KaspireTheme.midnight;
    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byType(Hub21Readable), matching: find.byType(Container)),
        findsNothing);
  });

  test('HUB21 persists without changing existing theme IDs or defaults',
      () async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.initialize();
    expect(AppSettings.theme.value, KaspireTheme.midnight);
    await AppSettings.setTheme(KaspireTheme.hub21);
    AppSettings.theme.value = KaspireTheme.midnight;
    await AppSettings.initialize();
    expect(AppSettings.theme.value, KaspireTheme.hub21);
    expect(KaspireTheme.hub21.label, 'HUB21');
    expect(KaspireTheme.midnight.name, 'midnight');
    expect(
        KasVaultTheme.forTheme(KaspireTheme.midnight).scaffoldBackgroundColor,
        const Color(0xFF050A0D));
  });

  for (final size in [
    const Size(360, 800),
    const Size(412, 900),
    const Size(800, 1280),
    const Size(900, 412)
  ]) {
    for (final scale in [1.0, 1.8]) {
      testWidgets('HUB21 layout ${size.width}x${size.height} at $scale',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(_ThemeFixture(scale: scale));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Hide balances'));
        await tester.pumpAndSettle();
        expect(find.text('7,783.8699 KAS'), findsNothing);
        expect(find.text(r'$269.51 USD'), findsNothing);
        expect(find.byTooltip('Show balances'), findsOneWidget);
        await tester.tap(find.byTooltip('Show balances'));
        await tester.pumpAndSettle();
        expect(find.text('7,783.8699 KAS'), findsOneWidget);
      });
    }
  }

  testWidgets('metal action remains accessible and tappable', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
        theme: KasVaultTheme.forTheme(KaspireTheme.hub21),
        home: Scaffold(
            body: Center(
                child: SizedBox(
                    width: 130,
                    child: Hub21Action(
                        icon: Icons.send,
                        label: 'SEND',
                        onTap: () => taps++))))));
    await tester.tap(find.text('SEND'));
    expect(taps, 1);
  });

  testWidgets('real settings shows HUB21 and its expandable display settings',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
        appName: 'Kaspire',
        packageName: 'space.kaspire.wallet',
        version: '0.11.30-hub21.1',
        buildNumber: '96',
        buildSignature: '');
    const channel = MethodChannel('space.kasvault/security');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => false);
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(MaterialApp(
        theme: KasVaultTheme.forTheme(KaspireTheme.hub21),
        builder: (context, child) => Hub21Backdrop(child: child!),
        home: Scaffold(
            body: SettingsScreen(
                address: 'kaspa:test',
                onManageWallets: () {},
                onManageDapps: () {},
                onManageAddressBook: () {}))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wallet display'));
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButtonFormField<KaspireTheme>), findsOneWidget);
    expect(find.text('HUB21'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('receive keeps a readable QR and copy action in HUB21',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: KasVaultTheme.forTheme(KaspireTheme.hub21),
        builder: (context, child) => Hub21Backdrop(child: child!),
        home: const Scaffold(
            body: ReceiveScreen(
                address:
                    'kaspa:qp0mtdvzscrkfft702j85s8yzdl8a87n5d6pgtm8vrxg6hqu0wywzvwkevdk3'))));
    await tester.pumpAndSettle();
    expect(find.text('RECEIVE KAS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // Opt-in visual inspection artifact from real Flutter widgets, not a mockup
  // image. Font loaded from the same Flutter SDK used to build this APK.
  if (const bool.fromEnvironment('HUB21_GOLDENS')) {
    testWidgets('HUB21 visual preview', (tester) async {
      final sdk = Platform.environment['FLUTTER_ROOT']!;
      final fontPath = '$sdk/bin/cache/dart-sdk/bin/resources/devtools/assets/'
          'packages/devtools_app_shared/fonts/Roboto';
      await tester.runAsync(() async {
        final loader = FontLoader('sans-serif');
        for (final weight in ['Regular']) {
          loader.addFont(File('$fontPath/Roboto-$weight.ttf')
              .readAsBytes()
              .then((bytes) => ByteData.sublistView(bytes)));
        }
        await loader.load();
        await (FontLoader('monospace')
              ..addFont(File(
                      '$sdk/bin/cache/dart-sdk/bin/resources/devtools/assets/'
                      'packages/devtools_app_shared/fonts/Roboto_Mono/RobotoMono-Regular.ttf')
                  .readAsBytes()
                  .then((bytes) => ByteData.sublistView(bytes))))
            .load();
        await (FontLoader('MaterialIcons')
              ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
            .load();
      });
      tester.view.physicalSize = const Size(412, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const _ThemeFixture());
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('goldens/hub21-phone.png'));
      await tester.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: KasVaultTheme.forTheme(KaspireTheme.hub21),
          builder: (context, child) => Hub21Backdrop(child: child!),
          home: const Scaffold(
              body: ReceiveScreen(
                  address:
                      'kaspa:qp0mtdvzscrkfft702j85s8yzdl8a87n5d6pgtm8vrxg6hqu0wywzvwkevdk3'))));
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('goldens/hub21-receive.png'));
    });
  }
}

class _ThemeFixture extends StatefulWidget {
  const _ThemeFixture({this.scale = 1});
  final double scale;
  @override
  State<_ThemeFixture> createState() => _ThemeFixtureState();
}

class _ThemeFixtureState extends State<_ThemeFixture> {
  bool hidden = false;
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: KasVaultTheme.forTheme(KaspireTheme.hub21),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(widget.scale)),
            child: Hub21Backdrop(child: child!)),
        home: Scaffold(
          body: SafeArea(
              child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 22, 20, 32),
                  children: [
                Row(children: [
                  const Expanded(child: KaspireWordmark(height: 19)),
                  IconButton(
                      onPressed: () {},
                      icon: const Icon(Icons.account_balance_wallet_outlined)),
                  const Hub21Panel(
                      radius: 20,
                      rim: 2,
                      gold: true,
                      padding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.circle, size: 8),
                        SizedBox(width: 7),
                        Text('LAYER 1',
                            style: TextStyle(
                                fontSize: 11, fontWeight: FontWeight.w800)),
                        Icon(Icons.expand_more_rounded, size: 16),
                      ])),
                ]),
                const SizedBox(height: 50),
                Hub21BalanceCard(
                    walletName: 'Wallet 1',
                    amount: '7,783.8699',
                    symbol: 'KAS',
                    fiat: r'$269.51 USD',
                    hideAmounts: hidden,
                    onTogglePrivacy: () => setState(() => hidden = !hidden)),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                      child: Hub21Action(
                          icon: Icons.arrow_upward_rounded,
                          label: 'SEND',
                          onTap: () {})),
                  const SizedBox(width: 12),
                  Expanded(
                      child: Hub21Action(
                          icon: Icons.arrow_downward_rounded,
                          label: 'RECEIVE',
                          onTap: () {})),
                  const SizedBox(width: 12),
                  Expanded(
                      child: Hub21Action(
                          icon: Icons.qr_code_scanner_rounded,
                          label: 'PAIR DAPP',
                          onTap: () {})),
                ]),
                const SizedBox(height: 32),
                const Hub21Readable(
                    child: Text('ASSETS & NAMES',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.2))),
                const SizedBox(height: 12),
                Hub21Panel(
                    padding: const EdgeInsets.all(17),
                    child: Column(children: [
                      for (final label in [
                        'KRC-20 TOKENS',
                        'KCC20 COVENANT TOKENS',
                        'KRC-721 COLLECTIONS'
                      ])
                        ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            leading: const Icon(Icons.layers_outlined),
                            title: Text(label,
                                style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: .7)),
                            subtitle: const Text('3 assets'),
                            children: const [
                              ListTile(title: Text('Example asset'))
                            ]),
                    ])),
              ])),
          bottomNavigationBar: KaspireNavigationBar(
              selectedIndex: 0,
              onDestinationSelected: (_) {},
              destinations: const [
                NavigationDestination(
                    icon: Icon(Icons.account_balance_wallet), label: 'Wallet'),
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
