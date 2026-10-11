import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/kron_dex_service.dart';

void main() {
  final txid = 'a' * 64, cid = 'b' * 64, script = '20${'c' * 64}ac';
  Map<String, Object?> request() => {
        'tradeSummary': {
          'inputAddresses': ['kaspa:test']
        },
        'txJsonString': jsonEncode({
          'inputs': [
            {
              'transactionId': txid,
              'index': 0,
              'utxo': {
                'amount': '100000000',
                'scriptPublicKey': '0000$script',
                'blockDaaScore': '123',
                'isCoinbase': false,
                'covenantId': cid
              }
            }
          ]
        })
      };
  KronDexService service({bool spent = false, bool wrongCovenant = false}) =>
      KronDexService(
          client: MockClient((r) async => http.Response(
              jsonEncode(r.url.path.endsWith('/utxos')
                  ? spent
                      ? []
                      : [
                          {
                            'outpoint': {'transactionId': txid, 'index': 0},
                            'utxoEntry': {
                              'amount': '100000000',
                              'scriptPublicKey': {'scriptPublicKey': script},
                              'blockDaaScore': '123',
                              'isCoinbase': false
                            }
                          }
                        ]
                  : {
                      'is_accepted': true,
                      'transaction_id': txid,
                      'outputs': [
                        {
                          'index': 0,
                          'covenant_id': wrongCovenant ? 'd' * 64 : cid
                        }
                      ]
                    }),
              200)));
  test('gateway schema verifies live script and confirmed covenant separately',
      () async {
    await service().verifyInputs(request());
  });
  test('spent input cannot reach review', () async {
    await expectLater(
        service(spent: true).verifyInputs(request()), throwsStateError);
  });
  test('wrong covenant cannot reach review', () async {
    await expectLater(
        service(wrongCovenant: true).verifyInputs(request()), throwsStateError);
  });
}
