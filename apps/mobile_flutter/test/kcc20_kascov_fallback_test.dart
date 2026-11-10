import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointycastle/digests/blake2b.dart';
import 'package:kasvault_wallet/src/kaspa_address.dart';
import 'package:kasvault_wallet/src/services/kcc20_standard_service.dart';

const address =
    'kaspa:qp30ahte7r7qq6lum8utxf99nftffwgeg6sewgs49fz89tzpc36mxk89jjqlf';
final owner = kaspaOwnerIdFromAddress(address), cid = 'c' * 64;
final templates = <bool, Map>{};
String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Map<String, dynamic> cell(int i,
    {bool ten = false,
    int units = 10,
    int borrow = 0,
    int deposit = 100000000}) {
  final t = templates[ten]!,
      little = hex([for (var b = 0; b < 8; b++) (units >> (8 * b)) & 255]);
  final program =
      '${t['prefix']}08${little}20${owner}010001${borrow.toRadixString(16).padLeft(2, '0')}20${'0' * 64}20${'0' * 64}${t['suffix']}';
  final bytes = Uint8List.fromList([
    for (var p = 0; p < program.length; p += 2)
      int.parse(program.substring(p, p + 2), radix: 16)
  ]);
  return {
    'outpoint': '${i.toRadixString(16).padLeft(64, '0')}:0',
    'program_hex': program,
    'script_hex': 'aa20${hex(Blake2bDigest(digestSize: 32).process(bytes))}87',
    'amount_str': '$units',
    'value_sompi': deposit,
    'is_minter': false,
    'owner': '00$owner',
    'borrow_scheme': borrow.toRadixString(16).padLeft(2, '0'),
    'borrow_guard': '0' * 64,
    'extension_commitment': '0' * 64
  };
}

