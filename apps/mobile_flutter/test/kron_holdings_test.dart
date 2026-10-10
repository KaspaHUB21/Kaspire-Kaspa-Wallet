import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/kron_holdings.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';

const id = '05f2718333af36854fa503f6cac402dcf5485a925ef0614874482b752efe848a';
const address =
    'kaspa:qrtfmlgmpa4k7el9xmuu9m477h24y24gpwxfhpg40rdxpmeuqy6ecfjxwudq4';
const holding = {
  'tick': 'KASM',
  'balance': '1000000',
  'dec': 0,
  'covenantId': id
};
http.Response reply(Object data) => http.Response(jsonEncode(data), 200);
MockClient client(
        {bool kasvioDown = false,
        bool stale = false,
        bool duplicate = false,
        bool wrongMetadata = false,
        int decimals = 0}) =>
    MockClient((request) async {
      if (request.url.path.endsWith('/info')) {
        return reply({
          'result': {
            'network': 'mainnet',
            'networkOk': true,
            'synced': true,
            'divergent': false
          }
        });
      }
      if (request.url.path.endsWith('/tokenlist')) {
        return reply({
          'result': [
            {...holding, 'dec': decimals},
            if (duplicate) holding
          ]
        });
      }
      if (request.url.host == 'kasvio.network') {
        if (kasvioDown) return http.Response('offline', 503);
        return reply({
          'stale': stale,
          'source': {'available': true},
          'tokens': [
            {
              'id': id,
              'price': '0.01',
              'logo': 'https://example.org/kasm.png',
              'balance': '0'
            }
          ]
        });
      }
      if (request.url.path.endsWith('/utxos')) {
        return reply({
          'result': [
            {
              'outpoint': {'transactionId': 'a' * 64, 'index': 0},
              'amount': '1000000',
              'ownerAddress': address,
              'redeemScriptHex': 'aa',
              'scriptPublicKey': 'bb'
            }
          ]
        });
      }
      return reply({
        'result': [
          {
            ...holding,
            'covenantId': wrongMetadata ? 'b' * 64 : id,
            'graduated': false
          }
        ]
      });
    });

void main() {
  test('wallet keeps KRON holdings when both legacy indexers fail', () async {
    final kron = client(kasvioDown: true);
    final api = KaspaApi(client: MockClient((request) async {
      if (request.url.host == 'idx.kron.technology' ||
          request.url.host == 'kasvio.network') {
        return kron.get(request.url);
      }
      if (request.url.host == 'kcc20.info' || request.url.host == 'kascov.io') {
        return http.Response('offline', 503);
      }
      if (request.url.path.endsWith('/balance')) return reply({'balance': 0});
      if (request.url.path.endsWith('/info/price')) {
        return reply({'price': 0.1});
      }
      return reply([]);
    }));
    final wallet = await api.loadWallet(address);
    expect(wallet.kcc20Tokens.single.covenantId, id);
    expect(wallet.kcc20Tokens.single.rawBalance, '1000000');
  });
  test('signing cells obtain KAS values and live status from the own node',
      () async {
    final kron = client();
    final api = KaspaApi(client: MockClient((request) async {
      if (request.url.host == 'idx.kron.technology') {
        return kron.get(request.url);
      }
      if (request.url.path.contains('/local-node/transactions/')) {
        return reply({
          'transaction_id': 'a' * 64,
          'is_accepted': true,
          'outputs': [
            {
              'index': 0,
              'amount': '23000000',
              'covenant_id': id,
              'script_public_key': 'bb',
              'script_public_key_address': address
            }
          ]
        });
      }
      if (request.url.path.endsWith('/utxos')) {
        return reply([
          {
            'outpoint': {'transactionId': 'a' * 64, 'index': 0},
            'utxoEntry': {
              'amount': '23000000',
              'blockDaaScore': '123',
              'scriptPublicKey': {'scriptPublicKey': 'bb'},
              'isCoinbase': false
            }
          }
        ]);
      }
      return http.Response('offline', 503);
    }));
    final cell = (await api.loadKronSigningCells(address, id, 1)).single;
    expect(cell.tokenAmount, 1000000);
    expect(cell.valueSompi, 23000000);
    expect(cell.blockDaaScore, 123);
  });
  test('KRON launchpad holding survives Kasvio outage and is published early',
      () async {
    var published = false;
    final assets = await KronHoldings(client(kasvioDown: true)).load(address,
        onProgress: (assets) {
      published = true;
      expect(assets.single.rawBalance, '1000000');
    });
    expect(published, isTrue);
    expect(assets.single.balance, 1000000);
    expect(assets.single.standard, 'kron-native');
    expect(assets.single.imageUrl, isNull);
  });
  test('Kasvio enriches metadata but cannot override KRON balance', () async {
    final asset =
        (await KronHoldings(client(decimals: 3)).load(address)).single;
    expect(asset.rawBalance, '1000000');
    expect(asset.balance, 1000);
    expect(asset.priceKas, 10);
    expect(asset.imageUrl, 'https://example.org/kasm.png');
  });
  test('stale Kasvio market data is not used', () async {
    expect(
        (await KronHoldings(client(stale: true)).load(address)).single.priceKas,
        isNull);
  });
  test('malformed optional market data cannot hide holdings', () async {
    final reader = client();
    final brokenMarkets = MockClient((request) async {
      if (request.url.host == 'kasvio.network') {
        return reply({'stale': false, 'source': 'invalid', 'tokens': {}});
      }
      return reader.get(request.url);
    });
    expect((await KronHoldings(brokenMarkets).load(address)).single.rawBalance,
        '1000000');
  });
  test('duplicate covenant holdings are rejected rather than added twice',
      () async {
    await expectLater(
        KronHoldings(client(duplicate: true)).load(address), throwsStateError);
  });
  test('same ticker with another covenant cannot supply signing data',
      () async {
    await expectLater(
        KronHoldings(client(wrongMetadata: true)).transferRows(address, id, 1),
        throwsStateError);
  });
  test('insufficient balance has an actionable error', () async {
    await expectLater(
        KronHoldings(client()).transferRows(address, id, 1000001),
        throwsA(isA<StateError>().having(
            (error) => error.message, 'message', contains('Insufficient'))));
  });
  test('ungraduated token cells are returned without a DEX filter', () async {
    final cells = await KronHoldings(client()).transferRows(address, id, 1);
    expect(cells.single['amount'], '1000000');
  });
}
