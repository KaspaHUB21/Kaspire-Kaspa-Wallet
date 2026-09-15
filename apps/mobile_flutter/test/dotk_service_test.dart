import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/dotk_service.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/models/wallet_snapshot.dart';

const ownerAddress =
    'kaspa:qqre4wt08dp0rvmxwqgwdkz4zu4m36g9uvmfledd27mx939uxe2yjpmmd37zq';
const deedAddress =
    'kaspa:pz7hc3eyu6z6f6xgmp5e843a7xpwqag6rywp3s8r96a0yvg0kgy2xcazlrru8';
const script =
    'aa20bd7c4724e685a4e8c8d86993d63df182e0751a191c18c0e32ebaf2310fb208a387';
const txid = 'e65cc49d882b85146ed844f8461c8c743ffacf267e940160cface39fe885b7f8';
Map<String, Object?> derived() => {
      'name': '21millioncoven',
      'address': ownerAddress,
      'deedAddress': deedAddress,
      'scriptPublicKey': script,
      'registryCovenantId': DotkService.registry,
      'bond': 100000000
    };
Map<String, Object?> directory() => {
      ...derived(),
      'ownerType': 0,
      'owner':
          '079ab96f3b42f1b3667010e6d855172bb8e905e3369fe5ad57b662c4bc365449'
    };
Map<String, Object?> coin() => {
      'address': deedAddress,
      'outpoint': {'transactionId': txid, 'index': 0},
      'utxoEntry': {
        'amount': '100000000',
        'isCoinbase': false,
        'scriptPublicKey': {'scriptPublicKey': script}
      }
    };
