import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/kaspa_address.dart';
import 'package:kasvault_wallet/src/screens/trestly_swap_screen.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/services/native_security.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/services/trestly_service.dart';
import 'package:kasvault_wallet/src/theme.dart';

const ownerAddress =
    'kaspa:qqre4wt08dp0rvmxwqgwdkz4zu4m36g9uvmfledd27mx939uxe2yjpmmd37zq';
TrestlySellBalance viewBalance(List<int> amounts, {bool complete = true}) =>
    TrestlySellBalance(
        cells: amounts
            .map((n) => <String, Object?>{
                  'state': {'amount': '$n'}
                })
            .toList(),
        complete: complete);

class BalanceNative extends NativeSecurity {
  @override
  Future<Map<String, Object?>> describeTrestly(
          Map<String, Object?> request) async =>
      {
        'profile': 'trestly-mainnet-v2',
        'payerAddress': 'kaspa:fixture',
        'payerScript': '000051'
      };
}

TrestlyService reader(List<int> amounts,
    {bool stale = false,
    bool truncated = false,
    bool unread = false,
    Set<int> missing = const {},
    bool fail = false,
    bool wrongOwner = false,
    bool duplicate = false}) {
  final rows = amounts
      .asMap()
      .entries
      .map((e) => <String, Object?>{
            'utxo': {
              'transactionId': (e.key + 1).toRadixString(16).padLeft(64, '0'),
              'index': 0
            },
            'state': {
              'amount': '${e.value}',
              'owner': wrongOwner
                  ? '00' * 32
                  : kaspaOwnerIdFromAddress(ownerAddress),
              'ownerScheme': 0,
              'borrowScheme': 0,
              'extensionCommitment': '00' * 32
            }
          })
      .toList();
  return TrestlyService(ownerAddress, security: BalanceNative(),
      client: MockClient((r) async {
    expect(r.method, 'GET');
    if (fail) return http.Response('{}', 503);
    if (r.url.path.endsWith('/status'))
      return http.Response(
          jsonEncode({
            'network': 'mainnet',
            'kaspa': {
              'covenantId': TrestlyService.tokenId,
              'poolId': TrestlyService.poolId
            }
          }),
          200);
    if (r.url.path.endsWith('/tokens'))
      return http.Response(
          jsonEncode({
            'states': [...rows, if (duplicate && rows.isNotEmpty) rows.first],
            'stale': stale,
            'truncated': truncated,
            'unread': unread ? [{}] : []
          }),
          200);
    if (r.url.path.endsWith('/pool'))
      return http.Response('{"pool":{"state":{"fixture":true}}}', 200);
    if (r.url.path.endsWith('/utxos'))
      return http.Response(
          jsonEncode(rows
              .asMap()
              .entries
              .where((e) => !missing.contains(e.key))
              .map((e) => {
                    'outpoint': e.value['utxo'],
                    'utxoEntry': {
                      'amount': 150000000,
                      'scriptPublicKey': {
                        'version': 0,
                        'scriptPublicKey': '51'
                      },
                      'blockDaaScore': 1000,
                      'isCoinbase': false,
                      'covenantId': TrestlyService.tokenId
                    }
                  })
              .toList()),
          200);
    throw StateError('Unexpected request ${r.url}');
  }));
}

