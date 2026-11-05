import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/screens/kforge_screen.dart';
import 'package:kasvault_wallet/src/screens/kforge_result_screen.dart';
import 'package:kasvault_wallet/src/services/kforge_service.dart';
import 'package:kasvault_wallet/src/services/kforge_trading.dart';
import 'package:kasvault_wallet/src/services/native_security.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';
import 'package:kasvault_wallet/src/widgets/kforge_image.dart';
import 'kforge_service_test.dart' show kforgeAddress, kforgeClient, kforgeToken;

Map<String, dynamic> tradeReceipt(String side, {String state = 'confirmed'}) =>
    {
      'address': kforgeAddress,
      'network': 'testnet-10',
      'id': 'e' * 64,
      'tokenId': 'a' * 64,
      'symbol': 'SAME',
      'side': side,
      'state': state,
      'createdAt': 1793732400000,
      'signed': <String, dynamic>{},
      'request': {
        'lpCovenantId': 'f' * 64,
        'tradeSummary': {
          'market': {'image': 'coin.png'}
        }
      },
      'verified': {
        'tokens': side == 'buy' ? '226' : '10000',
        'walletNet': side == 'buy' ? '1130000000' : '43544953186',
        'marketKas': side == 'buy' ? '1000000000' : '43574953186',
        'networkFee': '30000000',
        'protocolFee': side == 'buy' ? '10000000' : '440151042',
        'cellReserveChange': side == 'buy' ? 90000000 : 0,
        'venue': 'pool'
      }
    };

class ScreenSecurity extends NativeSecurity {
  @override
  Future<bool> authenticate(BuildContext context, String reason) async => true;
}

class ScreenTrading extends KForgeTrading {
  ScreenTrading({this.rows = const [], this.outcome = 'confirmed'})
      : super(security: ScreenSecurity());
  final List<Map<String, dynamic>> rows;
  final String outcome;
  Map<String, dynamic>? last;
  int signed = 0, resumed = 0;
  @override
  Future<List<Map<String, dynamic>>> saved(String a) async =>
      [...rows, if (last != null) last!];
  @override
  Future<Map<String, dynamic>?> pending(String a) async =>
      last?['state'] == 'pending' ? last : null;
  @override
  Future<Map<String, dynamic>> quote(
          String a, KForgeToken t, String side, BigInt amount) async =>
      {
        'at': DateTime.now().millisecondsSinceEpoch,
        'symbol': t.symbol,
        'side': side,
        'tokenId': t.id,
        'review': {
          'tradeSummary': {'verified': tradeReceipt(side)['verified']}
        }
      };
  @override
  Future<Map<String, dynamic>> sign(String a, Map p) async {
    signed++;
    return last = tradeReceipt(p['side'] as String, state: 'pending');
  }

  @override
  Future<Map<String, dynamic>> resume(String a, Map<String, dynamic> r,
      {bool submit = true}) async {
    resumed++;
    return last = {...r, 'state': outcome};
  }
}

Future<void> scroll(WidgetTester tester, String text, String list,
    {double delta = 240}) async {
  await tester.scrollUntilVisible(find.text(text), delta,
      scrollable: find
          .descendant(
              of: find.byKey(Key(list)), matching: find.byType(Scrollable))
          .first);
  await tester.pumpAndSettle();
}

void smallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  setUp(() => NetworkSettings.network.value = KaspaNetwork.tn10);
  for (final theme in KaspireTheme.values) {
    testWidgets(
        'Mainnet result uses the same layout and return action in ${theme.name}',
        (tester) async {
      smallScreen(tester);
      NetworkSettings.network.value = KaspaNetwork.mainnet;
      AppSettings.theme.value = theme;
      var returned = false;
      final receipt = tradeReceipt('buy')..['network'] = 'mainnet';
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: KForgeResultScreen(
              receipt: receipt, returnToDex: () => returned = true)));
      await tester.pumpAndSettle();
      expect(find.text('Swap confirmed'), findsOneWidget);
      expect(find.text('Kaspa Mainnet'), findsOneWidget);
      final preview = tester.widget<KForgeImage>(find.byType(KForgeImage));
      expect(preview.url, 'https://api.kforge.xyz/img/coin.png');
      await scroll(tester, 'Return to KForge DEX', 'kforge-result-list');
      await tester.tap(find.text('Return to KForge DEX'));
      await tester.pump();
      expect(returned, true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
    for (final side in ['buy', 'sell'])
      testWidgets(
          'full $side result fits ${theme.name} and copies the exact ID',
          (tester) async {
        smallScreen(tester);
        AppSettings.theme.value = theme;
        String? copied;
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData')
            copied = (call.arguments as Map)['text'] as String;
          return null;
        });
        addTearDown(() => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null));
        await tester.pumpWidget(MaterialApp(
            theme: KasVaultTheme.forTheme(theme),
            home: KForgeResultScreen(receipt: tradeReceipt(side))));
        await tester.pumpAndSettle();
        expect(find.text('Swap confirmed'), findsOneWidget);
        expect(find.byType(KForgeImage), findsOneWidget);
        await scroll(tester, 'Network fee', 'kforge-result-list');
        expect(
            find.text(
                side == 'buy' ? 'Total KAS paid (all-in)' : 'Net KAS received'),
            findsOneWidget);
        await scroll(tester, 'Copy transaction ID', 'kforge-result-list');
        await tester.tap(find.text('Copy transaction ID'));
        await tester.pump();
        expect(copied, 'e' * 64);
        await scroll(tester, 'Return to KForge DEX', 'kforge-result-list');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    testWidgets(
        'DEX/activity tabs and completed-trade details return to DEX in ${theme.name}',
        (tester) async {
      smallScreen(tester);
      AppSettings.theme.value = theme;
      final service = KForgeService(client: kforgeClient()),
          trading = ScreenTrading(rows: [tradeReceipt('sell')]);
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: KForgeScreen(
              address: kforgeAddress, service: service, trading: trading)));
      await tester.pumpAndSettle();
      expect(find.byType(TabBar), findsOneWidget);
      expect(find.text('DEX swaps'), findsOneWidget);
      await tester.tap(find.text('My activity'));
      await tester.pumpAndSettle();
      await scroll(tester, 'View trade details', 'kforge-activity-list');
      await tester.tap(find.text('View trade details'));
      await tester.pumpAndSettle();
      expect(find.text('Swap confirmed'), findsOneWidget);
      await scroll(tester, 'Return to KForge DEX', 'kforge-result-list');
      await tester.tap(find.text('Return to KForge DEX'));
      await tester.pumpAndSettle();
      expect(find.text('KForge · Testnet 10'), findsOneWidget);
      expect(find.text('Search ticker, name or covenant ID'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  for (final side in ['buy', 'sell'])
    testWidgets(
        'approved $side goes to a persistent success route and Return skips the old trade form',
        (tester) async {
      smallScreen(tester);
      final token = kforgeToken()
        ..['phase'] = 'pool'
        ..['pool'] = {'poolCovId': 'f' * 64};
      final service = KForgeService(client: kforgeClient(tokens: [token])),
          trading = ScreenTrading();
      await tester.pumpWidget(MaterialApp(
          home: KForgeScreen(
              address: kforgeAddress, service: service, trading: trading)));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ListTile));
      await tester.pumpAndSettle();
      if (side == 'sell') {
        await scroll(tester, 'Sell', 'kforge-trade-list');
        await tester.tap(find.text('Sell'));
        await tester.pumpAndSettle();
      }
      await scroll(tester, 'Refresh quote', 'kforge-trade-list');
      await tester.enterText(
          find.byType(TextField), side == 'buy' ? '10' : '10000');
      await tester.tap(find.text('Refresh quote'));
      await tester.pumpAndSettle();
      await scroll(tester, 'Review swap', 'kforge-trade-list');
      await tester.tap(find.text('Review swap'));
      // The approval intentionally keeps the background busy indicator alive.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Approve swap'));
      await tester.pumpAndSettle();
      expect(trading.signed, 1);
      expect(trading.resumed, 1);
      expect(find.text('Swap confirmed'), findsOneWidget);
      await tester.pump(const Duration(seconds: 8));
      expect(find.text('Swap confirmed'), findsOneWidget);
      await scroll(tester, 'Return to KForge DEX', 'kforge-result-list');
      await tester.tap(find.text('Return to KForge DEX'));
      await tester.pumpAndSettle();
      expect(find.text('KForge · Testnet 10'), findsOneWidget);
      expect(find.text('Review swap'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  testWidgets('pending and obsolete receipts never render a confirmed success',
      (tester) async {
    for (final state in ['pending', 'obsolete']) {
      await tester.pumpWidget(MaterialApp(
          home:
              KForgeResultScreen(receipt: tradeReceipt('buy', state: state))));
      await tester.pumpAndSettle();
      expect(find.text('Swap confirmed'), findsNothing);
      expect(
          find.textContaining('not independently confirmed'), findsOneWidget);
    }
  });
}
