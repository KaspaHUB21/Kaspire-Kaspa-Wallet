import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/kasforge_trading.dart';
import 'package:kasvault_wallet/src/services/native_security.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'kasforge_trading_test.dart' as fixtures;

String identity(Map request) =>
    jsonDecode('${request['txJsonString']}')['inputs'][0]['transactionId'] ==
            'a' * 64
        ? 'b' * 64
        : 'a' * 64;

class StepSecurity extends NativeSecurity {
  final signedIds = <String>[];
  void Function(String)? beforeSign;
  @override
  Future<Map<String, Object?>> preparePskt(Map<String, Object?> request,
          {bool kaspacomReview = false}) async =>
      {
        'transactionId': identity(request),
        'reviewHash': 'review-${identity(request)}'
      };
  @override
  Future<Map<String, Object?>> signPskt(
      Map<String, Object?> request, String hash,
      {bool kaspacomReview = false}) async {
    final id = identity(request);
    beforeSign?.call(id);
    signedIds.add(id);
    final tx = jsonDecode('${request['txJsonString']}') as Map;
    tx['inputs'][0]['signatureScript'] = '41${fixtures.ownerSignature}';
    return {
      'transactionId': id,
      'signedTxJson': jsonEncode(tx),
      'wrpcJson': jsonEncode(tx)
    };
  }
}

class StepTrading extends KasForgeTrading {
  StepTrading(StepSecurity auth, fixtures.Memory memory, http.Client client)
      : super(security: auth, store: memory, client: client);
  final acceptedIds = <String>{};
  final verificationParents = <int>[];
  @override
  Future<List<int>> readClocks() async => [1000000, 1000000];
  @override
  Future<bool> accepted(String id) async => acceptedIds.contains(id);
  @override
  Future<void> verify(String address, Map tx, Map<String, Map> parents) async {
    verificationParents.add(parents.length);
    if (tx['inputs'][0]['transactionId'] == 'a' * 64 &&
        !acceptedIds.contains('a' * 64)) {
      throw StateError('Parent not independently accepted');
    }
  }

  @override
  Future<void> waitForPreparation(List<String> ids) async {
    if (ids.any((id) => !acceptedIds.contains(id))) {
      throw KasForgeConfirmationPending();
    }
  }
}

Map<String, dynamic> plan() {
  final first = fixtures.unsignedTx();
  final second = jsonDecode(jsonEncode(first)) as Map;
  second['inputs'][0]['transactionId'] = 'a' * 64;
  Map<String, Object?> request(Map tx) => {
        'sender': fixtures.address,
        'profile': 'kasforge-tn10-order-v1',
        'txJsonString': jsonEncode(tx),
        'signInputs': [
          {'index': 0, 'sighashType': 1}
        ],
        'scripts': <Object>[]
      };
  return {
    'buildId': 'multi-step-fixture',
    'address': fixtures.address,
    'network': 'testnet-10',
    'contracts': '3.8',
    'stepSubmit': true,
    'side': 'sell',
    'state': 'prepared',
    'requests': [request(first), request(second)],
    'reviews': [
      {'reviewHash': 'review-${'a' * 64}'},
      {'reviewHash': 'review-${'b' * 64}'}
    ],
    'transactionIds': ['a' * 64, 'b' * 64],
    'order': {
      'state': {'expiryDaa': 1036000}
    }
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => NetworkSettings.network.value = KaspaNetwork.tn10);
  test(
      'submit prefix, independently confirm, sign dependent step, submit full plan',
      () async {
    final auth = StepSecurity(), memory = fixtures.Memory(), bodies = <Map>[];
    late StepTrading trading;
    trading = StepTrading(auth, memory, MockClient((request) async {
      final body = jsonDecode(request.body) as Map;
      bodies.add(body);
      expect(request.url.path, '/api/v1/submit');
      if (body['step'] == true) {
        expect(body['signed'], hasLength(1));
        expect(auth.signedIds, ['a' * 64]);
        final saved =
            (await KasForgeTrading(store: memory).pending(fixtures.address))!;
        expect(saved['signed'], hasLength(1));
        trading.acceptedIds.add('a' * 64);
      } else {
        expect(body['signed'], hasLength(2));
      }
      return http.Response(
          jsonEncode(
              {'ok': true, 'txid': body['step'] == true ? 'a' * 64 : 'b' * 64}),
          200);
    }));
    auth.beforeSign = (id) {
      if (id == 'b' * 64) expect(trading.acceptedIds, contains('a' * 64));
    };
    final r = plan();
    await trading.sign(fixtures.address, r);
    await trading.submit(fixtures.address, r);
    expect(auth.signedIds, ['a' * 64, 'b' * 64]);
    expect(bodies, hasLength(2));
    expect(bodies.last.containsKey('step'), false);
    expect(trading.verificationParents, everyElement(0));
    expect(r['acceptedPreparationCount'], 1);
    expect(r['state'], 'deposited');
    expect(trading.progress.value, isNull);
  });
  for (final failure in ['unknown', 'reject', 'wrong-id']) {
    test(
        '$failure preparation retains exact signed prefix and never signs the order',
        () async {
      final auth = StepSecurity(), memory = fixtures.Memory();
      final trading = StepTrading(auth, memory, MockClient((request) async {
        if (failure == 'reject') {
          return http.Response('{"ok":false,"error":"request expired"}', 409);
        }
        return http.Response(
            jsonEncode({
              'ok': true,
              'txid': failure == 'wrong-id' ? 'c' * 64 : 'a' * 64
            }),
            200);
      }));
      final r = plan();
      await expectLater(trading.sign(fixtures.address, r), throwsStateError);
      expect(auth.signedIds, ['a' * 64]);
      final saved =
          (await KasForgeTrading(store: memory).pending(fixtures.address))!;
      expect(saved['signed'], hasLength(1));
      expect(
          jsonDecode(saved['signed'][0] as String)['inputs'][0]
              ['signatureScript'],
          '41${fixtures.ownerSignature}');
      expect(saved['finalVerified'], isNot(true));
      expect(trading.progress.value, isNull);
    });
  }
  test(
      'reopen after interrupted preparation reuses bytes and does not sign step one again',
      () async {
    final auth = StepSecurity(), memory = fixtures.Memory();
    final trading = StepTrading(auth, memory,
        MockClient((_) async => http.Response('{"ok":true}', 200)));
    final r = plan();
    await expectLater(trading.sign(fixtures.address, r),
        throwsA(isA<KasForgeConfirmationPending>()));
    final saved = (await trading.pending(fixtures.address))!;
    final exact = saved['signed'][0];
    final reopenedAuth = StepSecurity();
    final reopened = StepTrading(
        reopenedAuth,
        memory,
        MockClient(
            (_) async => throw StateError('No duplicate prefix submission')))
      ..acceptedIds.add('a' * 64);
    await reopened.sign(fixtures.address, saved);
    expect(reopenedAuth.signedIds, ['b' * 64]);
    expect(saved['signed'][0], exact);
  });
  test('partial plan status is not an absent or completed order', () async {
    final r = plan()..['signed'] = <String>[];
    final t = KasForgeTrading(
        store: fixtures.Memory(),
        client: MockClient((_) async =>
            throw StateError('No server lookup for unsigned tail')));
    expect(
        (await t.status(fixtures.address, r))['status'], 'preparation-pending');
    expect(r['finalVerified'], isNot(true));
  });
}
