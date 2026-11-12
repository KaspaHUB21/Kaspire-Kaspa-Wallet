import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/models/wallet_snapshot.dart';
import 'package:kasvault_wallet/src/screens/krc20_token_detail_screen.dart';
import 'package:kasvault_wallet/src/screens/wallet_screen.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';
import 'package:kasvault_wallet/src/theme.dart';
import 'package:kasvault_wallet/src/widgets/krc20_locked_balance.dart';

const address =
    'kaspa:qp0mtdvzscrkfft702j85s8yzdl8a87n5d6pgtm8vrxg6hqu0wywzvwkevdk3';
const souls = WalletAsset(
    symbol: 'SOULS',
    id: 'krc20-souls',
    balance: 5356.78883154,
    rawBalance: '535678883154',
    rawLockedBalance: '200000000000',
    decimals: 8,
    kind: 'KRC-20');

class DetailApi extends KaspaApi {
  final market = Completer<WalletAsset>();
  @override
  Future<double> loadSelectedFiatRate() async => 1;
  @override
  Future<WalletAsset> loadTokenMarket(WalletAsset asset) => market.future;
}

void main() {
  test(
      'one holdings request returns available and PSKT-locked amounts separately',
      () async {
    final requests = <Uri>[];
    final api = KaspaApi(client: MockClient((r) async {
      requests.add(r.url);
      return http.Response(
          jsonEncode({
            'result': [
              {
                'tick': 'SOULS',
                'balance': '535678883154',
                'locked': '200000000000',
                'dec': '8'
              },
              {
                'tick': 'ONLYLOCKED',
                'balance': '0',
                'locked': '123456789012345678901',
                'dec': '8'
              },
              {'tick': 'EMPTY', 'balance': '0', 'locked': '0', 'dec': '8'},
              {'tick': 'MISSING', 'locked': '100', 'dec': '8'},
            ]
          }),
          200);
    }));
    final rows = await api.loadKrc20Holdings(address);
    expect(requests, hasLength(1));
    expect(requests.single.host, 'api.kasplex.org');
    expect(rows.map((a) => a.symbol), ['ONLYLOCKED', 'SOULS']);
    expect(rows.first.balance, 0);
    expect(rows.first.rawBalance, '0');
    expect(rows.first.rawLockedBalance, '123456789012345678901');
    expect(rows.last.balance, 5356.78883154);
    expect(rows.last.rawBalance, '535678883154');
    expect(rows.last.rawLockedBalance, '200000000000');
  });

  test(
      'mirror, cursor pages, duplicate rows and refresh keep current locked data',
      () async {
    var refresh = false;
    final requests = <Uri>[];
    final api = KaspaApi(client: MockClient((r) async {
      requests.add(r.url);
      if (r.url.host == 'api.kasplex.org') return http.Response('{}', 503);
      if (refresh) {
        return http.Response(
            '{"result":[{"tick":"SOULS","balance":"735678883154","locked":"0","dec":8}]}',
            200);
      }
      if (r.url.queryParameters['next'] == 'page2') {
        return http.Response(
            '{"result":[{"tick":"SOULS","balance":"1","locked":"200000000000","dec":8},{"tick":"OTHER","balance":"0","locked":"1","dec":0}]}',
            200);
      }
      return http.Response(
          '{"next":"page2","result":[{"tick":"SOULS","balance":"1","locked":"200000000000","dec":8}]}',
          200);
    }));
    final rows = await api.loadKrc20Holdings(address);
    expect(rows, hasLength(2));
    expect(rows.last.rawLockedBalance, '200000000000'); // Not summed twice.
    expect(requests, hasLength(3));
    expect(
        requests
            .skip(1)
            .every((r) => r.path.startsWith('/api/krc20-fallback/')),
        isTrue);
    refresh = true;
    final next = await api.loadKrc20Holdings(address);
    expect(next.single.rawLockedBalance, '0');
    expect(next.single.rawBalance, '735678883154');
    expect(
        requests, hasLength(5)); // No marketplace or per-token listing calls.
  });

  test(
      'missing or malformed locked values do not invent holdings or lose available tokens',
      () async {
    for (final invalid in [
      null,
      '-1',
      '1.5',
      'NaN',
      '1e8',
      '9' * 129,
      {},
      []
    ]) {
      final api = KaspaApi(
          client: MockClient((_) async => http.Response(
              jsonEncode({
                'result': [
                  {
                    'tick': 'AVAILABLE',
                    'balance': '12',
                    'dec': 0,
                    if (invalid != null) 'locked': invalid
                  },
                  {
                    'tick': 'EMPTY',
                    'balance': '0',
                    'dec': 0,
                    if (invalid != null) 'locked': invalid
                  },
                ]
              }),
              200)));
      final rows = await api.loadKrc20Holdings(address);
      expect(rows.single.symbol, 'AVAILABLE');
      expect(rows.single.balance, 12);
      expect(rows.single.rawLockedBalance, isNull);
    }
  });

  test(
      'market enrichment retains locked units without adding them to balance or value',
      () async {
    final api = KaspaApi(client: MockClient((r) async {
      if (r.url.path == '/api/floor-price') {
        return http.Response(
            '{"data":[{"ticker":"SOULS","floor_price":2}]}', 200);
      }
      if (r.url.path == '/info/price') {
        return http.Response('{"price":0.1}', 200);
      }
      return http.Response('{}', 200);
    }));
    final row = await api.loadTokenMarket(souls);
    expect(row.rawLockedBalance, souls.rawLockedBalance);
    expect(row.rawBalance, souls.rawBalance);
    expect(row.balance, souls.balance);
    expect(row.priceKas, 2);
  });

  test('progressive and final wallet snapshots both retain fully locked tokens',
      () async {
    final progress = <WalletSnapshot>[];
    final api = KaspaApi(client: MockClient((r) async {
      if (r.url.path.endsWith('/tokenlist')) {
        return http.Response(
            '{"result":[{"tick":"LOCKED","balance":"0","locked":"2100000000","dec":8}]}',
            200);
      }
      if (r.url.path.endsWith('/balance')) {
        return http.Response('{"balance":0}', 200);
      }
      if (r.url.path.endsWith('/utxos')) return http.Response('[]', 200);
      return http.Response('{}', 503);
    }));
    final snapshot = await api.loadWallet(address,
        includeNativeTransactions: false,
        includeAssetHistory: false,
        includeMarketData: false,
        onProgress: progress.add);
    expect(snapshot.krc20Tokens.single.symbol, 'LOCKED');
    expect(snapshot.krc20Tokens.single.balance, 0);
    expect(snapshot.krc20Tokens.single.rawLockedBalance, '2100000000');
    expect(
        progress.any((p) =>
            p.krc20Tokens.any((a) => a.rawLockedBalance == '2100000000')),
        isTrue);
  });

  for (final theme in KaspireTheme.values) {
    testWidgets('locked amount fits wallet rows and detail in $theme',
        (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: const Scaffold(
              body: WalletAssetRow(asset: souls, hideAmount: false))));
      expect(find.text('5,356.78883154'), findsOneWidget);
      expect(find.text('+2,000 SOULS locked'), findsOneWidget);
      expect(find.textContaining('KaspaCom'), findsNothing);
      expect(tester.takeException(), isNull);
      final api = DetailApi();
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: Krc20TokenDetailScreen(
              asset: souls,
              api: api,
              usdToFiat: 1,
              fiatCode: 'USD',
              fiatSymbol: r'$',
              onSend: () {})));
      await tester.pump();
      expect(find.text('+2,000 SOULS locked'), findsOneWidget);
      api.market.complete(souls);
      await tester.pumpAndSettle();
      expect(find.text('5,356.78883154 SOULS'), findsOneWidget);
      expect(find.text('+2,000 SOULS locked'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
      'privacy hides locked quantities; zero, absent and other protocols stay unchanged',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: Column(children: [
      WalletAssetRow(asset: souls, hideAmount: true),
      Krc20LockedBalance(
          asset: WalletAsset(
              symbol: 'OTHER',
              balance: 1,
              kind: 'KCC20',
              rawLockedBalance: '1')),
      Krc20LockedBalance(
          asset: WalletAsset(
              symbol: 'ZERO',
              balance: 1,
              kind: 'KRC-20',
              rawLockedBalance: '0')),
      Krc20LockedBalance(
          asset: WalletAsset(symbol: 'ABSENT', balance: 1, kind: 'KRC-20')),
    ]))));
    expect(find.text('•••••• locked'), findsOneWidget);
    expect(find.textContaining('2,000'), findsNothing);
    expect(find.textContaining('OTHER locked'), findsNothing);
    expect(find.textContaining('ZERO locked'), findsNothing);
    expect(find.textContaining('ABSENT locked'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
