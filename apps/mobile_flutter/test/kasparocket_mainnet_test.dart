import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kasvault_wallet/src/services/kasparocket_service.dart';
import 'package:kasvault_wallet/src/services/encrypted_store.dart';
import 'package:kasvault_wallet/src/services/activity_store.dart';

class MemoryStore implements EncryptedStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  const wallet = 'kaspa:qfixture';
  final origin = 'a' * 64, savedId = 'c' * 64, competing = 'b' * 64;
  Map<String, Object?> savedSwap({int next = 0}) => {
        'network': 'mainnet',
        'address': wallet,
        'next': next,
        'transactionIds': [savedId],
        'receipts': <Object?>[],
        'signed': [
          {
            'inputs': [
              {
                'previousOutpoint': {'transactionId': origin, 'index': 0},
                'utxo': {'covenantId': 'd' * 64},
              }
            ]
          }
        ],
      };
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('Mainnet uses only the pinned gateway, never client bearer credentials',
      () async {
    final paths = <String>[];
    final service = KaspaRocketService(
        mainnet: true,
        apiKey: 'must-not-leave-client',
        client: MockClient((request) async {
          expect(request.url.host, 'kaspire.kaslab.space');
          expect(request.headers.containsKey('authorization'), isFalse);
          paths.add(request.url.path);
          return http.Response(
              jsonEncode(request.url.path.endsWith('/protocol')
                  ? {'network': 'mainnet'}
                  : request.url.path.endsWith('/tokens')
                      ? []
                      : {'tokens': []}),
              200);
        }));
    expect(await service.tokens(), isEmpty);
    expect(paths.first, '/api/kasparocket/pro-api/protocol');
    expect(service.networkId, 'mainnet');
  });
  test('TN10 rejects an upstream silently switched to Mainnet', () async {
    var calls = 0;
    final service = KaspaRocketService(
        apiKey: 'krpub_test_fixture',
        client: MockClient((_) async {
          calls++;
          return http.Response('{"network":"mainnet"}', 200);
        }));
    await expectLater(service.tokens(), throwsStateError);
    expect(calls, 1);
  });
  test('Mainnet rejects testnet plans before the route endpoint is called',
      () async {
    var calls = 0;
    final service = KaspaRocketService(
        mainnet: true,
        client: MockClient((_) async {
          calls++;
          return http.Response('{"network":"mainnet"}', 200);
        }));
    await expectLater(
        service.plan(
            address: 'kaspatest:qfixture',
            tokenId: 'a' * 64,
            poolId: 'b' * 64,
            side: 'buy',
            rawAmount: '100'),
        throwsStateError);
    expect(calls, 1);
  });
  test('Recovery is wallet/network-bound and accepted swaps never resubmit',
      () async {
    final store = MemoryStore();
    var posts = 0;
    final service = KaspaRocketService(
        mainnet: true,
        store: store,
        client: MockClient((request) async {
          if (request.method == 'POST') posts++;
          return http.Response('{"network":"mainnet"}', 200);
        }));
    const wallet = 'kaspa:qfixture';
    await service.retain(wallet, {
      'network': 'mainnet',
      'address': wallet,
      'signed': [<String, Object?>{}],
      'transactionIds': ['c' * 64],
      'receipts': <Object?>[],
      'next': 0,
      'side': 'buy',
      'token': 'ROCKET',
      'tokenCovenant': 'a' * 64,
      'summary': {'amountTokens': '1000'},
      'timestamp': DateTime.utc(2026).toIso8601String(),
    });
    expect(await service.pending('kaspa:qother'), isNull);
    expect(await KaspaRocketService(store: store).pending(wallet), isNull);
    final result = await service.resume(wallet,
        accepted: (_) async => true,
        activity: ActivityStore(encryptedStore: store));
    expect(result['next'], 1);
    expect(posts, 0);
    expect(await service.pending(wallet), isNull);
    final activity = await ActivityStore(encryptedStore: store).load(wallet);
    expect(activity.single.assetSymbol, 'ROCKET');
    expect(activity.single.displayAmount, '1');
  });
  test('Failed submit keeps the exact signed swap for retry', () async {
    final store = MemoryStore();
    var posts = 0;
    final service = KaspaRocketService(
        mainnet: true,
        store: store,
        client: MockClient((request) async {
          if (request.method == 'POST') {
            posts++;
            return http.Response('{"error":"offline"}', 503);
          }
          return http.Response('{"network":"mainnet"}', 200);
        }));
    await service.retain('kaspa:qfixture', {
      'network': 'mainnet',
      'address': 'kaspa:qfixture',
      'signed': [
        {'signatureScript': 'signed-bytes'}
      ],
      'transactionIds': ['c' * 64],
      'receipts': <Object?>[],
      'next': 0,
    });
    await expectLater(
        service.resume('kaspa:qfixture',
            accepted: (_) async => false, conflict: (_, __) async => null),
        throwsStateError);
    expect(posts, 1);
    expect((await service.pending('kaspa:qfixture'))!['signed'], [
      {'signatureScript': 'signed-bytes'}
    ]);
  });
  for (final scenario in [
    'confirmed-conflict',
    'unaccepted-conflict',
    'different-output',
    'own-transaction',
    'rate-limit',
    'empty-history'
  ]) {
    test('Own-node stale-plan proof: $scenario', () async {
      final store = MemoryStore();
      var posts = 0;
      final candidate = scenario == 'own-transaction' ? savedId : competing;
      final spends = {
        'previous_outpoint_hash': origin,
        'previous_outpoint_index': scenario == 'different-output' ? '1' : '0'
      };
      final service = KaspaRocketService(
          mainnet: true,
          store: store,
          client: MockClient((request) async {
            if (request.method == 'POST') posts++;
            if (scenario == 'rate-limit') return http.Response('{}', 429);
            if (request.url.path.endsWith('/transactions/$origin')) {
              return http.Response(
                  jsonEncode({
                    'transaction_id': origin,
                    'is_accepted': true,
                    'outputs': [
                      {'index': 0, 'script_public_key_address': 'kaspa:qpool'}
                    ]
                  }),
                  200);
            }
            if (request.url.path.endsWith('/full-transactions')) {
              return http.Response(
                  jsonEncode(scenario == 'empty-history'
                      ? []
                      : [
                          {
                            'transaction_id': candidate,
                            'inputs': [spends]
                          }
                        ]),
                  200);
            }
            return http.Response(
                jsonEncode({
                  'transaction_id': candidate,
                  'is_accepted': scenario != 'unaccepted-conflict',
                  'inputs': [spends]
                }),
                200);
          }));
      await service.retain(wallet, savedSwap());
      if (scenario == 'rate-limit') {
        await expectLater(
            service.retireConflictedSwap(wallet, accepted: (_) async => false),
            throwsStateError);
      } else {
        expect(
            await service.retireConflictedSwap(wallet,
                accepted: (_) async => false),
            scenario == 'confirmed-conflict');
      }
      expect(posts, 0);
      if (scenario == 'confirmed-conflict') {
        expect(await service.pending(wallet), isNull);
        final archive = jsonDecode(store.values.values.single) as Map;
        expect(archive['conflictingTransactionId'], competing);
        expect(archive['signed'], savedSwap()['signed']);
      } else {
        expect(await service.pending(wallet), savedSwap());
      }
    });
  }
  test('Existing stale journals become refreshable without another broadcast',
      () async {
    final store = MemoryStore();
    var calls = 0;
    final service = KaspaRocketService(
        mainnet: true,
        store: store,
        client: MockClient((_) async {
          calls++;
          throw StateError('Must not broadcast');
        }));
    await service.retain(wallet, savedSwap());
    await expectLater(
        service.resume(wallet,
            accepted: (_) async => false,
            conflict: (_, ids) async {
              expect(ids, {savedId});
              return competing;
            }),
        throwsA(isA<KaspaRocketQuoteExpired>()));
    expect(calls, 0);
    expect(await service.pending(wallet), isNull);
  });
  test('A fresh submit conflict archives only after independent proof, once',
      () async {
    final store = MemoryStore();
    var posts = 0;
    final service = KaspaRocketService(
        mainnet: true,
        store: store,
        client: MockClient((request) async {
          if (request.method == 'POST') {
            posts++;
            return http.Response(
                '{"error":{"message":"selected pool input spent"}}', 409);
          }
          return http.Response('{"network":"mainnet"}', 200);
        }));
    await service.retain(wallet, savedSwap());
    await expectLater(
        service.resume(wallet,
            checkConflict: false,
            accepted: (_) async => false,
            conflict: (_, __) async => competing),
        throwsA(isA<KaspaRocketQuoteExpired>()));
    expect(posts, 1);
    expect(await service.pending(wallet), isNull);
  });
  test('409 alone never releases a signed swap and preserves provider details',
      () async {
    final store = MemoryStore();
    var posts = 0;
    final service = KaspaRocketService(
        mainnet: true,
        store: store,
        client: MockClient((request) async {
          if (request.method == 'POST') {
            posts++;
            return http.Response(
                '{"error":{"message":"node rejected transaction for another reason"}}',
                409);
          }
          return http.Response('{"network":"mainnet"}', 200);
        }));
    await service.retain(wallet, savedSwap());
    await expectLater(
        service.resume(wallet,
            checkConflict: false,
            accepted: (_) async => false,
            conflict: (_, __) async => null),
        throwsA(isA<KaspaRocketConflict>().having(
            (e) => e.detail, 'provider error', contains('another reason'))));
    expect(posts, 1);
    expect(await service.pending(wallet), savedSwap());
  });
  test('Partial multi-transaction plans are never discarded as a fresh swap',
      () async {
    final store = MemoryStore();
    final service = KaspaRocketService(mainnet: true, store: store);
    await service.retain(wallet, savedSwap(next: 1));
    expect(
        await service.retireConflictedSwap(wallet,
            accepted: (_) async => false, conflict: (_, __) async => competing),
        isFalse);
    expect(await service.pending(wallet), isNotNull);
  });
  test('Acceptance arriving during conflict lookup keeps the signed journal',
      () async {
    final store = MemoryStore();
    var checks = 0;
    final service = KaspaRocketService(mainnet: true, store: store);
    await service.retain(wallet, savedSwap());
    expect(
        await service.retireConflictedSwap(wallet,
            accepted: (_) async => ++checks > 1,
            conflict: (_, __) async => competing),
        isFalse);
    expect(await service.pending(wallet), isNotNull);
  });
}
