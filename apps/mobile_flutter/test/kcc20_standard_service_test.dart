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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
