import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kasvault_wallet/src/services/kasparocket_service.dart';
import 'package:kasvault_wallet/src/services/encrypted_store.dart';
import 'package:kasvault_wallet/src/services/activity_store.dart';

class MemoryStore implements EncryptedStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('Mainnet uses only the pinned gateway, never client bearer credentials',
      () async {
    final paths = <String>[];
    final service = KaspaRocketService(
        mainnet: true,
        apiKey: 'must-not-leave-client',
        client: MockClient((request) async {
          expect(request.url.host, 'kaspire.kaslab.space');
          expect(request.headers.containsKey('authorization'), isFalse);
          paths.add(request.url.path);
          return http.Response(
              jsonEncode(request.url.path.endsWith('/protocol')
                  ? {'network': 'mainnet'}
                  : request.url.path.endsWith('/tokens')
                      ? []
                      : {'tokens': []}),
              200);
        }));
    expect(await service.tokens(), isEmpty);
    expect(paths.first, '/api/kasparocket/pro-api/protocol');
    expect(service.networkId, 'mainnet');
  });
  test('TN10 rejects an upstream silently switched to Mainnet', () async {
    var calls = 0;
    final service = KaspaRocketService(
        apiKey: 'krpub_test_fixture',
        client: MockClient((_) async {
          calls++;
          return http.Response('{"network":"mainnet"}', 200);
        }));
    await expectLater(service.tokens(), throwsStateError);
    expect(calls, 1);
  });
  test('Mainnet rejects testnet plans before the route endpoint is called',
      () async {
    var calls = 0;
    final service = KaspaRocketService(
        mainnet: true,
        client: MockClient((_) async {
          calls++;
          return http.Response('{"network":"mainnet"}', 200);
        }));
    await expectLater(
        service.plan(
            address: 'kaspatest:qfixture',
            tokenId: 'a' * 64,
            poolId: 'b' * 64,
            side: 'buy',
            rawAmount: '100'),
        throwsStateError);
    expect(calls, 1);
  });
  test('Recovery is wallet/network-bound and accepted swaps never resubmit',
      () async {
    final store = MemoryStore();
    var posts = 0;
    final service = KaspaRocketService(
        mainnet: true,
        store: store,
        client: MockClient((request) async {
          if (request.method == 'POST') posts++;
          return http.Response('{"network":"mainnet"}', 200);
        }));
    const wallet = 'kaspa:qfixture';
    await service.retain(wallet, {
      'network': 'mainnet',
      'address': wallet,
      'signed': [<String, Object?>{}],
      'transactionIds': ['c' * 64],
      'receipts': <Object?>[],
      'next': 0,
      'side': 'buy',
      'token': 'ROCKET',
      'tokenCovenant': 'a' * 64,
      'summary': {'amountTokens': '1000'},
      'timestamp': DateTime.utc(2026).toIso8601String(),
    });
    expect(await service.pending('kaspa:qother'), isNull);
    expect(await KaspaRocketService(store: store).pending(wallet), isNull);
    final result = await service.resume(wallet,
        accepted: (_) async => true,
        activity: ActivityStore(encryptedStore: store));
    expect(result['next'], 1);
    expect(posts, 0);
    expect(await service.pending(wallet), isNull);
    final activity = await ActivityStore(encryptedStore: store).load(wallet);
    expect(activity.single.assetSymbol, 'ROCKET');
    expect(activity.single.displayAmount, '1');
  });
  test('Failed submit keeps the exact signed swap for retry', () async {
    final store = MemoryStore();
    var posts = 0;
    final service = KaspaRocketService(
        mainnet: true,
        store: store,
        client: MockClient((request) async {
          if (request.method == 'POST') {
            posts++;
            return http.Response('{"error":"offline"}', 503);
          }
          return http.Response('{"network":"mainnet"}', 200);
        }));
    await service.retain('kaspa:qfixture', {
      'network': 'mainnet',
      'address': 'kaspa:qfixture',
      'signed': [
        {'signatureScript': 'signed-bytes'}
      ],
      'transactionIds': ['c' * 64],
      'receipts': <Object?>[],
      'next': 0,
    });
    await expectLater(
        service.resume('kaspa:qfixture', accepted: (_) async => false),
        throwsStateError);
    expect(posts, 1);
    expect((await service.pending('kaspa:qfixture'))!['signed'], [
      {'signatureScript': 'signed-bytes'}
    ]);
  });
}
