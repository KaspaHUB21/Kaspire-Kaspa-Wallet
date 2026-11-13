import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/services/native_security.dart';
import 'package:kasvault_wallet/src/services/update_service.dart';
import 'package:kasvault_wallet/src/theme.dart';
import 'package:kasvault_wallet/src/widgets/android_wallet_lock.dart';
import 'package:kasvault_wallet/src/widgets/wallet_unlock_screen.dart';

void main() {
  const boundary = ValueKey('lock-preview');
  var fontsLoaded = false;
  tearDown(() {
    AppSettings.theme.value = KaspireTheme.midnight;
    UpdateService.instance.state.value = const UpdateCheckState();
  });
  Future<void> mount(WidgetTester tester,
      {KaspireTheme theme = KaspireTheme.midnight,
      Future<bool> Function()? auth,
      Future<({bool biometrics, bool pin})> Function()? methods,
      Future<void> Function()? activate,
      VoidCallback? unlocked}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    AppSettings.theme.value = theme;
    if (!fontsLoaded &&
        Platform.environment['LOCKSCREEN_PREVIEW_DIR'] != null) {
      await tester.runAsync(() async {
        for (final font in {
          'sans-serif': 'Roboto-Regular.ttf',
          'MaterialIcons': 'MaterialIcons-Regular.otf',
        }.entries) {
          final bytes = await File(
                  '/srv/kaspire/toolchains/flutter/bin/cache/artifacts/material_fonts/${font.value}')
              .readAsBytes();
          await (FontLoader(font.key)
                ..addFont(Future.value(ByteData.sublistView(bytes))))
              .load();
        }
      });
      fontsLoaded = true;
    }
    await tester.pumpWidget(MaterialApp(
      theme: KasVaultTheme.forTheme(theme),
      home: RepaintBoundary(
        key: boundary,
        child: WalletUnlockScreen(
          availableMethods: methods,
          authenticate: auth ?? () async => true,
          authenticateBiometrics: auth,
          authenticatePin: auth,
          activateSession: activate ?? () async {},
          onUnlocked: unlocked ?? () {},
        ),
      ),
    ));
    await tester.runAsync(() async {
      await precacheImage(
          const AssetImage('assets/branding/lock_reference_v2.jpg'),
          tester.element(find.byType(AndroidWalletLock)));
    });
    await tester.pumpAndSettle();
  }

  for (final theme in KaspireTheme.values) {
    testWidgets('Same public mountain lockscreen in $theme', (tester) async {
      await mount(tester, theme: theme);
      expect(find.text('Wallet Locked'), findsOneWidget);
      expect(find.text('Use Biometrics'), findsOneWidget);
      expect(find.textContaining('Face ID'), findsNothing);
      expect(find.byIcon(Icons.fingerprint_rounded), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      final context = tester.element(find.byType(AndroidWalletLock));
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.backgroundColor, AndroidWalletLock.background);
      expect(Theme.of(context).brightness, isNotNull);
      expect(find.byType(Image), findsNWidgets(3));
      expect(tester.takeException(), isNull);
      if (theme == KaspireTheme.midnight &&
          Platform.environment['LOCKSCREEN_PREVIEW_DIR'] != null) {
        await tester.runAsync(() async {
          final render =
              tester.renderObject<RenderRepaintBoundary>(find.byKey(boundary));
          final image = await render.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
                  '${Platform.environment['LOCKSCREEN_PREVIEW_DIR']}/lock.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }

  for (final mode in ['false', 'cancel', 'error', 'activation failure']) {
    testWidgets('$mode never unlocks and leaves retry available',
        (tester) async {
      var activated = 0, unlocked = 0;
      await mount(tester,
          auth: () async {
            if (mode == 'cancel' || mode == 'error') {
              throw PlatformException(
                  code: 'SECURITY_ERROR',
                  message: mode == 'cancel' ? 'Cancelled.' : 'Incorrect PIN.');
            }
            return mode != 'false';
          },
          activate: () async {
            activated++;
            throw StateError('Session unavailable');
          },
          unlocked: () => unlocked++);
      await tester.ensureVisible(find.text('Use Biometrics'));
      await tester.tap(find.text('Use Biometrics'));
      await tester.pumpAndSettle();
      expect(activated, mode == 'activation failure' ? 1 : 0);
      expect(unlocked, 0);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'Repeated taps share one native check; no activation after disposal',
      (tester) async {
    final result = Completer<bool>();
    var calls = 0, activated = 0;
    await mount(tester,
        auth: () {
          calls++;
          return result.future;
        },
        activate: () async => activated++);
    await tester.tap(find.text('Use Biometrics'));
    await tester.tap(find.text('Use Biometrics'));
    await tester.pump();
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    result.complete(true);
    await tester.pump();
    expect(activated, 0);
  });

  testWidgets('PIN success activates once; small and landscape layouts scroll',
      (tester) async {
    var activated = 0, unlocked = 0;
    await mount(tester,
        methods: () async => (biometrics: false, pin: true),
        activate: () async => activated++,
        unlocked: () => unlocked++);
    expect(find.text('Use Biometrics'), findsNothing);
    for (final size in [const Size(320, 568), const Size(740, 360)]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Enter wallet PIN'));
      await tester.tap(find.text('Enter wallet PIN'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    expect(activated, 2);
    expect(unlocked, 2);
  });

  testWidgets('No enrolled PIN/biometrics preserves device-credential entry',
      (tester) async {
    var authenticated = 0;
    await mount(tester,
        methods: () async => (biometrics: false, pin: false),
        auth: () async {
          authenticated++;
          return true;
        });
    expect(find.text('Use Biometrics'), findsNothing);
    expect(find.text('Enter wallet PIN'), findsNothing);
    await tester.ensureVisible(find.text('Use device lock'));
    await tester.tap(find.text('Use device lock'));
    await tester.pumpAndSettle();
    expect(authenticated, 1);
  });

  testWidgets('Verified update stays accessible while wallet is locked',
      (tester) async {
    UpdateService.instance.state.value = UpdateCheckState(
        update: KaspireUpdate(
      version: '1.0.0',
      build: 999,
      minimumBuild: 1,
      critical: false,
      publishedAt: DateTime.utc(2026),
      apkUrl: Uri.parse('https://kaspire.kaslab.space/downloads/fixture.apk'),
      sha256: 'a' * 64,
      releaseNotesUrl: Uri.parse(
          'https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/tag/fixture'),
    ));
    await mount(tester);
    await tester.tap(find.text('Update available'));
    await tester.pumpAndSettle();
    expect(find.text('How would you like to update?'), findsOneWidget);
    expect(find.text('Wallet Locked'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
      'Native shortcuts preserve PIN ownership and biometric-only verification',
      () async {
    final calls = <MethodCall>[];
    const security = MethodChannel('space.kasvault/security');
    const localAuth = MethodChannel('plugins.flutter.io/local_auth');
    var pin = true, enrolled = true, accepted = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(security, (call) async {
      calls.add(call);
      return call.method == 'hasPin' ? pin : accepted;
    });
    messenger.setMockMethodCallHandler(localAuth, (call) async {
      calls.add(call);
      return call.method == 'getAvailableBiometrics'
          ? (enrolled ? ['fingerprint'] : <String>[])
          : accepted;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(security, null);
      messenger.setMockMethodCallHandler(localAuth, null);
    });
    final native = NativeSecurity();
    expect(await native.authenticateWalletPin('Unlock Kaspire'), false);
    expect(calls.last.method, 'verifyPin');
    expect(calls.last.arguments, {'reason': 'Unlock Kaspire'});
    accepted = true;
    expect(await native.authenticateWalletPin('Unlock Kaspire'), true);
    expect(await native.authenticateWalletBiometrics('Unlock Kaspire'), true);
    expect((calls.last.arguments as Map)['biometricOnly'], true);
    expect(calls.last.method, 'authenticate');
    accepted = false;
    expect(await native.authenticateWalletBiometrics('Unlock Kaspire'), false);
    expect(calls.last.method, 'authenticate'); // Never falls back to verifyPin.
    pin = false;
    enrolled = false;
    final before = calls.where((call) => call.method == 'verifyPin').length;
    expect(await native.authenticateWalletPin('Unlock Kaspire'), false);
    expect(await native.authenticateWalletBiometrics('Unlock Kaspire'), false);
    expect(calls.where((call) => call.method == 'verifyPin').length, before);
    expect(await native.walletUnlockMethods(), (biometrics: false, pin: false));
  });
}
