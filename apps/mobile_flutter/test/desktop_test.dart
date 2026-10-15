import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/widgets/desktop_frame.dart';
import 'package:kasvault_wallet/src/widgets/windows_security_dialog.dart';
import 'package:kasvault_wallet/src/screens/onboarding_screen.dart';
import 'package:kasvault_wallet/src/screens/wallet_screen.dart';
import 'package:kasvault_wallet/src/theme.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/widgets/wallet_responsive_layout.dart';
import 'package:kasvault_wallet/src/services/security_channel.dart';
import 'package:kasvault_wallet/src/services/native_security.dart';
import 'package:kasvault_wallet/src/services/update_service.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    AppSettings.theme.value = KaspireTheme.midnight;
  });
  test('Windows storage notice describes DPAPI, not Android Keystore', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(walletStorageNotice, contains('Windows DPAPI'));
    expect(walletStorageNotice, isNot(contains('Android Keystore')));
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(walletStorageNotice, contains('Android Keystore'));
  });
  for (final theme in KaspireTheme.values) {
    for (final mode in [1, 2, 3, 6]) {
      testWidgets(
          'Themed Windows dialog $theme mode $mode keeps actions visible',
          (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        AppSettings.theme.value = theme;
        tester.view.devicePixelRatio = 2.25;
        tester.view.physicalSize = const Size(1080, 810);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(WindowsSecurityDialogs.channel,
                (call) async {
          calls.add(call);
          return null;
        });
        addTearDown(() => TestDefaultBinaryMessengerBinding
            .instance.defaultBinaryMessenger
            .setMockMethodCallHandler(WindowsSecurityDialogs.channel, null));
        await tester.pumpWidget(MaterialApp(
            theme: KasVaultTheme.forTheme(theme),
            home: Scaffold(
                body: WindowsSecurityDialog(
                    id: 11,
                    mode: mode,
                    title: mode == 3
                        ? 'Review transaction'
                        : 'Secure Kaspire input',
                    body: mode == 3
                        ? List.filled(80, 'Reviewed output: 1 KAS').join('\n')
                        : 'Enter the information here. Confirm with the visible button.'))));
        await tester.pump();
        expect(tester.takeException(), isNull);
        final label = mode == 6
            ? 'Done'
            : mode == 3
                ? 'Confirm'
                : 'Continue';
        final actions = find.widgetWithText(FilledButton, label);
        expect(actions.hitTestable(), findsOneWidget);
        expect(find.widgetWithText(OutlinedButton, 'Cancel').hitTestable(),
            findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        await tester.tap(actions);
        await tester.pump();
        final finish = calls.lastWhere((c) => c.method == 'finishPrompt');
        expect(finish.arguments, {'id': 11, 'accepted': true});
        if (mode != 3) {
          final layout = calls
              .firstWhere((c) => c.method == 'layoutPrompt')
              .arguments as Map;
          expect(layout['scale'], 2.25);
          expect(layout['width'], greaterThan(0));
          expect(layout['height'], greaterThan(0));
          expect(layout.keys, isNot(contains('text')));
        }
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }
  testWidgets('Windows dashboard reuses original widgets beside one another',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: WalletResponsiveLayout(children: [
      const Text('Original header'),
      const SizedBox(height: 20),
      const Text('Original balance'),
      const SizedBox(height: 16),
      const Text('Original actions'),
      const SizedBox(height: 32),
      const Text('Original assets'),
      const Text('Original activity'),
    ]))));
    expect(tester.getTopLeft(find.text('Original assets')).dx,
        greaterThan(tester.getTopLeft(find.text('Original balance')).dx));
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets('PIN layout is not resent on unrelated dialog rebuilds',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(WindowsSecurityDialogs.channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(WindowsSecurityDialogs.channel, null));
    Widget dialog(String title) => MaterialApp(
        home: Scaffold(
            body: WindowsSecurityDialog(
                id: 25, mode: 1, title: title, body: 'Enter PIN')));
    await tester.pumpWidget(dialog('Unlock wallet'));
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pumpWidget(dialog('Unlock wallet $i'));
      await tester.pump();
    }
    expect(calls.where((call) => call.method == 'layoutPrompt').length, 1);
    tester.view.physicalSize = const Size(1100, 700);
    await tester.pump();
    await tester.pump();
    final layouts =
        calls.where((call) => call.method == 'layoutPrompt').toList();
    expect(layouts.length, 2);
    expect((layouts.first.arguments as Map)['focus'], true);
    expect((layouts.last.arguments as Map)['focus'], false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });
  for (final theme in KaspireTheme.values) {
    testWidgets('Desktop $theme has the nine requested actions in three rows',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      AppSettings.theme.value = theme;
      void noop() {}
      final opened = <String>[];
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: Scaffold(
            body: SizedBox(
                width: 330,
                child: WalletDashboardActions(
                  onSend: noop,
                  onReceive: noop,
                  onVaults: noop,
                  onSwap: noop,
                  onBrowser: noop,
                  onPairDapp: noop,
                  onAgora: noop,
                  onSettings: noop,
                  onAssets: () => opened.add('assets'),
                  onActivity: () => opened.add('activity'),
                  onUtxos: () => opened.add('utxos'),
                )),
          )));
      for (final label in [
        'Send',
        'Receive',
        'Vaults',
        'Swap',
        'K-Agora',
        'Settings',
        'Assets',
        'Activity',
        'UTXOs'
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Browser'), findsNothing);
      expect(find.text('Pair dApp'), findsNothing);
      expect(tester.getTopLeft(find.text('Send')).dy,
          tester.getTopLeft(find.text('Vaults')).dy);
      expect(tester.getTopLeft(find.text('Swap')).dy,
          greaterThan(tester.getTopLeft(find.text('Send')).dy));
      expect(tester.getTopLeft(find.text('Assets')).dy,
          greaterThan(tester.getTopLeft(find.text('Settings')).dy));
      expect(tester.getTopLeft(find.text('Assets')).dy,
          tester.getTopLeft(find.text('UTXOs')).dy);
      for (final label in ['Assets', 'Activity', 'UTXOs']) {
        await tester.tap(find.text(label));
      }
      expect(opened, ['assets', 'activity', 'utxos']);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
    testWidgets('Desktop $theme header controls fit the left pane and reload',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      AppSettings.theme.value = theme;
      var reloads = 0, switches = 0;
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: Scaffold(
              body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                      width: 330,
                      child: WalletDashboardHeader(
                        onSwitchWallet: () => switches++,
                        onReload: () => reloads++,
                        networkSelector: const Text('Layer 1'),
                        notifications: const Icon(Icons.notifications_outlined),
                      ))))));
      for (final control in [
        find.byTooltip('Switch wallet'),
        find.text('Layer 1'),
        find.byIcon(Icons.notifications_outlined),
        find.byTooltip('Reload')
      ]) {
        expect(tester.getRect(control).right, lessThanOrEqualTo(330));
      }
      await tester.tap(find.byTooltip('Reload'));
      await tester.tap(find.byTooltip('Switch wallet'));
      expect(reloads, 1);
      expect(switches, 1);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }
  testWidgets(
      'Right-pane navigation and scrolling leave balance and actions visible',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final navigator = GlobalKey<NavigatorState>();
    Widget dashboard(String assets) => MaterialApp(
            home: Scaffold(
                body: WalletResponsiveLayout(
                    desktopNavigator: navigator,
                    children: [
              const Text('Header'),
              const SizedBox(height: 20),
              const Text('Persistent balance'),
              const SizedBox(height: 16),
              const Text('Persistent actions'),
              const SizedBox(height: 32),
              Text(assets),
              const SizedBox(height: 2000),
              const Text('Activity bottom'),
            ])));
    await tester.pumpWidget(dashboard('Original assets'));
    final position = tester.getTopLeft(find.text('Persistent balance'));
    expect(tester.getTopLeft(find.text('Header')).dx, position.dx);
    await tester.drag(find.byKey(const PageStorageKey('desktop-assets-pane')),
        const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Persistent balance')), position);
    expect(find.text('Header').hitTestable(), findsOneWidget);
    navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(
                body: Column(children: [
              const Text('Send on right'),
              TextButton(
                  onPressed: () =>
                      Navigator.of(navigator.currentContext!).pop(),
                  child: const Text('Done')),
            ]))));
    await tester.pumpAndSettle();
    expect(find.text('Send on right'), findsOneWidget);
    expect(find.text('Persistent balance').hitTestable(), findsOneWidget);
    expect(find.text('Persistent actions').hitTestable(), findsOneWidget);
    expect(tester.getTopLeft(find.text('Send on right')).dx,
        greaterThan(position.dx));
    await tester.pumpWidget(dashboard('Refreshed assets'));
    await tester.pumpAndSettle();
    expect(find.text('Send on right'), findsOneWidget);
    await tester.tap(find.byTooltip('Wallet overview'));
    await tester.pumpAndSettle();
    expect(find.text('Send on right'), findsNothing);
    await tester.drag(find.byKey(const PageStorageKey('desktop-assets-pane')),
        const Offset(0, 800));
    await tester.pumpAndSettle();
    expect(find.text('Refreshed assets', skipOffstage: false), findsOneWidget);
    expect(tester.getTopLeft(find.text('Persistent balance')), position);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets('Android wide screen still keeps existing dashboard ordering',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: WalletResponsiveLayout(children: [
      const Text('Header'),
      const SizedBox(height: 20),
      const Text('Balance'),
      const SizedBox(height: 16),
      const Text('Actions'),
      const SizedBox(height: 32),
      const Text('Assets'),
    ]))));
    expect(tester.getTopLeft(find.text('Assets')).dx,
        tester.getTopLeft(find.text('Balance')).dx);
    expect(tester.getTopLeft(find.text('Assets')).dy,
        greaterThan(tester.getTopLeft(find.text('Balance')).dy));
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets(
      'Desktop frame uses the available window without cutting its height',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1700, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(
        home: DesktopFrame(child: SizedBox.expand(key: Key('frame')))));
    expect(
        tester.getSize(find.byKey(const Key('frame'))), const Size(1700, 900));
    debugDefaultTargetPlatformOverride = null;
  });
  test(
      'Windows native channel sends only public arguments and distinct lock signal',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final calls = <Map>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('space.kaspire/security-windows'),
            (call) async {
      final frame = call.arguments as Map;
      calls.add(frame);
      final message = jsonDecode(frame['payload'] as String) as Map;
      return jsonEncode(
          {'result': message['method'] == 'hasPin' ? true : null});
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('space.kaspire/security-windows'), null));
    expect(await const SecurityChannel().invokeMethod<bool>('hasPin'), true);
    await NativeSecurity().setInternalNexusUnlocked(false);
    expect(calls[0]['lock'], false);
    expect(calls[1]['lock'], true);
    expect(jsonDecode(calls[1]['payload'] as String)['arguments'],
        {'enabled': false});
  });
  test('Windows native errors never fall back to Android signing', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('space.kaspire/security-windows'),
            (_) async => jsonEncode({
                  'error': 'Reviewed terms changed; no transaction was signed.'
                }));
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('space.kaspire/security-windows'), null));
    await expectLater(const SecurityChannel().invokeMethod<String>('signPskt'),
        throwsA(isA<PlatformException>()));
  });
  test('Windows fetches its signed installer channel, never Android APKs',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues(
        {'updates_highest_signed_build_v1': 181});
    var requests = 0;
    final payload = {
      'platform': 'windows-x64',
      'version': '0.1.4',
      'build': 5,
      'minimumBuild': 1,
      'critical': false,
      'publishedAt': '2026-10-16T00:00:00Z',
      'installerUrl':
          'https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/windows-v0.1.4/Kaspire-Windows-0.1.4-x64-Setup.exe',
      'sha256': 'ab' * 32,
      'sizeBytes': 100000,
      'releaseNotesUrl':
          'https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/tag/windows-v0.1.4'
    };
    final updates = UpdateService(
        client: MockClient((request) async {
          requests++;
          expect(request.url.path, '/updates/windows.json');
          return http.Response(
              jsonEncode({
                'payload': base64Encode(utf8.encode(jsonEncode(payload))),
                'signature': 'verified-fixture'
              }),
              200);
        }),
        verifier: (_, __) async => true,
        packageInfo: () async => PackageInfo(
            appName: 'Kaspire',
            packageName: 'space.kaspire.wallet',
            version: '0.1.3',
            buildNumber: '4'));
    final update = await updates.checkNow();
    expect(update?.isDesktop, true);
    expect(update?.build, 5);
    expect(requests, 1);
    expect(update?.apkUrl.path, endsWith('-Setup.exe'));
    expect(updates.state.value.error, isNull);
    payload['installerUrl'] = 'https://example.com/changed.exe';
    await updates.checkNow();
    expect(updates.state.value.error, contains('invalid fields'));
  });
  test('Windows internal Nexus challenge receives a bound authorization token',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    NativeSecurity.internalNexusUnlocked = true;
    addTearDown(() => NativeSecurity.internalNexusUnlocked = false);
    final calls = <Map>[];
    const channel = MethodChannel('space.kaspire/security-windows');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final message =
          jsonDecode((call.arguments as Map)['payload'] as String) as Map;
      calls.add(message);
      return jsonEncode({
        'result': message['method'] == 'authorizeOperation'
            ? 'native-nexus-token'
            : jsonEncode({'signature': 'fixture-signature'})
      });
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    expect(
        await NativeSecurity()
            .signInternalNexusChallenge('kaspa:fixture', 'challenge'),
        'fixture-signature');
    expect(calls[0]['arguments']['operation'], 'signInternalNexusChallenge');
    expect(calls[0]['arguments']['binding'], 'kaspa:fixture\u0000challenge');
    expect(calls[1]['arguments']['authorizationToken'], 'native-nexus-token');
  });
}
