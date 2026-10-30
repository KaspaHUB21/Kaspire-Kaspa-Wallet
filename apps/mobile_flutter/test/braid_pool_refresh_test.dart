import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/kaspa_address.dart';
import 'package:kasvault_wallet/src/services/braid_pool_reader.dart';
import 'package:kasvault_wallet/src/services/braid_service.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('../../crates/kaspa_secure_core/src/fixtures/$name.json')
        .readAsStringSync()) as Map<String, dynamic>;
Map<String, dynamic> proof() => fixture('braid-mainnet-then-pool');
Map<String, dynamic> transaction() => fixture('braid-mainnet-then-transaction');
http.Response reply(Object? value, [int code = 200]) =>
    http.Response(jsonEncode(value), code);
List<Map<String, Object?>> live(Map p, {String? id, bool badScript = false}) =>
    [
      {
        'outpoint': {
          'transactionId': id ?? p['transactionId'],
          'index': p['index']
        },
        'utxoEntry': {
          'amount': '100000000',
          'isCoinbase': false,
          'scriptPublicKey': {
            'version': 0,
            'scriptPublicKey':
                badScript ? 'aa20${'00' * 32}87' : p['scriptPublicKey']
          }
        }
      }
    ];

void main() {
  setUp(() => NetworkSettings.network.value = KaspaNetwork.mainnet);
  for (final reason in ['404', '503', 'not-accepted']) {
    test(
        'lagging own transaction index falls back, own live UTXO stays mandatory: $reason',
        () async {
      final p = proof(), tx = transaction(), seen = <Uri>[];
      final reader = BraidPoolReader(MockClient((r) async {
        seen.add(r.url);
        expect(r.method, 'GET');
        if (r.url.path.endsWith('/utxos')) {
          expect(r.url.host, 'kaspire.kaslab.space');
          return reply(live(p));
        }
        if (r.url.host == 'kaspire.kaslab.space') {
          return reason == 'not-accepted'
              ? reply({...tx, 'is_accepted': false})
              : reply({}, int.parse(reason));
        }
        expect(r.url.host, 'api.kaspa.org');
        return reply(tx);
      }), mainnet: true);
      expect(
          (await reader.value('${p['tokenId']}', BigInt.from(10000000), 100, {
            'transactionId': p['transactionId'],
            'index': p['index']
          }))['floor'],
          p['floor']);
      expect(seen.length, 3);
    });
  }
  for (final exactSpend in [true, false]) {
    test('public history may follow only the exact spent outpoint: $exactSpend',
        () async {
      final p = proof(),
          old = transaction(),
          next = transaction(),
          nextId = '22' * 32;
      next['transaction_id'] = nextId;
      (next['inputs'] as List).add({
        'previous_outpoint_hash': p['transactionId'],
        'previous_outpoint_index': exactSpend ? p['index'] : 999
      });
      var publicHistory = 0;
      final reader = BraidPoolReader(MockClient((r) async {
        expect(r.method, 'GET');
        if (r.url.path.endsWith('/utxos')) {
          expect(r.url.host, 'kaspire.kaslab.space');
          return reply(live(p, id: nextId));
        }
        if (r.url.path.endsWith('/full-transactions')) {
          if (r.url.host == 'api.kaspa.org') {
            publicHistory++;
            return reply([next]);
          }
          return reply([]);
        }
        return reply(r.url.path.endsWith('/$nextId') ? next : old);
      }), mainnet: true);
      final result = reader.value('${p['tokenId']}', BigInt.from(10000000), 100,
          {'transactionId': p['transactionId'], 'index': p['index']});
      if (exactSpend) {
        expect((await result)['transactionId'], nextId);
      } else {
        await expectLater(result, throwsStateError);
      }
      expect(publicHistory, 1);
    });
  }
  test('malformed live proof is not misreported as a spent pool', () async {
    final p = proof();
    final reader = BraidPoolReader(MockClient((r) async {
      expect(r.url.path.endsWith('/full-transactions'), false);
      return reply(r.url.path.endsWith('/utxos')
          ? live(p, badScript: true)
          : transaction());
    }), mainnet: true);
    await expectLater(
        reader.value('${p['tokenId']}', BigInt.from(10000000), 100,
            {'transactionId': p['transactionId'], 'index': p['index']}),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('UTXO data differs'))));
  });
  test(
      'public transaction acceptance never substitutes for a missing own-node UTXO',
      () async {
    final p = proof();
    final reader = BraidPoolReader(MockClient((r) async {
      if (r.url.path.endsWith('/utxos')) {
        expect(r.url.host, 'kaspire.kaslab.space');
        return reply([]);
      }
      if (r.url.path.endsWith('/full-transactions')) return reply([]);
      return reply(transaction());
    }), mainnet: true);
    await expectLater(
        reader.value('${p['tokenId']}', BigInt.from(10000000), 100,
            {'transactionId': p['transactionId'], 'index': p['index']}),
        throwsStateError);
  });
  test('TN10 never falls back to the Mainnet indexer', () async {
    var calls = 0;
    final reader = BraidPoolReader(MockClient((r) async {
      calls++;
      expect(r.url.host, 'api-tn10.kaspa.org');
      return reply({}, 503);
    }), mainnet: false);
    await expectLater(reader.transaction('11' * 32), throwsStateError);
    expect(calls, 1);
  });

  for (final mode in [
    'current',
    'missing',
    'list',
    'stale',
    'cached',
    'foreign',
    'network',
    'unavailable'
  ]) {
    test('production quote refresh handles pool hints: $mode', () async {
      final p = proof(), tx = transaction(), staleId = '11' * 32;
      final s =
          fixture('braid-mainnet-staged-deposit-change')['tradeSummary'] as Map;
      final from = BraidService.tokens.singleWhere((t) => t.id == p['tokenId']);
      final to = BraidService.tokens.singleWhere((t) => t.id == s['toId']);
      final address = kaspaAddressFromOwnerId('44' * 32);
      var discoveries = 0, history = 0, seedCache = mode == 'cached';
      final client = MockClient((r) async {
        expect(r.method, 'GET');
        if (r.url.path.endsWith('/info')) {
          return reply({
            'net': 'mainnet',
            'enabled': true,
            'pin': BraidService.mainnetPin,
            'expectedPin': BraidService.mainnetPin,
            'pinOk': true,
            'executorStatus': {'healthy': true}
          });
        }
        if (r.url.path.endsWith('/quote')) {
          final hint = r.url.queryParameters['walletFeeBps'] == null;
          return reply({
            'net': 'mainnet',
            'pin': BraidService.mainnetPin,
            'from': from.symbol,
            'to': to.symbol,
            'amountIn': '10000000',
            'staged': true,
            'midMin': s['midMin'],
            'amountOut': s['minimumOut'],
            if (hint && (mode == 'current' || mode == 'stale' || seedCache))
              'poolTips': {
                from.id: {
                  'transactionId':
                      mode == 'stale' ? staleId : p['transactionId'],
                  'index': p['index']
                }
              },
            if (hint && mode == 'list') 'poolTips': [],
            'walletFee': {
              'mode': 'bps',
              'bps': 100,
              'unit': 'KAS',
              'pk': BraidService.feeOwner,
              'address': kaspaAddressFromOwnerId(BraidService.feeOwner),
              'amount': s['walletFee'],
              'basis': s['feeBasis'],
              'basisKind': 'tradeKas'
            },
          });
        }
        if (r.url.path == '/api/mainnet/pools') {
          discoveries++;
          if (mode == 'cached' || mode == 'unavailable') return reply({}, 503);
          return reply({
            'network': mode == 'network' ? 'tn10' : 'mainnet',
            'pools': [
              {
                'tokenId': from.id,
                'poolCovid':
                    mode == 'foreign' ? '00' * 32 : p['poolCovenantId'],
                'venue': 'kr',
                'verified': false, // This flag is never authority.
                'tip': {
                  'transactionId': p['transactionId'],
                  'index': p['index']
                }
              }
            ]
          });
        }
        if (r.url.path.endsWith('/full-transactions')) {
          history++;
          return reply([]);
        }
        if (r.url.path.endsWith('/utxos')) {
          expect(r.url.host, 'kaspire.kaslab.space');
          return reply(live(p));
        }
        return reply(r.url.path.endsWith('/$staleId')
            ? {...tx, 'transaction_id': staleId}
            : tx);
      });
      final service = BraidService(client: client);
      try {
        if (seedCache) {
          await service.quote(address, from, to, '10000000', 100);
          seedCache = false;
        }
        final result = service.quote(address, from, to, '10000000', 100);
        if (['foreign', 'network', 'unavailable'].contains(mode)) {
          await expectLater(result, throwsStateError);
        } else {
          final q = await result;
          expect(q['localValuation']['transactionId'], p['transactionId']);
          expect(q['localValuation']['floor'], p['floor']);
        }
        expect(history, 0,
            reason: 'Fresh discovery precedes stale address history.');
        expect(discoveries, mode == 'current' ? 0 : 1);
      } finally {
        client.close();
      }
    });
  }
}
