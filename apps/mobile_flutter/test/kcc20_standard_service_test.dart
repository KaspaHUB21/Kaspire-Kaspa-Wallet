import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/kaspa_address.dart';
import 'package:kasvault_wallet/src/services/kcc20_standard_service.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';

const address =
    'kaspa:qp30ahte7r7qq6lum8utxf99nftffwgeg6sewgs49fz89tzpc36mxk89jjqlf';
final cid = 'c' * 64, txid = 'a' * 64;
final owner = kaspaOwnerIdFromAddress(address);
final meta = {
  'network': 'mainnet',
  'reference_commit': Kcc20StandardService.reference
};
final token = {
  'covenant_id': cid,
  'profile_id': 'KCC20PublicMint@c8a0871',
  'recognition': 'hash_proven_reference_actor_family',
  'metadata': {
    'ticker': 'wallet',
    'decimals': 8,
    'binding_verified': true,
    'image_bytes_verified': true,
    'image_hash': 'e' * 64
  },
};
Map<String, Object?> state({String? ownedBy}) => {
      'io_index': 0,
      'covenant_id': cid,
      'actor': 'KCC20',
      'token_amount': '100000000000000',
      'owner_scheme': 0,
      'owner_value': ownedBy ?? owner,
      'state_hash_verified': true,
      'template_hash': Kcc20StandardService.templateHash,
      'borrow_scheme': 0,
      'borrow_guard': '0' * 64,
      'extension_commitment': '0' * 64,
    };
http.Response envelope(Object data, {Map<String, Object?>? pagination}) =>
    http.Response(
        jsonEncode({
          'data': data,
          'meta': meta,
          if (pagination != null) 'pagination': pagination,
        }),
        200);
MockClient source(
        {bool historyDown = false,
        bool spent = false,
        bool wrongOwner = false,
        bool nodeWrongCid = false,
        bool noBalance = false}) =>
    MockClient((r) async {
      final path = r.url.path;
      if (path.endsWith('/status')) return envelope({'status': 'ready'});
      if (path.endsWith('/tokens')) return envelope([token]);
      if (path.endsWith('/balance')) {
        return envelope({
          'covenant_id': cid,
          'owner_value': owner,
          'owner_scheme': 0,
          'available': true,
          'balance_raw': noBalance ? '0' : '100000000000000',
          'outputs': [
            {
              'txid': txid,
              'output_index': 0,
              'balance_raw': '100000000000000',
              'amount_sompi': '100000000'
            }
          ],
        });
      }
      if (path.contains('/local-node/transactions/')) {
        return http.Response(
            jsonEncode({
              'transaction_id': txid,
              'is_accepted': true,
              'outputs': [
                {
                  'index': 0,
                  'covenant_id': nodeWrongCid ? 'd' * 64 : cid,
                  'amount': '100000000',
                  'script_public_key': 'aa',
                  'script_public_key_address': address,
                }
              ],
            }),
            200);
      }
      if (path.endsWith('/utxos')) {
        return http.Response(
            jsonEncode(spent
                ? []
                : [
                    {
                      'outpoint': {'transactionId': txid, 'index': 0},
                      'utxoEntry': {
                        'amount': '100000000',
                        'blockDaaScore': '123',
                        'isCoinbase': false,
                        'scriptPublicKey': {'scriptPublicKey': 'aa'}
                      },
                    }
                  ]),
            200);
      }
      if (path.endsWith('/transactions')) {
        return historyDown
            ? http.Response('down', 503)
            : envelope([
                {'txid': txid}
              ]);
      }
      if (path.endsWith('/transactions/$txid')) {
        return envelope({
          'txid': txid,
          'token': {'covenant_id': cid},
          'components_complete': true,
          'time_ms': DateTime.now().millisecondsSinceEpoch.toString(),
          'inputs': [state(ownedBy: 'f' * 64)],
          'outputs': [state(ownedBy: wrongOwner ? 'f' * 64 : owner)],
        });
      }
      return http.Response('unavailable', 503);
    });

