import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/kaspa_address.dart';
import 'package:kasvault_wallet/src/services/kasforge_service.dart';
import 'package:kasvault_wallet/src/services/kasforge_trading.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'kasforge_service_test.dart' as fixture;
import 'kasforge_trading_test.dart' show Memory;
import 'kasforge_trading_live_test.dart' show Inspector;
import 'kasforge38_snapshot_test.dart' show SnapshotTrading;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => NetworkSettings.network.value = KaspaNetwork.mainnet);
  final address = kaspaAddressFromOwnerId('11' * 32);
  test('Mainnet metadata, market, quote and positive balance stay on Mainnet',
      () async {
    final client = MockClient((request) async {
      expect(request.url.host, 'kaspa.pumpforge.tech');
      final path = request.url.path;
      Object data;
      if (path.endsWith('/tokenlist')) {
        expect(path, '/api/kaspa/forge/tokenlist');
        data = {
          'network': 'mainnet',
          'tokens': [
            {...fixture.token(), 'network': 'mainnet'}
          ]
        };
      } else if (path.endsWith('/markets')) {
        data = {
          'markets': [
            {...fixture.market(), 'network': 'mainnet'}
          ]
        };
      } else if (path.contains('/portfolio/')) {
        data = {...fixture.portfolio(), 'address': address};
      } else if (path.contains('/market/')) {
        data = {
          'market': {...fixture.market(), 'network': 'mainnet'}
        };
      } else if (path.contains('/quote/')) {
        data = {'ok': true, 'side': 'buy', 'payKas': 5, 'receiveTokens': 250};
      } else {
        throw StateError('Unexpected request $path');
      }
      return http.Response(jsonEncode(data), 200);
    });
    final service = KasForgeService(client: client);
    final tokens = await service.catalogue();
    expect(tokens.single.network, 'mainnet');
    expect((await service.walletAssets(address)).single.rawBalance, '250');
    expect(
        (await service.quote(tokens.single, 'buy', '5'))['receiveTokens'], 250);
    await expectLater(
        service.quote(KasForgeToken.fromJson(fixture.token()), 'buy', '5'),
        throwsStateError);
    client.close();
  });
  test(
      'network switch rejects an in-flight reply and cannot reuse a Mainnet service',
      () async {
    final gate = Completer<http.Response>();
    final service = KasForgeService(client: MockClient((_) => gate.future));
    final pending = service.tokens();
    final expectation = expectLater(pending, throwsStateError);
    NetworkSettings.network.value = KaspaNetwork.tn10;
    gate.complete(
        http.Response(jsonEncode({'network': 'mainnet', 'tokens': []}), 200));
    await expectation;
    await expectLater(service.tokens(), throwsStateError);
  });
  test(
      'saved orders isolate networks, retain TN10 journal key and reject mixed receipts',
      () async {
    final store = Memory();
    final main = KasForgeTrading(store: store);
    final receipt = <String, dynamic>{
      'address': address,
      'network': 'mainnet',
      'buildId': 'main'
    };
    await main.retain(address, receipt);
    expect(store.data.containsKey('kasforge_mainnet_orders_v1_$address'), true);
    NetworkSettings.network.value = KaspaNetwork.tn10;
    final tn = kaspaAddressWithPrefix(address, 'kaspatest');
    final test = KasForgeTrading(store: store);
    expect(await test.saved(tn), isEmpty);
    await test.retain(
        tn, {'address': tn, 'network': 'testnet-10', 'buildId': 'test'});
    expect(store.data.containsKey('kasforge_tn10_orders_v1_$tn'), true);
    await expectLater(test.retain(tn, receipt), throwsStateError);
    await expectLater(main.saved(address), throwsStateError);
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    expect((await main.saved(address)).single['buildId'], 'main');
  });
  test('Mainnet live input and confirmation use independent Mainnet endpoints',
      () async {
    final urls = <Uri>[];
    final trading = KasForgeTrading(client: MockClient((request) async {
      urls.add(request.url);
      if (request.url.path.endsWith('/utxos'))
        return http.Response(
            jsonEncode({
              'network': 'mainnet',
              'entries': [],
              'covenantIdsIncluded': true
            }),
            200);
      return http.Response(
          jsonEncode({'transaction_id': 'a' * 64, 'is_accepted': true}), 200);
    }));
    expect(await trading.live(address), isEmpty);
    expect(await trading.accepted('a' * 64), true);
    expect(urls.first.path, '/dex-test-v1/kasseal-mainnet/utxos');
    expect(urls.last.path, '/api/local-node/transactions/${'a' * 64}');
    expect(trading.profile, 'kasforge-mainnet-order-v1');
    await expectLater(
        trading.live(kaspaAddressWithPrefix(address, 'kaspatest')),
        throwsStateError);
  });

  final snapshot = Platform.environment['KASPIRE_FORGE_MAINNET_SNAPSHOT'];
  test(
      'captured Mainnet buy and sell pass actual Dart/native review without signing',
      () async {
    final data = jsonDecode(File(snapshot!).readAsStringSync()) as Map;
    var submissions = 0;
    final client = MockClient((request) async {
      Object? response;
      if (request.url.host == 'kaspire.kaslab.space') {
        expect(request.url.path, '/dex-test-v1/kasseal-mainnet/utxos');
        response = data['live'][request.url.queryParameters['address']];
      } else {
        expect(request.url.host, 'kaspa.pumpforge.tech');
        if (request.url.path.contains('/market/')) response = data['market'];
        if (request.url.path.contains('/account/')) response = data['account'];
        if (request.url.path.contains('/quote/'))
          response =
              data['trades'][request.url.queryParameters['side']]['quote'];
        if (request.url.path.endsWith('/build'))
          response = data['trades']
              ['${jsonDecode(request.body)['action']}'.substring(6)]['build'];
        if (request.url.path.endsWith('/submit')) submissions++;
      }
      if (response == null)
        throw StateError('Unexpected snapshot request ${request.url}');
      return http.Response(jsonEncode(response), 200);
    });
    final service = KasForgeService(client: client);
    final token = KasForgeToken.fromJson(
            (data['tokenlist']['tokens'] as List)
                .cast<Map>()
                .singleWhere((t) => t['covenantId'] == data['cid']),
            network: 'mainnet')
        .withMarket(data['market']['market'] as Map);
    for (final side in ['buy', 'sell']) {
      final amount = '${data['trades'][side]['amount']}';
      final quote = await service.quote(token, side, amount);
      final receipt = await SnapshotTrading(data, client)
          .build('${data['account']['address']}', token, side, amount, quote);
      expect(receipt['network'], 'mainnet');
      expect(receipt['contracts'], '3.8');
      expect(receipt['reviews'], isNotEmpty);
      expect(receipt['signed'], isNull);
      for (final request in (receipt['requests'] as List).cast<Map>()) {
        expect(request['profile'], 'kasforge-mainnet-order-v1');
        final wrong = Map<String, Object?>.from(request)
          ..['profile'] = 'kasforge-tn10-order-v1';
        await expectLater(Inspector().preparePskt(wrong), throwsStateError);
      }
    }
    expect(submissions, 0);
  },
      skip: snapshot == null
          ? 'Requires public unsigned Mainnet capture, no live test network access'
          : false);
}
