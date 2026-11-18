import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kasvault_wallet/src/screens/kaspacom_market_screen.dart';
import 'package:kasvault_wallet/src/services/kaspacom_market_service.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';
import 'package:kasvault_wallet/src/widgets/krc20_order_card.dart';

const wallet = 'kaspa:qqnvxvumjvzwmn755v8nrp4jxm2w50dv9mr2u4qrfqpq3h2hzyjx7tgkdtdgs';

Future<void> chooseSort(WidgetTester tester, String from, String label) async {
  final control = find.byKey(ValueKey('sort-krc20-$from'));
  await tester.ensureVisible(control);
  await tester.pumpAndSettle();
  await tester.tap(control);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({'watch_address_v1': wallet});
    NetworkSettings.network.value = KaspaNetwork.mainnet;
  });

  for (final theme in KaspireTheme.values) {
    testWidgets('KRC20 sort matches PWA in ${theme.name} at 320px', (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final queries = <Map<String, String>>[];
      final service = KaspaComMarketService(wallet, client: MockClient((r) async {
        if (r.url.path.endsWith('/browse')) queries.add(r.url.queryParameters);
        return http.Response('{"orders":[],"items":[],"totalCount":0,"floorPrice":0.9}', 200);
      }));
      await tester.pumpWidget(MaterialApp(
        theme: KasVaultTheme.forTheme(theme),
        home: KaspaComMarketScreen(address: wallet, service: service),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('KRC-20'));
      await tester.pumpAndSettle();
      final search = find.byType(TextField);
      await tester.ensureVisible(search);
      await tester.enterText(search, 'KASBTC');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(queries.last['sort'], 'low');
      expect(queries.last['offset'], '0');
      expect(queries.last['search'], 'KASBTC');
      await chooseSort(tester, 'low', 'Most recent listings');
      expect(queries.last['sort'], 'recent');
      expect(queries.last['offset'], '0');
      await chooseSort(tester, 'recent', 'Price: High to Low');
      expect(queries.last['sort'], 'high');
      await chooseSort(tester, 'high', 'Price: Low to High');
      expect(queries.last['sort'], 'low');
      expect(find.text('Rank (asc)'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  test('KRC20 sends selected sort on every page and refresh starts at zero', () async {
    final queries = <Map<String, String>>[];
    final service = KaspaComMarketService(wallet, client: MockClient((r) async {
      queries.add(r.url.queryParameters);
      final offset = int.parse(r.url.queryParameters['offset']!);
      return http.Response(jsonEncode({
        'orders': List.generate(10, (i) => {'orderId': '${offset + i}', 'status': 'LISTED_FOR_SALE'}),
        'totalCount': 30,
      }), 200);
    }));
    for (final sort in ['recent', 'low', 'high']) {
      final first = await service.browse('krc20', 'KASBTC', sort, 0);
      expect(first['nextOffset'], 10);
      await service.browse('krc20', 'KASBTC', sort, 10);
      await service.browse('krc20', 'KASBTC', sort, 0);
      expect(queries.sublist(queries.length - 3).map((q) => q['sort']), [sort, sort, sort]);
      expect(queries.sublist(queries.length - 3).map((q) => q['offset']), ['0', '10', '0']);
    }
    service.close();
  });

  testWidgets('changing KRC20 sort ignores late results from previous sort', (tester) async {
    final stale = Completer<http.Response>();
    var holdRecent = false;
    final service = KaspaComMarketService(wallet, client: MockClient((r) async {
      if (holdRecent && r.url.path.endsWith('/browse') && r.url.queryParameters['sort'] == 'recent') {
        return stale.future;
      }
      if (r.url.path.endsWith('/browse') && r.url.queryParameters['sort'] == 'high') {
        return http.Response('{"orders":[{"orderId":"current","quantity":2,"totalPrice":4,"pricePerToken":2,"ticker":"KASBTC"}],"totalCount":1}', 200);
      }
      return http.Response('{"orders":[],"items":[],"totalCount":0}', 200);
    }));
    await tester.pumpWidget(MaterialApp(home: KaspaComMarketScreen(address: wallet, service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('KRC-20'));
    await tester.pumpAndSettle();
    holdRecent = true;
    await tester.enterText(find.byType(TextField), 'KASBTC');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final initial = find.byKey(const ValueKey('sort-krc20-low'));
    await tester.ensureVisible(initial);
    await tester.pumpAndSettle();
    await tester.tap(initial);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Most recent listings').last);
    await tester.pump();
    final control = find.byKey(const ValueKey('sort-krc20-recent'));
    await tester.ensureVisible(control);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(control);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Price: High to Low').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sort-krc20-high')), findsOneWidget);
    expect(tester.widgetList<Krc20OrderCard>(find.byType(Krc20OrderCard)).map((r) => r.quantity), ['2']);
    stale.complete(http.Response('{"orders":[{"orderId":"stale","quantity":99,"totalPrice":99,"pricePerToken":1,"ticker":"KASBTC"}],"totalCount":1}', 200));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sort-krc20-high')), findsOneWidget);
    expect(tester.widgetList<Krc20OrderCard>(find.byType(Krc20OrderCard)).map((r) => r.quantity), ['2']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
