import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/dex_display_price.dart';
import 'package:kasvault_wallet/src/widgets/dex_token_metrics.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';

void main() {
  final now = DateTime.utc(2026, 10, 30, 17);
  Map<String, Object?> explorer(Object? value, {DateTime? at}) => {
        'updated_at': (at ?? now).toIso8601String(),
        'data': {'price_usd': value}
      };
  http.Response response(Object data) => http.Response(jsonEncode(data), 200);

  test('fresh Kasseal quote is used once, coalesced and cached', () async {
    var calls = 0;
    final pending = Completer<http.Response>();
    final service = DexDisplayPrice(
        now: () => now,
        client: MockClient((r) {
          calls++;
          expect(r.url.toString(), 'https://app.kasseal.com/v1/price/kas');
          return pending.future;
        }));
    final a = service.kasUsd(kasseal: true), b = service.kasUsd(kasseal: true);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    pending.complete(response(
        {'usd': .04, 'asOfMs': now.millisecondsSinceEpoch, 'stale': false}));
    expect(await a, .04);
    expect(await b, .04);
    expect(await service.kasUsd(kasseal: true), .04);
    expect(calls, 1);
  });

  test(
      'stale Kasseal or failed SDK falls back to the explorer, Rocket uses explorer',
      () async {
    final urls = <String>[];
    final service = DexDisplayPrice(
        now: () => now,
        client: MockClient((r) async {
          urls.add(r.url.toString());
          return r.url.host == 'app.kasseal.com'
              ? response({
                  'usd': 99,
                  'asOfMs': now.millisecondsSinceEpoch,
                  'stale': true
                })
              : response(explorer(.032));
        }));
    expect(await service.kasUsd(kasseal: true), .032);
    expect(await service.kasUsd(kasseal: false), .032);
    expect(urls.length, 3);
    expect(urls.last, 'https://kaspatoken.kaslab.space/api/kaspa/stats');
    final failed = DexDisplayPrice(
        now: () => now,
        client: MockClient((r) async {
          if (r.url.host == 'app.kasseal.com') throw StateError('offline');
          return response(explorer(.05));
        }));
    expect(await failed.kasUsd(kasseal: true), .05);
  });

  test('expired cached rate is not retained after failed refresh', () async {
    var clock = now, failed = false;
    final service = DexDisplayPrice(
        now: () => clock,
        client: MockClient((_) async =>
            failed ? http.Response('{}', 503) : response(explorer(.04))));
    expect(await service.kasUsd(kasseal: false), .04);
    clock = now.add(const Duration(minutes: 3));
    failed = true;
    expect(await service.kasUsd(kasseal: false), isNull);
  });

  test('unknown, invalid, stale rates are not zero or USD quotes', () async {
    for (final value in [null, 0, -1, 'NaN', 'Infinity']) {
      final service = DexDisplayPrice(
          now: () => now,
          client: MockClient((_) async => response(explorer(value))));
      expect(await service.kasUsd(kasseal: false), isNull);
    }
    final stale = DexDisplayPrice(
        now: () => now,
        client: MockClient((_) async => response(
            explorer(.04, at: now.subtract(const Duration(hours: 1))))));
    expect(await stale.kasUsd(kasseal: false), isNull);
  });

  test(
      'Kasseal spot price uses whole-token supply, not lot or raw-unit scaling',
      () {
    final token = {
      'marketCapSompi': '76128931200000',
      'supply': {'total': '1200000000'},
      'curve': {'lotSize': '1000', 'nextLotPrice': '63440776'}
    };
    expect(DexDisplayPrice.kassealCapKas(token), 761289.312);
    expect(
        DexDisplayPrice.kassealPriceKas(token), closeTo(.00063440776, 1e-14));
    expect(DexDisplayPrice.kassealPriceKas({'marketCapSompi': '5'}), isNull);
    expect(
        DexDisplayPrice.kassealPriceKas({
          'marketCapSompi': '0',
          'supply': {'total': '100'}
        }),
        0);
    expect(
        DexDisplayPrice.kassealPriceKas({
          'marketCapSompi': '5',
          'supply': {'total': '0'}
        }),
        isNull);
  });

  testWidgets(
      'slow USD result arrives without blocking KAS metrics, missing is explicit',
      (tester) async {
    final rate = Completer<double?>();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: DexTokenMetrics(
                marketCapKas: 1000,
                priceKas: .00063440776,
                volume24hKas: 0,
                kasUsd: rate.future))));
    expect(find.text('Market cap: Unavailable'), findsOneWidget);
    expect(find.text('Price: 0.00063441 KAS / token'), findsOneWidget);
    expect(find.text('24h volume: 0 KAS'), findsOneWidget);
    await tester.pump(const Duration(seconds: 31));
    rate.complete(.04);
    await tester.pumpAndSettle();
    expect(find.text('Market cap: 40.00 USD'), findsOneWidget);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: DexTokenMetrics(
                marketCapKas: null,
                priceKas: null,
                volume24hKas: null,
                kasUsd: Future.value(null)))));
    await tester.pump();
    expect(find.text('Market cap: Unavailable'), findsOneWidget);
    expect(find.text('Price: Unavailable / token'), findsOneWidget);
    expect(find.text('24h volume: Unavailable'), findsOneWidget);
  });

  for (final theme in KaspireTheme.values) {
    testWidgets('three metrics wrap safely in a narrow $theme layout',
        (tester) async {
      tester.view.physicalSize = const Size(320, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: Scaffold(
              body: Card(
                  child: ListTile(
                      leading: const Icon(Icons.token),
                      title: const Text('KASPIREISTHEBESTKASPAWALLET'),
                      trailing: const Icon(Icons.chevron_right),
                      subtitle: DexTokenMetrics(
                          marketCapKas: 987654321.123,
                          priceKas: .012345678,
                          volume24hKas: 123456.789,
                          kasUsd: Future.value(.04)))))));
      await tester.pumpAndSettle();
      expect(find.textContaining('USD'), findsOneWidget);
      expect(
          find.textContaining('24h volume: 123,456.789 KAS'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
