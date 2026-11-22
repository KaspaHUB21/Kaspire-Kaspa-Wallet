import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/trestly_service.dart';
import 'package:kasvault_wallet/src/services/encrypted_store.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/services/native_security.dart';
import 'package:kasvault_wallet/src/screens/trestly_swap_screen.dart';
import 'package:kasvault_wallet/src/screens/kron_dex_screen.dart';
import 'package:kasvault_wallet/src/theme.dart';

class Store implements EncryptedStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String k) async => values[k];
  @override
  Future<void> write(String k, String v) async {
    values[k] = v;
  }

  @override
  Future<void> delete(String k) async {
    values.remove(k);
  }
}

class Demo extends TrestlyService {
  Demo() : super('kaspa:test', store: Store());
  @override
  Future<TrestlyRow?> pending() async => null;
  @override
  Future<TrestlyRow> quote(String side, String amount) async => {
        'request': <String, Object?>{},
        'review': {
          'amountIn':
              parseTrestlyAmount(amount, side == 'buy' ? 8 : 6).toString(),
          'amountOut': side == 'buy' ? '24975000' : '99800000',
          'maxFeeSompi': '30000000'
        },
        'createdAt': DateTime.now().millisecondsSinceEpoch
      };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native swap rejects a stale library and accepts the checked v2 profile',
      () async {
    const channel = MethodChannel('space.kasvault/security');
    var profile = 'trestly-mainnet-v1';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel, (call) async => jsonEncode({'profile': profile}));
    try {
      final native = NativeSecurity();
      await expectLater(native.describeTrestly({}), throwsStateError);
      await expectLater(native.prepareTrestly({}), throwsStateError);
      profile = 'trestly-mainnet-v2';
      expect((await native.describeTrestly({}))['profile'], profile);
      expect((await native.prepareTrestly({}))['profile'], profile);
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });
  test('exact comma and point quantities, not floating point', () {
    expect(parseTrestlyAmount('69,92', 6), 69920000);
    expect(parseTrestlyAmount('0.00000001', 8), 1);
    expect(() => parseTrestlyAmount('1.0000001', 6), throwsFormatException);
    expect(() => parseTrestlyAmount('1,234.5', 6), throwsFormatException);
    expect(() => parseTrestlyAmount('-1', 8), throwsFormatException);
    expect(() => parseTrestlyAmount('NaN', 6), throwsFormatException);
  });
  test('TN10 cannot obtain a quote or submit a saved Mainnet transaction',
      () async {
    NetworkSettings.network.value = KaspaNetwork.tn10;
    var calls = 0;
    final s = TrestlyService('kaspa:test', client: MockClient((r) async {
      calls++;
      return http.Response('{}', 200);
    }), store: Store());
    await expectLater(s.quote('buy', '100'), throwsStateError);
    await expectLater(s.resume(), throwsStateError);
    expect(calls, 0);
    NetworkSettings.network.value = KaspaNetwork.mainnet;
  });
  test('unknown UTXOs and wrong creating covenant cannot pass own-node proof',
      () async {
    final id = 'a' * 64;
    final s = TrestlyService('kaspa:test',
        client: MockClient((r) async => http.Response(
            jsonEncode(r.url.path.endsWith('/utxos') ? [] : {}), 200)),
        store: Store());
    await expectLater(
        s.proof({'transactionId': id, 'index': 0}, 'kaspa:test', '000051',
            TrestlyService.tokenId),
        throwsStateError);
  });
  test('saved swap recovery never signs again or substitutes a transaction',
      () async {
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    final store = Store(), id = 'b' * 64;
    var submissions = 0;
    final s = TrestlyService('kaspa:test', store: store,
        client: MockClient((r) async {
      if (r.method != 'GET') submissions++;
      return http.Response(
          jsonEncode({'transactionId': id, 'status': 'confirmed'}), 200);
    }));
    final row = {
      'transactionId': id,
      'wrpcJson': 'exact signed bytes',
      'feeSompi': '123'
    };
    await store.write(s.key, jsonEncode(row));
    expect((await s.resume())['transactionId'], id);
    expect(submissions, 0);
    expect(await s.pending(), null);
    expect(await store.read('${s.key}.last'),
        jsonEncode({...row, 'status': 'confirmed'}));
  });
  test('old saved wRPC text is sent unchanged ONLY to the native Kaspire relay',
      () async {
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    final store = Store(), id = 'c' * 64;
    const exact =
        '{ "sequence":18446744073709551615,"computeBudget":12345,"covenant":{"authorizingInput":0} }';
    var posts = 0, reads = 0;
    final s = TrestlyService('kaspa:test', store: store,
        client: MockClient((r) async {
      expect(r.url.host, 'kaspire.kaslab.space');
      expect(r.url.path, startsWith('/api/native-kusdt/'));
      if (r.method == 'POST') {
        posts++;
        expect(r.url.path, '/api/native-kusdt/submit');
        final body = jsonDecode(r.body) as Map;
        expect(body['transactionId'], id);
        expect(body['transactionJson'], exact);
        expect(body.containsKey('signedTxJson'), false);
        return http.Response(
            jsonEncode({'transactionId': id, 'status': 'submitted'}), 200);
      }
      reads++;
      return http.Response(
          jsonEncode({
            'transactionId': id,
            'status': reads == 1 ? 'not_seen' : 'confirmed'
          }),
          200);
    }));
    await store.write(
        s.key, jsonEncode({'transactionId': id, 'wrpcJson': exact}));
    expect((await s.resume())['status'], 'confirmed');
    expect(posts, 1);
    expect(await s.pending(), null);
  });
  for (final state in ['unknown', 'mempool', 'unavailable']) {
    test('saved swap $state is never treated as missing or re-signed',
        () async {
      NetworkSettings.network.value = KaspaNetwork.mainnet;
      final store = Store(), id = 'd' * 64;
      var posts = 0, reads = 0;
      final s = TrestlyService('kaspa:test', store: store,
          client: MockClient((r) async {
        if (r.method == 'POST') posts++;
        reads++;
        return state == 'unavailable'
            ? http.Response('{"error":"Node unavailable"}', 503)
            : http.Response(
                jsonEncode({
                  'transactionId': id,
                  'status':
                      state == 'mempool' && reads > 1 ? 'confirmed' : state
                }),
                200);
      }));
      final saved =
          jsonEncode({'transactionId': id, 'wrpcJson': 'exact signed data'});
      await store.write(s.key, saved);
      if (state == 'mempool') {
        expect((await s.resume())['status'], 'confirmed');
      } else {
        await expectLater(s.resume(), throwsStateError);
        expect(await store.read(s.key), saved);
      }
      expect(posts, 0);
    });
  }
  test(
      'actual node rejection and a lost HTTP response both preserve the original journal',
      () async {
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    final store = Store(), id = 'e' * 64;
    var posts = 0;
    bool confirmed = false;
    final s = TrestlyService('kaspa:test', store: store,
        client: MockClient((r) async {
      if (r.method == 'GET')
        return http.Response(
            jsonEncode({
              'transactionId': id,
              'status': confirmed ? 'confirmed' : 'not_seen'
            }),
            200);
      posts++;
      return http.Response(
          '{"code":"node_rejected","error":"input is already spent"}', 422);
    }));
    final original = jsonEncode(
        {'transactionId': id, 'wrpcJson': 'saved bytes from v0.11.118'});
    await store.write(s.key, original);
    await expectLater(
        s.resume(),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'node cause', contains('already spent'))));
    expect(await store.read(s.key), original);
    expect(posts, 1);
    confirmed = true;
    expect((await s.resume())['status'], 'confirmed');
    expect(posts, 1);
  });
  testWidgets('native kUSDT entry precedes all Mainnet DEXes', (tester) async {
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    await tester.pumpWidget(
        const MaterialApp(home: DexSelectionScreen(address: 'kaspa:test')));
    await tester.pump();
    final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect((tiles.first.title as Text).data, 'KAS / kUSDT');
    expect(find.text('Trestly KasPool · Native swap'), findsOneWidget);
  });
  testWidgets('readable exact quote in every theme and narrow/wide layouts',
      (tester) async {
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    for (final theme in KaspireTheme.values) {
      AppSettings.theme.value = theme;
      for (final width in [320.0, 768.0]) {
        await tester.binding.setSurfaceSize(Size(width, 900));
        await tester.pumpWidget(MaterialApp(
            theme: KasVaultTheme.forTheme(theme),
            home: TrestlySwapScreen(
                key: ValueKey('$theme-$width'),
                address: 'kaspa:test',
                service: Demo())));
        await tester.pump();
        await tester.enterText(find.byType(TextField), '25,00');
        await tester.tap(find.text('Get live quote'));
        await tester.pumpAndSettle();
        expect(find.text('You receive'), findsOneWidget);
        expect(find.text('24.975 kUSDT'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    }
    await tester.binding.setSurfaceSize(null);
    AppSettings.theme.value = KaspireTheme.midnight;
  });
}