MockClient fragmented(List<int> amounts,
    {int? spentIndex,
    int? differentExtensionIndex,
    List<String>? paths,
    void Function(String)? onRead}) {
  final upstream = source();
  return MockClient((r) async {
    final path = r.url.path;
    paths?.add(path);
    onRead?.call(path);
    final response = await upstream.get(r.url);
    final value = jsonDecode(response.body);
    if (path.endsWith('/balance')) {
      value['data']['balance_raw'] =
          amounts.fold<int>(0, (a, b) => a + b).toString();
      value['data']['outputs'] = List.generate(
          amounts.length,
          (i) => {
                'txid': txid,
                'output_index': i,
                'balance_raw': amounts[i].toString(),
                'amount_sompi': '100000000'
              });
    } else if (path.contains('/local-node/transactions/')) {
      value['outputs'] = List.generate(
          amounts.length, (i) => {...(value['outputs'][0] as Map), 'index': i});
    } else if (path.endsWith('/utxos')) {
      final row = (value as List).single as Map;
      return http.Response(
          jsonEncode([
            for (var i = 0; i < amounts.length; i++)
              if (i != spentIndex)
                {
                  ...row,
                  'outpoint': {'transactionId': txid, 'index': i}
                }
          ]),
          200);
    } else if (path.endsWith('/transactions/$txid')) {
      value['data']['outputs'] = List.generate(
          amounts.length,
          (i) => {
                ...state(),
                'io_index': i,
                'token_amount': amounts[i].toString(),
                if (i == differentExtensionIndex)
                  'extension_commitment': 'e' * 64
              });
    }
    return http.Response(jsonEncode(value), 200);
  });
}

