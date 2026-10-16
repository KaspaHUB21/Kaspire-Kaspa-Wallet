import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/widgets/wallet_unlock_screen.dart';
import 'package:kasvault_wallet/src/widgets/windows_security_dialog.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    AppSettings.theme.value = KaspireTheme.midnight;
  });
  for (final theme in KaspireTheme.values) {
    testWidgets(
        'Wrong Windows password shows an error and allows retry in $theme',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      AppSettings.theme.value = theme;
      final result = Completer<bool>();
      var attempts = 0, activations = 0, unlocked = 0;
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: WalletUnlockScreen(
              authenticate: () {
                attempts++;
                return attempts == 1 ? result.future : Future.value(true);
              },
              activateSession: () async {
                activations++;
              },
              onUnlocked: () => unlocked++)));
      await tester.tap(find.text('Unlock Kaspire'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      result.completeError(PlatformException(
          code: 'SECURITY_ERROR',
          message: 'Incorrect Kaspire password. No transaction was signed.'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Incorrect password.'), findsOneWidget);
      expect(find.textContaining('PlatformException'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(activations, 0);
      expect(unlocked, 0);
      await tester.tap(find.text('Unlock Kaspire'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(activations, 1);
      expect(unlocked, 1);
      expect(find.textContaining('Incorrect password.'), findsNothing);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }
  for (final mode in ['cancel', 'false', 'activation failure', 'throttle']) {
    testWidgets('Unlock $mode always clears busy state and stays locked',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      var unlocked = false;
      await tester.pumpWidget(MaterialApp(
          home: WalletUnlockScreen(
              authenticate: () async {
                if (mode == 'cancel') {
                  throw PlatformException(
                      code: 'SECURITY_ERROR',
                      message: 'Cancelled. No new transaction was signed.');
                }
                if (mode == 'throttle') {
                  throw PlatformException(
                      code: 'SECURITY_ERROR',
                      message: 'Too many incorrect password attempts.');
                }
                return mode != 'false';
              },
              activateSession: () async {
                throw StateError('Session unavailable');
              },
              onUnlocked: () => unlocked = true)));
      await tester.tap(find.text('Unlock Kaspire'));
      await tester.pumpAndSettle();
      expect(unlocked, false);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNotNull);
      if (mode == 'cancel') {
        expect(find.textContaining('Could not authenticate'), findsNothing);
      }
      if (mode == 'throttle') {
        expect(find.textContaining('wait one minute'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }
  testWidgets('Disposed unlock screen never activates a late session',
      (tester) async {
    final result = Completer<bool>();
    var activated = false;
    await tester.pumpWidget(MaterialApp(
        home: WalletUnlockScreen(
            authenticate: () => result.future,
            activateSession: () async {
              activated = true;
            },
            onUnlocked: () {})));
    await tester.tap(find.text('Unlock Kaspire'));
    await tester.pumpWidget(const SizedBox.shrink());
    result.complete(true);
    await tester.pump();
    expect(activated, false);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Password eye sends visibility only and new dialog starts masked',
      (tester) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(WindowsSecurityDialogs.channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(WindowsSecurityDialogs.channel, null));
    Widget dialog(int id) => MaterialApp(
        home: WindowsSecurityDialog(
            key: ValueKey(id),
            id: id,
            mode: 1,
            title: 'Set Kaspire password',
            body: 'Choose a case-sensitive password.'));
    await tester.pumpWidget(dialog(1));
    await tester.pump();
    await tester.tap(find.byTooltip('Show password'));
    await tester.pumpAndSettle();
    expect(calls.lastWhere((c) => c.method == 'setPromptVisibility').arguments,
        {'id': 1, 'visible': true});
    expect(find.byTooltip('Hide password'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byTooltip('Hide password'));
    await tester.pumpAndSettle();
    expect(calls.lastWhere((c) => c.method == 'setPromptVisibility').arguments,
        {'id': 1, 'visible': false});
    await tester.tap(find.byTooltip('Show password'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(dialog(2));
    await tester.pump();
    expect(find.byTooltip('Show password'), findsOneWidget);
    expect(find.byTooltip('Hide password'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
