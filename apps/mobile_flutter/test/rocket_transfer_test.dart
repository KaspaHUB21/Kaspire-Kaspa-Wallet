import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/kasparocket_service.dart';
import 'package:kasvault_wallet/src/services/kcc20_standard_service.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';

const wallet =
    'kaspa:qqre4wt08dp0rvmxwqgwdkz4zu4m36g9uvmfledd27mx939uxe2yjpmmd37zq';
void main() {
  test(
      'Rocket display-only assets use dynamic native reference transfers, not the legacy discovery gate',
      () {
    expect(Kcc20StandardService.isStandard('kasparocket-kcc20'), true);
  });
  test('API dispatches Rocket cell preparation without any Kasvio request',
      () async {
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    final cid = 'c' * 64, txid = 'a' * 64, reads = <String>[];
    final api = KaspaApi(client: MockClient((r) async {
      reads.add(r.url.toString());
      if (r.url.path.endsWith('/protocol'))
        return http.Response('{"network":"mainnet"}', 200);
      expect(r.url.path, endsWith('/rocket-cells'));
      expect(r.url.queryParameters['tokenId'], cid);
      return http.Response(
          jsonEncode({
            'network': 'mainnet',
            'address': wallet,
            'tokenId': cid,
            'requestedAmount': '1000',
            'templateId': Kcc20StandardService.tenTemplateId,
            'inputLimit': 10,
            'requiredCells': 1,
            'cells': [
              {
                'transactionId': txid,
                'index': 3,
                'valueSompi': '200000000',
                'blockDaaScore': '123',
                'scriptPublicKey': 'aa20${'b' * 64}87',
                'tokenAmount': '84085',
                'redeemScript': '6b20aa'
              }
            ]
          }),
          200);
    }));
    final batch = await api.loadStandardKcc20SigningBatch(wallet, cid, 1000,
        sourceStandard: 'kasparocket-kcc20', fullPlan: true);
    expect(batch.inputLimit, 10);
    expect(batch.templateId, Kcc20StandardService.tenTemplateId);
    expect(batch.cells.single.tokenAmount, 84085);
    expect(batch.compound, false);
    expect(reads.any((url) => url.contains('kasvio')), false);
  });
  test(
      'Mismatched network, token or missing amount coverage never enable a Rocket transfer',
      () async {
    for (final mutation in ['network', 'tokenId', 'coverage']) {
      final cid = 'c' * 64;
      final service = KaspaRocketService(
          mainnet: true,
          client: MockClient((r) async {
            if (r.url.path.endsWith('/protocol'))
              return http.Response('{"network":"mainnet"}', 200);
            return http.Response(
                jsonEncode({
                  'network': mutation == 'network' ? 'testnet-10' : 'mainnet',
                  'address': wallet,
                  'tokenId': mutation == 'tokenId' ? 'd' * 64 : cid,
                  'requestedAmount': '1000',
                  'templateId': Kcc20StandardService.tenTemplateId,
                  'inputLimit': 10,
                  'requiredCells': 1,
                  'cells': [
                    {
                      'transactionId': 'a' * 64,
                      'index': 0,
                      'valueSompi': '200000000',
                      'blockDaaScore': '123',
                      'scriptPublicKey': 'aa20${'b' * 64}87',
                      'tokenAmount': mutation == 'coverage' ? '1' : '1000',
                      'redeemScript': '6b20aa'
                    }
                  ]
                }),
                200);
          }));
      await expectLater(service.signingBatch(wallet, cid, 1000, fullPlan: true),
          throwsStateError);
    }
  });
  test(
      'Kasseal Mainnet balances appear on the home wallet without opening Swap',
      () async {
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    final cid = 'c' * 64;
    var kassealReads = 0;
    final api = KaspaApi(client: MockClient((r) async {
      if (r.url.host == 'app.kasseal.com' && r.url.path.endsWith('/tokens')) {
        kassealReads++;
        return http.Response(
            jsonEncode({
              'address': wallet,
              'tokens': [
                {
                  'meta': {
                    'covenantId': cid,
                    'ticker': 'SEALCOIN',
                    'decimals': 0,
                    'imageSource': 'verified',
                    'imageUrl': '/v1/images/${'b' * 64}'
                  }
                }
              ],
              'holdings': [
                {
                  'tokenId': cid,
                  'balance': '49389000',
                  'cells': 1,
                  'deposits': '250000000'
                }
              ]
            }),
            200);
      }
      if (r.url.path.endsWith('/balance'))
        return http.Response('{"balance":0}', 200);
      if (r.url.path.endsWith('/utxos')) return http.Response('[]', 200);
      return http.Response('{}', 503);
    }));
    final data = await api.loadWallet(wallet,
        includeMarketData: false,
        includeAssetHistory: false,
        includeNativeTransactions: false);
    expect(kassealReads, 1);
    expect(data.kcc20Tokens.single.symbol, 'SEALCOIN');
    expect(data.kcc20Tokens.single.balance, 49389000);
    expect(data.kcc20Tokens.single.standard, 'kasseal-kcc20');
    expect(data.kcc20Tokens.single.imageUrl,
        'https://app.kasseal.com/v1/images/${'b' * 64}');
  });
}
