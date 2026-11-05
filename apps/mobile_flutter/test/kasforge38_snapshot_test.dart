import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/kasforge_trading.dart';
import 'package:kasvault_wallet/src/services/kasforge_service.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'kasforge_trading_test.dart' show Memory;
import 'kasforge_trading_live_test.dart' show Inspector;

class SnapshotTrading extends KasForgeTrading {
  SnapshotTrading(this.snapshot, http.Client client)
      : super(client: client, store: Memory(), security: Inspector());
  final Map snapshot;
  @override
  Future<List<int>> readClocks() async =>
      (snapshot['clocks'] as List).cast<int>();
}

class CancellationPreview extends KasForgeTrading {
  CancellationPreview() : super(store: Memory(), security: Inspector());
  @override
  Future<void> verify(String address, Map tx, Map<String, Map> parents) async {
    // The captured order has never been signed or broadcast: test only the
    // local cancellation adapter, not a claim of live UTXO acceptance.
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final file = Platform.environment['KASPIRE_FORGE38_SNAPSHOT'];
  test(
      'current 3.8 API buy and sell builds pass independent native review without signing',
      () async {
    final data = jsonDecode(File(file!).readAsStringSync()) as Map;
    NetworkSettings.network.value = KaspaNetwork.tn10;
    var submits = 0;
    final client = MockClient((request) async {
      Object? response;
      if (request.url.host == 'kaspire.kaslab.space') {
        response = data['live'][request.url.queryParameters['address']];
      } else if (request.url.path.contains('/market/')) {
        response = data['market'];
      } else if (request.url.path.contains('/account/')) {
        response = data['account'];
      } else if (request.url.path.contains('/quote/')) {
        response = data['trades'][request.url.queryParameters['side']]['quote'];
      } else if (request.url.path.endsWith('/build')) {
        final body = jsonDecode(request.body) as Map;
        response = data['trades']['${body['action']}'.substring(6)]['build'];
      } else if (request.url.path.endsWith('/submit')) {
        submits++;
      }
      if (response == null) {
        throw StateError('Unexpected snapshot request ${request.url}');
      }
      return http.Response(jsonEncode(response), 200);
    });
    final token = KasForgeToken.fromJson((data['tokenlist']['tokens'] as List)
            .cast<Map>()
            .singleWhere((r) => r['covenantId'] == data['cid']))
        .withMarket(data['market']['market'] as Map);
    final address = data['market']['market']['creator'] as String;
    for (final side in ['buy', 'sell']) {
      final amount = data['trades'][side]['amount'] as String;
      final quote =
          await KasForgeService(client: client).quote(token, side, amount);
      final receipt = await SnapshotTrading(data, client)
          .build(address, token, side, amount, quote);
      expect(receipt['contracts'], '3.8');
      expect(receipt['reviews'], isNotEmpty);
      expect(receipt['signed'], isNull);
      if (side == 'sell') {
        final cancel = await CancellationPreview().cancel(address, receipt);
        final tx = jsonDecode('${cancel['txJsonString']}') as Map;
        expect(tx['inputs'][0]['utxo']['amount'], '200000000');
        expect(tx['outputs'][0]['value'], '100000000');
        expect(tx['outputs'][1]['value'], '190000000');
        final review = await Inspector().preparePskt(cancel);
        expect('${review['feeSompi']}', '10000000');
      }
      final altered = Map<String, Object?>.from(receipt['requests'][0] as Map);
      altered['tradeSummary'] = {
        ...(altered['tradeSummary'] as Map),
        'contracts': '3.3'
      };
      await expectLater(Inspector().preparePskt(altered), throwsStateError);
    }
    expect(submits, 0);
  },
      skip: file == null
          ? 'Provide a parent-captured public unsigned 3.8 snapshot; never network or sign in this test'
          : false);
}
