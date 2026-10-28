import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/kasforge_service.dart';
import 'package:kasvault_wallet/src/services/kasforge_trading.dart';
import 'package:kasvault_wallet/src/services/native_security.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/services/encrypted_store.dart';
import 'package:kasvault_wallet/src/services/braid_service.dart';

class Memory implements EncryptedStore {
  final data = <String, String>{};
  @override
  Future<String?> read(String k) async => data[k];
  @override
  Future<void> write(String k, String v) async {
    data[k] = v;
  }

  @override
  Future<void> delete(String k) async {
    data.remove(k);
  }
}

class Inspector extends NativeSecurity {
  @override
  Future<Map<String, Object?>> preparePskt(Map<String, Object?> request,
      {bool kaspacomReview = false}) async {
    final p = await Process.start('../../target/debug/kasforge_inspect',
        request['profile'] == null ? ['--self-return'] : []);
    p.stdin.write(jsonEncode(request));
    await p.stdin.close();
    final out = p.stdout.transform(utf8.decoder).join(),
        errors = p.stderr.transform(utf8.decoder).join();
    if (await p.exitCode != 0) throw StateError(await errors);
    return Map<String, Object?>.from(jsonDecode(await out) as Map);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test(
      'live Forge curve/pool buy/sell builds pass the independent native review',
      () async {
    NetworkSettings.network.value = KaspaNetwork.tn10;
    const address =
        'kaspatest:qp2srppaehqgjxxw4fyf2ckdzha9nz573eapxw0acg4ntc27cy2w23jck27ql';
    final read = KasForgeService(),
        trade = KasForgeTrading(store: Memory(), security: Inspector());
    final tokens = await read.catalogue();
    for (final cid in [
      'e6f41426e62a3c1250a3d08daf8de3edcaed95e35ff062fec8dc021023b49f53',
      'a846ff488043fb36626c5af59c03782477ff1a91f690168d42d3e241907c1384'
    ]) {
      final token = tokens.singleWhere((t) => t.id == cid);
      for (final side in ['buy', 'sell']) {
        // The public pool fixture has 100% of its tokens in the pool and no
        // funded holder. Never sign a real buy just to manufacture coverage.
        if (token.graduated && side == 'sell') continue;
        final amount = side == 'buy' ? '10' : '100000';
        final quote = await read.quote(token, side, amount);
        final receipt = await trade.build(address, token, side, amount, quote);
        expect(receipt['reviews'], isNotEmpty);
        // Check the actual API-shaped handoff with Rusty-Kaspa 2.1.0, not a
        // stub JSON parser. Dummy witnesses only: no key, valid signature,
        // Forge /submit request or node broadcast is produced by this test.
        final signed = <String>[];
        for (final raw in receipt['requests'] as List) {
          final request = raw as Map;
          final tx = jsonDecode('${request['txJsonString']}') as Map;
          for (final selection in (request['signInputs'] as List).cast<Map>()) {
            final descriptors = (request['scripts'] as List? ?? []).cast<Map>();
            final script = descriptors
                .where((s) => s['inputIndex'] == selection['index'])
                .firstOrNull;
            final sig = '${'11' * 64}01';
            tx['inputs'][selection['index']]['signatureScript'] = script == null
                ? '41$sig'
                : '${(script['signatureScript']['args'] as List).map((arg) => BraidService.push(arg['type'] == 'signature' ? '${arg['prefixHex'] ?? ''}$sig' : '${arg['hex']}')).join()}${BraidService.push('${script['scriptHex']}')}';
          }
          signed.add(jsonEncode(tx));
        }
        receipt['signed'] = signed;
        final adapter = KasForgeTrading(
            store: Memory(),
            security: Inspector(),
            client: MockClient((request) async {
              expect(request.url.path, '/api/v1/submit');
              final process = await Process.start('node', [
                '-e',
                r'''
const assert = require('node:assert/strict');
const sdk = require(process.argv[1]);
let text = ''; process.stdin.on('data', b => text += b);
process.stdin.on('end', () => {
  for (const raw of JSON.parse(text).signed) {
    const data = JSON.parse(raw);
    assert.ok(data.inputs.every(i => /^41[0-9a-f]{128}01$/.test(i.signatureScript)));
    const old = {...data}; delete old.id;
    assert.throws(() => sdk.Transaction.deserializeFromSafeJSON(JSON.stringify(old)),
      e => String(e).includes('missing field `id`'));
    const tx = sdk.Transaction.deserializeFromSafeJSON(raw);
    assert.equal(tx.finalize().toString(), data.id);
    const roundtrip = JSON.parse(tx.serializeToSafeJSON());
    assert.deepEqual(roundtrip.inputs.map(i => i.signatureScript), data.inputs.map(i => i.signatureScript));
    tx.free();
  }
});
''',
                '../../services/kasseal-test/node_modules/@kassealhq/sdk/dist/kaspa/nodejs/kaspa.js'
              ]);
              process.stdin.write(request.body);
              await process.stdin.close();
              final stderr = process.stderr.transform(utf8.decoder).join();
              expect(await process.exitCode, 0, reason: await stderr);
              return http.Response(
                  jsonEncode({
                    'ok': true,
                    'txid': (receipt['transactionIds'] as List).last
                  }),
                  200);
            }));
        await adapter.submit(address, receipt);
        expect(receipt['state'], 'deposited'); // intercepted API result only
        adapter.client.close();
        if (side == 'buy' && (receipt['requests'] as List).length == 1) {
          final back = await trade.fundingReturn(address, receipt);
          final review = await Inspector().preparePskt(back);
          expect('${review['feeSompi']}', '10000000');
          final tx = jsonDecode('${back['txJsonString']}') as Map;
          expect(tx['outputs'], hasLength(1));
          expect(
              tx['outputs'][0]['scriptPublicKey'],
              (jsonDecode('${receipt['requests'][0]['txJsonString']}')
                  as Map)['inputs'][0]['utxo']['scriptPublicKey']);
        }
      }
    }
    read.client.close();
    trade.client.close();
  },
      skip: !const bool.fromEnvironment('KASPIRE_FORGE_LIVE'),
      timeout: const Timeout(Duration(minutes: 3)));
}