void main() {
  test('targeted history never scans the catalogue or global token history',
      () async {
    final paths = <String>[];
    final client = MockClient((r) async {
      paths.add(r.url.path);
      if (r.url.path.endsWith('/tokens/$cid')) return envelope(token);
      if (r.url.path.endsWith('/transactions/$txid')) {
        return envelope({
          'txid': txid,
          'token': {'covenant_id': cid},
          'components_complete': true,
          'time_ms': DateTime.now().millisecondsSinceEpoch.toString(),
          'inputs': [state(ownedBy: 'f' * 64)],
          'outputs': [state()],
        });
      }
      throw StateError('Unexpected global scan: ${r.url}');
    });
    final service = Kcc20StandardService(client);
    final refs = {
      cid: {txid}
    };
    final first = await service.historyForTransactions(address, refs);
    expect(first.single.incoming, true);
    expect(first.single.displayAmount, '1,000,000');
    final cached = await Kcc20StandardService(client)
        .historyForTransactions(address, refs);
    expect(cached, hasLength(1));
    expect(paths, hasLength(2));
  });
  test(
      'sold tokens resolve without a current balance and foreign owners are excluded',
      () async {
    final client = MockClient((r) async {
      if (r.url.path.endsWith('/tokens/$cid')) return envelope(token);
      return envelope({
        'txid': txid,
        'token': {'covenant_id': cid},
        'components_complete': true,
        'time_ms': DateTime.now().millisecondsSinceEpoch.toString(),
        'inputs': [state()],
        'outputs': [state(ownedBy: 'f' * 64)]
      });
    });
    final rows =
        await Kcc20StandardService(client).historyForTransactions(address, {
      cid: {txid}
    });
    expect(rows.single.incoming, false);
    expect(rows.single.assetSymbol, 'WALLET');
  });
  test('unknown pool covenants do not produce a false token outage', () async {
    final client = MockClient((r) async => http.Response('{}', 404));
    final warnings = <String>[];
    final rows = await Kcc20StandardService(client).historyForTransactions(
        address,
        {
          cid: {txid}
        },
        onWarning: warnings.add);
    expect(rows, isEmpty);
    expect(warnings, isEmpty);
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  test('10/10 program uses ten inputs and compounds only above ten', () async {
    for (final count in [10, 11]) {
      final base = fragmented(List.filled(count, 10));
      final client = MockClient((r) async {
        final response = await base.get(r.url);
        final value = jsonDecode(response.body);
        if (!r.url.path.contains('/local-node/') &&
            r.url.path.contains('/transactions/')) {
          for (final row in value['data']['outputs'] as List) {
            row['template_hash'] = Kcc20StandardService.tenTemplateHash;
          }
        }
        return http.Response(jsonEncode(value), 200);
      });
      final batch = await Kcc20StandardService(client)
          .signingBatch(address, cid, count * 10 - 1);
      expect(batch.inputLimit, 10);
      expect(batch.templateId, Kcc20StandardService.tenTemplateId);
      expect(batch.cells, hasLength(10));
      expect(batch.compound, count > 10);
      expect(batch.transactionCount, count == 10 ? 1 : 2);
      final full = await Kcc20StandardService(client)
          .signingBatch(address, cid, count * 10 - 1, fullPlan: true);
      expect(full.cells, hasLength(count));
      expect(full.compound, isFalse);
      expect(full.transactionCount, count == 10 ? 1 : 2);
    }
  });
  test('indexer limit claims cannot upgrade a three-input program', () async {
    final base = fragmented(List.filled(4, 10));
    final service = Kcc20StandardService(MockClient((r) async {
      final response = await base.get(r.url);
      final value = jsonDecode(response.body);
      if (value is Map && value['data'] is Map) {
        value['data']['max_token_inputs'] = 10;
      }
      return http.Response(jsonEncode(value), 200);
    }));
    final step = await service.signingBatch(address, cid, 39);
    expect(step.inputLimit, 3);
    expect(step.cells, hasLength(3));
    expect(step.compound, isTrue);
    expect(
        Kcc20StandardService.tokenTemplate({
          ...token,
          'template_hash': 'f' * 64,
        }),
        isNull);
    expect(
        Kcc20StandardService.tokenTemplate({
          'template_hash': Kcc20StandardService.tenTemplateHash,
        }),
        Kcc20StandardService.tenTemplateId);
  });
  test(
      'complete plan verifies all seven original cells once with shared proofs',
      () async {
    final paths = <String>[];
    final batch =
        await Kcc20StandardService(fragmented(List.filled(7, 10), paths: paths))
            .signingBatch(address, cid, 69, fullPlan: true);
    expect(batch.cells, hasLength(7));
    expect(batch.amount, 69);
    expect(batch.compound, isFalse);
    expect(batch.transactionCount, 3);
    expect(paths, hasLength(4));
    await expectLater(
        Kcc20StandardService(fragmented(List.filled(7, 10), spentIndex: 5))
            .signingBatch(address, cid, 69, fullPlan: true),
        throwsStateError);
    await expectLater(
        Kcc20StandardService(fragmented(List.filled(66, 1)))
            .signingBatch(address, cid, 66, fullPlan: true),
        throwsStateError);
  });
  test(
      'ordinary payment consumes smallest spare cells, preserving recipient amount',
      () async {
    final paths = <String>[], progress = <String>[];
    final step =
        await Kcc20StandardService(fragmented([90, 30, 10, 2, 1], paths: paths))
            .signingBatch(address, cid, 80, onProgress: progress.add);
    expect(step.cells.map((c) => c.index), [0, 4, 3]);
    expect(step.cells.fold<int>(0, (sum, c) => sum + c.tokenAmount), 93);
    expect(step.amount, 80);
    expect(step.compound, isFalse);
    expect(step.transactionCount, 1);
    expect(step.requiredCells, 1);
    expect(paths,
        hasLength(4)); // balance, one detail, one origin, one live proof.
    expect(progress, hasLength(4));
  });
  test('two required cells leave one slot for smallest dust', () async {
    final step = await Kcc20StandardService(fragmented([50, 40, 30, 2, 1]))
        .signingBatch(address, cid, 80);
    expect(step.cells.map((c) => c.index), [0, 1, 4]);
    expect(step.amount, 80);
    expect(step.requiredCells, 2);
  });
  test('optional spent or incompatible dust is skipped, mandatory fails closed',
      () async {
    for (final client in [
      fragmented([90, 30, 10, 2, 1], spentIndex: 4),
      fragmented([90, 30, 10, 2, 1], differentExtensionIndex: 4),
    ]) {
      final step =
          await Kcc20StandardService(client).signingBatch(address, cid, 80);
      expect(step.cells.map((c) => c.index), [0, 3]);
      expect(step.amount, 80);
    }
    for (final client in [
      fragmented([50, 40, 30], spentIndex: 1),
      fragmented([50, 40, 30], differentExtensionIndex: 1),
    ]) {
      await expectLater(
          Kcc20StandardService(client).signingBatch(address, cid, 80),
          throwsStateError);
    }
  });
  test('large fragmented payment returns bounded self-step and upfront count',
      () async {
    final step = await Kcc20StandardService(fragmented(List.filled(10, 10)))
        .signingBatch(address, cid, 100);
    expect(step.cells, hasLength(3));
    expect(step.compound, isTrue);
    expect(step.amount, 30);
    expect(step.requiredCells, 10);
    expect(step.transactionCount, 5);
  });
  test(
      'waiting for consolidation checks only balance, never signing proofs or catalogue',
      () async {
    final paths = <String>[];
    await Kcc20StandardService(fragmented([10, 20], paths: paths))
        .waitForCell(address, cid, txid);
    expect(paths, hasLength(1));
    expect(paths.single, endsWith('/balance'));
  });
  test('cancellation prevents publishing verified optional inputs', () async {
    var cancelled = false;
    final service = Kcc20StandardService(fragmented([90, 2, 1], onRead: (path) {
      if (path.endsWith('/utxos')) cancelled = true;
    }));
    await expectLater(
        service.signingBatch(address, cid, 80, isCancelled: () => cancelled),
        throwsStateError);
  });
  test(
      'Kasvio throttling retries 429 and shares pacing across service instances',
      () async {
    var calls = 0;
    final starts = <DateTime>[];
    final client = MockClient((r) async {
      starts.add(DateTime.now());
      if (++calls == 1) {
        return http.Response('limited', 429, headers: {'retry-after': '0'});
      }
      return envelope([]);
    });
    await Future.wait([
      Kcc20StandardService(client).directory(),
      Kcc20StandardService(client).directory(),
    ]);
    expect(calls, 3);
    expect(starts[1].difference(starts[0]).inMilliseconds,
        greaterThanOrEqualTo(1400));
    expect(starts[2].difference(starts[1]).inMilliseconds,
        greaterThanOrEqualTo(290));
  });
  test('activity reads precede queued discovery without concurrent requests',
      () async {
    final gate = Completer<void>();
    final paths = <String>[];
    var active = 0, peak = 0;
    final client = MockClient((request) async {
      active++;
      if (active > peak) peak = active;
      paths.add(request.url.path.split('/').last);
      if (paths.length == 1) await gate.future;
      active--;
      return envelope([]);
    });
    final service = Kcc20StandardService(client);
    final first = service.get('${service.base}/first');
    final discovery = service.get('${service.base}/discovery');
    final activity = service.get('${service.base}/activity', priority: true);
    gate.complete();
    await Future.wait([first, discovery, activity]);
    expect(paths, ['first', 'activity', 'discovery']);
    expect(peak, 1);
    client.close();
  });
  test('dotted standard symbols remain visible', () async {
    final upstream = source();
    final client = MockClient((r) async {
      final response = await upstream.get(r.url);
      if (!r.url.path.endsWith('/tokens')) return response;
      return envelope([
        {
          ...token,
          'metadata': {...token['metadata'] as Map, 'ticker': 'wobbly.k'}
        }
      ]);
    });
    final wallet =
        await Kcc20StandardService(client).load(address, historyLimit: 0);
    expect(wallet.assets.single.symbol, 'WOBBLY.K');
  });
  test('holdings-only lookup never requests per-token transaction history',
      () async {
    final paths = <String>[];
    final upstream = source();
    final client = MockClient((r) async {
      paths.add(r.url.path);
      final response = await upstream.get(r.url);
      return response;
    });
    final wallet =
        await Kcc20StandardService(client).load(address, historyLimit: 0);
    expect(wallet.assets, hasLength(1));
    expect(wallet.transactions, isEmpty);
    expect(paths.any((path) => path.contains('/transactions')), isFalse);
    client.close();
    upstream.close();
  });
  test('verified decimals and image, progressive holdings and exact activity',
      () async {
    var published = false;
    final wallet =
        await Kcc20StandardService(source()).load(address, onProgress: (w) {
      published = true;
      expect(w.assets.single.balance, 1000000);
    });
    expect(published, isTrue);
    expect(wallet.assets.single.symbol, 'WALLET');
    expect(wallet.assets.single.rawBalance, '100000000000000');
    expect(wallet.assets.single.standard, Kcc20StandardService.standard);
    expect(wallet.assets.single.validationStatus, 'observed');
    expect(wallet.assets.single.imageUrl, contains('/images/'));
    expect(wallet.transactions.single.displayAmount, '1,000,000');
    expect(wallet.transactions.single.tokenId, cid);
    expect(wallet.transactions.single.incoming, isTrue);
  });
  test('missing history never hides holdings', () async {
    final wallet =
        await Kcc20StandardService(source(historyDown: true)).load(address);
    expect(wallet.assets, hasLength(1));
    expect(wallet.transactions, isEmpty);
  });
  test('historical activity remains when current balance is zero', () async {
    final wallet =
        await Kcc20StandardService(source(noBalance: true)).load(address);
    expect(wallet.assets, isEmpty);
    expect(wallet.transactions, hasLength(1));
  });
  test('catalogue follows opaque cursors and rejects repeated cursors',
      () async {
    var calls = 0;
    final service = Kcc20StandardService(MockClient((r) async {
      calls++;
      if (calls == 2) expect(r.url.queryParameters['cursor'], 'opaque+/=');
      return envelope([token],
          pagination: {'has_more': true, 'next_cursor': 'opaque+/='});
    }));
    await expectLater(service.directory(), throwsStateError);
    expect(calls, 2);
  });
  test('wrong network is rejected', () async {
    final service = Kcc20StandardService(MockClient((r) async => http.Response(
        jsonEncode({
          'data': {},
          'meta': {...meta, 'network': 'testnet-10'},
        }),
        200)));
    await expectLater(service.directory(), throwsStateError);
  });
  test('signing cells use own-node DAA and locally pinned redeem program',
      () async {
    final cell =
        (await Kcc20StandardService(source()).signingCells(address, cid, 1))
            .single;
    expect(cell.blockDaaScore, 123);
    expect(cell.tokenAmount, 100000000000000);
    expect(cell.valueSompi, 100000000);
    expect(cell.redeemScript,
        startsWith('6b20${Kcc20StandardService.templateHash}'));
  });
  test(
      'spent outputs, wrong owner and wrong covenant cannot become signing cells',
      () async {
    for (final client in [
      source(spent: true),
      source(wrongOwner: true),
      source(nodeWrongCid: true)
    ]) {
      await expectLater(
          Kcc20StandardService(client).signingCells(address, cid, 1),
          throwsStateError);
    }
  });
  test(
      'fragmented holdings return a bounded verified compound batch, largest first',
      () async {
    final base = source();
    final service = Kcc20StandardService(MockClient((r) async {
      final response = await base.get(r.url);
      final value = jsonDecode(response.body);
      if (r.url.path.endsWith('/balance')) {
        value['data']['balance_raw'] = '400';
        value['data']['outputs'] = List.generate(
            4,
            (i) => {
                  'txid': txid,
                  'output_index': i,
                  'balance_raw': '100',
                  'amount_sompi': '100000000'
                });
      } else if (r.url.path.contains('/local-node/transactions/')) {
        value['outputs'] = List.generate(
            4, (i) => {...(value['outputs'][0] as Map), 'index': i});
      } else if (r.url.path.endsWith('/utxos')) {
        final row = (value as List).single as Map;
        return http.Response(
            jsonEncode(List.generate(
                4,
                (i) => {
                      ...row,
                      'outpoint': {'transactionId': txid, 'index': i}
                    })),
            200);
      } else if (r.url.path.endsWith('/transactions/$txid')) {
        value['data']['outputs'] = List.generate(
            4, (i) => {...state(), 'io_index': i, 'token_amount': '100'});
      }
      return http.Response(jsonEncode(value), 200);
    }));
    final cells =
        await service.signingCells(address, cid, 400, allowCompound: true);
    expect(cells.length, 3);
    expect(cells.fold<int>(0, (s, c) => s + c.tokenAmount), 300);
    await expectLater(
        service.signingCells(address, cid, 400), throwsStateError);
  });
  test(
      'borrowing-policy cells fail closed rather than implying Borrowed Receive support',
      () async {
    final base = source();
    final service = Kcc20StandardService(MockClient((r) async {
      final response = await base.get(r.url);
      if (!r.url.path.endsWith('/transactions/$txid') ||
          r.url.path.contains('/local-node/')) {
        return response;
      }
      final value = jsonDecode(response.body);
      value['data']['outputs'][0]['borrow_scheme'] = 1;
      return http.Response(jsonEncode(value), 200);
    }));
    await expectLater(service.signingCells(address, cid, 1), throwsStateError);
  });
  test('Kasvio standard holdings survive unavailable legacy and KRON sources',
      () async {
    final reader = source();
    final api = KaspaApi(client: MockClient((r) async {
      if (r.url.path.contains('/api/kcc20/v1/')) return reader.get(r.url);
      if (r.url.path.endsWith('/balance')) {
        return http.Response('{"balance":0}', 200);
      }
      if (r.url.path.endsWith('/info/price')) {
        return http.Response('{"price":0.1}', 200);
      }
      if (r.url.path.endsWith('/utxos') ||
          r.url.path.contains('/full-transactions')) {
        return http.Response('[]', 200);
      }
      return http.Response('unavailable', 503);
    }));
    final wallet = await api.loadWallet(address);
    expect(wallet.kcc20Tokens.single.symbol, 'WALLET');
    expect(wallet.transactions.where((tx) => tx.assetKind == 'KCC20'),
        hasLength(1));
  });
}
