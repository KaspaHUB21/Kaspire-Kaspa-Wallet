import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kasvault_wallet/src/screens/kaspacom_market_screen.dart';
import 'package:kasvault_wallet/src/services/kaspacom_market_service.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';

const wallet =
    'kaspa:qqnvxvumjvzwmn755v8nrp4jxm2w50dv9mr2u4qrfqpq3h2hzyjx7tgkdtdgs';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final theme in KaspireTheme.values)
    testWidgets(
        'all 200 trait values remain scrollable and selectable ${theme.name} at 320px',
        (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({'watch_address_v1': wallet});
      NetworkSettings.network.value = KaspaNetwork.mainnet;
      final queries = <Map<String, String>>[],
          values = List.generate(200, (i) => 'Trait ${i + 1}');
      final service =
          KaspaComMarketService(wallet, client: MockClient((request) async {
        if (request.url.path.endsWith('/traits'))
          return http.Response(
              jsonEncode({
                'traitOptions': {'HEADWEAR': values}
              }),
              200);
        if (request.url.path.endsWith('/browse'))
          queries.add(request.url.queryParameters);
        return http.Response('{"orders":[],"totalCount":0,"items":[]}', 200);
      }));
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: KaspaComMarketScreen(
              address: wallet, service: service, initialTicker: 'JEETSLIFE')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Trait filters'));
      await tester.tap(find.text('Trait filters'));
      await tester.pumpAndSettle();
      expect(
          find.text(
              'Only traits on currently listed PSKT NFTs are shown. Unlisted NFTs and escrow listings are not included.'),
          findsOneWidget);
      final control = find.byWidgetPredicate(
          (w) => w is DropdownButton<String> && (w.items?.length ?? 0) > 100);
      expect(control, findsOneWidget);
      final widget = tester.widget<DropdownButton<String>>(control);
      expect(widget.items, hasLength(201));
      expect(widget.items!.last.value, 'Trait 200');
      await tester.ensureVisible(control);
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).first, const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(control.hitTestable(), findsOneWidget);
      await tester.tap(control);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Trait 200'), 300,
          scrollable: find.byType(Scrollable).last, maxScrolls: 60);
      await tester.tap(find.text('Trait 200').last);
      await tester.pumpAndSettle();
      expect(jsonDecode(queries.last['traits']!), {'HEADWEAR': 'Trait 200'});
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
}
