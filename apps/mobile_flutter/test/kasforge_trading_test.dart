import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/kasforge_trading.dart';
import 'package:kasvault_wallet/src/services/encrypted_store.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/services/braid_service.dart';
import 'package:kasvault_wallet/src/kaspa_address.dart';
import 'package:kasvault_wallet/src/services/native_security.dart';

const address =
    'kaspatest:qp2srppaehqgjxxw4fyf2ckdzha9nz573eapxw0acg4ntc27cy2w23jck27ql';

class Memory implements EncryptedStore {
  final data = <String, String>{};
  bool fail = false;
  @override
  Future<String?> read(String k) async => data[k];
  @override
  Future<void> write(String k, String v) async {
    if (!fail) data[k] = v;
  }

  @override
  Future<void> delete(String k) async {
    data.remove(k);
  }
}

Map<String, dynamic> unsignedTx() => {
      'version': 1,
      'inputs': [
        {
          'transactionId': 'd' * 64,
          'index': 0,
          'signatureScript': '',
          'utxo': {'amount': '200000000'}
        }
      ],
      'outputs': [
        {'value': '100000000', 'scriptPublicKey': '00'}
      ],
    };

class ReviewSecurity extends NativeSecurity {
  ReviewSecurity({this.id, this.hash});
  final String? id, hash;
  @override
  Future<Map<String, Object?>> preparePskt(Map<String, Object?> request,
          {bool kaspacomReview = false}) async =>
      {'transactionId': id ?? 'a' * 64, 'reviewHash': hash ?? 'review'};
}

Map<String, dynamic> receipt() => {
      'buildId': 'fixture',
      'address': address,
      'network': 'testnet-10',
      'signed': [
        jsonEncode({
          ...unsignedTx(),
          'inputs': [
            {
              ...(unsignedTx()['inputs'] as List).first as Map,
              'signatureScript': '410001',
            }
          ]
        })
      ],
      'requests': [
        {
          'sender': address,
          'profile': 'kasforge-tn10-order-v1',
          'txJsonString': jsonEncode(unsignedTx()),
          'signInputs': [
            {'index': 0, 'sighashType': 1}
          ]
        }
      ],
      'reviews': [
        {'reviewHash': 'review'}
      ],
      'transactionIds': ['a' * 64],
      'side': 'sell',
      'state': 'signed',
      'order': <String, dynamic>{
        'output': {'outpoint': '${'a' * 64}:2', 'sompi': 100000000},
        'state': {'unitsIn': null, 'minSompi': 100000000, 'kcc20': 'b' * 64}
      }
    };
Map<String, dynamic> fundingReceipt() {
  final r = receipt()..['side'] = 'buy';
  final tx = jsonDecode('${r['requests'][0]['txJsonString']}') as Map;
  tx['inputs'][0]['utxo']['scriptPublicKey'] =
      '000020${kaspaOwnerIdFromAddress(address)}ac';
  tx['inputs'][0]['utxo']['covenantId'] = null;
  tx['inputs'][0]['utxo']['isCoinbase'] = false;
  r['requests'][0]['txJsonString'] = jsonEncode(tx);
  return r;
}

class FundingTrading extends KasForgeTrading {
  FundingTrading() : super(store: Memory());
  int reads = 0;
  @override
  Future<List> live(String address) async {
    reads++;
    return [
      {
        'outpoint': {'transactionId': 'd' * 64, 'index': 0},
        'utxoEntry': {
          'amount': '200000000',
          'isCoinbase': false,
          'covenantId': null,
          'blockDaaScore': '100',
          'scriptPublicKey': {
            'version': 0,
            'script': '20${kaspaOwnerIdFromAddress(address)}ac'
          }
        }
      }
    ];
  }
}