class BalanceDemo extends TrestlyService {
  BalanceDemo(this.read) : super(ownerAddress);
  Future<TrestlySellBalance> Function() read;
  String? quotedAmount;
  @override
  Future<TrestlyRow?> pending() async => null;
  @override
  Future<TrestlySellBalance> sellBalance({TrestlyRow? poolState}) => read();
  @override
  Future<TrestlyRow> quote(String side, String amount) async {
    quotedAmount = amount;
    return {
      'review': {
        'amountIn': '${parseTrestlyAmount(amount, 6)}',
        'amountOut': '100000000',
        'maxFeeSompi': '30000000'
      },
      'request': <String, Object?>{}
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => NetworkSettings.network.value = KaspaNetwork.mainnet);
  tearDown(() => AppSettings.theme.value = KaspireTheme.midnight);
  test('verified total and single-cell maximum retain all six decimal places',
      () async {
    final b = await reader([12345678, 20000001]).sellBalance();
    expect(b.complete, true);
    expect(b.verifiedRaw, BigInt.from(32345679));
    expect(b.maximumRaw, BigInt.from(20000001));
    expect(b.maximumAmount, '20.000001');
    expect(viewBalance([1]).maximumAmount, '0.000001');
    expect(viewBalance([1000000]).maximumAmount, '1');
  });
  test(
      'empty complete response is genuine zero, failures and partial snapshots are not',
      () async {
    final zero = await reader([]).sellBalance();
    expect(zero.complete, true);
    expect(zero.verifiedRaw, BigInt.zero);
    for (final service in [
      reader([], stale: true),
      reader([], truncated: true),
      reader([], unread: true),
      reader([1000000], missing: {0}),
      reader([1000000], wrongOwner: true)
    ]) {
      final b = await service.sellBalance();
      expect(b.complete, false);
    }
    await expectLater(reader([], fail: true).sellBalance(), throwsStateError);
  });
  test(
      'failed coins retain a verified lower bound; duplicates cannot inflate the balance',
      () async {
    final b = await reader([1000001, 2000002], missing: {1}).sellBalance();
    expect(b.complete, false);
    expect(b.verifiedRaw, BigInt.from(1000001));
    final duplicate = await reader([1000001], duplicate: true).sellBalance();
    expect(duplicate.complete, false);
    expect(duplicate.verifiedRaw, BigInt.from(1000001));
  });
  testWidgets(
      'sell balance and MAX match the send layout across every theme and widths',
      (tester) async {
    for (final theme in KaspireTheme.values) {
      AppSettings.theme.value = theme;
      for (final width in [320.0, 768.0]) {
        final demo = BalanceDemo(() async => viewBalance([12345678]));
        await tester.binding.setSurfaceSize(Size(width, 900));
        await tester.pumpWidget(MaterialApp(
            theme: KasVaultTheme.forTheme(theme),
            home: TrestlySwapScreen(
                key: ValueKey('$theme-$width'),
                address: ownerAddress,
                service: demo)));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sell kUSDT'));
        await tester.pumpAndSettle();
        expect(find.text('Available:'), findsOneWidget);
        expect(find.text('12.345678 kUSDT'), findsOneWidget);
        await tester.tap(find.text('MAX'));
        await tester.pump();
        expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            '12.345678');
        await tester.tap(find.text('Get live quote'));
        await tester.pumpAndSettle();
        expect(demo.quotedAmount, '12.345678');
        expect(
            find.textContaining(
                'Pool and bridge have not been independently audited'),
            findsNothing);
        expect(tester.takeException(), isNull);
      }
    }
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('fragmented balance displays both total and executable maximum',
      (tester) async {
    final demo = BalanceDemo(() async => viewBalance([12345678, 20000001]));
    await tester.pumpWidget(MaterialApp(
        home: TrestlySwapScreen(address: ownerAddress, service: demo)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sell kUSDT'));
    await tester.pumpAndSettle();
    expect(find.text('32.345679 kUSDT'), findsOneWidget);
    expect(
        find.textContaining('MAX per swap: 20.000001 kUSDT'), findsOneWidget);
    await tester.tap(find.text('MAX'));
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '20.000001');
  });
  testWidgets(
      'late old reads cannot overwrite a new balance after reopening sell',
      (tester) async {
    final first = Completer<TrestlySellBalance>(),
        second = Completer<TrestlySellBalance>();
    var calls = 0;
    final demo = BalanceDemo(() => ++calls == 1 ? first.future : second.future);
    await tester.pumpWidget(MaterialApp(
        home: TrestlySwapScreen(address: ownerAddress, service: demo)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sell kUSDT'));
    await tester.pump();
    expect(find.text('Loading…'), findsOneWidget);
    expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'MAX'))
            .onPressed,
        isNull);
    await tester.tap(find.text('Buy kUSDT'));
    await tester.pump();
    await tester.tap(find.text('Sell kUSDT'));
    await tester.pump();
    second.complete(viewBalance([2000001]));
    await tester.pumpAndSettle();
    first.complete(viewBalance([99000000]));
    await tester.pumpAndSettle();
    expect(find.text('2.000001 kUSDT'), findsOneWidget);
    expect(find.text('99 kUSDT'), findsNothing);
  });
  testWidgets(
      'partial and unavailable states disable MAX; refresh recovers without a false zero',
      (tester) async {
    final demo = BalanceDemo(() async => viewBalance([], complete: false));
    await tester.pumpWidget(MaterialApp(
        home: TrestlySwapScreen(address: ownerAddress, service: demo)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sell kUSDT'));
    await tester.pumpAndSettle();
    expect(find.text('Unavailable'), findsOneWidget);
    expect(find.text('0 kUSDT'), findsNothing);
    expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'MAX'))
            .onPressed,
        isNull);
    demo.read = () async => throw StateError('Balance source offline');
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('Balance source offline'), findsOneWidget);
    expect(find.text('0 kUSDT'), findsNothing);
    demo.read = () async => viewBalance([5000001]);
    await tester.tap(find.text('Retry balance'));
    await tester.pumpAndSettle();
    expect(find.text('5.000001 kUSDT'), findsOneWidget);
    await tester.tap(find.text('MAX'));
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '5.000001');
  });
}
