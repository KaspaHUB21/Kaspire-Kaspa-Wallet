import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/screens/braid_screen.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/services/braid_service.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';

class Source extends BraidService {
  Source({this.failure = false, this.slow, this.rows = const []});
  final List<Map<String, dynamic>> rows;
  final bool failure;
  final Completer<Map<String, dynamic>>? slow;
  @override
  void guard(String address) {}
  @override
  Future<List<Map<String, dynamic>>> saved(String address) async => rows;
  @override
  Future<Map<String, dynamic>?> pending(String address) async => null;
  @override
  Future<Map<String, dynamic>> notes(String address, BraidToken token) async {
    if (slow != null) return slow!.future;
    if (failure) throw StateError('Token source unavailable');
    return {
      'notes': [
        {'amount': '12345'}
      ]
    };
  }

  @override
  Future<Map<String, dynamic>> quote(String address, BraidToken from,
          BraidToken to, String amount, int slippage) async =>
      {
        'amountOut': '2105645645',
        'localFloor': '2084589198',
        'txs': [
          {
            'legs': [
              {'venue': 'kr', 'tick': 'ICE', 'side': 'buy'}
            ]
          }
        ],
        'walletFee': {'amount': '0', 'reason': 'fixture fee waiver'}
      };
}

Future<void> selectFrom(WidgetTester tester, BraidToken token) async {
  await tester.tap(find.byKey(const Key('braid-select-from')));
  await tester.pumpAndSettle();
  await tester.enterText(
      find.byKey(const Key('braid-token-search')), token.symbol);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('braid-token-${token.id}')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => NetworkSettings.network.value = KaspaNetwork.tn10);
  test('router buy/sell legs, multi-venue routes and legacy receipts', () {
    expect(braidRouteLabel({'venue': 'kr', 'tick': 'THEN', 'side': 'buy'}),
        'KaspaRocket: KAS → THEN');
    expect(braidRouteLabel({'venue': 'kr', 'tick': 'GUZA', 'side': 'sell'}),
        'KaspaRocket: GUZA → KAS');
    expect(braidRouteLabel({'venue': 'kron', 'tick': 'KRON', 'side': 'buy'}),
        'KRON: KAS → KRON');
    expect(
        [
          {'venue': 'kr', 'tick': 'THEN', 'side': 'sell'},
          {'venue': 'kron', 'tick': 'PEPE', 'side': 'buy'},
        ].map(braidRouteLabel),
        ['KaspaRocket: THEN → KAS', 'KRON: KAS → PEPE']);
    expect(braidRouteLabel({'venue': 'kr', 'from': 'KAS', 'to': 'ICE'}),
        'KaspaRocket: KAS → ICE');
    expect(braidRouteLabel({'venue': 'kr', 'from': null, 'to': 'null'}),
        'KaspaRocket: Route details unavailable');
    expect(braidRouteLabel({'venue': 'kr', 'side': 'buy', 'tick': null}),
        'KaspaRocket: KAS → Token');
    expect(braidRouteLabel({}), 'Swap route: Route details unavailable');
  });
  testWidgets(
      'activity taps open the selected swap details rather than changing an invisible tab',
      (tester) async {
    final row = <String, dynamic>{
      'from': 'KAS',
      'to': 'ICE',
      'signed': {'0': 'fixture'},
      'state': 'done',
      'verifiedFinal': true,
      'transactionId': 'a' * 64,
      'quote': {
        'localAmount': '3000000000',
        'localFloor': '12345',
        'txs': [
          {
            'legs': [
              {'venue': 'kr', 'tick': 'ICE', 'side': 'buy'}
            ]
          }
        ]
      }
    };
    await tester.pumpWidget(MaterialApp(
        home: BraidScreen(address: 'fixture', service: Source(rows: [row]))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My activity'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('KAS → ICE'));
    await tester.pumpAndSettle();
    expect(find.text('Swap finished'), findsOneWidget);
    expect(find.text('You paid'), findsOneWidget);
    expect(find.text('30 KAS'), findsOneWidget);
    expect(find.text('12,345 ICE base units'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('KaspaRocket: KAS → ICE'), 120,
        scrollable: find
            .descendant(
                of: find.byType(ListView).first,
                matching: find.byType(Scrollable))
            .first);
    expect(find.text('KaspaRocket: KAS → ICE'), findsOneWidget);
    expect(find.textContaining('null → null'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  for (final theme in [
    KaspireTheme.midnight,
    KaspireTheme.hub21,
    KaspireTheme.glacier,
    KaspireTheme.neptune
  ]) {
    testWidgets(
        'Braid narrow layout, quote invalidation and sell presets in $theme',
        (tester) async {
      tester.view.physicalSize = const Size(320, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: BraidScreen(address: 'fixture', service: Source())));
      await tester.pumpAndSettle();
      await selectFrom(tester, BraidService.tokens[2]);
      expect(find.textContaining('12,345 FIRE'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('MAX'), 150,
          scrollable: find.byType(Scrollable).first);
      for (final (label, value) in [
        ('25%', '3086'),
        ('50%', '6172'),
        ('75%', '9258'),
        ('MAX', '12345')
      ]) {
        await tester.tap(find.text(label));
        await tester.pump();
        expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            value);
      }
      await tester.scrollUntilVisible(find.text('Refresh quote'), 120,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Refresh quote'));
      await tester.pumpAndSettle();
      expect(find.text('Estimated received'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('KaspaRocket: KAS → ICE'), 120,
          scrollable: find
              .descendant(
                  of: find.byType(ListView).first,
                  matching: find.byType(Scrollable))
              .first);
      expect(find.text('KaspaRocket: KAS → ICE'), findsOneWidget);
      expect(find.textContaining('null → null'), findsNothing);
      await tester.enterText(find.byType(TextField), '100');
      await tester.pump();
      expect(find.text('Estimated received'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('failed token balance remains unknown, never zero',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: BraidScreen(address: 'fixture', service: Source(failure: true))));
    await tester.pumpAndSettle();
    await selectFrom(tester, BraidService.tokens[2]);
    expect(find.text('Token source unavailable'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.text('Token balance unavailable / loading'), 120,
        scrollable: find
            .descendant(
                of: find.byType(ListView).first,
                matching: find.byType(Scrollable))
            .first);
    expect(find.text('Token balance unavailable / loading'), findsOneWidget);
    expect(find.textContaining('Token balance: 0'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  for (final theme in KaspireTheme.values) {
    testWidgets('Mainnet decimal amounts and narrow themed selectors: $theme',
        (tester) async {
      NetworkSettings.network.value = KaspaNetwork.mainnet;
      tester.view.physicalSize = const Size(320, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: BraidScreen(address: 'fixture', service: Source())));
      await tester.pumpAndSettle();
      await selectFrom(tester, BraidService.tokens[1]);
      expect(find.textContaining('12.345 THEN'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('MAX'), 150,
          scrollable: find.byType(Scrollable).first);
      for (final (label, value) in [
        ('25%', '3.086'),
        ('50%', '6.172'),
        ('75%', '9.258'),
        ('MAX', '12.345')
      ]) {
        await tester.tap(find.text(label));
        await tester.pump();
        expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            value);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('late balance cannot overwrite a subsequently selected asset',
      (tester) async {
    final slow = Completer<Map<String, dynamic>>();
    await tester.pumpWidget(MaterialApp(
        home: BraidScreen(address: 'fixture', service: Source(slow: slow))));
    await tester.pumpAndSettle();
    await selectFrom(tester, BraidService.tokens[2]);
    await selectFrom(tester, BraidService.tokens.first);
    slow.complete({
      'notes': [
        {'amount': '99999999'}
      ]
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('99,999,999'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('both selectors search ticker or covenant and copy the full ID',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(
        MaterialApp(home: BraidScreen(address: 'fixture', service: Source())));
    await tester.pumpAndSettle();
    for (final side in ['from', 'to']) {
      final token = BraidService.tokens[2];
      await tester.tap(find.byKey(Key('braid-select-$side')));
      await tester.pumpAndSettle();
      final search = find.byKey(const Key('braid-token-search'));
      await tester.enterText(search, 'not-a-token');
      await tester.pump();
      expect(find.text('No matching tokens.'), findsOneWidget);
      await tester.enterText(search, token.id.toUpperCase());
      await tester.pump();
      expect(find.byKey(Key('braid-token-${token.id}')), findsOneWidget);
      expect(find.byKey(Key('braid-token-${BraidService.tokens[1].id}')),
          findsNothing);
      await tester.tap(find.byKey(Key('braid-token-${token.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('braid-copy-$side')));
      await tester.pump();
      expect(copied, token.id);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
