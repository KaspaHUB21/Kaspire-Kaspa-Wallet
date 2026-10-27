import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/models/wallet_snapshot.dart';
import 'package:kasvault_wallet/src/screens/kasforge_screen.dart';
import 'package:kasvault_wallet/src/screens/kron_dex_screen.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/services/kasforge_service.dart';
import 'package:kasvault_wallet/src/services/kasforge_trading.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';
import 'package:kasvault_wallet/src/widgets/sell_amount_buttons.dart';

final token = KasForgeToken(
    id: 'a' * 64,
    symbol: 'LONGKASFORGETICKER',
    name: 'A long KasForge token name which must wrap on a narrow phone',
    decimals: 0,
    genesis: 'b' * 64,
    curve: 'c' * 64,
    pool: 'd' * 64,
    graduated: true,
    priceKas: 0.001);

class Source extends KasForgeService {
  Source({this.failWallet = false});
  final bool failWallet;
  @override
  Future<List<KasForgeToken>> catalogue() async => [token];
  @override
  Future<List<WalletAsset>> walletAssets(String address) async {
    if (failWallet) throw StateError('Indexer unavailable');
    return [
      WalletAsset(
          symbol: token.symbol,
          balance: 12345,
          rawBalance: '12345',
          kind: 'KCC20',
          covenantId: token.id,
          decimals: 0)
    ];
  }

  @override
  Future<Map<String, dynamic>> portfolio(String address) async =>
      {'orders': [], 'activity': []};
  @override
  Future<Map<String, dynamic>> quote(
          KasForgeToken t, String side, String amount) async =>
      {
        'side': side,
        if (side == 'buy') 'receiveTokens': 250,
        if (side == 'sell') 'receiveKas': 10,
        'tokenDepositKas': 1,
      };
}

Map<String, dynamic> savedOrder() => {
      'symbol': token.symbol,
      'side': 'buy',
      'state': 'deposited-untracked',
      'signed': ['saved bytes'],
      'amount': '10',
      'minimumOut': '123',
      'tokenId': token.id,
      'transactionIds': ['b' * 64],
      'order': {
        'state': {'expiryDaa': 12345678},
        'address': 'kaspatest:p${'a' * 60}'
      },
    };

class Journal extends KasForgeTrading {
  Journal({this.rows = const [], this.failure = false, this.gate});
  final List<Map<String, dynamic>> rows;
  bool failure;
  final Completer<List<Map<String, dynamic>>>? gate;
  int builds = 0;
  @override
  Future<List<Map<String, dynamic>>> saved(String address) async {
    if (failure) throw StateError('Encrypted journal unavailable');
    return gate?.future ?? rows;
  }

  @override
  Future<Map<String, dynamic>> build(String address, KasForgeToken token,
      String side, String amount, Map quote) async {
    builds++;
    throw StateError('A new build must not be requested');
  }
}

