import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/screens/kasforge_order_screen.dart';
import 'package:kasvault_wallet/src/services/kasforge_trading.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';

class Trading extends KasForgeTrading {
  var signs = 0, submits = 0;
  bool failure = false;
  @override
  Future<void> sign(String address, Map<String, dynamic> receipt) async {
    signs++;
    receipt['signed'] = ['same bytes'];
  }

  @override
  Future<void> submit(String address, Map<String, dynamic> receipt) async {
    submits++;
    if (failure) throw StateError('Node unavailable; signed order retained.');
    receipt['state'] = 'deposited';
  }

  @override
  Future<Map<String, dynamic>> status(
      String address, Map<String, dynamic> receipt) async {
    receipt['finalVerified'] = true;
    receipt['state'] = 'filled';
    return {'status': 'filled'};
  }
}

Map<String, dynamic> receipt() => {
      'buildId': 'fixture',
      'side': 'buy',
      'symbol': 'VERY-LONG-FORGE-TICKER',
      'amount': '10',
      'minimumOut': '1234',
      'tokenId': 'a' * 64,
      'order': {
        'state': {'expiryDaa': 12345678},
        'address': 'kaspatest:p${'a' * 60}'
      },
      'transactionIds': ['b' * 64],
      'reviews': [
        {'feeSompi': 1000000}
      ],
      'state': 'prepared'
    };
void main() {
  for (final theme in [
    KaspireTheme.midnight,
    KaspireTheme.hub21,
    KaspireTheme.glacier,
    KaspireTheme.neptune
  ]) {
    testWidgets(
        'Forge order review, signed persistence and success navigation in $theme',
        (tester) async {
      tester.view.physicalSize = const Size(320, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final trading = Trading(), r = receipt();
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: KasForgeOrderScreen(
              address: 'fixture', receipt: r, trading: trading)));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
          find.text('Authorize and place order'), 180,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Authorize and place order'));
      await tester.pumpAndSettle();
      expect(trading.signs, 1);
      expect(trading.submits, 1);
      expect(find.text('Return to marketplace'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('failed submission leaves the saved same-byte resume controls',
      (tester) async {
    final trading = Trading()..failure = true, r = receipt();
    await tester.pumpWidget(MaterialApp(
        home: KasForgeOrderScreen(
            address: 'fixture', receipt: r, trading: trading)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Authorize and place order'), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Authorize and place order'));
    await tester.pumpAndSettle();
    expect(r['signed'], ['same bytes']);
    expect(find.text('Resume saved order'), findsOneWidget);
    expect(find.textContaining('Node unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
