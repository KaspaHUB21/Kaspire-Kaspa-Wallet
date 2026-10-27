import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/kasforge_trading.dart';
import 'package:kasvault_wallet/src/services/encrypted_store.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';

const address =
    'kaspatest:qp2srppaehqgjxxw4fyf2ckdzha9nz573eapxw0acg4ntc27cy2w23jck27ql';

class Memory implements EncryptedStore {
  final data = <String, String>{};
  bool fail = false;
  @override
  Future<String?> read(String k) async => data[k];
  @override
  Future<void> write(String k, String v) async {
    if (!fail) data[k] = v;
  }

  @override
  Future<void> delete(String k) async {
    data.remove(k);
  }
}

Map<String, dynamic> receipt() => {
      'buildId': 'fixture',
      'address': address,
      'network': 'testnet-10',
      'signed': ['saved signatures'],
      'requests': [{}],
      'transactionIds': ['a' * 64],
      'side': 'sell',
      'state': 'signed',
      'order': {
        'output': {'outpoint': '${'a' * 64}:2', 'sompi': 100000000},
        'state': {'unitsIn': null, 'minSompi': 100000000, 'kcc20': 'b' * 64}
      }
    };
void main() {
  setUp(() => NetworkSettings.network.value = KaspaNetwork.tn10);
  test('Forge amounts never pass through floating point or scientific notation',
      () {
    expect(KasForgeTrading.kasSompi('10.00000001'), BigInt.from(1000000001));
    for (final text in ['1e3', '-1', '1.000000001', 'NaN', '1,000']) {
      expect(() => KasForgeTrading.kasSompi(text), throwsStateError);
    }
  });
  test('Mainnet fails before any build or HTTP call', () async {
    var calls = 0;
    final trading = KasForgeTrading(client: MockClient((_) async {
      calls++;
      return http.Response('{}', 200);
    }));
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    await expectLater(
        trading.call(address, 'build', body: {}), throwsStateError);
    expect(calls, 0);
  });
  test('saved journals survive failed submit and reopening', () async {
    final store = Memory();
    final trading = KasForgeTrading(
        store: store,
        client: MockClient((_) async =>
            http.Response(jsonEncode({'error': 'build expired'}), 409)));
    final r = receipt();
    await trading.retain(address, r);
    await expectLater(trading.submit(address, r), throwsStateError);
    expect((await KasForgeTrading(store: store).pending(address))!['signed'],
        r['signed']);
  });
  test(
      'failed durable save stops submission before HTTP and rejects another wallet',
      () async {
    var calls = 0;
    final store = Memory()..fail = true;
    final trading = KasForgeTrading(
        store: store,
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }));
    await expectLater(trading.submit(address, receipt()), throwsStateError);
    expect(calls, 0);
    await expectLater(
        trading.retain(address, {...receipt(), 'address': 'foreign'}),
        throwsStateError);
  });
  test(
      'API success cannot finish an order without exact accepted on-chain spend',
      () async {
    final store = Memory(), r = receipt();
    final trading = KasForgeTrading(
        store: store,
        client: MockClient((request) async => http.Response(
            jsonEncode(request.url.host == 'api-tn10.kaspa.org'
                ? {
                    'transaction_id': 'c' * 64,
                    'is_accepted': true,
                    'inputs': [],
                    'outputs': []
                  }
                : {'ok': true, 'status': 'filled', 'txid': 'c' * 64}),
            200)));
    await trading.retain(address, r);
    await expectLater(trading.status(address, r), throwsStateError);
    expect(r['finalVerified'], isNot(true));
    expect(await trading.pending(address), isNotNull);
  });
  test('per-wallet operation lock releases after an authorization error',
      () async {
    final trading = KasForgeTrading();
    await expectLater(
        trading.exclusive(address, () async => throw StateError('cancelled')),
        throwsStateError);
    expect(await trading.exclusive(address, () async => 42), 42);
  });
}
