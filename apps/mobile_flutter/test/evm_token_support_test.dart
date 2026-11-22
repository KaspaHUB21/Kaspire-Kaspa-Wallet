import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/evm_api.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';

void main() {
  tearDown(() => NetworkSettings.network.value = KaspaNetwork.mainnet);
  for (final network in [KaspaNetwork.igra, KaspaNetwork.kasplex]) {
    test(
        '$network: unlisted ERC20 is supported, NFT excluded and missing decimals read exactly',
        () async {
      NetworkSettings.network.value = network;
      final contract = '0x${'a' * 40}',
          missing = '0x${'c' * 40}',
          unread = '0x${'d' * 40}';
      final api = EvmApi(client: MockClient((request) async {
        if (request.method == 'POST') {
          final p = jsonDecode(request.body) as Map;
          Object? result = '0x0';
          if (p['method'] == 'eth_call') {
            final to = p['params'][0]['to'];
            if (to == unread)
              return http.Response(
                  jsonEncode({
                    'jsonrpc': '2.0',
                    'id': p['id'],
                    'error': {
                      'code': -32000,
                      'message': 'fixture metadata unavailable'
                    }
                  }),
                  200);
            result = '0x${'8'.padLeft(64, '0')}';
          }
          return http.Response(
              jsonEncode({'jsonrpc': '2.0', 'id': p['id'], 'result': result}),
              200);
        }
        if (request.url.host == 'api.katbridge.com')
          return http.Response('[]', 200);
        return http.Response(
            jsonEncode([
              {
                'token': {
                  'address_hash': contract,
                  'symbol': 'NEW',
                  'name': 'New token',
                  'type': 'ERC-20',
                  'decimals': '6'
                },
                'value': '1234567'
              },
              {
                'token': {
                  'address_hash': missing,
                  'symbol': 'READ',
                  'type': 'ERC-20'
                },
                'value': '123456789'
              },
              {
                'token': {
                  'address_hash': unread,
                  'symbol': 'RAW',
                  'type': 'ERC-20'
                },
                'value': '42'
              },
              {
                'token': {'address_hash': '0x${'b' * 40}', 'type': 'ERC-721'},
                'value': '1'
              },
              {
                'token': {
                  'address_hash': 'not-a-contract',
                  'type': 'ERC-20',
                  'decimals': 18
                },
                'value': '123'
              },
            ]),
            200);
      }));
      final wallet = await api.loadWallet('0x${'1' * 40}');
      expect(wallet.tokens.length, 3);
      final normal = wallet.tokens.singleWhere((t) => t.symbol == 'NEW');
      expect(normal.trusted, isFalse);
      expect(normal.canTransfer, isTrue);
      expect(normal.decimals, 6);
      expect(normal.rawBalance, BigInt.from(1234567));
      expect(wallet.tokens.singleWhere((t) => t.symbol == 'READ').decimals, 8);
      final raw = wallet.tokens.singleWhere((t) => t.symbol == 'RAW');
      expect(raw.canTransfer, isFalse);
      expect(raw.rawBalance, BigInt.from(42));
      expect(raw.decimals, -1);
    });
  }
}
