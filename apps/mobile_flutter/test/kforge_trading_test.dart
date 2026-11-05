import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/encrypted_store.dart';
import 'package:kasvault_wallet/src/services/kforge_service.dart';
import 'package:kasvault_wallet/src/services/kforge_trading.dart';
import 'package:kasvault_wallet/src/services/native_security.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';

class MemoryKForgeStore implements EncryptedStore {
  final values = <String, String>{};
  bool fail = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (!fail) values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class ReviewKForgeSecurity extends NativeSecurity {
  int prepares = 0, signs = 0;
  @override
  Future<Map<String, Object?>> preparePskt(Map<String, Object?> r,
      {bool kaspacomReview = false}) async {
    prepares++;
    return {
      'reviewHash': 'hash',
      'transactionId': 'a' * 64,
      'tradeSummary': {
        ...(r['tradeSummary'] as Map),
        'verified': {
          'tokens': '1000000',
          'walletNet': '801595507',
          'marketKas': '651595507',
          'networkFee': '60000000',
          'cellReserveChange': 90000000
        }
      }
    };
  }

  @override
  Future<Map<String, Object?>> signPskt(
      Map<String, Object?> request, String hash,
      {bool kaspacomReview = false}) async {
    signs++;
    throw StateError('No test signatures here');
  }
}

class CapturedKForgeTrading extends KForgeTrading {
  CapturedKForgeTrading(
      {required super.client, required super.store, required super.security});
  int verifications = 0;
  @override
  Future<void> verify(String address, Map tx) async {
    guard(address);
    verifications++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final capture = jsonDecode(File(
          '../../crates/kaspa_secure_core/src/fixtures/kforge-tn10-unsigned.json')
      .readAsStringSync()) as Map;
  final address = capture['wallet'] as String;
  setUp(() => NetworkSettings.network.value = KaspaNetwork.tn10);
  test('wallet refresh notification only follows durably confirmed transitions',
      () async {
    final store = MemoryKForgeStore(), t = KForgeTrading(store: store);
    var changes = 0;
    void listener() => changes++;
    KForgeTrading.changes.addListener(listener);
    addTearDown(() => KForgeTrading.changes.removeListener(listener));
    final r = <String, dynamic>{
      'address': address,
      'network': 'testnet-10',
      'id': 'b' * 64,
      'state': 'pending',
      'signed': <String, Object?>{}
    };
    await t.retain(address, r);
    expect(changes, 0);
    store.fail = true;
    await expectLater(
        t.retain(address, {...r, 'state': 'confirmed'}), throwsStateError);
    expect(changes, 0);
    store.fail = false;
    await t.retain(address, {...r, 'state': 'confirmed'});
    expect(changes, 1);
    await t.retain(address, {...r, 'state': 'confirmed'});
    expect(changes, 1);
  });
  test('graduation requires a fresh market even though Buy always uses KAS',
      () async {
    final row = capture['trades']['pool-buy'] as Map;
    final old = <String, dynamic>{
      ...Map<String, dynamic>.from(row['token'] as Map),
      'phase': 'curve',
      'pool': null
    };
    var posts = 0;
    final client = MockClient((r) async {
      if (r.method == 'POST') posts++;
      return http.Response(
          jsonEncode(r.url.path.endsWith('registry')
              ? capture['registry']
              : [row['token']]),
          200);
    });
    final t = CapturedKForgeTrading(
        client: client,
        store: MemoryKForgeStore(),
        security: ReviewKForgeSecurity());
    await expectLater(
        t.quote(
            address, KForgeToken.fromJson(old), 'buy', BigInt.from(1000000)),
        throwsStateError);
    expect(posts, 0);
  });
  Map<String, dynamic> receipt() => {
        'address': address,
        'network': 'testnet-10',
        'id': 'a' * 64,
        'state': 'pending',
        'signed': <String, Object?>{}
      };
  test(
      'all four prepare routes retain selected units and bind derived review limits',
      () async {
    for (final name in ['curve-buy', 'curve-sell', 'pool-buy', 'pool-sell']) {
      final row = capture['trades'][name] as Map, calls = <String>[];
      final client = MockClient((r) async {
        calls.add('${r.method} ${r.url.path}');
        if (r.url.path == '/v6/registry')
          return http.Response(jsonEncode(capture['registry']), 200);
        if (r.url.path == '/v6/tokens')
          return http.Response(jsonEncode([row['token']]), 200);
        expect(r.method, 'POST');
        expect(r.url.path, row['path']);
        expect(jsonDecode(r.body), row['body']);
        return http.Response(jsonEncode(row['response']), 200);
      });
      final store = MemoryKForgeStore(), security = ReviewKForgeSecurity();
      final trading = CapturedKForgeTrading(
          client: client, store: store, security: security);
      final token = KForgeToken.fromJson(row['token'] as Map),
          buy = name.endsWith('buy'),
          pool = name.startsWith('pool');
      final amount = buy
          ? (pool
              ? BigInt.from(1000000000)
              : KForgeTrading.curveBuyCost(token, 1))
          : BigInt.from(pool ? 10000 : 1000000);
      final q =
          await trading.quote(address, token, buy ? 'buy' : 'sell', amount);
      expect(security.prepares, 2);
      expect(security.signs, 0);
      expect(trading.verifications, 1);
      expect(q['request']['tradeSummary']['maximumDebit'], '801595507');
      expect(q['request']['tradeSummary']['minimumOut'],
          buy ? '1000000' : '801595507');
      expect(await trading.pending(address), isNull);
      expect(calls.where((c) => c.contains('submit')), isEmpty);
    }
  });
  test(
      'encrypted readback failure blocks submission, pending survives reopening',
      () async {
    final store = MemoryKForgeStore();
    final t = KForgeTrading(store: store);
    final r = receipt();
    await t.retain(address, r);
    expect(
        (await KForgeTrading(store: store).pending(address))?['id'], r['id']);
    store.fail = true;
    await expectLater(
        t.retain(address, {...r, 'state': 'confirmed'}), throwsStateError);
    expect((await t.pending(address))?['state'], 'pending');
    store.fail = false;
    await t.retain(address, {...r, 'state': 'confirmed'});
    expect(await t.pending(address), isNull);
    expect((await t.saved(address)).single['state'], 'confirmed');
  });
  test('exclusive action releases on failure, refuses concurrency', () async {
    final t = KForgeTrading(store: MemoryKForgeStore()),
        gate = Completer<void>();
    final first = t.exclusive(address, () => gate.future);
    await expectLater(t.exclusive(address, () async {}), throwsStateError);
    gate.complete();
    await first;
    await expectLater(
        t.exclusive(address, () async => throw StateError('fail')),
        throwsStateError);
    await t.exclusive(address, () async {});
  });
  test('network switch, expired quote and a pending swap never sign again',
      () async {
    final store = MemoryKForgeStore(), s = ReviewKForgeSecurity();
    final t = KForgeTrading(store: store, security: s);
    await expectLater(
        t.sign(address, {'at': DateTime.now().millisecondsSinceEpoch - 61000}),
        throwsStateError);
    await t.retain(address, receipt());
    await expectLater(t.sign(address, {}), throwsStateError);
    expect(s.signs, 0);
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    await expectLater(t.saved(address), throwsStateError);
  });
  test(
      'missing transaction status is not success, lookup failure preserves journal',
      () async {
    final store = MemoryKForgeStore();
    final r = receipt();
    final t = KForgeTrading(
        store: store,
        client: MockClient((_) async => http.Response('unavailable', 503)));
    await t.retain(address, r);
    await expectLater(t.resume(address, r), throwsStateError);
    expect((await t.pending(address))?['id'], r['id']);
    final missing = KForgeTrading(
        store: store,
        client: MockClient((_) async => http.Response('{}', 404)));
    expect(await missing.accepted('a' * 64), false);
    expect((await missing.pending(address))?['state'], 'pending');
  });
  test(
      'only the selected normal Schnorr SIGHASH_ALL witness is sent to the API',
      () {
    final sig = '11' * 64 + '01';
    expect(
        KForgeTrading.signature({
          'inputs': [
            {'signatureScript': '41$sig'}
          ]
        }, 0),
        sig);
    final leader = '00' * 6 + '42' + '00$sig' + '04' + '79c71c23' + '01' + 'aa';
    expect(
        KForgeTrading.signature({
          'inputs': [
            {'signatureScript': leader}
          ]
        }, 0),
        sig);
    for (final wrong in ['41' + '11' * 65, '41$sig' + '00', '4d00']) {
      expect(
          () => KForgeTrading.signature({
                'inputs': [
                  {'signatureScript': wrong}
                ]
              }, 0),
          throwsStateError);
    }
  });
}
