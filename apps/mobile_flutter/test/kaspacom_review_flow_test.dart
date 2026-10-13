import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kasvault_wallet/src/services/kaspacom_market_service.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';
import 'package:kasvault_wallet/src/services/native_security.dart';

const address =
    'kaspa:qqnvxvumjvzwmn755v8nrp4jxm2w50dv9mr2u4qrfqpq3h2hzyjx7tgkdtdgs';
final commitId = 'a' * 64, revealId = 'b' * 64, sellerId = 'c' * 64;

class FlowApi extends KaspaApi {
  @override
  Future<String> loadUtxos(String address) async => '[]';
  @override
  Future<double> loadFeeRate() async => 1;
}

class FlowSecurity extends NativeSecurity {
  final signed = <String>[];
  @override
  Future<Map<String, Object?>> prepareInscription(
          Map<String, Object?> r) async =>
      {'commitAddress': address, 'commitAmountSompi': 10000};
  @override
  Future<Map<String, Object?>> prepareKaspacomCommit(
          Map<String, Object?> r, Map<String, Object?> operation) async =>
      {
        'reviewHash': 'commit-review',
        'amountSompi': 10000,
        'feeSompi': 100,
        'changeSompi': 0,
        'mass': 100,
        'inputCount': 1,
        'outputCount': 1
      };
  @override
  Future<Map<String, Object?>> signTransaction(Map<String, Object?> r, String h,
      {bool kaspacomReview = false}) async {
    expect(kaspacomReview, isTrue);
    expect(h, 'commit-review');
    signed.add('commit');
    return {'transactionId': commitId, 'submitJson': '{}'};
  }

  @override
  Future<Map<String, Object?>> prepareReveal(Map<String, Object?> r,
      {bool kaspacomReview = false}) async {
    expect(kaspacomReview, isTrue);
    return {
      'reviewHash': 'reveal-review',
      'feeSompi': 100,
      'returnSompi': 9000
    };
  }

  @override
  Future<Map<String, Object?>> signReveal(Map<String, Object?> r, String h,
      {bool kaspacomReview = false}) async {
    expect(kaspacomReview, isTrue);
    expect(h, 'reveal-review');
    signed.add('reveal');
    return {'transactionId': revealId, 'submitJson': '{}'};
  }

  @override
  Future<Map<String, Object?>> prepareKaspacomMarket(
          Map<String, Object?> r) async =>
      r['action'] == 'describe'
          ? {'listingAddress': address}
          : {
              'request': {'sender': address}
            };
  @override
  Future<Map<String, Object?>> preparePskt(Map<String, Object?> r,
      {bool kaspacomReview = false}) async {
    expect(kaspacomReview, isTrue);
    return {'reviewHash': 'seller-review', 'outputs': []};
  }

  @override
  Future<Map<String, Object?>> signPskt(Map<String, Object?> r, String h,
      {bool kaspacomReview = false}) async {
    expect(kaspacomReview, isTrue);
    expect(h, 'seller-review');
    signed.add('seller');
    return {'transactionId': sellerId, 'signedTxJson': '{}'};
  }
}

class FlowMarket extends KaspaComMarketService {
  FlowMarket(FlowSecurity security)
      : super(address, security: security, api: FlowApi());
  int ownNodeChecks = 0;
  @override
  Future<void> authenticate() async {}
  @override
  Future<void> acceptedOrBroadcast(String id, String json) async {}
  @override
  Future<String> waitCells(String target, String id,
      {bool ownNode = false}) async {
    if (id == revealId) {
      expect(ownNode, isTrue);
      ownNodeChecks++;
    }
    return '[]';
  }

  @override
  Future<Map<String, Object?>> request(String path,
      {Map<String, String>? query,
      Map<String, Object?>? body,
      bool private = false}) async {
    expect(path, '/krc721/orders');
    return {'status': 'LISTED_FOR_SALE', 'id': 'published-order'};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() =>
      SharedPreferences.setMockInitialValues({'watch_address_v1': address}));
  for (final cancelAt in [null, 1, 2, 3]) {
    test(
        'listing has three bound reviews; cancellation at $cancelAt preserves recovery',
        () async {
      final security = FlowSecurity();
      final actual = FlowMarket(security);
      final reviews = <String>[];
      Future<bool> approve(String title, Map<String, Object?> details) async {
        reviews.add(title);
        if (reviews.length == 3) expect(actual.ownNodeChecks, 1);
        return reviews.length != cancelAt;
      }

      final create = actual.create('krc721',
          {'ticker': 'HASH', 'tokenId': '48'}, 1100000000, '', 1, approve);
      if (cancelAt == null) {
        await create;
        expect(reviews, [
          '1 of 3 · Commit listing',
          '2 of 3 · Reveal listing',
          '3 of 3 · Confirm listing'
        ]);
        expect(security.signed, ['commit', 'reveal', 'seller']);
        expect(actual.ownNodeChecks, 2);
        expect((await actual.saved()).single['stage'], 'done');
      } else {
        await expectLater(create, throwsA(isA<KaspaComCancelled>()));
        expect(security.signed.length, cancelAt - 1);
        if (cancelAt > 1) {
          expect((await actual.saved()).single['stage'],
              cancelAt == 2 ? 'commit' : 'offer');
        }
      }
      actual.close();
    });
  }
  test(
      'normal signers keep native approval; marketplace mode is explicit and hash-bound',
      () async {
    const channel = MethodChannel('space.kasvault/security');
    final commands = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      commands.add(call.method);
      if (call.method.startsWith('authorize')) {
        expect((call.arguments as Map)['binding'], 'exact-review');
        return 'one-use-token';
      }
      expect((call.arguments as Map)['authorizationToken'], 'one-use-token');
      return '{"transactionId":"signed"}';
    });
    try {
      final security = NativeSecurity();
      await security.signPskt({'sender': address}, 'exact-review');
      await security
          .signPskt({'sender': address}, 'exact-review', kaspacomReview: true);
      expect(commands, [
        'authorizeOperation',
        'signPskt',
        'authorizeKaspacomOperation',
        'signPskt'
      ]);
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
    final android = File(
            'android/app/src/main/kotlin/space/kasvault/wallet/MainActivity.kt')
        .readAsStringSync();
    expect(android, contains('it.kaspacomInApp && it.operation == operation'));
    expect(android, contains('it.expiresAt >= System.currentTimeMillis()'));
    expect(
        android,
        contains(
            'parseCore(raw).optString("profile") == "kaspacom-market-v1"'));
    expect(
        android,
        contains(
            'payment.getString("recipient") == plan.getString("commitAddress")'));
    expect(android, contains('operationAuthorizations.remove(token)'));
  });
}
