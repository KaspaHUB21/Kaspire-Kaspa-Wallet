import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/kaspa_address.dart';
import 'package:kasvault_wallet/src/services/braid_service.dart';
import 'package:kasvault_wallet/src/services/braid_pool_reader.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'braid_service_test.dart' show Memory;
import 'braid_mainnet_handoff_test.dart' show SnapshotClock;

Map<String, dynamic> deep(Map value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

void main() {
  setUp(() => NetworkSettings.network.value = KaspaNetwork.mainnet);
  final owner = '11' * 32,
      dep = '22' * 32,
      stage = '33' * 32,
      finish = '44' * 32;
  final address = kaspaAddressFromOwnerId(owner);
  Map<String, dynamic> receipt() => {
        'ref': 'staged-test',
        'address': address,
        'network': 'mainnet',
        'signed': {'0': 'aa'},
        'transactionId': dep,
        'depositCoinIndex': 0,
        'depositCoinValue': '110000000',
        'depositNoteIndex': 1,
        'depositNoteValue': '50000000',
        'context': {
          'fromId': BraidService.tokens[2].id,
          'toId': BraidService.tokens[1].id,
          'amountIn': '100000', 'minimumOut': '50000',
          // These dummy programs exercise ancestry independently of server hints;
          // pinned program validation and real script execution are native tests.
          'router': {'prefix': '6b', 'suffix': '51'},
          'terms': {
            'recipient': owner,
            'refund': owner,
            'outKind': '1',
            'outCovid': BraidService.tokens[1].id,
            'outTpl': BraidService.tokens[1].template,
            'outPfl': '34',
            'outSfl': '11312',
            'minOut': '50000',
            'inKind': '1',
            'inCovid': BraidService.tokens[2].id,
            'inTpl': BraidService.tokens[2].template,
            'inPfl': '34',
            'inSfl': '11312',
            'inAmount': '100000',
            'wfeePk': BraidService.feeOwner,
            'wfee': '10000000',
            'feeCap': '0',
            'midMin': '550000000',
            'deadline': '1000000',
            'intent': '55' * 32,
            'tkFloor': '0',
          }
        },
        'status': {
          'stage': {'txid': stage}
        },
      };
  test(
      'stage2 changes only input-side fields and midMin, retaining all payout, fee and expiry terms',
      () {
    final terms = receipt()['context']['terms'] as Map;
    final next = BraidService.stageTerms(terms);
    for (final key in terms.keys) {
      if (![
        'inKind',
        'inCovid',
        'inTpl',
        'inPfl',
        'inSfl',
        'inAmount',
        'midMin'
      ].contains(key)) {
        expect(next[key], terms[key], reason: '$key');
      }
    }
    expect(next['inKind'], '0');
    expect(next['inCovid'], BraidService.zero);
    expect(terms['inKind'], '1');
  });
  test(
      'staged KAS fee uses independently verified sale, not token units or returned reserves',
      () {
    final s = BraidService();
    final valuation = jsonDecode(File(
            '../../crates/kaspa_secure_core/src/fixtures/braid-mainnet-guza-pool.json')
        .readAsStringSync()) as Map;
    final q = jsonDecode(File(
            '../../crates/kaspa_secure_core/src/fixtures/braid-mainnet-guza-then-staged-quote.json')
        .readAsStringSync()) as Map;
    final fee = q['walletFee'] as Map;
    expect(fee['basis'], '6980051422');
    expect(valuation['tradeKas'], '6910250908');
    expect(
        BigInt.parse('${fee['basis']}') >
            BigInt.parse('${valuation['tradeKas']}'),
        true);
    void check(Map quote) => s.validateFee(quote, BraidService.tokens[2],
        BraidService.tokens[1], '100000', 100, valuation);
    check(q);
    for (final mutation in [
      {...fee, 'unit': 'token'},
      {...fee, 'basis': '6980051423'},
      {...fee, 'amount': '69800515'},
      {...fee, 'basisKind': 'stageKas'},
      {...fee, 'carrier': '10000000'},
      {...fee, 'tkFloor': '990000000'},
      {...fee, 'pk': owner},
    ]) {
      expect(() => check({...q, 'walletFee': mutation}), throwsStateError);
    }
    final floor = BigInt.parse('${valuation['floor']}');
    expect(
        () => check({
              ...q,
              'midMin':
                  '${floor - floor ~/ BigInt.from(100) + BigInt.from(50000000) - BigInt.one}'
            }),
        throwsStateError);
  });
  test(
      'stage coin and KAS refund follow exact original inputs and deterministic stage2 script',
      () async {
    for (final fault in [
      'none',
      'coin',
      'note',
      'script',
      'amount',
      'unaccepted',
      'final',
      'timeout'
    ]) {
      final r = receipt(), memory = Memory();
      // A test-only serializer mirrors the public 21-field state layout.
      final fields = (r['context']['terms'] as Map).keys;
      final terms = BraidService.stageTerms(r['context']['terms'] as Map);
      final state = fields.map((key) {
        final value = '${terms[key]}';
        if ([
          'recipient',
          'refund',
          'outCovid',
          'outTpl',
          'inCovid',
          'inTpl',
          'wfeePk',
          'intent'
        ].contains(key)) return '20$value';
        final n = BigInt.parse(value);
        return '08${BraidService.hex(List.generate(8, (i) => ((n >> (i * 8)) & BigInt.from(255)).toInt()))}';
      }).join();
      final spk = BraidService.scriptHash('6b${state}51');
      final c = MockClient((req) async {
        expect(req.method, 'GET');
        expect(req.url.host, 'kaspire.kaslab.space');
        if (fault == 'timeout') throw const SocketException('offline');
        if (req.url.path.endsWith('/transactions/$finish')) {
          return http.Response(
              jsonEncode({
                'transaction_id': finish,
                'is_accepted': true,
                'inputs': [
                  {
                    'previous_outpoint_hash': fault == 'final' ? dep : stage,
                    'previous_outpoint_index': 2
                  }
                ],
                'outputs': [
                  {'script_public_key': '20${owner}ac', 'amount': '635000000'}
                ]
              }),
              200);
        }
        if (req.url.path.contains('/full-transactions'))
          return http.Response('[]', 200);
        expect(req.url.path.endsWith('/transactions/$stage'), true);
        return http.Response(
            jsonEncode({
              'transaction_id': stage,
              'is_accepted': fault != 'unaccepted',
              'inputs': [
                {
                  'previous_outpoint_hash': fault == 'coin' ? finish : dep,
                  'previous_outpoint_index': 0
                },
                {
                  'previous_outpoint_hash': dep,
                  'previous_outpoint_index': fault == 'note' ? 3 : 1
                }
              ],
              'outputs': [
                {
                  'index': 2,
                  'script_public_key':
                      fault == 'script' ? 'aa20${owner}87' : spk.substring(4),
                  'covenant_id': null,
                  'amount': fault == 'amount' ? '639999999' : '640000000'
                }
              ]
            }),
            200);
      });
      final s = BraidService(client: c, store: memory);
      await s.retain(address, r);
      final verification = s.verifyFinal(address, r, {
        'state': 'refunded',
        'refund': {'txid': finish}
      });
      if (fault == 'none') {
        await verification;
        expect(r['verifiedStage']['transactionId'], stage);
        final reopened = BraidService(client: c, store: memory);
        expect((await reopened.pending(address))!['verifiedStage']['index'], 2);
      } else {
        await expectLater(verification,
            throwsA(anyOf(isA<StateError>(), isA<SocketException>())));
        expect((await s.pending(address))!['verifiedFinal'], isNot(true));
      }
    }
  });

  test(
      'production intermediate recovery request passes the actual Dart-to-Rust boundary',
      () async {
    final fixture = jsonDecode(File(
            '../../crates/kaspa_secure_core/src/fixtures/braid-tn10-kas-buy.json')
        .readAsStringSync()) as Map;
    final ctx = deep(fixture['tradeSummary'] as Map);
    final proof = jsonDecode(File(
            '../../crates/kaspa_secure_core/src/fixtures/braid-mainnet-then-pool.json')
        .readAsStringSync()) as Map;
    final floor = BigInt.parse('${proof['floor']}');
    final from = BraidService.tokens[1], to = BraidService.tokens[2];
    final terms = deep(ctx['terms'] as Map);
    terms.addAll({
      'recipient': owner,
      'refund': owner,
      'inKind': '1',
      'outKind': '1',
      'inCovid': from.id,
      'outCovid': to.id,
      'inTpl': from.template,
      'outTpl': to.template,
      'inPfl': '34',
      'outPfl': '34',
      'inSfl': '11312',
      'outSfl': '11312',
      'inAmount': '10000000',
      'midMin': '${floor + BigInt.from(50000000)}',
      'wfee': '0',
      'wfeePk': BraidService.zero,
      'tkFloor': '0'
    });
    final router = deep(ctx['router'] as Map);
    const executor =
        '4f6eb864ff5eaf2ab9358d24b425cc41306b3913b061d4cfd54a47ee75f2c4b4';
    const feeKey =
        '0de066137de17b4b8c13761fdbc821c34f9c55579af57c8a9186fee0daed0400';
    router['suffix'] = '${router['suffix']}'
        .replaceAll('${router['executor']}', executor)
        .replaceAll('${router['feePk']}', feeKey);
    router.addAll({
      'pin': BraidService.mainnetPin,
      'executor': executor,
      'feePk': feeKey
    });
    ctx.addAll({
      'network': 'mainnet',
      'terms': terms,
      'router': router,
      'fromId': from.id,
      'toId': to.id,
      'amountIn': '10000000',
      'payTotal': '0',
      'valuation': proof,
      'slippageBps': '100',
      'midMin': terms['midMin'],
      'feeBps': '100',
      'walletFee': '0',
      'feeCarrier': '0'
    });
    final next = BraidService.stageTerms(terms);
    final bytes = terms.keys.map((k) {
      if ([
        'recipient',
        'refund',
        'outCovid',
        'outTpl',
        'inCovid',
        'inTpl',
        'wfeePk',
        'intent'
      ].contains(k)) return '20${next[k]}';
      final n = BigInt.parse('${next[k]}');
      return '08${BraidService.hex(List.generate(8, (i) => ((n >> (8 * i)) & BigInt.from(255)).toInt()))}';
    }).join();
    final spk =
        BraidService.scriptHash('${router['prefix']}$bytes${router['suffix']}');
    final value = floor + BigInt.from(130000000);
    final rec = <String, dynamic>{
      'ref': ctx['ref'],
      'address': address,
      'network': 'mainnet',
      'signed': {'0': 'aa'},
      'transactionId': dep,
      'depositCoinIndex': 0,
      'depositCoinValue': '100000000',
      'depositNoteIndex': 1,
      'context': ctx,
      'status': {
        'stage': {'txid': stage}
      }
    };
    final service = BraidService(
        store: Memory(),
        clock: SnapshotClock(int.parse('${terms['deadline']}') + 1),
        client: MockClient((req) async {
          expect(req.method, 'GET');
          if (req.url.path.endsWith('/transactions/$stage'))
            return http.Response(
                jsonEncode({
                  'transaction_id': stage,
                  'is_accepted': true,
                  'inputs': [
                    {
                      'previous_outpoint_hash': dep,
                      'previous_outpoint_index': 0
                    },
                    {
                      'previous_outpoint_hash': dep,
                      'previous_outpoint_index': 1
                    }
                  ],
                  'outputs': [
                    {
                      'index': 0,
                      'amount': '$value',
                      'script_public_key': spk.substring(4),
                      'covenant_id': null
                    }
                  ]
                }),
                200);
          expect(req.url.path, '/dex-test-v1/kasseal-mainnet/utxos');
          return http.Response(
              jsonEncode({
                'network': 'mainnet',
                'covenantIdsIncluded': true,
                'entries': [
                  {
                    'outpoint': {'transactionId': stage, 'index': 0},
                    'utxoEntry': {
                      'amount': '$value',
                      'isCoinbase': false,
                      'blockDaaScore': '123',
                      'covenantId': null,
                      'scriptPublicKey': {
                        'version': 0,
                        'scriptPublicKey': spk.substring(4)
                      }
                    }
                  }
                ]
              }),
              200);
        }));
    final request = await service.reclaim(address, rec);
    expect((request['tradeSummary'] as Map)['reclaimStage2'], true);
    final tx = jsonDecode('${request['txJsonString']}') as Map;
    expect((tx['inputs'] as List).length, 1);
    expect(tx['inputs'][0]['transactionId'], stage);
    expect(tx['outputs'][0]['value'], '${value - BigInt.from(5000000)}');
    final process = await Process.start('../../target/debug/braid_inspect', []);
    process.stdin.write(jsonEncode(request));
    await process.stdin.close();
    final out = utf8.decoder.bind(process.stdout).join(),
        err = utf8.decoder.bind(process.stderr).join();
    expect(await process.exitCode, 0, reason: await err);
    expect((jsonDecode(await out) as Map)['finalFeeKnown'], true);
  }, skip: !File('../../target/debug/braid_inspect').existsSync());

  test(
      'staged quote reaches production pool verification and keeps the reviewed intermediate floor',
      () async {
    final proof = jsonDecode(File(
            '../../crates/kaspa_secure_core/src/fixtures/braid-mainnet-then-pool.json')
        .readAsStringSync()) as Map;
    final poolTx = jsonDecode(File(
            '../../crates/kaspa_secure_core/src/fixtures/braid-mainnet-then-transaction.json')
        .readAsStringSync()) as Map;
    final floor = BigInt.parse('${proof['floor']}'),
        value = BraidPoolReader.saleAmounts('mainnet', '${proof['tokenId']}',
                '${proof['redeem']}', BigInt.from(10000000))
            .gross;
    final seen = <String>[];
    late final BraidService s;
    s = BraidService(client: MockClient((req) async {
      expect(req.method, 'GET');
      seen.add(req.url.path);
      if (req.url.path.endsWith('/info'))
        return http.Response(
            jsonEncode({
              'net': 'mainnet',
              'enabled': true,
              'pin': BraidService.mainnetPin,
              'expectedPin': BraidService.mainnetPin,
              'pinOk': true,
              'executorStatus': {'healthy': true}
            }),
            200);
      if (req.url.path.endsWith('/quote'))
        return http.Response(
            jsonEncode({
              'net': 'mainnet',
              'from': 'THEN',
              'to': 'GUZA',
              'amountIn': '10000000',
              'amountOut': '12345',
              'pin': BraidService.mainnetPin,
              'staged': true,
              'midMin': '${floor + BigInt.from(50000000)}',
              'poolTips': {
                proof['tokenId']: {
                  'transactionId': proof['transactionId'],
                  'index': proof['index']
                }
              },
              'walletFee': {
                'mode': 'bps',
                'bps': 100,
                'address': s.feeAddress,
                'pk': BraidService.feeOwner,
                'unit': 'KAS',
                'basisKind': 'tradeKas',
                'basis': '$value',
                'amount': '${value ~/ BigInt.from(100)}'
              }
            }),
            200);
      if (req.url.path.contains('/transactions/'))
        return http.Response(jsonEncode(poolTx), 200);
      if (req.url.path.endsWith('/utxos'))
        return http.Response(
            jsonEncode([
              {
                'outpoint': {
                  'transactionId': proof['transactionId'],
                  'index': proof['index']
                },
                'utxoEntry': {
                  'amount': '100000000',
                  'isCoinbase': false,
                  'scriptPublicKey': {
                    'version': 0,
                    'scriptPublicKey': proof['scriptPublicKey']
                  }
                }
              }
            ]),
            200);
      throw StateError('Unexpected fixture URL');
    }));
    final quote = await s.quote(address, BraidService.tokens[1],
        BraidService.tokens[2], '10000000', 100);
    expect(quote['staged'], true);
    expect(quote['localMidMin'], '${floor + BigInt.from(50000000)}');
    expect(quote['localValuation']['floor'], proof['floor']);
    expect(seen.where((p) => p.endsWith('/quote')).length, 2);
    expect(seen.any((p) => p.contains('/transactions/')), true);
  });
}