Map<String, Object?> transaction() => {
      'transaction_id': txid,
      'is_accepted': true,
      'outputs': [
        {
          'index': 0,
          'amount': 100000000,
          'covenant_id': DotkService.registry,
          'script_public_key_address': deedAddress,
          'script_public_key': script
        }
      ]
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('strict ASCII .k grammar, normalizes case and whitespace', () {
    expect(DotkService.bareName(' 21MillionCoven.K '), '21millioncoven');
    expect(DotkService.bareName('a.k'), 'a');
    for (final input in [
      'name',
      'a.kas',
      '.k',
      'tést.k',
      'name.k.evil',
      '-a.k',
      'a-.k',
      'a.b.k',
      '${'a' * 33}.k'
    ]) {
      expect(() => DotkService.bareName(input), throwsA(isA<DotkException>()));
    }
  });

  DotkService service(
      {Map<String, Object?>? row,
      Map<String, Object?>? native,
      Map<String, Object?>? tx,
      List<Object?>? coins,
      bool spentOnRecheck = false,
      bool failPrimary = false}) {
    var utxoCalls = 0;
    return DotkService(
        nodeBaseUrl: 'https://node.test',
        directories: failPrimary
            ? ['https://broken.test/v1', 'https://directory.test/v1']
            : ['https://directory.test/v1'],
        derive: (request) async {
          expect(request['name'], '21millioncoven');
          return native ?? derived();
        },
        client: MockClient((request) async {
          if (request.url.host == 'broken.test') {
            return http.Response('Unavailable', 503);
          }
          if (request.url.path.contains('/names/')) {
            return http.Response(jsonEncode(row ?? directory()), 200);
          }
          if (request.url.path.endsWith('/utxos')) {
            expect(
                Uri.decodeComponent(request.url.path), contains(deedAddress));
            utxoCalls++;
            return http.Response(
                jsonEncode(
                    spentOnRecheck && utxoCalls > 1 ? [] : coins ?? [coin()]),
                200);
          }
          if (request.url.path.contains('/transactions/')) {
            return http.Response(jsonEncode(tx ?? transaction()), 200);
          }
          return http.Response('Not found', 404);
        }));
  }

  test('resolves current deed and rechecks unspent outpoint', () async {
    final result = await service().resolve('21millioncoven.k');
    expect(result.address, ownerAddress);
    expect(result.verified, true);
    expect(result.outpoint, '$txid:0');
  });

  test('shared send resolver routes .k to native proof and rejects TN10',
      () async {
    const channel = MethodChannel('space.kasvault/security');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'deriveDotkDeed');
      expect(jsonDecode(call.arguments['request'])['name'], '21millioncoven');
      return jsonEncode(derived());
    });
    final previousNetwork = NetworkSettings.network.value;
    try {
      NetworkSettings.network.value = KaspaNetwork.mainnet;
      final api =
          KaspaApi(client: service().client, baseUrl: 'https://node.test');
      expect(await api.resolveWalletInput('21MillionCoven.k'), ownerAddress);
      NetworkSettings.network.value = KaspaNetwork.tn10;
      await expectLater(api.resolveWalletInput('21millioncoven.k'),
          throwsA(isA<KaspaApiException>()));
    } finally {
      NetworkSettings.network.value = previousNetwork;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });

  test('dot.k holdings survive activity snapshot updates', () {
    const snapshot = WalletSnapshot(
        balanceSompi: 0,
        kasUsd: null,
        transactions: [],
        krc20Tokens: [],
        krc721Collections: [],
        knsDomains: [],
        dotkNames: [DotkName(name: '21millioncoven.k', address: ownerAddress)]);
    expect(snapshot.withTransactions([]).dotkNames.single.name,
        '21millioncoven.k');
  });
  test('healthy mirror is used when primary fails', () async {
    expect(
        (await service(failPrimary: true).resolve('21millioncoven.k')).address,
        ownerAddress);
  });
  test('rejects another name, payment address, deed or deployment', () async {
    for (final replacement in [
      {'name': 'other'},
      {'address': 'kaspa:wrong'},
      {'deedAddress': 'kaspa:wrong'},
      {'registryCovenantId': '00' * 32}
    ]) {
      await expectLater(
          service(row: {...directory(), ...replacement})
              .resolve('21millioncoven.k'),
          throwsA(isA<DotkException>()));
    }
  });
  test('rejects covenant-only owner instead of making a recipient', () async {
    await expectLater(
        service(native: {...derived(), 'address': null})
            .resolve('21millioncoven.k'),
        throwsA(isA<DotkException>()));
  });
  test('rejects spent deed and stale proof', () async {
    await expectLater(service(coins: []).resolve('21millioncoven.k'),
        throwsA(isA<DotkException>()));
    await expectLater(service(spentOnRecheck: true).resolve('21millioncoven.k'),
        throwsA(isA<DotkException>()));
  });
  test('funding real deed address with foreign covenant is not proof',
      () async {
    final tx = transaction();
    ((tx['outputs'] as List).first as Map)['covenant_id'] = '00' * 32;
    await expectLater(service(tx: tx).resolve('21millioncoven.k'),
        throwsA(isA<DotkException>()));
  });
  test('rejects unaccepted transaction, mismatched script and wrong bond',
      () async {
    await expectLater(
        service(tx: {...transaction(), 'is_accepted': false})
            .resolve('21millioncoven.k'),
        throwsA(isA<DotkException>()));
    for (final amount in ['1', '200000000']) {
      final c = coin();
      (c['utxoEntry'] as Map)['amount'] = amount;
      await expectLater(service(coins: [c]).resolve('21millioncoven.k'),
          throwsA(isA<DotkException>()));
    }
    final c = coin();
    (c['utxoEntry'] as Map)['scriptPublicKey'] = {
      'scriptPublicKey': 'aa20bad87'
    };
    await expectLater(service(coins: [c]).resolve('21millioncoven.k'),
        throwsA(isA<DotkException>()));
  });
  test('complete holdings sorted, deduplicated and never called proven',
      () async {
    final s = DotkService(
        nodeBaseUrl: 'https://node.test',
        directories: ['https://directory.test/v1'],
        client: MockClient((_) async => http.Response(
            jsonEncode({
              'address': ownerAddress,
              'names': [
                'zebra',
                'aaa',
                'zebra',
                ...List.generate(130, (i) => 'name-$i')
              ],
              'registryCovenantId': DotkService.registry
            }),
            200)));
    final names = await s.namesOf(ownerAddress);
    expect(names.length, 132);
    expect(names.first.name, 'aaa.k');
    expect(names.last.name, 'zebra.k');
    expect(names.every((n) => !n.verified), true);
  });
}
