import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/models/wallet_snapshot.dart';
import 'package:kasvault_wallet/src/screens/kasforge_screen.dart';
import 'package:kasvault_wallet/src/screens/kron_dex_screen.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/services/kasforge_service.dart';
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
              address: 'fixture', token: token, service: Source())));
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
            service: Source(failWallet: true))));
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
          home: KasForgeScreen(address: 'fixture', service: Source())));
      await tester.pumpAndSettle();
      expect(find.text(token.symbol), findsOneWidget);
      await tester.tap(find.text('My activity'));
      await tester.pumpAndSettle();
      expect(find.text('No open KasForge orders.'), findsOneWidget);
      expect(find.text('No KasForge activity.'), findsOneWidget);
    }
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
