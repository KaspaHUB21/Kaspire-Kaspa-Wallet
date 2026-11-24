import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kasvault_wallet/src/app.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/services/dapp_session_service.dart';
import 'package:kasvault_wallet/src/services/native_security.dart';
import 'package:kasvault_wallet/src/services/update_service.dart';
import 'package:kasvault_wallet/src/widgets/android_wallet_lock.dart';
import 'dapp_request_recovery_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const security = MethodChannel('space.kasvault/security');
  const localAuth = MethodChannel('plugins.flutter.io/local_auth');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<List<bool>> start(WidgetTester tester, {
    bool saved = true, bool native = true, int minutes = 15,
    DateTime? lastActivity,
  }) async {
    SharedPreferences.setMockInitialValues({
      if (saved) 'watch_address_v1': fixture.wallet,
    });
    FlutterSecureStorage.setMockInitialValues({});
    AppSettings.lockMinutes.value = minutes;
    if (lastActivity != null) await AppSettings.recordBackgroundedAt(lastActivity);
    NativeSecurity.internalNexusUnlocked = false;
    final enabled = <bool>[];
    messenger.setMockMethodCallHandler(security, (call) async {
      switch (call.method) {
        case 'initializeVault': return null;
        case 'getNativeAddress': return native ? fixture.wallet : null;
        case 'hasNativeWallet': return native;
        case 'hasPin': return true;
        case 'verifyPin': return false; // No successful authentication in this fixture.
        case 'setInternalNexusUnlocked':
          final value = (call.arguments as Map)['enabled'] == true;
          enabled.add(value);
          // Bound the old-path reproduction before any wallet/dashboard reads.
          if (value) throw StateError('Session activated without authentication');
          return null;
        default: throw StateError('Unexpected native call: ${call.method}');
      }
    });
    messenger.setMockMethodCallHandler(localAuth, (call) async =>
        call.method == 'getAvailableBiometrics' ? ['fingerprint'] : false);
    for (final name in ['com.llfbandit.app_links/messages', 'com.llfbandit.app_links/events']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    await tester.pumpWidget(KasVaultApp(dappSessions:
        DappSessionService.forTesting(() async => fixture.FakeKit())));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      messenger.setMockMethodCallHandler(security, null);
      messenger.setMockMethodCallHandler(localAuth, null);
      for (final name in ['com.llfbandit.app_links/messages', 'com.llfbandit.app_links/events']) {
        messenger.setMockMethodCallHandler(MethodChannel(name), null);
      }
      AppSettings.lockMinutes.value = 15;
      UpdateService.instance.state.value = const UpdateCheckState();
      NativeSecurity.internalNexusUnlocked = false;
    });
    return enabled;
  }

  for (final minutes in [0, 1, 15, 60]) {
    testWidgets('Android cold start is locked with recent activity and $minutes minute timer', (tester) async {
      final enabled = await start(tester, minutes: minutes, lastActivity: DateTime.now());
      expect(enabled, isNot(contains(true)));
      expect(NativeSecurity.internalNexusUnlocked, isFalse);
      expect(find.byType(AndroidWalletLock), findsOneWidget);
      expect(find.text('Wallet Locked'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('Future persisted activity cannot authorize an Android cold start', (tester) async {
    final enabled = await start(tester, lastActivity: DateTime.now().add(const Duration(days: 1)));
    expect(enabled, isNot(contains(true)));
    expect(find.byType(AndroidWalletLock), findsOneWidget);
  });
  testWidgets('Native wallet recovered without address preferences still starts locked', (tester) async {
    final enabled = await start(tester, saved: false);
    expect(enabled, isNot(contains(true)));
    expect(find.byType(AndroidWalletLock), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getString('watch_address_v1'), fixture.wallet);
  });
  testWidgets('Watch address does not bypass the cold-start gate', (tester) async {
    final enabled = await start(tester, native: false, lastActivity: DateTime.now());
    expect(enabled, isNot(contains(true)));
    expect(find.byType(AndroidWalletLock), findsOneWidget);
  });
  testWidgets('Locked touches, cancelled PIN and background round trip do not unlock', (tester) async {
    final old = DateTime.now().subtract(const Duration(minutes: 1));
    final enabled = await start(tester, minutes: 0, lastActivity: old);
    await tester.tap(find.text('Wallet Locked'));
    await tester.pumpAndSettle();
    expect((await AppSettings.lastBackgroundedAt())!.millisecondsSinceEpoch, old.millisecondsSinceEpoch);
    await tester.ensureVisible(find.text('Enter wallet PIN'));
    await tester.tap(find.text('Enter wallet PIN'));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(enabled, isNot(contains(true)));
    expect(find.byType(AndroidWalletLock), findsOneWidget);
    expect(NativeSecurity.internalNexusUnlocked, isFalse);
  });
}
