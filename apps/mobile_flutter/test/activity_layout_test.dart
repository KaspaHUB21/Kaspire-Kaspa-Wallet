import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/models/wallet_snapshot.dart';
import 'package:kasvault_wallet/src/screens/wallet_screen.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';

void main() {
  for (final theme in KaspireTheme.values) {
    testWidgets('long covenant names stay inside narrow cards in $theme',
        (tester) async {
      tester.view.physicalSize = const Size(280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: MediaQuery(
              data: const MediaQueryData(
                  size: Size(280, 900), textScaler: TextScaler.linear(1.4)),
              child: Scaffold(
                  body: SingleChildScrollView(
                      child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(children: [
                            WalletAssetRow(
                                asset: const WalletAsset(
                                    symbol: 'KASPIREISTHEBESTKASPAWALLET',
                                    balance: 21000000,
                                    kind: 'KCC20'),
                                hideAmount: false,
                                onTap: () {}),
                            WalletActivityTile(
                                transaction: WalletTransaction(
                                    id: 'a' * 64,
                                    timestamp: DateTime.utc(2026),
                                    amountSompi: 0,
                                    incoming: true,
                                    assetKind: 'COVENANT',
                                    assetSymbol: 'WYRM',
                                    operationLabel:
                                        'Covenant Wyrm Incubation Started',
                                    amountLabelOverride:
                                        'Covenant Wyrm #100000000'),
                                walletAddress: 'kaspa:qtest',
                                hideAmounts: false),
                            WalletActivityTile(
                                transaction: WalletTransaction(
                                    id: 'b' * 64,
                                    timestamp: DateTime.utc(2026),
                                    amountSompi: 0,
                                    incoming: true,
                                    assetKind: 'KCC20',
                                    assetSymbol: 'KASPIREISTHEBESTKASPAWALLET',
                                    displayAmount: '21000000'),
                                walletAddress: 'kaspa:qtest',
                                hideAmounts: false),
                          ])))))));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
