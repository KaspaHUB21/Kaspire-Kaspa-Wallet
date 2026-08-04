import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/models/wallet_snapshot.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';

void main() {
  const address =
      'kaspa:qz03mracsz6c0pjxmsdaql39453tn3jgmrldkqpy24ea39rxtvd9xxynslpyc';
  const otherAddress =
      'kaspa:qqd6e65yefepe9wk0m9vuxdufxd80sphy67gwwd0vdaumzdt4tc9s3qt0lqeh';

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
        return http.Response(
          '[{"address":"$address","outpoint":{"transactionId":"${'1' * 64}","index":0},"utxoEntry":{"amount":"1"}},{"address":"$address","outpoint":{"transactionId":"${'2' * 64}","index":1},"utxoEntry":{"amount":"2"}}]',
          200,
        );
      }
      if (request.url.path.endsWith('/balance')) {
        return http.Response('{"balance":0}', 200);
      }
      if (request.url.path.endsWith('/info/price')) {
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

  test('falls back to public Kaspa reads when the own gateway fails', () async {
    final fallbackPaths = <String>[];
    final client = MockClient((request) async {
      if (request.url.host == 'primary.example' &&
          (request.url.path.endsWith('/balance') ||
              request.url.path.endsWith('/info/price') ||
              request.url.path.contains('/full-transactions'))) {
        return http.Response('gateway timeout', 504);
      }
      if (request.url.host == 'api.kaspa.org') {
        fallbackPaths.add(request.url.path);
        if (request.url.path.endsWith('/balance')) {
          return http.Response('{"balance":123000000}', 200);
        }
        if (request.url.path.endsWith('/info/price')) {
          return http.Response('{"price":0.1}', 200);
        }
        return http.Response('[]', 200);
      }
      if (request.url.path.endsWith('/utxos')) {
        return http.Response('[]', 200);
      }
      if (request.url.host == 'kaspatoken.kaslab.space' ||
          request.url.host == 'kascov.io') {
        return http.Response('{}', 503);
      }
      return http.Response('[]', 200);
    });

    final snapshot = await KaspaApi(
      client: client,
      baseUrl: 'https://primary.example',
    ).loadWallet(address);

    expect(snapshot.balanceSompi, 123000000);
    expect(snapshot.kasUsd, 0.1);
    expect(fallbackPaths, hasLength(3));
  });

  test('converts the wallet fiat value into the selected currency', () async {
    AppSettings.fiatCurrency.value = FiatCurrency.eur;
    final client = MockClient((request) async {
      if (request.url.host == 'open.er-api.com') {
        return http.Response('{"rates":{"EUR":0.8}}', 200);
      }
      if (request.url.path.endsWith('/utxos')) {
        return http.Response('[]', 200);
      }
      if (request.url.path.endsWith('/balance')) {
        return http.Response('{"balance":100000000}', 200);
      }
      if (request.url.path.endsWith('/info/price')) {
        return http.Response('{"price":0.1}', 200);
      }
      if (request.url.host == 'kaspatoken.kaslab.space' ||
          request.url.host == 'kascov.io') {
        return http.Response('{}', 503);
      }
      return http.Response('[]', 200);
    });

    final snapshot = await KaspaApi(client: client).loadWallet(address);
    expect(snapshot.fiatCode, 'EUR');
    expect(snapshot.fiatSymbol, '€');
    expect(snapshot.fiatValue, closeTo(0.08, 0.0000001));
    AppSettings.fiatCurrency.value = FiatCurrency.usd;
  });

  test('rejects UTXOs attributed to another wallet', () {
    expect(
      () => KaspaApi.validateUtxos([
        {
          'address': 'kaspa:qattacker',
          'outpoint': {'transactionId': '1' * 64, 'index': 0},
          'utxoEntry': {'amount': '1000'},
        }
      ], address),
      throwsA(
        isA<KaspaApiException>().having(
          (error) => error.message,
          'message',
          contains('another address'),
        ),
      ),
    );
  });

  test('rejects duplicate and malformed UTXOs', () {
    final utxo = {
      'address': address,
      'outpoint': {'transactionId': 'a' * 64, 'index': 0},
      'utxoEntry': {'amount': '1000'},
    };
    expect(
      () => KaspaApi.validateUtxos([utxo, utxo], address),
      throwsA(isA<KaspaApiException>()),
    );
    for (final malformed in <Object?>[
      null,
      const {},
      {
        'outpoint': {'transactionId': '../evil', 'index': -1},
        'utxoEntry': {'amount': '-1'},
      },
    ]) {
      expect(
        () => KaspaApi.validateUtxos([malformed], address),
        throwsA(isA<KaspaApiException>()),
      );
    }
  });

  test('rejects impossible fee estimates instead of silently using them',
      () async {
    for (final body in [
      '{"priorityBucket":{"feerate":-1}}',
      '{"priorityBucket":{"feerate":100000001}}',
      '{"priorityBucket":{"feerate":"NaN"}}',
    ]) {
      final api = KaspaApi(
        client: MockClient((_) async => http.Response(body, 200)),
      );
      await expectLater(api.loadFeeRate(), throwsA(isA<KaspaApiException>()));
    }
  });

  test('rejects negative amounts in manipulated transaction history', () {
    expect(
      () => KaspaApi.parseTransactions([
        {
          'transaction_id': 'bad',
          'outputs': [
            {'script_public_key_address': address, 'amount': -1}
          ],
        }
      ], address),
      throwsA(isA<KaspaApiException>()),
    );
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
          '{"data":{"address":"$address","tokens":[{"symbol":"NACHO","balance":12.5,"decimals":8,"raw_balance":"1250000000"}],"krc721_tokens":[{"symbol":"TOCCATA","balance":2,"decimals":0}],"domains":[{"name":"demo.kas","status":"default","asset_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaai0"}],"transactions":[{"id":"krc20-op","token_symbol":"NACHO","amount":"2.5","from_wallet":"$otherAddress","to_wallet":"$address","timestamp":"2026-07-16T00:00:00.000Z"}]}}',
          200,
        );
      }
      if (request.url.path.endsWith('/balance')) {
        return http.Response('{"balance":0}', 200);
      }
      if (request.url.path.endsWith('/info/price')) {
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

  test('falls back to direct KRC20, KRC721 and KNS indexers', () async {
    final client = MockClient((request) async {
      if (request.url.host == 'kaspatoken.kaslab.space') {
        return http.Response('unavailable', 503);
      }
      if (request.url.host == 'api.kasplex.org' &&
          request.url.path.contains('/tokenlist')) {
        return http.Response(
          '{"result":[{"tick":"NACHO","balance":"1250000000","dec":8}]}',
          200,
        );
      }
      if (request.url.host == 'api.kasplex.org' &&
          request.url.path.endsWith('/oplist')) {
        return http.Response('{"result":[]}', 200);
      }
      if (request.url.host == 'api.knsdomains.org') {
        return http.Response(
          '{"data":{"assets":[{"asset":"fallback.kas","assetId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaai0","owner":"$address","status":"default"}],"pagination":{"totalPages":1}}}',
          200,
        );
      }
      if (request.url.host == 'krc721-indexer.kaspa.com') {
        return http.Response(
          '{"result":[{"tick":"TOCCATA","tokenId":"7"}]}',
          200,
        );
      }
      if (request.url.host == 'api.kaspa.com' &&
          request.url.path == '/api/floor-price') {
        return http.Response(
          '{"data":[{"ticker":"NACHO","floor_price":2.5}]}',
          200,
        );
      }
      if (request.url.path.endsWith('/balance')) {
        return http.Response('{"balance":0}', 200);
      }
      if (request.url.path.endsWith('/info/price')) {
        return http.Response('{"price":0.1}', 200);
      }
      if (request.url.path.contains('/full-transactions') ||
          request.url.path.endsWith('/utxos')) {
        return http.Response('[]', 200);
      }
      return http.Response('[]', 200);
    });

    final snapshot = await KaspaApi(client: client).loadWallet(address);
    expect(snapshot.krc20Tokens.single.symbol, 'NACHO');
    expect(snapshot.krc20Tokens.single.balance, 12.5);
    expect(snapshot.krc20Tokens.single.priceKas, 2.5);
    expect(snapshot.krc20Tokens.single.priceUsd, closeTo(0.25, 0.000001));
    expect(snapshot.krc721Collections.single.symbol, 'TOCCATA');
    expect(snapshot.krc721Collections.single.balance, 1);
    expect(snapshot.knsDomains.single.name, 'fallback.kas');
  });

  test('rejects manipulated token metadata while preserving KAS data',
      () async {
    final client = MockClient((request) async {
      if (request.url.host == 'kaspatoken.kaslab.space') {
        return http.Response(
          '{"data":{"tokens":[{"symbol":"<script>","balance":1,"decimals":999}],"domains":[{"name":"<script>.kas","status":"unverified"}],"transactions":[]}}',
          200,
        );
      }
      if (request.url.path.endsWith('/balance')) {
        return http.Response('{"balance":123}', 200);
      }
      if (request.url.path == '/info/price') {
        return http.Response('{"price":0.1}', 200);
      }
      if (request.url.path.endsWith('/utxos')) {
        return http.Response('[]', 200);
      }
      return http.Response('[]', 200);
    });

    final snapshot = await KaspaApi(client: client).loadWallet(address);
    expect(snapshot.balanceSompi, 123);
    expect(snapshot.krc20Tokens, isEmpty);
    expect(snapshot.knsDomains, isEmpty);
    expect(snapshot.assetWarning, contains('unusable KRC-20'));
    expect(snapshot.assetWarning, contains('unusable KNS'));
  });

  test('missing optional KNS metadata does not hide valid holdings', () async {
    final client = MockClient((request) async {
      if (request.url.host == 'kaspatoken.kaslab.space') {
        return http.Response(
          '{"data":{"tokens":[{"symbol":"NACHO","balance":12.5,"decimals":8,"raw_balance":"1250000000"}],"krc721_tokens":[{"symbol":"TOCCATA","balance":2,"decimals":0}],"domains":[{"name":"broken.kas","status":null},{"name":"chr1.runningcode.c.02.antx.kas","status":"default","asset_id":"080450581c0f6195263a50f17aafb235566e9c5038fed5b2ef4f1f39e01261bbi0"}],"transactions":[]}}',
          200,
        );
      }
      if (request.url.path.endsWith('/balance')) {
        return http.Response('{"balance":123}', 200);
      }
      if (request.url.path == '/info/price') {
        return http.Response('{"price":0.1}', 200);
      }
      if (request.url.path.endsWith('/utxos')) {
        return http.Response('[]', 200);
      }
      return http.Response('[]', 200);
    });

    final snapshot = await KaspaApi(client: client).loadWallet(address);
    expect(snapshot.krc20Tokens.single.symbol, 'NACHO');
    expect(snapshot.krc721Collections.single.symbol, 'TOCCATA');
    expect(snapshot.knsDomains, hasLength(2));
    expect(snapshot.knsDomains.first.name, 'broken.kas');
    expect(snapshot.knsDomains.first.status, isNull);
    expect(
      snapshot.knsDomains.last.name,
      'chr1.runningcode.c.02.antx.kas',
    );
    expect(snapshot.assetWarning, isNot(contains('KRC/KNS')));
    expect(snapshot.assetWarning, isNot(contains('unusable KNS')));
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

  test('marks KRON signing cells complete without a legacy template hash',
      () async {
    const owner =
        '1bacea84ca721c95d67ecace19bc499a77c03726bc8739af637bcd89abaaf058';
    const wallet =
        'kaspa:qqd6e65yefepe9wk0m9vuxdufxd80sphy67gwwd0vdaumzdt4tc9s3qt0lqeh';
    const covenant =
        '067e2835bd4533b7065444fab13828209f9ca5becf9eab10309c66b5813e9a6c';
    const txid =
        '3333333333333333333333333333333333333333333333333333333333333333';
    final client = MockClient((request) async {
      if (request.url.host == 'kcc20.info') {
        if (request.url.path == '/v1/status') {
          return http.Response(
            '{"max_daa":200,"capabilities":{"balances":true,"owner_history":true,"signing_data":true}}',
            200,
          );
        }
        if (request.url.path.endsWith('/balances')) {
          return http.Response(
            '{"balances":[{"token_id":"$covenant","balance":"16569","validation_status":"template_verified","unresolved_cells":0}],"next_cursor":null}',
            200,
          );
        }
        if (request.url.path.endsWith('/cells')) {
          return http.Response(
            '{"cells":[{"covenant_id":"$covenant","outpoint_tx_id":"$txid","outpoint_index":2,"value":50000000,"created_daa":190,"script_public_key":"0000aa20aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","redeem_script":"20${owner}010308b9400000000000000100aa","state":{"owner":"$owner","amount":16569,"is_minter":false},"signing_ready":true}],"unmapped":[]}',
            200,
          );
        }
        if (request.url.path.endsWith('/history')) {
          return http.Response('{"history":[]}', 200);
        }
        return http.Response(
          '{"token_id":"$covenant","ticker":"SHAY","decimals":0,"standard":"kron-native","contract_type":"kron-native","validation_status":"template_verified","unresolved_cells":0}',
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

    final token =
        (await KaspaApi(client: client).loadWallet(wallet)).kcc20Tokens.single;
    expect(token.standard, 'kron-native');
    expect(token.templateHash, isEmpty);
    expect(token.discoveryComplete, isTrue);
    expect(token.kcc20Cells.single.tokenAmount, 16569);
    expect(token.kcc20Cells.single.redeemScript, isNotEmpty);
    expect(token.kcc20Cells.single.scriptPublicKey, startsWith('aa20'));
  });

  test('resolves an exact KNS domain owner', () async {
    const resolved =
        'kaspa:qqd6e65yefepe9wk0m9vuxdufxd80sphy67gwwd0vdaumzdt4tc9s3qt0lqeh';
    final client = MockClient(
      (_) async => http.Response('{"data":{"address":"$resolved"}}', 200),
    );

    expect(
      await KaspaApi(client: client)
          .resolveWalletInput('CHR1.RunningCode.C.02.ANTX.KAS'),
      resolved,
    );
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

  test('verifies a live KCC20 covenant cell against the own node', () async {
    final transactionId = 'a' * 64;
    final covenantId = 'b' * 64;
    const script = 'aa20deadbeef87';
    const scriptAddress = 'kaspa:pnode-confirmed-cell';
    final cell = Kcc20CellRecord(
      covenantId: covenantId,
      transactionId: transactionId,
      index: 2,
      valueSompi: 50000000,
      blockDaaScore: 42,
      scriptPublicKey: script,
      tokenAmount: 1000,
    );
    final client = MockClient((request) async {
      if (request.url.path.contains('/local-node/transactions/')) {
        return http.Response(
          jsonEncode({
            'transaction_id': transactionId,
            'is_accepted': true,
            'outputs': [
              {
                'index': 2,
                'amount': 50000000,
                'script_public_key': script,
                'script_public_key_address': scriptAddress,
                'covenant_id': covenantId,
              }
            ],
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/utxos')) {
        return http.Response(
          jsonEncode([
            {
              'outpoint': {'transactionId': transactionId, 'index': 2},
              'utxoEntry': {
                'amount': '50000000',
                'scriptPublicKey': {'scriptPublicKey': script},
                'isCoinbase': false,
              },
            }
          ]),
          200,
        );
      }
      return http.Response('{}', 404);
    });

    await KaspaApi(client: client).verifyKcc20CellsOnOwnNode(
      [cell],
      covenantId,
    );
  });

  test('rejects duplicate KCC20 outpoints before querying the node', () async {
    final transactionId = 'a' * 64;
    final covenantId = 'b' * 64;
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('{}', 500);
    });
    final cell = Kcc20CellRecord(
      covenantId: covenantId,
      transactionId: transactionId,
      index: 0,
      valueSompi: 1,
      blockDaaScore: 1,
      scriptPublicKey: 'aa',
      tokenAmount: 1,
    );

    await expectLater(
      KaspaApi(client: client).verifyKcc20CellsOnOwnNode(
        [cell, cell],
        covenantId,
      ),
      throwsA(isA<KaspaApiException>()),
    );
    expect(requests, 0);
  });

  test('rejects an indexer covenant conflicting with the own node', () async {
    final transactionId = 'a' * 64;
    final covenantId = 'b' * 64;
    final client = MockClient((request) async => http.Response(
          jsonEncode({
            'transaction_id': transactionId,
            'is_accepted': true,
            'outputs': [
              {
                'index': 0,
                'amount': 1,
                'script_public_key': 'aa',
                'script_public_key_address': 'kaspa:pfake',
                'covenant_id': 'c' * 64,
              }
            ],
          }),
          200,
        ));
    final cell = Kcc20CellRecord(
      covenantId: covenantId,
      transactionId: transactionId,
      index: 0,
      valueSompi: 1,
      blockDaaScore: 1,
      scriptPublicKey: 'aa',
      tokenAmount: 1,
    );

    expect(
      () => KaspaApi(client: client).verifyKcc20CellsOnOwnNode(
        [cell],
        covenantId,
      ),
      throwsA(isA<KaspaApiException>()),
    );
  });
}
