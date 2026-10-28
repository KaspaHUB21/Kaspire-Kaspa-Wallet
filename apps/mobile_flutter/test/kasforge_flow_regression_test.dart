import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/kasforge_trading.dart';
import 'package:kasvault_wallet/src/services/kasforge_service.dart';
import 'package:kasvault_wallet/src/services/native_security.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/services/braid_service.dart';
import 'package:kasvault_wallet/src/kaspa_address.dart';
import 'kasforge_trading_test.dart' as fixtures;
import 'kasforge_trading_live_test.dart' show Inspector;

class SettlementTrading extends KasForgeTrading {
  SettlementTrading(http.Client client)
      : super(client: client, store: fixtures.Memory());
  int verifications = 0;
  @override
  Future<void> verifyFinal(String address, Map<String, dynamic> receipt,
      String id, bool filled) async {
    if (++verifications == 1) throw KasForgeConfirmationPending();
  }
}

class RecoverySecurity extends NativeSecurity {
  int signs = 0;
  @override
  Future<Map<String, Object?>> preparePskt(Map<String, Object?> request,
          {bool kaspacomReview = false}) async =>
      {
        'transactionId': request['profile'] == null
            ? 'c' * 64
            : jsonDecode('${request['txJsonString']}')['id'] ?? 'a' * 64,
        'reviewHash': 'review',
        'feeSompi': '10000000'
      };
  @override
  Future<Map<String, Object?>> signPskt(
      Map<String, Object?> request, String reviewHash,
      {bool kaspacomReview = false}) async {
    signs++;
    return {'transactionId': 'c' * 64, 'wrpcJson': request['txJsonString']};
  }
}

class RecoveryTrading extends KasForgeTrading {
  RecoveryTrading(this.auth) : super(store: fixtures.Memory(), security: auth);
  final RecoverySecurity auth;
  final acceptedIds = <String>{};
  final broadcasts = <String>[];
  @override
  Future<bool> accepted(String id) async => acceptedIds.contains(id);
  @override
  Future<List> live(String address) async {
    final rows = await fixtures.FundingTrading().live(address);
    if (acceptedIds.contains('a' * 64)) {
      final change = jsonDecode(jsonEncode(rows.first)) as Map;
      change['outpoint']['transactionId'] = 'a' * 64;
      rows.add(change);
    }
    return rows;
  }

