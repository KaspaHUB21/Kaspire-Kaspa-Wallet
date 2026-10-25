import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kasvault_wallet/src/services/kasseal_service.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/services/encrypted_store.dart';
import 'package:kasvault_wallet/src/services/activity_store.dart';

class MemoryStore implements EncryptedStore {
  final data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async {
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }
}

void main() {
  test(
      'Global token search preserves search text and cursor without query injection',
      () async {
    final service = KassealService(client: MockClient((r) async {
      expect(r.url.path, endsWith('/tokens'));
      expect(r.url.queryParameters['sort'], 'mcap-volume');
      expect(r.url.queryParameters['search'], 'unnachod &limit=100');
      expect(r.url.queryParameters['cursor'], 'query-page-2');
      expect(r.url.queryParameters.containsKey('limit'), false);
      return http.Response('{"tokens":[],"nextCursor":null}', 200);
    }));
    await service.searchTokens(' unnachod &limit=100 ', 'query-page-2');
    await expectLater(service.searchTokens('x' * 65), throwsStateError);
  });
  final fixture = Map<String, Object?>.from(jsonDecode(
      File('../../crates/kaspa_secure_core/src/fixtures/kasseal-tn10-buy.json')
          .readAsStringSync()));
  final address = '${fixture['sender']}', id = '${fixture['tokenId']}';
  setUp(() {
    NetworkSettings.network.value = KaspaNetwork.tn10;
    SharedPreferences.setMockInitialValues({});
  });
  http.Response response(Object data, [int status = 200]) =>
      http.Response(jsonEncode(data), status,
          headers: {'content-type': 'application/json'});
  test(
      'Confirmed preparation never records a sale and keeps its journal if indexing mismatches',
      () async {
    for (final mismatch in [false, true]) {
      final store = MemoryStore(),
          ledger = ActivityStore(encryptedStore: MemoryStore());
      var posts = 0;
      final service = KassealService(
          store: store,
          activity: ledger,
          client: MockClient((r) async {
            if (r.method == 'POST') posts++;
            if (r.url.path.endsWith('/prepared'))
              return response({
                'network': mismatch ? 'mainnet' : 'testnet-10',
                'tokenId': id,
                'transactionId': 'd' * 64,
                'ready': true
              });
            return response({'transaction_id': 'd' * 64, 'is_accepted': true});
          }));
      final saved = {
        'address': address,
        'network': 'testnet-10',
        'transactionId': 'd' * 64,
        'signedTxJson': 'EXACT PREPARATION',
        'ticker': 'WALLET',
        'timestamp': '2026-10-23T01:00:00Z',
        'summary': {
          'stage': 'preparation',
          'operation': 'split',
          'side': 'sell',
          'tokenId': id,
          'tokenAmount': '10000'
        }
      };
      await service.retain(address, saved);
      if (mismatch) {
        await expectLater(service.resume(address), throwsStateError);
        expect(await service.pending(address), saved);
      } else {
        expect(await service.resume(address), 'd' * 64);
        expect(await service.pending(address), isNull);
      }
      expect(posts, 0);
      expect(await ledger.load(address), isEmpty);
      expect(store.data['${service.key(address)}_preparations'],
          contains('EXACT PREPARATION'));
    }
  });
  test(
      'Mainnet uses its own routes, profiles and journals; rejects TN10 wallets',
      () async {
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    final service = KassealService(
        client: MockClient((_) async => throw StateError('must not fetch')));
    expect(() => service.guard(address), throwsStateError);
    expect(service.network, 'mainnet');
    expect(service.api, 'https://app.kasseal.com/v1');
    expect(service.planner, endsWith('/kasseal-mainnet'));
    expect(service.profile('swap'), 'kasseal-mainnet-swap-v1');
    expect(service.key('kaspa:qfixture'), contains('_mainnet_'));
    expect(() => service.guard('kaspa:qfixture'), returnsNormally);
    NetworkSettings.network.value = KaspaNetwork.tn10;
    expect(() => service.guard('kaspa:qfixture'), throwsStateError);
    await expectLater(
        service.quote(address, id, 'buy', '100000000'), throwsStateError);
  });
  test(
      'Sale preparation is explicitly opted into and restricted to self split/merge stages',
      () async {
    for (final operation in ['split', 'merge', 'withdraw']) {
      final store = MemoryStore();
      final service = KassealService(
          store: store,
          client: MockClient((r) async {
            final body = jsonDecode(r.body) as Map;
            expect(body['allowPreparation'], true);
            return response({
              'proofStatus': 'bound',
              'request': {
                'sender': address,
                'tokenId': id,
                'side': 'sell',
                'profile': 'kasseal-tn10-prepare-v1',
                'tradeSummary': {
                  ...body,
                  'stage': 'preparation',
                  'operation': operation,
                  'maxPreparationDebitSompi': '700000000'
                }
              }
            });
          }));
      final quote = <String, dynamic>{
        'quoteExpiresAt': DateTime.now().millisecondsSinceEpoch + 60000,
        'tokenId': id,
        'side': 'sell',
        'rawAmount': '10000',
        'tokenAmount': '10000',
        'kasSompi': '231583220',
        'maxSpendSompi': '931583220'
      };
      if (operation == 'withdraw')
        await expectLater(service.plan(address, quote), throwsStateError);
      else
        expect((await service.plan(address, quote))['profile'],
            'kasseal-tn10-prepare-v1');
    }
  });
  test('Only verified same-origin hash-addressed images are loaded', () {
    expect(
        KassealService().image({
          'imageSource': 'external',
          'imageUrl': 'https://example.invalid/tracker.png'
        }),
        isNull);
    expect(
        KassealService()
            .image({'imageSource': 'verified', 'imageUrl': '//evil.invalid/a'}),
        isNull);
    expect(
        KassealService().image(
            {'imageSource': 'verified', 'imageUrl': '/v1/images/${'a' * 64}'}),
        'https://testnet.kasseal.com/v1/images/${'a' * 64}');
  });
  test('Buying budget counts only spendable plain KAS, not token deposits',
      () async {
    final service = KassealService(
        client: MockClient((r) async => response({
              'network': 'testnet-10',
              'covenantIdsIncluded': true,
              'entries': [
                {
                  'utxoEntry': {
                    'amount': '123000000',
                    'covenantId': null,
                    'isCoinbase': false
                  }
                },
                {
                  'utxoEntry': {
                    'amount': '500000000',
                    'covenantId': id,
                    'isCoinbase': false
                  }
                },
                {
                  'utxoEntry': {
                    'amount': '900000000',
                    'covenantId': null,
                    'isCoinbase': true
                  }
                }
              ]
            })));
    expect(await service.kasBalance(address), BigInt.from(123000000));
  });
  test(
      'Swap history includes older activity and retains full encrypted receipts',
      () async {
    final store = MemoryStore(),
        activity = ActivityStore(encryptedStore: MemoryStore());
    final service = KassealService(store: store, activity: activity);
    await activity.recordAssetTransfer(
        wallet: address,
        operation: {
          'kind': 'kcc20',
          'ticker': 'OLD',
          'displayAmount': '1000',
          'operationLabel': 'Kasseal Buy'
        },
        transactionId: 'a' * 64,
        timestamp: DateTime.utc(2026, 10, 22),
        incoming: true);
    await store.write(
        '${service.key(address)}_history',
        jsonEncode([
          {
            'transactionId': 'b' * 64,
            'ticker': 'NEW',
            'timestamp': '2026-10-23T01:00:00.000Z',
            'summary': {
              'side': 'sell',
              'tokenAmount': '2000',
              'kasSompi': '100000000'
            }
          }
        ]));
    final rows = await service.history(address);
    expect(rows.length, 2);
    expect(rows.first['ticker'], 'NEW');
    expect(rows.last['ticker'], 'OLD');
    expect(rows.first['summary']['kasSompi'], '100000000');
  });
  test(
      'Live node resolves DAA and covenant IDs without pruned transaction history',
      () async {
    for (final badCid in [false, true]) {
      final request =
          Map<String, Object?>.from(jsonDecode(jsonEncode(fixture)));
      final original = jsonDecode('${request['txJsonString']}') as Map,
          inputs = original['inputs'] as List;
      final client = MockClient((r) async {
        if (r.url.path.endsWith('/utxos')) {
          final hint = r.url.queryParameters['address'];
          return response({
            'network': 'testnet-10',
            'covenantIdsIncluded': true,
            'entries': inputs
                .where((i) => i['utxo']['address'] == hint)
                .map((i) => {
                      'outpoint': {
                        'transactionId': i['transactionId'],
                        'index': i['index']
                      },
                      'utxoEntry': {
                        'amount': i['utxo']['amount'],
                        'scriptPublicKey': {
                          'scriptPublicKey':
                              i['utxo']['scriptPublicKey'].substring(4)
                        },
                        'blockDaaScore': '123456',
                        'isCoinbase': false,
                        'covenantId':
                            badCid ? 'bb' * 32 : i['utxo']['covenantId']
                      }
                    })
                .toList()
          });
        }
        fail(
            'Live UTXO verification must not request transaction history: ${r.url}');
      });
      final service = KassealService(client: client);
      if (badCid) {
        await expectLater(
            service.verifyInputs(address, request), throwsStateError);
        continue;
      }
      await service.verifyInputs(address, request);
      final changed = jsonDecode('${request['txJsonString']}') as Map;
      expect(
          (changed['inputs'] as List)
              .every((i) => i['utxo']['blockDaaScore'] == '123456'),
          isTrue);
      expect(changed['id'], original['id']);
      final review = <String, Object?>{
        'inputs': inputs.map((i) => {'address': i['utxo']['address']}).toList()
      };
      await service.verifyInputs(address, request, review);
    }
  });
  test('Incomplete, wrong-network or altered live node state fails closed',
      () async {
    for (final mutation in [
      'network',
      'capability',
      'missingCid',
      'amount',
      'spk',
      'coinbase',
      'daa',
      'spent'
    ]) {
      final request =
          Map<String, Object?>.from(jsonDecode(jsonEncode(fixture)));
      final inputs =
          (jsonDecode('${request['txJsonString']}') as Map)['inputs'] as List;
      final service = KassealService(client: MockClient((r) async {
        final hint = r.url.queryParameters['address'];
        final entries =
            inputs.where((i) => i['utxo']['address'] == hint).map((i) {
          final utxo = i['utxo'] as Map;
          final live = <String, Object?>{
            'amount': mutation == 'amount' ? '1' : utxo['amount'],
            'scriptPublicKey': {
              'version': 0,
              'script': mutation == 'spk'
                  ? '00'
                  : '${utxo['scriptPublicKey']}'.substring(4)
            },
            'blockDaaScore': mutation == 'daa' ? null : '123456',
            'isCoinbase': mutation == 'coinbase',
            if (mutation != 'missingCid') 'covenantId': utxo['covenantId']
          };
          return {
            'outpoint': {
              'transactionId': i['transactionId'],
              'index': i['index']
            },
            'utxoEntry': live
          };
        }).toList();
        return response({
          'network': mutation == 'network' ? 'mainnet' : 'testnet-10',
          'covenantIdsIncluded': mutation != 'capability',
          'entries': mutation == 'spent' ? [] : entries
        });
      }));
      await expectLater(
          service.verifyInputs(address, request), throwsStateError,
          reason: mutation);
    }
  });
  test(
      'Unknown confirmation preserves the exact saved signed bytes and never starts another quote',
      () async {
    final store = MemoryStore(), service = KassealService(store: MemoryStore());
    final receipt = {
      'address': address,
      'network': 'testnet-10',
      'transactionId': 'd' * 64,
      'signedTxJson': '{"inputs":[]}'
    };
    await store.write(service.key(address), jsonEncode(receipt));
    var posts = 0;
    final failing = KassealService(
        store: store,
        client: MockClient((r) async {
          if (r.method == 'POST') posts++;
          return response({'error': 'unavailable'}, 503);
        }));
    await expectLater(failing.resume(address), throwsStateError);
    expect(await failing.pending(address), receipt);
    expect(posts, 0);
    await expectLater(failing.retain(address, receipt), throwsStateError);
  });
  test('Already accepted recovery records token activity without another POST',
      () async {
    final store = MemoryStore();
    var posts = 0;
    final service = KassealService(
        store: store,
        activity: ActivityStore(encryptedStore: store),
        client: MockClient((r) async {
          if (r.method == 'POST') posts++;
          return response({'transaction_id': 'd' * 64, 'is_accepted': true});
        }));
    await service.retain(address, {
      'address': address,
      'network': 'testnet-10',
      'transactionId': 'd' * 64,
      'signedTxJson': 'unused',
      'ticker': 'FIXTURE',
      'timestamp': '2026-10-22T12:00:00Z',
      'summary': {'side': 'buy', 'tokenId': id, 'tokenAmount': '6000'}
    });
    expect(await service.resume(address), 'd' * 64);
    expect(posts, 0);
    expect(await service.pending(address), isNull);
    final activity = await ActivityStore(encryptedStore: store).load(address);
    expect(activity.single.assetSymbol, 'FIXTURE');
  });
  test('Pruned input origins do not block submission of the exact saved bytes',
      () async {
    final store = MemoryStore();
    var submitted = false, posts = 0;
    final signed = jsonEncode({
      'inputs': [
        {'transactionId': 'a' * 64, 'index': 0}
      ]
    });
    final service = KassealService(
        store: store,
        activity: ActivityStore(encryptedStore: store),
        client: MockClient((r) async {
          if (r.method == 'POST') {
            posts++;
            expect(jsonDecode(r.body)['txJson'], signed);
            submitted = true;
            return response({'transactionId': 'd' * 64});
          }
          if (r.url.path.endsWith('/${'d' * 64}') && submitted) {
            return response({'transaction_id': 'd' * 64, 'is_accepted': true});
          }
          return response({'detail': 'Transaction not found'}, 404);
        }));
    await service.retain(address, {
      'address': address,
      'network': 'testnet-10',
      'transactionId': 'd' * 64,
      'signedTxJson': signed,
      'ticker': 'FIXTURE',
      'timestamp': '2026-10-22T12:00:00Z',
      'summary': {'side': 'buy', 'tokenId': id, 'tokenAmount': '6000'}
    });
    expect(await service.resume(address), 'd' * 64);
    expect(posts, 1);
    expect(await service.pending(address), isNull);
    expect(store.data.containsKey('${service.key(address)}_obsolete'), false);
  });
  test(
      'Only an independently accepted exact conflicting outpoint archives a stale swap',
      () async {
    final store = MemoryStore(),
        origin = 'a' * 64,
        saved = 'd' * 64,
        rival = 'b' * 64;
    final input = {'transactionId': origin, 'index': 2};
    final service = KassealService(
        store: store,
        client: MockClient((r) async {
          if (r.url.path.endsWith('/$saved')) return response({}, 404);
          if (r.url.path.endsWith('/$origin'))
            return response({
              'transaction_id': origin,
              'is_accepted': true,
              'outputs': [
                {'index': 2, 'script_public_key_address': address}
              ]
            });
          final other = {
            'transaction_id': rival,
            'is_accepted': true,
            'inputs': [
              {'previous_outpoint_hash': origin, 'previous_outpoint_index': '2'}
            ]
          };
          if (r.url.path.endsWith('/full-transactions'))
            return response([other]);
          return response(other);
        }));
    await service.retain(address, {
      'address': address,
      'network': 'testnet-10',
      'transactionId': saved,
      'signedTxJson': jsonEncode({
        'inputs': [input]
      })
    });
    expect(await service.retireConflict(address), isTrue);
    expect(await service.pending(address), isNull);
    expect(store.data['${service.key(address)}_obsolete'], contains(rival));
  });
}
