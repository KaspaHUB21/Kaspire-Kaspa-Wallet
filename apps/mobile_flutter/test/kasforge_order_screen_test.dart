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

class PollingTrading extends Trading {
  int checks = 0;
  @override
  Future<Map<String, dynamic>> status(
      String address, Map<String, dynamic> receipt) async {
    checks++;
    if (checks < 3) {
      receipt['status'] = {
        'status': 'verification-pending',
        'message': 'Waiting for independent confirmation.'
      };
      return Map<String, dynamic>.from(receipt['status'] as Map);
    }
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
  testWidgets(
      'signed order verifies automatically through delayed acceptance without resubmitting',
      (tester) async {
    final r = receipt()
      ..['signed'] = ['saved bytes']
      ..['state'] = 'deposited';
    final trading = PollingTrading();
    await tester.pumpWidget(MaterialApp(
        home: KasForgeOrderScreen(
            address: 'fixture', receipt: r, trading: trading)));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(trading.checks, 1);
    expect(r['finalVerified'], isNot(true));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
    }
    expect(r['finalVerified'], isTrue);
    expect(trading.submits, 0);
    expect(trading.signs, 0);
    await tester.scrollUntilVisible(find.text('Return to marketplace'), 180,
        scrollable: find.byType(Scrollable).first);
    expect(
        find.textContaining(
            'Forge completion is not independently accepted yet'),
        findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
      'automatic order checks pause with app and resume without a new signature',
      (tester) async {
    final r = receipt()
      ..['signed'] = ['saved bytes']
      ..['state'] = 'deposited';
    final trading = PollingTrading();
    await tester.pumpWidget(MaterialApp(
        home: KasForgeOrderScreen(
            address: 'fixture', receipt: r, trading: trading)));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 30));
    expect(trading.checks, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(trading.checks, 2);
    expect(trading.signs, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('expired request offers recovery rather than an endless resume',
      (tester) async {
    final r = receipt()
      ..['signed'] = ['saved']
      ..['submissionError'] = 'This request expired, start again';
    await tester.pumpWidget(MaterialApp(
        home: KasForgeOrderScreen(
            address: 'fixture',
            receipt: r,
            trading: Trading(),
            autoCheck: false)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Recover expired request'), 180,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Resume saved order'), findsNothing);
    expect(find.text('Resubmit same saved order'), findsNothing);
    expect(find.text('Recover expired request'), findsOneWidget);
  });
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
              address: 'fixture',
              receipt: r,
              trading: trading,
              autoCheck: false)));
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
            address: 'fixture',
            receipt: r,
            trading: trading,
            autoCheck: false)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Authorize and place order'), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Authorize and place order'));
    await tester.pumpAndSettle();
    expect(r['signed'], ['same bytes']);
    await tester.scrollUntilVisible(find.text('Resume saved order'), 180,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Resume saved order'), findsOneWidget);
    expect(find.textContaining('Node unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final theme in [
    KaspireTheme.midnight,
    KaspireTheme.hub21,
    KaspireTheme.glacier,
    KaspireTheme.neptune
  ]) {
    testWidgets(
        'unregistered deposit and saved API error remain visible in $theme',
        (tester) async {
      tester.view.physicalSize = const Size(320, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final r = receipt()
        ..['signed'] = ['same saved bytes']
        ..['state'] = 'deposited-untracked'
        ..['submissionError'] = 'KasForge: build expired'
        ..['status'] = {
          'status': 'deposited-untracked',
          'message': 'Deposit remains unspent. This is not a completed trade.'
        };
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: KasForgeOrderScreen(
              address: 'fixture',
              receipt: r,
              trading: Trading(),
              autoCheck: false)));
      await tester.pumpAndSettle();
      expect(
          find.text('Deposit confirmed · swap not registered'), findsOneWidget);
      await tester.scrollUntilVisible(
          find.text('Last Forge submission error'), 180,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('KasForge: build expired'), findsOneWidget);
      expect(find.text('Return to marketplace'), findsNothing);
      await tester.scrollUntilVisible(
          find.text('Cancel / recover unfilled order'), 180,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Cancel / recover unfilled order'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