http.Response json(Object value) => http.Response(jsonEncode(value), 200);
MockClient source(List<Map<String, dynamic>> cells,
        {bool ten = false,
        bool omitted = false,
        bool spent = false,
        bool stale = false,
        bool wrongNode = false,
        bool kasseal = false,
        bool nodeDown = false,
        bool transactionOnlyDown = false,
        List<String>? requests}) =>
    MockClient((r) async {
      requests?.add(r.url.toString());
      if (r.url.host == 'kcc20.info')
        fail('Retired indexer must never be used');
      if (r.url.host == 'kasvio.network') {
        if (transactionOnlyDown && r.url.path.endsWith('/balance')) {
          return json({
            'meta': {
              'network': 'mainnet',
              'reference_commit': Kcc20StandardService.reference
            },
            'data': {
              'covenant_id': cid,
              'owner_scheme': 0,
              'owner_value': owner,
              'available': true,
              'balance_raw': cells
                  .fold<int>(0, (s, c) => s + int.parse(c['amount_str']))
                  .toString(),
              'outputs': cells
                  .map((c) => {
                        'txid': c['outpoint'].split(':')[0],
                        'output_index': 0,
                        'balance_raw': c['amount_str'],
                        'amount_sompi': '${c['value_sompi']}'
                      })
                  .toList(),
            }
          });
        }
        return http.Response('{"error":"source_unavailable"}', 503);
      }
      if (r.url.host == 'kascov.io') {
        if (r.url.path.contains('/addr/'))
          return json({
            'network': 'mainnet',
            'address': address,
            'pubkey': owner,
            'tip_daa': 123,
            'tip_at_ms': DateTime.now()
                .subtract(stale ? const Duration(hours: 1) : Duration.zero)
                .millisecondsSinceEpoch,
            'next_before_token': null,
            'token_holdings': [
              {'token_id': cid, 'status': 'verified', 'balance_str': '30'},
              {
                'token_id': 'd' * 64,
                'status': 'verified',
                'balance_str': '1000'
              },
            ]
          });
        if (r.url.path.endsWith('/cells'))
          return json({
            'network': 'mainnet',
            'token_id': cid,
            'owner': '00$owner',
            'omitted_over_limit': omitted ? 1 : 0,
            'omitted_unproven': 0,
            'omitted_unvalued': 0,
            'cells': cells
          });
        if (r.url.path.endsWith('d' * 64))
          return json({
            'network': 'mainnet',
            'token': {
              'covenant_id': 'd' * 64,
              'status': 'verified',
              'layout': 'kcc20-46'
            }
          });
        return json({
          'network': 'mainnet',
          'token': {
            'covenant_id': cid,
            'status': 'verified',
            'layout': 'kcc0020-112',
            'standard': {
              'template_hash': ten
                  ? Kcc20StandardService.tenTemplateHash
                  : Kcc20StandardService.templateHash
            },
            'kcc23': {
              'binding': 'verified',
              'declaration': jsonEncode({'ticker': 'WALLET', 'decimals': 0})
            }
          },
          if (kasseal)
            'market': {
              'program': {
                'token_covenant_id': cid,
                'skeleton': 'Kasseal curve v1'
              }
            }
        });
      }
      if (r.url.path.contains('/local-node/transactions/')) {
        if (nodeDown) return http.Response('{}', 503);
        final id = r.url.pathSegments.last,
            c = cells.firstWhere((c) => c['outpoint'] == '$id:0');
        return json({
          'transaction_id': id,
          'is_accepted': true,
          'outputs': [
            {
              'index': 0,
              'covenant_id': wrongNode ? 'e' * 64 : cid,
              'amount': '${c['value_sompi']}',
              'script_public_key': c['script_hex'],
              'script_public_key_address': address
            }
          ]
        });
      }
      if (r.url.path.endsWith('/utxos'))
        return json(spent
            ? []
            : cells
                .map((c) => {
                      'outpoint': {
                        'transactionId': c['outpoint'].split(':')[0],
                        'index': 0
                      },
                      'utxoEntry': {
                        'amount': '${c['value_sompi']}',
                        'blockDaaScore': '123',
                        'isCoinbase': false,
                        'scriptPublicKey': {'scriptPublicKey': c['script_hex']}
                      }
                    })
                .toList());
      return http.Response('{}', 404);
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    templates[false] = jsonDecode(
        await rootBundle.loadString('assets/kcc20_standard_template.json'));
    templates[true] = jsonDecode(
        await rootBundle.loadString('assets/kcc20_reference_10_template.json'));
  });
  test('Kasvio 503: modern discovery and sends use Kascov, legacy is excluded',
      () async {
    final requests = <String>[],
        client = source([cell(1), cell(2), cell(3)], requests: requests);
    final service = Kcc20StandardService(client),
        wallet = await service.load(address, historyLimit: 0);
    expect(wallet.assets.single.symbol, 'WALLET');
    expect(wallet.assets.single.standard, 'kcc20');
    expect(wallet.assets.single.balance, 30);
    expect(wallet.warning, isEmpty);
    final step = await service.signingBatch(address, cid, 15, fullPlan: true);
    expect(step.templateId, Kcc20StandardService.templateId);
    expect(step.cells.length, 3); // includes eligible in-payment dust
    expect(
        step.cells.every(
            (c) => c.redeemScript!.startsWith(templates[false]!['prefix'])),
        true);
    expect(
        requests.where((u) => Uri.parse(u).host == 'kasvio.network').length, 1);
    expect(requests.any((u) => u.contains('kcc20.info')), false);
  });
  for (final ten in [false, true]) {
    test(
        'fallback preserves ${ten ? 10 : 3}-input limits and compound planning',
        () async {
      final count = ten ? 11 : 4,
          service = Kcc20StandardService(source(
              [for (var i = 1; i <= count; i++) cell(i, ten: ten)],
              ten: ten));
      final step =
          await service.signingBatch(address, cid, count * 10, fullPlan: false);
      expect(step.inputLimit, ten ? 10 : 3);
      expect(step.compound, true);
      expect(step.cells.length, ten ? 10 : 3);
      final plan =
          await service.signingBatch(address, cid, count * 10, fullPlan: true);
      expect(plan.cells.length, count);
      expect(plan.transactionCount, 2);
    });
  }
  test('mid-flow transaction API failure loads independently committed cells',
      () async {
    final service =
        Kcc20StandardService(source([cell(1)], transactionOnlyDown: true));
    expect(
        (await service.signingBatch(address, cid, 5)).cells.single.tokenAmount,
        10);
  });
  test('Kasseal fallback keeps owner-only signing and 5 KAS reserve', () async {
    final service = Kcc20StandardService(
        source([cell(1, deposit: 500000000)], kasseal: true));
    final w = await service.load(address, historyLimit: 0);
    expect(w.assets.single.standard, 'kasseal-kcc20');
    final step =
        await service.signingBatch(address, cid, 5, kassealOwnerOnly: true);
    expect(step.templateId, Kcc20StandardService.kassealOwnerTemplateId);
    expect(step.cells.single.valueSompi, 500000000);
  });
  test('borrowed receive remains available through Kascov proofs', () async {
    final service = Kcc20StandardService(source([cell(1, borrow: 1)]));
    final first = (await service.signingBatch(address, cid, 5)).cells.single;
    final receive = await service.borrowedReceive(
        address, cid, 2, first, Kcc20StandardService.templateId);
    expect(receive, isNotNull);
    expect(receive!.tokenAmount, 10);
  });
  for (final change in [
    'program_hex',
    'script_hex',
    'amount_str',
    'owner',
    'borrow_guard',
    'extension_commitment'
  ]) {
    test('fallback rejects tampered $change before preparing payment',
        () async {
      final c = cell(1);
      c[change] = change == 'amount_str' ? '999' : '00';
      await expectLater(
          Kcc20StandardService(source([c])).signingBatch(address, cid, 5),
          throwsStateError);
    });
  }
  test('truncated cell data is unavailable, never zero', () async {
    await expectLater(
        Kcc20StandardService(source([cell(1)], omitted: true))
            .signingBatch(address, cid, 5),
        throwsStateError);
  });
  test('stale fallback data keeps positive holdings and explicit partial state',
      () async {
    final wallet = await Kcc20StandardService(source([cell(1)], stale: true))
        .load(address, historyLimit: 0);
    expect(wallet.assets, isNotEmpty);
    expect(wallet.coverageComplete, false);
    expect(wallet.warning, isEmpty);
  });
  test('spent cell and node/covenant mismatch remain blocked', () async {
    for (final client in [
      source([cell(1)], spent: true),
      source([cell(1)], wrongNode: true)
    ]) {
      await expectLater(
          Kcc20StandardService(client).signingBatch(address, cid, 5),
          throwsStateError);
    }
  });
  test('own-node 503 is labelled correctly, not bypassed through Kascov',
      () async {
    await expectLater(
        Kcc20StandardService(source([cell(1)], nodeDown: true))
            .signingBatch(address, cid, 5),
        throwsA(isA<Kcc20ReadError>()
            .having((e) => e.message, 'source', contains('Own-node'))));
  });
}
