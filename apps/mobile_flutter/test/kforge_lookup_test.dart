import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/kforge_service.dart';
import 'package:kasvault_wallet/src/services/kforge_trading.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'kforge_mainnet_test.dart' show KForgeInspector;
import 'kforge_trading_test.dart' show MemoryKForgeStore, ReviewKForgeSecurity;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Map fixture(String name) =>
      jsonDecode(File('../../crates/kaspa_secure_core/src/fixtures/$name.json')
          .readAsStringSync()) as Map;
  final capture = fixture('kforge-mainnet-unsigned');
  final live = fixture('kforge-mainnet-live');
  setUp(() => NetworkSettings.network.value = KaspaNetwork.mainnet);
  tearDown(() => NetworkSettings.network.value = KaspaNetwork.mainnet);

  test(
      'real four-input buy retries busy reads sequentially before native review',
      () async {
    final row = capture['trades']['curve-buy'] as Map;
    final address = row['wallet'] as String;
    expect((jsonDecode(row['response']['txJson'])['inputs'] as List).length, 4);
    var active = 0, peak = 0, submits = 0;
    var busyOnce = true;
    final waits = <Duration>[];
    final client = MockClient((r) async {
      Object? value;
      if (r.url.host == 'api.kforge.xyz') {
        if (r.url.path.endsWith('registry')) value = capture['registry'];
        if (r.url.path == '/v6/tokens') value = [row['token']];
        if (r.url.path.contains('/holdings/')) {
          value = capture['wallets'][address];
        }
        if (r.method == 'POST') {
          if (r.url.path.endsWith('submit')) submits++;
          expect(r.url.path, row['path']);
          value = row['response'];
        }
      } else {
        expect(r.url.path, '/dex-test-v1/kasseal-mainnet/utxos');
        if (busyOnce) {
          busyOnce = false;
          return http.Response('busy', 503);
        }
        if (active >= 3) return http.Response('busy', 503);
        active++;
        if (active > peak) peak = active;
        try {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          value = {
            'network': 'mainnet',
            'covenantIdsIncluded': true,
            'entries': live['utxos'][r.url.queryParameters['address']]
          };
        } finally {
          active--;
        }
      }
      if (value == null) throw StateError('Unexpected fixture route');
      return http.Response(jsonEncode(value), 200);
    });
    final store = MemoryKForgeStore();
    final trading = KForgeTrading(
        client: client,
        store: store,
        security: KForgeInspector(),
        lookupWait: (delay) async {
          waits.add(delay);
        });
    final token = KForgeToken.fromJson(row['token'] as Map);
    final plan = await trading.quote(
        address, token, 'buy', KForgeTrading.curveBuyCost(token, 1));
    expect(plan['review']['tradeSummary']['verified']['network'], 'mainnet');
    expect(peak, 1);
    expect(waits.first, const Duration(milliseconds: 250));
    expect(waits.skip(1), everyElement(const Duration(milliseconds: 220)));
    expect(waits, hasLength(4));
    expect(submits, 0);
    expect(store.values, isEmpty);
  });

  for (final network in [KaspaNetwork.mainnet, KaspaNetwork.tn10]) {
    test(
        'same-owner cache is local and signing rechecks fresh inputs: $network',
        () async {
      NetworkSettings.network.value = network;
      final mainnet = network == KaspaNetwork.mainnet;
      var reads = 0;
      final waits = <Duration>[];
      late KForgeTrading trading;
      final spk = '000020${'11' * 32}ac';
      final inputs = [
        for (final hex in ['a', 'b', 'c', 'd'])
          {
            'transactionId': hex * 64,
            'index': 0,
            'utxo': {
              'scriptPublicKey': spk,
              'amount': '100',
              'covenantId': null
            }
          }
      ];
      trading = KForgeTrading(
          mainnet: mainnet,
          lookupWait: (d) async => waits.add(d),
          client: MockClient((r) async {
            reads++;
            expect(r.url.path,
                '/dex-test-v1/${mainnet ? 'kasseal-mainnet' : 'kasseal'}/utxos');
            return http.Response(
                jsonEncode({
                  'network': mainnet ? 'mainnet' : 'testnet-10',
                  'covenantIdsIncluded': true,
                  'entries': [
                    for (final input in inputs)
                      {
                        'outpoint': {
                          'transactionId': input['transactionId'],
                          'index': 0
                        },
                        'utxoEntry': {
                          'amount': reads == 1 ? '100' : '101',
                          'scriptPublicKey': {
                            'version': 0,
                            'script': spk.substring(4)
                          },
                          'covenantId': null,
                          'isCoinbase': false,
                          'blockDaaScore': '9'
                        }
                      }
                  ]
                }),
                200);
          }));
      final address = trading.inputAddress(spk);
      await trading.verify(address, {'inputs': inputs});
      expect(reads, 1);
      expect(waits, isEmpty);
      await expectLater(
          trading.verify(address, {'inputs': inputs}),
          throwsA(isA<StateError>().having((e) => e.message, 'reason',
              contains('differs from the independent node'))));
      expect(reads, 2);
    });
  }

  for (final status in [429, 502, 503, 504]) {
    test('transient HTTP $status retries only GET and returns verified data',
        () async {
      var reads = 0;
      final waits = <Duration>[];
      final trading = KForgeTrading(
          lookupWait: (d) async => waits.add(d),
          client: MockClient((r) async {
            expect(r.method, 'GET');
            return ++reads == 1
                ? http.Response('busy', status)
                : http.Response('{"ok":true}', 200);
          }));
      expect(await trading.read('https://kaspire.kaslab.space/fixture'),
          {'ok': true});
      expect(reads, 2);
      expect(waits, [const Duration(milliseconds: 250)]);
    });
  }

  test(
      'persistent overload is bounded and leaves an existing receipt untouched',
      () async {
    var reads = 0;
    final waits = <Duration>[];
    final store = MemoryKForgeStore(), security = ReviewKForgeSecurity();
    final row = capture['trades']['curve-buy'] as Map;
    final address = row['wallet'] as String;
    final trading = KForgeTrading(
        store: store,
        security: security,
        lookupWait: (d) async => waits.add(d),
        client: MockClient((r) async {
          reads++;
          expect(r.method, 'GET');
          return http.Response('busy', 503);
        }));
    await trading.retain(address, {
      'address': address,
      'network': 'mainnet',
      'state': 'pending',
      'id': 'a' * 64,
      'signed': {'immutable': 'saved bytes'}
    });
    final before = Map.of(store.values);
    await expectLater(
        trading.resume(address, (await trading.pending(address))!),
        throwsA(isA<KForgeLookupUnavailable>().having(
            (e) => e.toString(), 'message', isNot(contains('Bad state')))));
    expect(reads, 4);
    expect(waits, [
      const Duration(milliseconds: 250),
      const Duration(milliseconds: 750),
      const Duration(milliseconds: 1500)
    ]);
    expect(store.values, before);
    expect(security.prepares, 0);
    expect(security.signs, 0);
  });

  test('Retry-After cannot make a lookup wait indefinitely', () async {
    var reads = 0;
    final waits = <Duration>[];
    final trading = KForgeTrading(
        lookupWait: (d) async => waits.add(d),
        client: MockClient((_) async => ++reads == 1
            ? http.Response('busy', 429, headers: {'retry-after': '999999'})
            : http.Response('{}', 200)));
    await trading.read('https://kaspire.kaslab.space/fixture');
    expect(waits, [const Duration(seconds: 2)]);
  });

  test('a stalled read has one deadline and does not start overlapping retries',
      () async {
    var reads = 0;
    final trading = KForgeTrading(
        lookupWait: (_) async => fail('Do not retry an in-flight timeout'),
        client: MockClient((_) {
          reads++;
          return Completer<http.Response>().future;
        }));
    await expectLater(
        trading.read('https://kaspire.kaslab.space/fixture',
            timeout: const Duration(milliseconds: 20)),
        throwsA(isA<KForgeLookupUnavailable>()));
    expect(reads, 1);
  });

  test('timeout, malformed, oversized and permanent errors never become zero',
      () async {
    for (final failure in ['timeout', 'transport', 'json', 'large', '400']) {
      var reads = 0;
      final trading = KForgeTrading(
          lookupWait: (_) async => fail('Do not retry this failure'),
          client: MockClient((_) async {
            reads++;
            if (failure == 'timeout') throw TimeoutException('fixture');
            if (failure == 'transport') throw http.ClientException('fixture');
            if (failure == '400') return http.Response('{}', 400);
            return http.Response(
                failure == 'large' ? 'a' * (4194304 + 1) : '[', 200);
          }));
      await expectLater(trading.read('https://kaspire.kaslab.space/fixture'),
          throwsA(isA<KForgeLookupUnavailable>()));
      expect(reads, 1);
    }
  });
}
