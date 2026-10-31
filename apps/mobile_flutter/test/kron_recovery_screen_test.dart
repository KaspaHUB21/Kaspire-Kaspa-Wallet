import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/screens/kron_dex_screen.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/services/kron_dex_service.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';
import 'dex_sell_presets_test.dart' show Api, Holdings, id;
import 'kron_recovery_test.dart' show receipt;

class Saved extends KronDexService {
  KronRecoveryState state = KronRecoveryState.pending;
  bool fail = false;
  int submissions = 0;
  @override
  Future<Map<String, dynamic>?> pending(String address) async => receipt();
  @override
  Future<KronRecoveryState> checkSaved(
      String address, Map<String, dynamic> receipt) async {
    if (fail) {
      throw StateError('Own-node status unavailable. Signed swap retained.');
    }
    return state;
  }

  @override
  Future<String> submit(String address, Map<String, dynamic> receipt) async {
    submissions++;
    return receipt['transactionId'];
  }
}

void main() {
  setUp(() => NetworkSettings.network.value = KaspaNetwork.mainnet);
  Widget screen(Saved service, KaspireTheme theme) => MaterialApp(
      theme: KasVaultTheme.forTheme(theme),
      home: KronTradeScreen(
          address: 'kaspa:fixture',
          token: {
            'covenantId': id,
            'ticker': 'KRON',
            'name': 'KRON',
            'image': 'https://example.invalid/logo.png',
            'decimals': 8
          },
          service: service,
          api: Api(),
          holdings: Holdings()));
  for (final theme in KaspireTheme.values) {
    testWidgets('official Braid mark in swap selector at 320px in $theme',
        (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: const DexSelectionScreen(address: 'kaspa:fixture')));
      await tester.pumpAndSettle();
      final tile = find.ancestor(
          of: find.text('Braid Aggregator'), matching: find.byType(ListTile));
      final mark = tester.widget<SvgPicture>(
          find.descendant(of: tile, matching: find.byType(SvgPicture)));
      expect((mark.bytesLoader as SvgAssetLoader).assetName,
          'assets/browser/braid.svg');
      expect(
          find.descendant(of: tile, matching: find.byIcon(Icons.route_rounded)),
          findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  for (final theme in [
    KaspireTheme.midnight,
    KaspireTheme.hub21,
    KaspireTheme.glacier,
    KaspireTheme.neptune
  ]) {
    for (final outcome in [
      KronRecoveryState.confirmed,
      KronRecoveryState.obsolete
    ]) {
      testWidgets('saved swap $outcome releases the right UI in $theme',
          (tester) async {
        tester.view.physicalSize = const Size(320, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final source = Saved();
        await tester.pumpWidget(screen(source, theme));
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(find.byType(TextField)).enabled, false);
        source.state = outcome;
        final button = find.text('Check status / refresh quote');
        await tester.scrollUntilVisible(button, 160,
            scrollable: find.byType(Scrollable).first);
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        await tester.tap(button);
        await tester.pumpAndSettle();
        if (outcome == KronRecoveryState.confirmed) {
          expect(find.text('Swap submitted'), findsOneWidget);
          expect(find.byType(TextField), findsNothing);
        } else {
          expect(
              tester.widget<TextField>(find.byType(TextField)).enabled, true);
          expect(find.textContaining('old signed swap was archived'),
              findsOneWidget);
        }
        expect(find.text('Retry same saved swap'), findsNothing);
        expect(source.submissions, 0);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets(
      'unknown status retains recovery and retry completes without a signing request',
      (tester) async {
    tester.view.physicalSize = const Size(400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = Saved()..fail = true;
    await tester.pumpWidget(screen(source, KaspireTheme.midnight));
    await tester.pumpAndSettle();
    expect(find.textContaining('Signed swap retained'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, false);
    source.fail = false;
    final button = find.text('Retry same saved swap');
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(source.submissions, 1);
    expect(find.text('Swap submitted'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