void main() {
  setUp(() => NetworkSettings.network.value = KaspaNetwork.tn10);
  test('Forge amounts never pass through floating point or scientific notation',
      () {
    expect(KasForgeTrading.kasSompi('10.00000001'), BigInt.from(1000000001));
    for (final text in ['1e3', '-1', '1.000000001', 'NaN', '1,000']) {
      expect(() => KasForgeTrading.kasSompi(text), throwsStateError);
    }
  });
  test('Mainnet fails before any build or HTTP call', () async {
    var calls = 0;
    final trading = KasForgeTrading(client: MockClient((_) async {
      calls++;
      return http.Response('{}', 200);
    }));
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    await expectLater(
        trading.call(address, 'build', body: {}), throwsStateError);
    expect(calls, 0);
  });
  test('saved journals survive failed submit and reopening', () async {
    final store = Memory();
    final trading = KasForgeTrading(
        security: ReviewSecurity(),
        store: store,
        client: MockClient((_) async =>
            http.Response(jsonEncode({'error': 'build expired'}), 409)));
    final r = receipt();
    await trading.retain(address, r);
    await expectLater(trading.submit(address, r), throwsStateError);
    expect((await KasForgeTrading(store: store).pending(address))!['signed'],
        r['signed']);
  });
  for (final failure in ['reject', 'timeout', 'malformed']) {
    test('submit $failure never broadcasts a signed deposit directly',
        () async {
      final store = Memory(), calls = <Uri>[];
      final r = receipt()..['signedWrpc'] = ['{"saved":"exact bytes"}'];
      final trading = KasForgeTrading(
          security: ReviewSecurity(),
          store: store,
          client: MockClient((request) async {
            calls.add(request.url);
            expect(request.url.path, '/api/v1/submit');
            if (failure == 'timeout') throw http.ClientException('timeout');
            return failure == 'reject'
                ? http.Response('{"error":"build expired","ok":false}', 409)
                : http.Response('not json', 502);
          }));
      await expectLater(trading.submit(address, r), throwsA(isA<Object>()));
      expect(calls, hasLength(1));
      final reopened = (await KasForgeTrading(store: store).pending(address))!;
      expect(reopened['signed'], r['signed']);
      expect(reopened['signedWrpc'], r['signedWrpc']);
      expect(reopened['submissionError'], isNotEmpty);
      if (failure == 'reject') {
        expect(reopened['submissionError'], contains('build expired'));
      }
      expect(reopened['finalVerified'], isNot(true));
      expect(reopened['state'], isNot('deposited-untracked'));
    });
  }
  test('retry uses the exact saved build and signatures and clears old error',
      () async {
    final r = receipt()..['submissionError'] = 'earlier failure';
    final trading = KasForgeTrading(
        security: ReviewSecurity(),
        store: Memory(),
        client: MockClient((request) async {
          expect(request.url.path, '/api/v1/submit');
          final body = jsonDecode(request.body) as Map;
          expect(body['buildId'], r['buildId']);
          final tx = jsonDecode(body['signed'][0] as String) as Map;
          expect(tx['id'], 'a' * 64);
          expect(tx['inputs'][0]['signatureScript'], '410001');
          return http.Response(jsonEncode({'ok': true, 'txid': 'a' * 64}), 200);
        }));
    await trading.submit(address, r);
    expect(r['submissionError'], isNull);
    expect(r['state'], 'deposited');
    expect(r['finalVerified'], isNot(true));
  });
  for (final change in [
    'wrong-id',
    'output',
    'input',
    'missing-signature',
    'native-id',
    'review'
  ]) {
    test('submission metadata repair rejects $change before any HTTP',
        () async {
      final r = receipt(), store = Memory();
      final tx = jsonDecode(r['signed'][0] as String) as Map;
      if (change == 'wrong-id') tx['id'] = 'f' * 64;
      if (change == 'output') tx['outputs'][0]['value'] = '99999999';
      if (change == 'input') tx['inputs'][0]['utxo']['amount'] = '200000001';
      if (change == 'missing-signature') {
        tx['inputs'][0]['signatureScript'] = '';
      }
      r['signed'] = [jsonEncode(tx)];
      final before = jsonEncode(r);
      var calls = 0;
      final trading = KasForgeTrading(
          store: store,
          security: ReviewSecurity(
              id: change == 'native-id' ? 'f' * 64 : null,
              hash: change == 'review' ? 'different' : null),
          client: MockClient((_) async {
            calls++;
            return http.Response('{}', 200);
          }));
      await trading.retain(address, r);
      await expectLater(trading.submit(address, r), throwsStateError);
      expect(calls, 0);
      expect(jsonEncode(r), before);
      expect(await trading.pending(address), isNotNull);
    });
  }
  for (final outcome in [
    'unspent',
    'spent',
    'mismatch',
    'unknown',
    'offline'
  ]) {
    test('missing Forge order with $outcome deposit never means completed',
        () async {
      final r = receipt(), store = Memory();
      final hash = BraidService.scriptHash('51');
      r['order']['address'] =
          kaspaScriptHashAddress(hash.substring(8, 72), prefix: 'kaspatest');
      r['order']['redeemScript'] = '51';
      r['tokenId'] = 'b' * 64;
      final calls = <Uri>[];
      final trading = KasForgeTrading(
          store: store,
          client: MockClient((request) async {
            calls.add(request.url);
            if (request.url.host == 'kaspa.pumpforge.tech') {
              expect(request.url.queryParameters['market'], 'b' * 64);
              return http.Response('{"error":"no such order","ok":false}', 400);
            }
            if (request.url.host == 'api-tn10.kaspa.org') {
              return http.Response(
                  jsonEncode({
                    'transaction_id': 'a' * 64,
                    'is_accepted': outcome != 'unknown',
                  }),
                  200);
            }
            expect(request.url.host, 'kaspire.kaslab.space');
            if (outcome == 'offline') return http.Response('{}', 503);
            return http.Response(
                jsonEncode({
                  'network': 'testnet-10',
                  'covenantIdsIncluded': true,
                  'entries': outcome == 'spent'
                      ? []
                      : [
                          {
                            'outpoint': {'transactionId': 'a' * 64, 'index': 2},
                            'utxoEntry': {
                              'amount':
                                  outcome == 'mismatch' ? '1' : '100000000',
                              'covenantId': null,
                              'isCoinbase': false,
                              'scriptPublicKey': {
                                'version': 0,
                                'script': hash.substring(4)
                              },
                            }
                          }
                        ],
                }),
                200);
          }));
      await trading.retain(address, r);
      if (outcome == 'unspent') {
        final result = await trading.status(address, r);
        expect(result['status'], 'deposited-untracked');
        expect(result['message'], contains('not a completed trade'));
      } else {
        await expectLater(trading.status(address, r), throwsStateError);
        expect(r['state'], isNot('deposited-untracked'));
      }
      expect(calls.every((u) => !u.path.contains('submit')), isTrue);
      expect(r['finalVerified'], isNot(true));
      expect(await KasForgeTrading(store: store).pending(address), isNotNull);
    });
  }
  test(
      'failed durable save stops submission before HTTP and rejects another wallet',
      () async {
    var calls = 0;
    final store = Memory()..fail = true;
    final trading = KasForgeTrading(
        security: ReviewSecurity(),
        store: store,
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }));
    await expectLater(trading.submit(address, receipt()), throwsStateError);
    expect(calls, 0);
    await expectLater(
        trading.retain(address, {...receipt(), 'address': 'foreign'}),
        throwsStateError);
  });
  test(
      'API success cannot finish an order without exact accepted on-chain spend',
      () async {
    final store = Memory(), r = receipt();
    final trading = KasForgeTrading(
        store: store,
        client: MockClient((request) async => http.Response(
            jsonEncode(request.url.host == 'api-tn10.kaspa.org'
                ? {
                    'transaction_id': 'c' * 64,
                    'is_accepted': true,
                    'inputs': [],
                    'outputs': []
                  }
                : {'ok': true, 'status': 'filled', 'txid': 'c' * 64}),
            200)));
    await trading.retain(address, r);
    await expectLater(trading.status(address, r), throwsStateError);
    expect(r['finalVerified'], isNot(true));
    expect(await trading.pending(address), isNotNull);
  });
  test('per-wallet operation lock releases after an authorization error',
      () async {
    final trading = KasForgeTrading();
    await expectLater(
        trading.exclusive(address, () async => throw StateError('cancelled')),
        throwsStateError);
    expect(await trading.exclusive(address, () async => 42), 42);
  });
  test('unconfirmed buy recovery returns exact verified funding to self only',
      () async {
    final r = fundingReceipt(), trading = FundingTrading();
    final before = jsonEncode(r);
    final request = await trading.fundingReturn(address, r);
    final tx = jsonDecode('${request['txJsonString']}') as Map;
    expect(
        request['profile'], isNull); // existing P2PK path, no new token profile
    expect(tx['inputs'][0]['transactionId'], 'd' * 64);
    expect(tx['inputs'][0]['signatureScript'], '');
    expect(tx['outputs'], [
      {
        'value': '190000000',
        'scriptPublicKey': '000020${kaspaOwnerIdFromAddress(address)}ac'
      }
    ]);
    expect(request['signInputs'], [
      {'index': 0, 'sighashType': 1}
    ]);
    expect(trading.reads, 1);
    expect(jsonEncode(r), before);
  });
  for (final unsupported in [
    'sell',
    'multi-step',
    'token-input',
    'foreign-owner'
  ]) {
    test('funding recovery does not broaden $unsupported support', () async {
      final r = fundingReceipt(), trading = FundingTrading();
      if (unsupported == 'sell') r['side'] = 'sell';
      if (unsupported == 'multi-step') r['requests'].add(r['requests'][0]);
      final tx = jsonDecode('${r['requests'][0]['txJsonString']}') as Map;
      if (unsupported == 'token-input') {
        tx['inputs'][0]['utxo']['covenantId'] = 'f' * 64;
      }
      if (unsupported == 'foreign-owner') {
        tx['inputs'][0]['utxo']['scriptPublicKey'] = '000020${'f' * 64}ac';
      }
      r['requests'][0]['txJsonString'] = jsonEncode(tx);
      await expectLater(trading.fundingReturn(address, r), throwsStateError);
      expect(trading.reads, 0);
    });
  }
  for (final outcome in [
    'accepted',
    'missing',
    'wrong-input',
    'wrong-output',
    'wrong-amount'
  ]) {
    test(
        'funding invalidation $outcome clears blocking journal only with exact accepted proof',
        () async {
      final r = fundingReceipt()
        ..['cancelId'] = 'c' * 64
        ..['cancelKind'] = 'invalidate-funding';
      final store = Memory();
      final trading = KasForgeTrading(
          store: store,
          client: MockClient((request) async {
            expect(request.url.host, 'api-tn10.kaspa.org');
            expect(request.method, 'GET');
            return http.Response(
                jsonEncode({
                  'transaction_id': 'c' * 64,
                  'is_accepted': outcome != 'missing',
                  'inputs': [
                    {
                      'previous_outpoint_hash':
                          (outcome == 'wrong-input' ? 'e' : 'd') * 64,
                      'previous_outpoint_index': 0
                    }
                  ],
                  'outputs': [
                    {
                      'amount':
                          outcome == 'wrong-amount' ? '189999999' : '190000000',
                      'script_public_key':
                          '20${outcome == 'wrong-output' ? 'f' * 64 : kaspaOwnerIdFromAddress(address)}ac'
                    }
                  ],
                }),
                200);
          }));
      await trading.retain(address, r);
      final result = await trading.status(address, r);
      expect(result['status'],
          outcome == 'accepted' ? 'cancelled' : 'cancellation-pending');
      expect(await trading.pending(address),
          outcome == 'accepted' ? isNull : isNotNull);
      expect(
          (await trading.saved(address)), hasLength(1)); // never erase recovery
      expect(r['finalVerified'] == true, outcome == 'accepted');
    });
  }
  test(
      'deposit winning the invalidation race reopens contract recovery without losing signed attempts',
      () async {
    final r = fundingReceipt()
      ..['cancelId'] = 'c' * 64
      ..['cancelSigned'] = 'saved-self-return'
      ..['cancelKind'] = 'invalidate-funding';
    final trading = KasForgeTrading(
        store: Memory(),
        client: MockClient((request) async {
          if (request.url.host == 'kaspa.pumpforge.tech') {
            return http.Response('{"ok":true,"status":"open"}', 200);
          }
          final deposit = request.url.path.endsWith('a' * 64);
          return http.Response(
              jsonEncode({
                'transaction_id': (deposit ? 'a' : 'c') * 64,
                'is_accepted': deposit
              }),
              200);
        }));
    await trading.status(address, r);
    expect(r['cancelId'], isNull);
    expect(r['cancelSigned'], isNull);
    expect(r['fundingInvalidationAttempt']['signed'], 'saved-self-return');
    expect(r['state'], 'deposited');
    expect(r['finalVerified'], isNot(true));
    expect(await trading.pending(address), isNotNull);
  });
}