  @override
  Future<void> broadcastSaved(Map tx, String id) async {
    broadcasts.add(id);
    acceptedIds.add(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => NetworkSettings.network.value = KaspaNetwork.tn10);
  test(
      'full covenant witness becomes SDK owner signature without changing saved node bytes',
      () async {
    final r = fixtures.receipt();
    final sig = fixtures.ownerSignature;
    final descriptor = {
      'inputIndex': 0,
      'scriptHex': '51',
      'signatureScript': {
        'mode': 'ordered-args',
        'args': [
          {'type': 'data', 'hex': ''},
          {'type': 'data', 'hex': 'aa'},
          {'type': 'signature', 'prefixHex': '00'},
          {'type': 'data', 'hex': '79c71c23'}
        ]
      }
    };
    r['requests'][0]['scripts'] = [descriptor];
    final tx = jsonDecode(r['signed'][0] as String) as Map;
    final full =
        '00${BraidService.push('aa')}${BraidService.push('00$sig')}${BraidService.push('79c71c23')}${BraidService.push('51')}';
    tx['inputs'][0]['signatureScript'] = full;
    r['signed'] = [jsonEncode(tx)];
    r['signedWrpc'] = ['untouched-full-node-bytes'];
    final trade = KasForgeTrading(
        store: fixtures.Memory(),
        security: fixtures.ReviewSecurity(),
        client: MockClient((request) async {
          final data = jsonDecode(request.body) as Map;
          final apiTx = jsonDecode(data['signed'][0] as String) as Map;
          expect(apiTx['id'], 'a' * 64);
          expect(apiTx['inputs'][0]['signatureScript'], '41$sig');
          return http.Response(jsonEncode({'ok': true, 'txid': 'a' * 64}), 200);
        }));
    await trade.submit(fixtures.address, r);
    expect(jsonDecode(r['signed'][0] as String)['inputs'][0]['signatureScript'],
        full);
    expect(r['signedWrpc'], ['untouched-full-node-bytes']);
  });
  for (final change in ['prefix', 'argument', 'redeem', 'sighash']) {
    test('reject malformed covenant API envelope: $change', () {
      final sig = '${'11' * 64}${change == 'sighash' ? '84' : '01'}';
      final descriptor = {
        'scriptHex': '51',
        'signatureScript': {
          'mode': 'ordered-args',
          'args': [
            {'type': 'data', 'hex': 'aa'},
            {'type': 'signature', 'prefixHex': '00'}
          ]
        }
      };
      final witness = '${BraidService.push(change == 'argument' ? 'bb' : 'aa')}'
          '${BraidService.push('${change == 'prefix' ? '01' : '00'}$sig')}'
          '${BraidService.push(change == 'redeem' ? '52' : '51')}';
      expect(() => KasForgeTrading.forgeSignatureEnvelope(witness, descriptor),
          throwsStateError);
    });
  }
  test(
      'filled before independent acceptance is pending, then completes without a new submit',
      () async {
    var posts = 0;
    final t = SettlementTrading(MockClient((request) async {
      if (request.method == 'POST') posts++;
      return http.Response(
          jsonEncode({'ok': true, 'status': 'filled', 'txid': 'c' * 64}), 200);
    }));
    final r = fixtures.receipt();
    expect((await t.status(fixtures.address, r))['status'],
        'verification-pending');
    expect(r['finalVerified'], isNot(true));
    expect((await t.status(fixtures.address, r))['status'], 'filled');
    expect(r['finalVerified'], isTrue);
    expect(posts, 0);
  });
  for (final missing in [true, false]) {
    test('independent completion waits safely (404: $missing)', () async {
      final t = KasForgeTrading(
          store: fixtures.Memory(),
          client: MockClient((r) async {
            if (r.url.host == 'api-tn10.kaspa.org') {
              return http.Response(
                  missing
                      ? 'not indexed yet'
                      : jsonEncode(
                          {'transaction_id': 'c' * 64, 'is_accepted': false}),
                  missing ? 404 : 200);
            }
            return http.Response(
                jsonEncode({'ok': true, 'status': 'filled', 'txid': 'c' * 64}),
                200);
          }));
      final r = fixtures.receipt();
      expect((await t.status(fixtures.address, r))['status'],
          'verification-pending');
      expect(r['finalVerified'], isNot(true));
      expect(await t.pending(fixtures.address), isNotNull);
    });
  }
  test(
      'expired sell invalidates only wallet KAS, leaving token inputs untouched',
      () async {
    final r = fixtures.fundingReceipt()..['side'] = 'sell';
    final raw = jsonDecode(r['requests'][0]['txJsonString'] as String) as Map;
    raw['inputs'].insert(0, {
      'transactionId': 'f' * 64,
      'index': 1,
      'signatureScript': '',
      'utxo': {
        'amount': '100000000',
        'scriptPublicKey': '0000aa20${'f' * 64}87',
        'covenantId': 'b' * 64
      }
    });
    r['requests'][0]['txJsonString'] = jsonEncode(raw);
    final request =
        await fixtures.FundingTrading().fundingReturn(fixtures.address, r);
    final back = jsonDecode('${request['txJsonString']}') as Map;
    expect(back['inputs'], hasLength(1));
    expect(back['inputs'][0]['transactionId'], 'd' * 64);
    expect(back['outputs'][0]['value'], '190000000');
    expect(raw['inputs'], hasLength(2));
  });
  test(
      'unsigned expired preparation archives without moving funds or deleting journal',
      () async {
    final auth = RecoverySecurity();
    final t = RecoveryTrading(auth);
    final r = fixtures.receipt()
      ..['signed'] = <String>[]
      ..['signedWrpc'] = <String>[]
      ..['state'] = 'prepared';
    await t.cancelAndSubmit(fixtures.address, r);
    expect(r['finalVerified'], isTrue);
    expect(await t.pending(fixtures.address), isNull);
    expect(await t.saved(fixtures.address), hasLength(1));
    expect(t.broadcasts, isEmpty);
    expect(auth.signs, 0);
  });
  test(
      'sell request expiry still allows exact cash invalidation through existing P2PK signer',
      () async {
    final auth = RecoverySecurity(),
        r = fixtures.fundingReceipt()..['side'] = 'sell';
    final t = RecoveryTrading(auth);
    // Keep this synthetic signed sample aligned with its reviewed unsigned body.
    final raw = jsonDecode(r['requests'][0]['txJsonString'] as String) as Map;
    raw['inputs'][0]['signatureScript'] = '41${fixtures.ownerSignature}';
    r['signed'] = [jsonEncode(raw)];
    await t.cancelAndSubmit(fixtures.address, r);
    expect(auth.signs, 1);
    expect(t.broadcasts, ['c' * 64]);
    expect(r['cancelKind'], 'invalidate-funding');
    expect(r['fundingReturnTerms']['points'], ['${'d' * 64}:0']);
    expect(r['finalVerified'],
        isNot(true)); // accepted payout still must be checked
  });
  for (final partial in [false, true]) {
    test(
        'multi-step sell recovery never broadcasts deposit (partial: $partial)',
        () async {
      final auth = RecoverySecurity();
      final t = RecoveryTrading(auth);
      final r = fixtures.fundingReceipt()..['side'] = 'sell';
      final original = r['requests'][0] as Map;
      final requests = <Map>[], signed = <String>[];
      for (var i = 0; i < 2; i++) {
        final raw = jsonDecode('${original['txJsonString']}') as Map;
        raw['id'] = (i == 0 ? 'a' : 'b') * 64;
        raw['inputs'][0]['transactionId'] = (i == 0 ? 'd' : 'a') * 64;
        requests.add({
          ...original,
          'txJsonString': jsonEncode(raw),
          'tradeSummary': {'action': i == 0 ? 'merge' : 'order-sell'}
        });
        raw['inputs'][0]['signatureScript'] = '41${fixtures.ownerSignature}';
        signed.add(jsonEncode(raw));
      }
      r['requests'] = requests;
      r['reviews'] = [
        {'reviewHash': 'review'},
        {'reviewHash': 'review'}
      ];
      r['transactionIds'] = ['a' * 64, 'b' * 64];
      r['signed'] = partial ? signed.sublist(0, 1) : signed;
      r['signedWrpc'] = List<String>.from(r['signed'] as List);
      await t.cancelAndSubmit(fixtures.address, r);
      expect(t.broadcasts, partial ? ['c' * 64] : ['a' * 64, 'c' * 64]);
      expect(t.broadcasts, isNot(contains('b' * 64)));
      expect(r['fundingReturnTerms']['sourceIndex'], partial ? 0 : 1);
      expect(r['finalVerified'], isNot(true));
      expect(auth.signs, 1);
    });
  }
  test(
      'accepted consolidation with unsigned order tail archives without a new payment',
      () async {
    final auth = RecoverySecurity(), r = fixtures.fundingReceipt();
    final t = RecoveryTrading(auth)..acceptedIds.add('a' * 64);
    final first = r['requests'][0] as Map;
    final raw = jsonDecode('${first['txJsonString']}') as Map;
    raw['inputs'][0]['signatureScript'] = '41${fixtures.ownerSignature}';
    r['signed'] = [jsonEncode(raw)];
    r['signedWrpc'] = List<String>.from(r['signed'] as List);
    r['requests'] = [
      first,
      {...first}
    ];
    r['transactionIds'] = ['a' * 64, 'b' * 64];
    r['reviews'] = [
      {'reviewHash': 'review'},
      {'reviewHash': 'review'}
    ];
    await t.cancelAndSubmit(fixtures.address, r);
    expect(r['finalVerified'], isTrue);
    expect(r['retiredReason'], 'unsigned-order-tail-cancelled');
    expect(t.broadcasts, isEmpty);
    expect(auth.signs, 0);
  });
  test('sell invalidation clears only after accepted exact KAS subset return',
      () async {
    final r = fixtures.fundingReceipt()
      ..['side'] = 'sell'
      ..['cancelId'] = 'c' * 64
      ..['cancelKind'] = 'invalidate-funding'
      ..['fundingReturnTerms'] = {
        'sourceIndex': 0,
        'points': ['${'d' * 64}:0']
      };
    final original = jsonDecode('${r['requests'][0]['txJsonString']}') as Map;
    original['inputs'].insert(0, {
      'transactionId': 'f' * 64,
      'index': 0,
      'utxo': {
        'amount': '100000000',
        'covenantId': 'b' * 64,
        'scriptPublicKey': '0000aa20${'f' * 64}87'
      }
    });
    r['requests'][0]['txJsonString'] = jsonEncode(original);
    final t = KasForgeTrading(
        store: fixtures.Memory(),
        client: MockClient((request) async => http.Response(
            jsonEncode({
              'transaction_id': 'c' * 64,
              'is_accepted': true,
              'inputs': [
                {
                  'previous_outpoint_hash': 'd' * 64,
                  'previous_outpoint_index': 0
                }
              ],
              'outputs': [
                {
                  'amount': '190000000',
                  'script_public_key':
                      '20${kaspaOwnerIdFromAddress(fixtures.address)}ac'
                }
              ]
            }),
            200)));
    await t.retain(fixtures.address, r);
    expect((await t.status(fixtures.address, r))['status'], 'cancelled');
    expect(await t.pending(fixtures.address), isNull);
    expect(await t.saved(fixtures.address), hasLength(1));
  });
  test(
      'completed local orders merge once with indexed amounts and cancellations remain in activity',
      () {
    final local = fixtures.receipt()
      ..['finalVerified'] = true
      ..['state'] = 'filled'
      ..['symbol'] = 'KASCAT'
      ..['settlementId'] = 'c' * 64;
    final cancelled = fixtures.receipt()
      ..['buildId'] = 'cancelled'
      ..['finalVerified'] = true
      ..['state'] = 'cancelled';
    final rows = KasForgeService.activityRows([
      {
        'txid': 'c' * 64,
        'tokens': 1234567,
        'kas': 985.17,
        'tick': 'KASCAT',
        'side': 'buy',
        'ts': 100
      }
    ], [
      local,
      cancelled
    ]);
    expect(rows, hasLength(2));
    expect(rows.first['tokens'], 1234567);
    expect(rows.first['kas'], 985.17);
    expect(rows.first['receipt'], isNotNull);
    expect(rows.last['state'], 'cancelled');
  });
  test(
      'actual native signed buy/sell survives SDK owner envelope and Rusty deserialization',
      () async {
    HttpOverrides.global = null;
    for (final name in ['buy', 'sell']) {
      final data = jsonDecode(await File(
              '/srv/kaspire/verification/forge-build219/native-fixtures/$name.json')
          .readAsString()) as Map;
      final request = data['request'] as Map, signed = data['signed'] as Map;
      final address = '${request['sender']}';
      final r = <String, dynamic>{
        'buildId': 'synthetic-$name',
        'address': address,
        'network': 'testnet-10',
        'requests': [request],
        'reviews': [data['review']],
        'signed': [signed['signedTxJson']],
        'signedWrpc': [signed['wrpcJson']],
        'transactionIds': [signed['transactionId']]
      };
      final t = KasForgeTrading(
          store: fixtures.Memory(),
          security: Inspector(),
          client: MockClient((req) async {
            final body = jsonDecode(req.body) as Map;
            final tx = jsonDecode(body['signed'][0] as String) as Map;
            for (final input in tx['inputs'] as List) {
              expect(input['signatureScript'],
                  matches(RegExp(r'^41[a-f0-9]{128}01$')));
            }
            final process = await Process.start('node', [
              '-e',
              r'''
const sdk = require(process.argv[1]); const assert = require('node:assert/strict');
let text = ''; process.stdin.on('data', b => text += b); process.stdin.on('end', () => {
 const data = JSON.parse(text); const tx = sdk.Transaction.deserializeFromSafeJSON(text);
 assert.equal(tx.finalize().toString(), data.id); tx.free();
});
''',
              '../../services/kasseal-test/node_modules/@kassealhq/sdk/dist/kaspa/nodejs/kaspa.js'
            ]);
            process.stdin.write(jsonEncode(tx));
            await process.stdin.close();
            final errors = process.stderr.transform(utf8.decoder).join();
            expect(await process.exitCode, 0, reason: await errors);
            return http.Response(
                jsonEncode({'ok': true, 'txid': signed['transactionId']}), 200);
          }));
      await t.submit(address, r);
      expect(r['signedWrpc'], [signed['wrpcJson']]);
      expect(jsonDecode('${r['signed'][0]}')['inputs'],
          jsonDecode('${signed['signedTxJson']}')['inputs']);
    }
  }, skip: !const bool.fromEnvironment('KASPIRE_FORGE_SIGNED_FIXTURES'));
}
