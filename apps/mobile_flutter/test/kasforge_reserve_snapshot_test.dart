import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/kasforge_service.dart';
import 'package:kasvault_wallet/src/services/kasforge_trading.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';

import 'kasforge38_snapshot_test.dart' show SnapshotTrading;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('unsigned preparation errors do not expose JNI exception wrappers', () {
    final message = KasForgeTrading.preparationError(PlatformException(
        code: 'SECURITY_ERROR',
        message: 'IllegalStateException: invalid transaction request: '
            'KasForge: token reserve differs from independently checked inputs'));
    expect(message, contains('KasForge: token reserve differs'));
    expect(message, contains('Nothing was signed or submitted.'));
    expect(message, isNot(contains('PlatformException')));
    expect(message, isNot(contains('IllegalStateException')));
  });

  final directory = Platform.environment['KASPIRE_FORGE_RESERVE_SNAPSHOTS'];
  for (final name in ['v38', 'rocket']) {
    test('captured $name sale checks actual reserves on the independent node',
        () async {
      final data = jsonDecode(File('$directory/$name-verified-snapshot.json')
          .readAsStringSync()) as Map;
      NetworkSettings.network.value = KaspaNetwork.tn10;
      var submits = 0;
      final client = MockClient((request) async {
        Object? value;
        if (request.url.host == 'kaspire.kaslab.space') {
          value = data['live'][request.url.queryParameters['address']];
        } else if (request.url.path.contains('/market/')) {
          value = data['market'];
        } else if (request.url.path.contains('/account/')) {
          value = data['account'];
        } else if (request.url.path.contains('/quote/')) {
          value = data['quote'];
        } else if (request.url.path.endsWith('/build')) {
          value = data['build'];
        } else if (request.url.path.endsWith('/submit')) {
          submits++;
        }
        if (value == null) throw StateError('Unexpected capture request');
        return http.Response(jsonEncode(value), 200);
      });
      final token = KasForgeToken.fromJson((data['tokenlist']['tokens'] as List)
              .cast<Map>()
              .singleWhere((row) => row['covenantId'] == data['cid']))
          .withMarket(data['market']['market'] as Map);
      final quote = await KasForgeService(client: client)
          .quote(token, 'sell', '${data['amount']}');
      final receipt = await SnapshotTrading(data, client).build(
          '${data['account']['address']}',
          token,
          'sell',
          '${data['amount']}',
          quote);
      expect(receipt['reviews'], isNotEmpty);
      expect(receipt['signed'], isNull);
      expect(receipt['order']['tokens']['output']['sompi'],
          name == 'rocket' ? 300000000 : 100000000);
      expect(submits, 0);
      client.close();
    },
        skip: directory == null
            ? 'Requires parent-captured public unsigned builds and independent UTXOs'
            : false);
  }
}