void main() {
  setUp(() => NetworkSettings.network.value = KaspaNetwork.tn10);
  for (final theme in [
    KaspireTheme.midnight,
    KaspireTheme.hub21,
    KaspireTheme.glacier,
    KaspireTheme.neptune
  ]) {
    testWidgets(
        'KasForge balance, long labels, sell presets and quote-gated signing in $theme',
        (tester) async {
      tester.view.physicalSize = const Size(320, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: KasForgeTradeScreen(
              address: 'fixture',
              token: token,
              service: Source(),
              trading: Journal())));
      await tester.pumpAndSettle();
      expect(find.textContaining('12,345'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Sell'), 120,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Sell'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byType(SellAmountButtons), 120,
          scrollable: find.byType(Scrollable).first);
      final field = tester.widget<TextField>(find.byType(TextField));
      for (final (label, value) in [
        ('25%', '3086'),
        ('50%', '6172'),
        ('75%', '9258'),
        ('MAX', '12345')
      ]) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(field.controller!.text, value);
      }
      await tester.scrollUntilVisible(find.text('Review Forge order'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Review Forge order'))
              .onPressed,
          isNull);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
      'unavailable balance is not shown as zero and has no sell shortcuts',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: KasForgeTradeScreen(
            address: 'fixture',
            token: token,
            service: Source(failWallet: true),
            trading: Journal())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sell'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Wallet balance unavailable'), findsOneWidget);
    expect(find.byType(SellAmountButtons), findsNothing);
    expect(find.textContaining('Wallet token balance: 0'), findsNothing);
  });
  testWidgets('catalogue and empty history are distinct, reopening still loads',
      (tester) async {
    for (var i = 0; i < 2; i++) {
      await tester.pumpWidget(MaterialApp(
          key: ValueKey(i),
          home: KasForgeScreen(
              address: 'fixture', service: Source(), trading: Journal())));
      await tester.pumpAndSettle();
      expect(find.text(token.symbol), findsOneWidget);
      await tester.tap(find.text('My activity'));
      await tester.pumpAndSettle();
      expect(find.textContaining('No open orders reported by Forge.'),
          findsOneWidget);
      expect(find.text('No KasForge activity.'), findsOneWidget);
    }
  });
  for (final theme in [
    KaspireTheme.midnight,
    KaspireTheme.hub21,
    KaspireTheme.glacier,
    KaspireTheme.neptune
  ]) {
    testWidgets(
        'local recovery remains accessible despite empty Forge history in $theme',
        (tester) async {
      tester.view.physicalSize = const Size(320, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final journal = Journal(rows: [savedOrder()]);
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: KasForgeScreen(
              address: 'fixture', service: Source(), trading: journal)));
      await tester.pumpAndSettle();
      expect(find.text('Saved Forge order needs attention'), findsOneWidget);
      await tester.tap(find.text('My activity'));
      await tester.pumpAndSettle();
      expect(find.text('Saved orders on this device'), findsOneWidget);
      await tester.tap(find.text('Open saved order / recovery'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
          find.text('Cancel / recover unfilled order'), 180,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Cancel / recover unfilled order'), findsOneWidget);
      expect(journal.builds, 0);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('local journal error is visible and retry restores recovery',
      (tester) async {
    final journal = Journal(rows: [savedOrder()], failure: true);
    await tester.pumpWidget(MaterialApp(
        home: KasForgeScreen(
            address: 'fixture', service: Source(), trading: journal)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Saved Forge orders could not be loaded'),
        findsOneWidget);
    expect(find.text('No saved orders for this wallet on this device.'),
        findsNothing);
    journal.failure = false;
    await tester.tap(find.text('Retry saved orders'));
    await tester.pumpAndSettle();
    expect(find.text('Open saved order / recovery'), findsOneWidget);
  });
  testWidgets(
      'late local journal result is retained after ordinary UI deadlines',
      (tester) async {
    final gate = Completer<List<Map<String, dynamic>>>();
    await tester.pumpWidget(MaterialApp(
        home: KasForgeTradeScreen(
            address: 'fixture',
            token: token,
            service: Source(),
            trading: Journal(gate: gate))));
    await tester.pump(const Duration(seconds: 45));
    expect(find.text('Loading saved Forge orders…'), findsOneWidget);
    gate.complete([savedOrder()]);
    await tester.pumpAndSettle();
    expect(find.text('Open saved order / recovery'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'review opens the exact blocking saved order instead of building a second',
      (tester) async {
    final journal = Journal(rows: [savedOrder()]);
    await tester.pumpWidget(MaterialApp(
        home: KasForgeTradeScreen(
            address: 'fixture',
            token: token,
            service: Source(),
            trading: journal)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byType(TextField), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(find.byType(TextField), '10');
    await tester.scrollUntilVisible(find.text('Preview quote'), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Preview quote'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Review Forge order'), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Review Forge order'));
    await tester.pumpAndSettle();
    expect(
        find.text('Deposit confirmed · swap not registered'), findsOneWidget);
    expect(journal.builds, 0);
  });
  testWidgets('KasForge is absent from mainnet Swap selection', (tester) async {
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    await tester.pumpWidget(
        const MaterialApp(home: DexSelectionScreen(address: 'kaspa:qfixture')));
    await tester.pumpAndSettle();
    expect(find.text('KasForge'), findsNothing);
    expect(find.text('KaspaRocket'), findsOneWidget);
    expect(find.text('Kasseal DEX'), findsOneWidget);
    expect(find.text('Kron DEX'), findsOneWidget);
  });
}
