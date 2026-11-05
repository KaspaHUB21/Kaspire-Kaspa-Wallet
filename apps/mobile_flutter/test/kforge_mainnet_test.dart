import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/kaspa_address.dart';
import 'package:kasvault_wallet/src/models/wallet_snapshot.dart';
import 'package:kasvault_wallet/src/screens/kron_dex_screen.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';
import 'package:kasvault_wallet/src/services/kforge_service.dart';
import 'package:kasvault_wallet/src/services/kforge_trading.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/services/native_security.dart';
import 'kforge_trading_test.dart' show MemoryKForgeStore;

class KForgeInspector extends NativeSecurity {
  @override
  Future<Map<String, Object?>> preparePskt(Map<String, Object?> request,
      {bool kaspacomReview = false}) async {
    final p =
        await Process.start('../../target/debug/kforge_inspect', ['--stdin']);
    p.stdin.write(jsonEncode(request));
    await p.stdin.close();
    final out = p.stdout.transform(utf8.decoder).join(),
        err = p.stderr.transform(utf8.decoder).join();
    if (await p.exitCode != 0) throw StateError(await err);
    return Map<String, Object?>.from(jsonDecode(await out) as Map);
  }
}

http.Response jsonResponse(String body, int status) =>
    http.Response.bytes(utf8.encode(body), status,
        headers: {"content-type": "application/json; charset=utf-8"});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Map fixture(String name) =>
      jsonDecode(File('../../crates/kaspa_secure_core/src/fixtures/$name.json')
          .readAsStringSync()) as Map;
  final capture = fixture('kforge-mainnet-unsigned'),
      live = fixture('kforge-mainnet-live');
  setUp(() => NetworkSettings.network.value = KaspaNetwork.mainnet);
  tearDown(() => NetworkSettings.network.value = KaspaNetwork.mainnet);
  test('complete real Mainnet catalogue parses all token metadata and previews',
      () async {
    final service = KForgeService(
        client: MockClient((r) async => jsonResponse(
            jsonEncode(r.url.path.endsWith('registry')
                ? capture['registry']
                : capture['tokens']),
            200)));
    final tokens = await service.catalogue();
    expect(tokens, hasLength((capture['tokens'] as List).length));
    expect(tokens.firstWhere((t) => t.symbol == 'KASUSD').logo,
        'https://api.kforge.xyz/img/18e4dd785f7af82f0005.png');
  });

  for (final entry in (capture['trades'] as Map).entries) {
    test(
        'captured Mainnet ${entry.key}: real app quote, own-node verification and native review',
        () async {
      final row = entry.value as Map, address = row['wallet'] as String;
      var submits = 0, nodeReads = 0, prepares = 0;
      final client = MockClient((r) async {
        Object? value;
        if (r.url.host == 'api.kforge.xyz') {
          if (r.url.path == '/v6/registry') value = capture['registry'];
          if (r.url.path == '/v6/tokens') value = [row['token']];
          if (r.url.path.contains('/holdings/'))
            value = capture['wallets'][address];
          if (r.method == 'POST') {
            if (r.url.path.contains('submit')) submits++;
            expect(r.url.path, row['path']);
            expect(jsonDecode(r.body), row['body']);
            prepares++;
            value = row['response'];
          }
        } else if (r.url.host == 'kaspire.kaslab.space' &&
            r.url.path == '/dex-test-v1/kasseal-mainnet/utxos') {
          nodeReads++;
          value = {
            'network': 'mainnet',
            'covenantIdsIncluded': true,
            'entries': live['utxos'][r.url.queryParameters['address']]
          };
        }
        if (value == null)
          throw StateError('Unexpected captured read ${r.url}');
        return jsonResponse(jsonEncode(value), 200);
      });
      final store = MemoryKForgeStore(),
          trading = KForgeTrading(
              client: client, store: store, security: KForgeInspector());
      final name = '${entry.key}',
          buy = name.endsWith('buy'),
          pool = name.startsWith('pool');
      final token = KForgeToken.fromJson(row['token'] as Map);
      final amount = buy
          ? (pool
              ? BigInt.from(row['body']['kas'] as int)
              : KForgeTrading.curveBuyCost(token, 1))
          : BigInt.from(pool ? row['body']['tokens'] as int : 1000000);
      final plan =
          await trading.quote(address, token, buy ? 'buy' : 'sell', amount);
      final request = plan['request'] as Map,
          v = plan['review']['tradeSummary']['verified'] as Map;
      expect(request['profile'], 'kforge-mainnet-swap-v1');
      expect(v['network'], 'mainnet');
      if (buy) {
        expect(request['tradeSummary']['buyBudgetSompi'], '$amount');
        expect(v['buyBudgetSompi'], '$amount');
        expect(v['unspentBudgetSompi'], '0');
      }
      expect(request['tradeSummary']['maximumDebit'], v['walletNet']);
      expect(request['tradeSummary']['minimumOut'],
          buy ? v['tokens'] : v['walletNet']);
      expect(nodeReads, greaterThanOrEqualTo(3));
      expect(prepares, 1);
      expect(submits, 0);
      expect(store.values, isEmpty);
    });
  }
  test('Mainnet registry cannot borrow TN10 parameters or image origin',
      () async {
    final address = (capture['trades'] as Map).values.first['wallet'] as String;
    for (final change in ['network', 'base', 'slope']) {
      final registry = jsonDecode(jsonEncode(capture['registry'])) as Map;
      if (change == 'network') {
        registry['network'] = 'testnet-10';
      } else {
        registry['parameters'][change] = 1;
      }
      final service = KForgeService(
          client: MockClient((r) async => jsonResponse(
              jsonEncode(r.url.path.endsWith('registry') ? registry : []),
              200)));
      await expectLater(service.load(address), throwsStateError);
    }
    expect(
        KForgeToken.image('coin.png'), 'https://api.kforge.xyz/img/coin.png');
    final captured = KForgeTrading(store: MemoryKForgeStore());
    NetworkSettings.network.value = KaspaNetwork.tn10;
    expect(() => captured.guard(address), throwsStateError);
  });
  test(
      'Mainnet receipt reopening stays isolated from TN10 and never resubmits on read',
      () async {
    final address = (capture['trades'] as Map).values.first['wallet'] as String;
    final store = MemoryKForgeStore();
    var posts = 0;
    final client = MockClient((r) async {
      if (r.method == 'POST') posts++;
      expect(r.url.host, 'kaspire.kaslab.space');
      expect(r.url.path, '/api/local-node/transactions/${'e' * 64}');
      return jsonResponse(
          jsonEncode({'transaction_id': 'e' * 64, 'is_accepted': true}), 200);
    });
    final t = KForgeTrading(client: client, store: store);
    await t.retain(address, {
      'address': address,
      'network': 'mainnet',
      'id': 'e' * 64,
      'state': 'pending',
      'signed': {}
    });
    final saved =
        await KForgeTrading(client: client, store: store).pending(address);
    final result = await t.resume(address, saved!, submit: false);
    expect(result['state'], 'confirmed');
    expect(posts, 0);
    NetworkSettings.network.value = KaspaNetwork.tn10;
    final tn = KForgeTrading(store: store);
    expect(
        await tn.saved(kaspaAddressWithPrefix(address, 'kaspatest')), isEmpty);
    expect(store.values.keys.single, contains('kforge_mainnet_atomic_v1_'));
  });
  test(
      'actual Mainnet wallet publishes KForge holdings while Kasvio and other sources are slow or unavailable',
      () async {
    final row = capture['trades']['pool-sell'] as Map,
        address = row['wallet'] as String;
    final positive = Completer<WalletSnapshot>(),
        slow = Completer<http.Response>();
    final api = KaspaApi(client: MockClient((r) async {
      if (r.url.host == 'api.kforge.xyz') {
        final value = r.url.path.endsWith('registry')
            ? capture['registry']
            : r.url.path == '/v6/tokens'
                ? capture['tokens']
                : capture['wallets'][address];
        return jsonResponse(jsonEncode(value), 200);
      }
      if (r.url.path.endsWith('/balance'))
        return jsonResponse('{"balance":100000000}', 200);
      if (r.url.path.endsWith('/utxos')) return jsonResponse('[]', 200);
      return slow.future;
    }));
    final loaded = api.loadWallet(address,
        includeNativeTransactions: false,
        includeAssetHistory: false,
        includeMarketData: false, onProgress: (s) {
      if (s.kcc20Tokens.any((a) => a.standard == 'kforge-kcc20') &&
          !positive.isCompleted) positive.complete(s);
    });
    final early = await positive.future.timeout(const Duration(seconds: 3));
    final asset = early.kcc20Tokens
        .firstWhere((a) => a.covenantId == row['token']['tokenCovId']);
    expect(asset.decimals, 0);
    expect(asset.rawBalance, '73870809');
    expect(asset.discoveryComplete, false);
    slow.complete(jsonResponse('{}', 503));
    final result = await loaded;
    final finalAsset =
        result.kcc20Tokens.firstWhere((a) => a.covenantId == asset.covenantId);
    expect(finalAsset.rawBalance, asset.rawBalance);
    expect(finalAsset.symbol, 'KASUSD');
    expect(finalAsset.imageUrl, startsWith('https://api.kforge.xyz/img/'),
        reason: result.assetWarning);
  });
  testWidgets('Mainnet venue order is Rocket, Kasseal, Braid, KForge, Kron',
      (tester) async {
    await tester.pumpWidget(
        const MaterialApp(home: DexSelectionScreen(address: 'public-address')));
    await tester.pump();
    final tiles = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((t) => (t.title as Text).data)
        .toList();
    expect(tiles, [
      'KaspaRocket',
      'Kasseal DEX',
      'Braid Aggregator',
      'KForge',
      'Kron DEX'
    ]);
    expect(tester.takeException(), isNull);
  });
}
