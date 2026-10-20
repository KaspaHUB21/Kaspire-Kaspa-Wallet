import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:kasvault_wallet/src/screens/receive_screen.dart';
import 'package:kasvault_wallet/src/screens/hidden_kas_screen.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';

const owner =
    'kaspa:qp0mtdvzscrkfft702j85s8yzdl8a87n5d6pgtm8vrxg6hqu0wywzvwkevdk3';
void main() {
  const channel = MethodChannel('space.kasvault/security');
  for (final theme in [
    KaspireTheme.midnight,
    KaspireTheme.hub21,
    KaspireTheme.glacier,
    KaspireTheme.neptune
  ]) {
    testWidgets(
        'Receive opens normally and switches to P2SH without signing in $theme',
        (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final previous = AppSettings.theme.value;
      AppSettings.theme.value = theme;
      addTearDown(() => AppSettings.theme.value = previous);
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'getNativeAddress') return owner;
        if (call.method == 'listWallets') {
          return jsonEncode([
            {
              'id': 'wallet',
              'address': owner,
              'kind': 'private-key',
              'active': true
            }
          ]);
        }
        throw PlatformException(code: 'UNEXPECTED_CALL', message: call.method);
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: const Scaffold(body: ReceiveScreen(address: owner))));
      await tester.pumpAndSettle();
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.byType(HiddenKasScreen), findsNothing);
      await tester.tap(find.text('P2SH account'));
      await tester.pumpAndSettle();
      expect(find.byType(HiddenKasScreen), findsOneWidget);
      expect(find.text('Seed-based HD wallet required'), findsOneWidget);
      expect(find.textContaining('PlatformException'), findsNothing);
      expect(
          calls.where(
              (call) => call.contains('sign') || call == 'deriveHiddenKas'),
          isEmpty);
      await tester.tap(find.text('Receive KAS').first);
      await tester.pumpAndSettle();
      expect(find.byType(HiddenKasScreen), findsNothing);
      expect(find.byType(QrImageView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('TN10 receive does not expose a Mainnet P2SH switch',
      (tester) async {
    final previous = NetworkSettings.network.value;
    NetworkSettings.network.value = KaspaNetwork.tn10;
    addTearDown(() => NetworkSettings.network.value = previous);
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ReceiveScreen(address: owner))));
    await tester.pumpAndSettle();
    expect(find.text('P2SH account'), findsNothing);
  });
}
