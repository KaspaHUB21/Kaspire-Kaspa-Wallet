import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';

void main() {
  const address = 'kaspa:qtestaddress';

  test('parses an incoming transaction from decoded outputs', () {
    final result = KaspaApi.parseTransactions([
      {
        'transaction_id': 'abc123',
        'block_time': 1700000000000,
        'inputs': <Object?>[],
        'outputs': [
          {'script_public_key_address': address, 'amount': 250000000},
          {'script_public_key_address': 'kaspa:qother', 'amount': 1000},
        ],
      },
    ], address);

    expect(result, hasLength(1));
    expect(result.single.incoming, isTrue);
    expect(result.single.amountKas, 2.5);
  });

  test('parses net spend and ignores change', () {
    final result = KaspaApi.parseTransactions([
      {
        'transaction_id': 'def456',
        'block_time': 1700000000000,
        'inputs': [
          {
            'previous_outpoint_address': address,
            'previous_outpoint_amount': 500000000,
          },
        ],
        'outputs': [
          {'script_public_key_address': address, 'amount': 190000000},
          {
            'script_public_key_address': 'kaspa:qrecipient',
            'amount': 300000000,
          },
        ],
      },
    ], address);

    expect(result.single.incoming, isFalse);
    expect(result.single.amountKas, 3.1);
    expect(result.single.feeSompi, 10000000);
    expect(result.single.totalInputSompi, 500000000);
    expect(result.single.totalOutputSompi, 490000000);
    expect(result.single.inputCount, 1);
    expect(result.single.outputCount, 2);
    expect(result.single.from.single.address, address);
    expect(result.single.to.last.address, 'kaspa:qrecipient');
  });

  test('counts wallet UTXOs in the wallet snapshot', () async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/utxos')) {
        return http.Response('[{"outpoint":{}},{"outpoint":{}}]', 200);
      }
      if (request.url.path.endsWith('/balance')) {
        return http.Response('{"balance":0}', 200);
      }
      if (request.url.path == '/info/price') {
        return http.Response('{"price":0.1}', 200);
      }
      if (request.url.host == 'kaspatoken.kaslab.space' ||
          request.url.host == 'kascov.io') {
        return http.Response('{}', 503);
      }
      return http.Response('[]', 200);
    });

    final snapshot = await KaspaApi(client: client).loadWallet(address);
    expect(snapshot.utxoCount, 2);
  });

  test('loads KRC-20, KRC-721 and KNS wallet assets', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/token/krc20-nacho') {
        return http.Response(
          '{"data":{"image_url":"https://images.example/nacho.png"}}',
          200,
        );
      }
      if (request.url.host == 'kaspatoken.kaslab.space') {
        return http.Response(
          '{"data":{"address":"$address","tokens":[{"symbol":"NACHO","balance":12.5,"decimals":8,"raw_balance":"1250000000"}],"krc721_tokens":[{"symbol":"TOCCATA","balance":2}],"domains":[{"name":"demo.kas","status":"verified","asset_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaai0"}],"transactions":[{"id":"krc20-op","token_symbol":"NACHO","amount":2.5,"from_wallet":"kaspa:qsender","to_wallet":"$address","timestamp":"2026-07-16T00:00:00.000Z"}]}}',
          200,
        );
      }
      if (request.url.path.endsWith('/balance')) {
        return http.Response('{"balance":0}', 200);
      }
      if (request.url.path == '/info/price') {
        return http.Response('{"price":0.1}', 200);
      }
      return http.Response('[]', 200);
    });

    final snapshot = await KaspaApi(client: client).loadWallet(address);
    expect(snapshot.krc20Tokens.single.symbol, 'NACHO');
    expect(
      snapshot.krc20Tokens.single.imageUrl,
      'https://images.example/nacho.png',
    );
    expect(snapshot.krc721Collections.single.balance, 2);
    expect(snapshot.krc20Tokens.single.decimals, 8);
    expect(snapshot.krc20Tokens.single.rawBalance, '1250000000');
    expect(snapshot.knsDomains.single.name, 'demo.kas');
    expect(snapshot.knsDomains.single.assetId, endsWith('i0'));
    final tokenActivity =
        snapshot.transactions.singleWhere((tx) => tx.id == 'krc20-op');
    expect(tokenActivity.assetKind, 'KRC-20');
    expect(tokenActivity.incoming, isTrue);
    expect(tokenActivity.amountLabel, '2.5 NACHO');
  });

  test('loads KCC20 cells when live_utxos is a numeric count', () async {
    const owner =
        '1111111111111111111111111111111111111111111111111111111111111111';
    const covenant =
        '2222222222222222222222222222222222222222222222222222222222222222';
    const txid =
        '3333333333333333333333333333333333333333333333333333333333333333';
    const template =
        '36205a78ae657a7f1db798f6c52925ca82aca7361df71ef6a8202ce05aa7ec5f';
    final client = MockClient((request) async {
      if (request.url.host == 'kascov.io') {
        if (request.url.path.contains('/addr/')) {
          return http.Response('{"pubkey":"$owner"}', 200);
        }
        if (request.url.path.endsWith('/tokens.json')) {
          return http.Response(
            '{"tip_daa":200,"tip_at_ms":1780000000000,"note":"verified means every event matched","tokens":[{"covenant_id":"$covenant","status":"verified","claimed_ticker":"COIN","claimed_decimals":2}]}',
            200,
          );
        }
        if (request.url.path.endsWith('/token/$covenant')) {
          return http.Response(
            '{"token":{"covenant_id":"$covenant","status":"verified","claimed_ticker":"COIN","claimed_decimals":2},"balances":[{"owner":"$owner","balance":1000}],"events":[{"txid":"$txid","delta_idx":0,"accepting_daa":190,"token_kind":"mint","amount":1000,"owner_to":"$owner"}],"validation":{"checked":1}}',
            200,
          );
        }
        return http.Response(
          '{"lineage_complete":true,"live_utxos":1,"kcc1_template_hash":"$template","utxos":[{"outpoint":"$txid:0","value":50000000,"live":true,"created_daa":190,"script_hex":"aa","state_fields":[{"name":"program_hash","value":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}]}',
          200,
        );
      }
      if (request.url.path.endsWith('/balance')) {
        return http.Response('{"balance":0}', 200);
      }
      if (request.url.path == '/info/price') {
        return http.Response('{"price":0.1}', 200);
      }
      if (request.url.host == 'kaspatoken.kaslab.space') {
        return http.Response('{}', 503);
      }
      return http.Response('[]', 200);
    });

    final snapshot = await KaspaApi(client: client).loadWallet(address);
    final token = snapshot.kcc20Tokens.single;
    expect(token.symbol, 'COIN');
    expect(token.balance, 10);
    expect(token.discoveryComplete, isTrue);
    expect(token.kcc20Cells.single.tokenAmount, 1000);
    expect(token.templateHash, template);
    expect(snapshot.assetWarning, isNot(contains('verified means')));
    expect(
      snapshot.withTransactions(const []).kcc20Tokens,
      same(snapshot.kcc20Tokens),
    );
    final activity =
        snapshot.transactions.singleWhere((item) => item.id == txid);
    expect(activity.assetKind, 'KCC20');
    expect(activity.amountLabel, '10 COIN');
    expect(
      activity.to.single.address,
      'kaspa:qqg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zng5quzmq',
    );
    expect(activity.to.single.ownerId, owner);
  });

  test('uses kcc20.info owner data without Kascov when signing-ready',
      () async {
    const owner =
        '1bacea84ca721c95d67ecace19bc499a77c03726bc8739af637bcd89abaaf058';
    const wallet =
        'kaspa:qqd6e65yefepe9wk0m9vuxdufxd80sphy67gwwd0vdaumzdt4tc9s3qt0lqeh';
    const covenant =
        '2222222222222222222222222222222222222222222222222222222222222222';
    const txid =
        '3333333333333333333333333333333333333333333333333333333333333333';
    const template =
        '36205a78ae657a7f1db798f6c52925ca82aca7361df71ef6a8202ce05aa7ec5f';
    var usedPrimary = false;
    var resolvedThroughKascov = false;
    final client = MockClient((request) async {
      if (request.url.host == 'kcc20.info') {
        usedPrimary = true;
        if (request.url.path == '/v1/status') {
          return http.Response(
            '{"max_daa":200,"capabilities":{"balances":true,"owner_history":true,"signing_data":true}}',
            200,
          );
        }
        if (request.url.path.endsWith('/balances')) {
          return http.Response(
            '{"owner":"$owner","balances":[{"token_id":"$covenant","balance":"1000","validation_status":"verified","unresolved_cells":0}],"next_cursor":null}',
            200,
          );
        }
        if (request.url.path.endsWith('/cells')) {
          return http.Response(
            '{"owner":"$owner","cells":[{"token_id":"$covenant","outpoint_tx_id":"$txid","outpoint_index":0,"value":50000000,"created_daa":190,"script_public_key":"aa","token_amount":"1000","template_hash":"$template","owner":"$owner","signing_ready":true}],"unmapped":[]}',
            200,
          );
        }
        if (request.url.path.endsWith('/history')) {
          return http.Response(
            '{"owner":"$owner","history":[{"daa":190,"tx_id":"$txid","token_id":"$covenant","balance_delta":"1000","kind":"mint"}]}',
            200,
          );
        }
        return http.Response(
          '{"token_id":"$covenant","ticker":"COIN","claimed_decimals":2,"validation_status":"verified","unresolved_cells":0}',
          200,
        );
      }
      if (request.url.host == 'kascov.io') {
        if (request.url.path.contains('/addr/')) {
          resolvedThroughKascov = true;
          return http.Response('{"pubkey":"$owner"}', 200);
        }
        if (request.url.path.endsWith('/token/$covenant')) {
          return http.Response(
            '{"token":{"status":"verified","claimed_ticker":"COIN","claimed_decimals":2},"balances":[{"owner":"$owner","balance":1000}],"events":[]}',
            200,
          );
        }
        return http.Response(
          '{"lineage_complete":true,"live_utxos":1,"kcc1_template_hash":"$template","utxos":[{"outpoint":"$txid:0","value":50000000,"live":true,"script_hex":"aa","state_fields":[{"name":"amount","value":"e803000000000000"},{"name":"owner_identifier","value":"$owner"}]}]}',
          200,
        );
      }
      if (request.url.path.endsWith('/balance')) {
        return http.Response('{"balance":0}', 200);
      }
      if (request.url.path == '/info/price') {
        return http.Response('{"price":0.1}', 200);
      }
      if (request.url.host == 'kaspatoken.kaslab.space') {
        return http.Response('{}', 503);
      }
      return http.Response('[]', 200);
    });

    final snapshot = await KaspaApi(client: client).loadWallet(wallet);
    expect(usedPrimary, isTrue);
    expect(resolvedThroughKascov, isFalse);
    expect(snapshot.kcc20Tokens.single.symbol, 'COIN');
    expect(snapshot.kcc20Tokens.single.rawBalance, '1000');
    expect(snapshot.kcc20Tokens.single.discoveryComplete, isTrue);
    expect(snapshot.transactions.any((item) => item.id == txid), isTrue);
  });

  test('resolves an exact KNS domain owner', () async {
    const resolved =
        'kaspa:qqd6e65yefepe9wk0m9vuxdufxd80sphy67gwwd0vdaumzdt4tc9s3qt0lqeh';
    final client = MockClient(
      (_) async => http.Response('{"data":{"address":"$resolved"}}', 200),
    );

    expect(await KaspaApi(client: client).resolveWalletInput('Demo.KAS'),
        resolved);
  });

  test('broadcasts KCC20 SafeJSON through Toccata wRPC transport', () async {
    const transactionId =
        '4444444444444444444444444444444444444444444444444444444444444444';
    final client = MockClient((request) async {
      expect(request.url.host, 'gothdag.kaslab.space');
      expect(request.url.path, '/api/covenant-broadcast');
      final body = jsonDecode(request.body) as Map<String, Object?>;
      expect(body['signedTxJson'], '{"version":1,"computeBudget":20}');
      return http.Response('{"ok":true,"txId":"$transactionId"}', 200);
    });

    final result = await KaspaApi(client: client).broadcastKcc20(
      '{"version":1,"computeBudget":20}',
      expectedTransactionId: transactionId,
    );
    expect(result, transactionId);
  });

  test('loads individual NFTs for an owned KRC-721 collection', () async {
    final client = MockClient(
      (request) async => request.method == 'POST'
          ? http.Response(
              '{"items":[{"tokenId":"42","rarityRank":7}]}',
              200,
            )
          : http.Response(
              '{"data":{"ticker":"TOCCATA","total":1,"next_offset":null,"nfts":[{"ticker":"TOCCATA","token_id":"42","image_url":"https://images.example/42.png","rarity_rank":null}]}}',
              200,
            ),
    );

    final page = await KaspaApi(client: client).loadNftCollection(
      address,
      'TOCCATA',
    );
    expect(page.total, 1);
    expect(page.nfts.single.tokenId, '42');
    expect(page.nfts.single.rarityRank, 7);
  });
}
