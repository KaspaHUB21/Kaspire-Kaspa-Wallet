import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/kasparocket_service.dart';

void main() {
  test('KaspaRocket provider ID is preserved only as non-consensus metadata',
      () {
    const providerId =
        'd6315814616f4732a10a77673081d3ed144a054be8974f412dbd469fb95c0df7';
    final request = KaspaRocketService().signingRequest(
      address:
          'kaspatest:qrr92fscxfvdadn4zcmkll5v76ep6nz9gae4sr43crrxey84a9zuzuuczvuhd',
      token: const KaspaRocketToken(
        tokenId:
            'd80ca3a50a0f58e23695335dfbfa24dbab33a861c331436dfd4e66859607940b',
        ticker: 'KRAT',
        name: 'Kaspian Rodent',
        image: '',
        description: '',
      ),
      poolId:
          'f8ce03e171bbeaaeca5c4f538cb4274e83b4aebd7e0b6650c66ee7217a710195',
      side: 'buy',
      summary: const <String, Object?>{},
      planned: <String, Object?>{
        'tx': <String, Object?>{
          'id': providerId,
          'version': 1,
          'inputs': <Object?>[
            <String, Object?>{
              'previousOutpoint': <String, Object?>{
                'transactionId':
                    '1111111111111111111111111111111111111111111111111111111111111111',
                'index': 0,
              },
              'sequence': '0',
              'computeBudget': 10,
              'signatureScript': '',
              'utxo': <String, Object?>{
                'amount': '100000000',
                'scriptPublicKey': <String, Object?>{
                  'version': 0,
                  'script':
                      '202222222222222222222222222222222222222222222222222222222222222222ac',
                },
                'blockDaaScore': '1',
                'isCoinbase': false,
              },
            },
          ],
          'outputs': <Object?>[
            <String, Object?>{
              'value': '99900000',
              'scriptPublicKey': <String, Object?>{
                'version': 0,
                'script':
                    '202222222222222222222222222222222222222222222222222222222222222222ac',
              },
              'covenant': null,
            },
          ],
          'subnetworkId': '0000000000000000000000000000000000000000',
          'lockTime': '0',
          'gas': '0',
          'mass': '1000',
          'payload': '',
        },
        'signingInstructions': const <Object?>[],
      },
    );

    final transaction =
        jsonDecode(request['txJsonString']! as String) as Map<String, dynamic>;
    expect(transaction.containsKey('id'), isFalse);
    expect(transaction['providerTransactionId'], providerId);
    expect(transaction['storageMass'], '1000');
  });

  test('KaspaRocket wallet holdings become visible but not blindly spendable',
      () async {
    final client = MockClient((request) async => http.Response(
          jsonEncode({
            'tokens': [
              {
                'kcc20_covenant_id':
                    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                'ticker': 'rocket',
                'balance_tokens': '427757',
                'price_sompi': '117000000',
                'image_url': 'https://example.invalid/rocket.png',
              },
              {
                'kcc20_covenant_id':
                    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
                'ticker': 'empty',
                'balance_tokens': '0',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ));

    final assets =
        await KaspaRocketService(client: client, apiKey: 'krpub_test_fixture')
            .walletAssets(
      'kaspatest:qtest',
    );

    expect(assets, hasLength(1));
    expect(assets.single.symbol, 'ROCKET');
    expect(assets.single.balance, 427.757);
    expect(assets.single.priceKas, 1.17);
    expect(assets.single.standard, 'kasparocket-kcc20');
    expect(assets.single.discoveryComplete, isFalse);
  });

  test('SDK amountTokensDisplay takes precedence over raw token units', () {
    expect(
        KaspaRocketService.amountTokensDisplay({
          'amountTokens': '420290',
          'amountTokensDisplay': '420.29',
        }),
        '420.29');
    expect(
        KaspaRocketService.amountTokensDisplay({
          'amount_tokens': '15875064',
          'amount_tokens_display': '15875.064',
        }),
        '15875.064');
  });

  test('legacy quote amounts still use one canonical decimal conversion', () {
    expect(KaspaRocketService.amountTokensDisplay({'amountTokens': '420290'}),
        '420.29');
    expect(
        KaspaRocketService.amountTokensDisplay({'amount_tokens': '1000'}), '1');
  });
}
