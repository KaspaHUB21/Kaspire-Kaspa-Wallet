import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/kaspa_address.dart';
import 'package:kasvault_wallet/src/services/kforge_service.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';

final kforgeAddress = kaspaAddressFromOwnerId('11' * 32, prefix: 'kaspatest');
Map kforgeToken([String id = 'a']) => {
      'tokenCovId': id * 64,
      'rungCovId': (id == 'a' ? 'b' : 'd') * 64,
      'name': 'KForge coin',
      'ticker': 'SAME',
      'phase': 'curve',
      'pool': null,
      'image': 'coin.png',
      'pricePerLot': 100000000,
      'marketCap': 100000000000,
      'volume24h': 1000000000
    };
Map kforgeRegistry() => {
      'network': 'testnet-10',
      'version': 'v6',
      'parameters': {
        'totalSupply': 1000000000,
        'tokensPerStep': 1000000,
        'base': 624999772,
        'slope': 1564455,
        'feeBps': 100
      }
    };
Map kforgeHoldings([Object? amount = 15000000]) => {
      'wallet': kforgeAddress,
      'holdings': [
        {'tokenCovId': 'a' * 64, 'rungCovId': 'b' * 64, 'amount': amount}
      ]
    };
http.Client kforgeClient(
        {List? tokens, Map? holdings, Map? registry, int status = 200}) =>
    MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.host, 'api-test.kforge.xyz');
      final Object response = request.url.path.endsWith('/registry')
          ? registry ?? kforgeRegistry()
          : request.url.path.endsWith('/tokens')
              ? tokens ?? [kforgeToken()]
              : holdings ?? kforgeHoldings();
      return http.Response(jsonEncode(response), status);
    });
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => NetworkSettings.network.value = KaspaNetwork.tn10);
  test(
      'KForge is distinct from KasForge, uses zero decimals and exact indexed quantities',
      () async {
    final data =
        await KForgeService(client: kforgeClient()).load(kforgeAddress);
    expect(data.tokens.single.priceKas, 0.000001);
    expect(data.tokens.single.marketCapKas, 1000);
    final asset = data.assets.single;
    expect(asset.rawBalance, '15000000');
    expect(asset.decimals, 0);
    expect(asset.standard, 'kforge-kcc20');
    expect(asset.discoveryComplete, false);
    expect(asset.imageUrl, 'https://api-test.kforge.xyz/img/coin.png');
    expect(KForgeService.tradingEnabled, true);
  });
  test('duplicate tickers remain separate covenant identities', () async {
    final data = await KForgeService(
        client: kforgeClient(tokens: [
      kforgeToken(),
      kforgeToken('c')
    ], holdings: {
      'wallet': kforgeAddress,
      'holdings': [
        ...kforgeHoldings()['holdings'],
        {'tokenCovId': 'c' * 64, 'rungCovId': 'd' * 64, 'amount': 7}
      ]
    })).load(kforgeAddress);
    expect(data.assets.map((a) => a.rawBalance), ['15000000', '7']);
    expect(data.assets.map((a) => a.covenantId).toSet(), hasLength(2));
  });
  test('known zero is empty, unavailable or malformed is never zero', () async {
    expect(
        await KForgeService(client: kforgeClient(holdings: kforgeHoldings(0)))
            .walletAssets(kforgeAddress),
        isEmpty);
    for (final value in [null, -1, '0.025', 1000000001, 'unknown']) {
      await expectLater(
          KForgeService(client: kforgeClient(holdings: kforgeHoldings(value)))
              .walletAssets(kforgeAddress),
          throwsStateError);
    }
    await expectLater(
        KForgeService(client: kforgeClient(status: 503))
            .walletAssets(kforgeAddress),
        throwsStateError);
  });
  test(
      'foreign wallet, unknown token, duplicate IDs and wrong registry fail closed',
      () async {
    final wrong = kforgeHoldings()
      ..['wallet'] = kaspaAddressFromOwnerId('22' * 32, prefix: 'kaspatest');
    await expectLater(
        KForgeService(client: kforgeClient(holdings: wrong))
            .load(kforgeAddress),
        throwsStateError);
    await expectLater(
        KForgeService(client: kforgeClient(tokens: [kforgeToken('c')]))
            .load(kforgeAddress),
        throwsStateError);
    await expectLater(
        KForgeService(
                client: kforgeClient(tokens: [kforgeToken(), kforgeToken()]))
            .load(kforgeAddress),
        throwsStateError);
    for (final r in [
      kforgeRegistry()..['network'] = 'mainnet',
      kforgeRegistry()..['version'] = 'v7',
      {
        'network': 'testnet-10',
        'version': 'v6',
        'parameters': {'totalSupply': 1000000000, 'tokensPerStep': 1000}
      }
    ]) {
      await expectLater(
          KForgeService(client: kforgeClient(registry: r)).catalogue(),
          throwsStateError);
      await expectLater(
          KForgeService(client: kforgeClient(registry: r))
              .walletAssets(kforgeAddress),
          throwsStateError);
    }
  });
  test('graduation requires a pool covenant; image URLs are HTTPS-only',
      () async {
    final t = kforgeToken()..['phase'] = 'pool';
    expect(() => KForgeToken.fromJson(t), throwsStateError);
    t['pool'] = {'poolCovId': 'f' * 64};
    t['image'] = 'javascript:alert(1)';
    expect(KForgeToken.fromJson(t).pool, 'f' * 64);
    expect(KForgeToken.fromJson(t).logo, isNull);
  });
  test(
      'token previews support uploaded files, HTTPS and IPFS without unsafe URLs',
      () {
    expect(KForgeToken.image('coin.png'),
        'https://api-test.kforge.xyz/img/coin.png');
    expect(KForgeToken.image('https://cdn.example/coin.webp'),
        'https://cdn.example/coin.webp');
    expect(KForgeToken.image('ipfs://${'b' * 46}/coin.png'),
        'https://ipfs.io/ipfs/${'b' * 46}/coin.png');
    for (final url in [
      'http://example.com/a.png',
      'file:///a.png',
      'https://user:pass@example.com/a.png',
      'https://localhost/a.png',
      'https://127.0.0.1/a.png',
      '../coin.png',
      'ipfs://${'b' * 46}/../a.png'
    ]) {
      expect(KForgeToken.image(url), isNull);
    }
  });
  test(
      'positive indexed holdings publish before a delayed catalogue and retain their exact units',
      () async {
    final gate = Completer<http.Response>(), progress = <List<dynamic>>[];
    final holding = kforgeHoldings();
    (holding['holdings'] as List).single['ticker'] = 'NEW';
    final service = KForgeService(client: MockClient((r) async {
      if (r.url.path.endsWith('/tokens')) return gate.future;
      return http.Response(
          jsonEncode(
              r.url.path.endsWith('/registry') ? kforgeRegistry() : holding),
          200);
    }));
    final visible = Completer<void>();
    final loaded = service.walletAssets(kforgeAddress, onProgress: (rows) {
      progress.add(rows);
      if (!visible.isCompleted) visible.complete();
    });
    await visible.future;
    expect(progress.single.single.symbol, 'NEW');
    expect(progress.single.single.rawBalance, '15000000');
    expect(progress.single.single.decimals, 0);
    expect(progress.single.single.priceKas, isNull);
    gate.complete(http.Response(jsonEncode([kforgeToken()]), 200));
    expect((await loaded).single.symbol, 'SAME');
    expect(progress.last.single.imageUrl, isNotNull);
  });
  test(
      'catalogue failure and a newly unlisted token never suppress a positive holding',
      () async {
    for (final unavailable in [true, false]) {
      final warnings = <String>[];
      final body = kforgeHoldings();
      (body['holdings'] as List).single['ticker'] = 'NEW';
      final service = KForgeService(client: MockClient((r) async {
        if (r.url.path.endsWith('/tokens'))
          return http.Response(
              jsonEncode(unavailable ? {} : [kforgeToken('c')]),
              unavailable ? 503 : 200);
        return http.Response(
            jsonEncode(
                r.url.path.endsWith('/registry') ? kforgeRegistry() : body),
            200);
      }));
      final rows =
          await service.walletAssets(kforgeAddress, onWarning: warnings.add);
      expect(rows.single.symbol, 'NEW');
      expect(rows.single.rawBalance, '15000000');
      expect(rows.single.discoveryComplete, false);
      expect(warnings, isNotEmpty);
    }
  });
  test(
      'Mainnet and late responses after a network switch never query or publish TN10 balances',
      () async {
    var calls = 0;
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    final service = KForgeService(client: MockClient((_) async {
      calls++;
      throw StateError('Not allowed');
    }));
    await expectLater(service.load(kforgeAddress), throwsStateError);
    expect(calls, 0);
    NetworkSettings.network.value = KaspaNetwork.tn10;
    final gate = Completer<void>();
    final delayed = KForgeService(client: MockClient((_) async {
      await gate.future;
      return http.Response('{}', 200);
    })).catalogue();
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    gate.complete();
    await expectLater(delayed, throwsStateError);
  });
  final snapshot = Platform.environment['KASPIRE_KFORGE_SNAPSHOT'];
  test(
      'captured public KForge catalogue and positive holdings parse without signing',
      () async {
    final root = snapshot!;
    final tokens =
        jsonDecode(File('$root/kforge-tokens.json').readAsStringSync()) as List;
    final holdings = jsonDecode(
        File('$root/kforge-positive-holdings.json').readAsStringSync()) as Map;
    final registry =
        jsonDecode(File('$root/kforge-registry.json').readAsStringSync())
            as Map;
    final data = await KForgeService(
            client: kforgeClient(
                tokens: tokens, holdings: holdings, registry: registry))
        .load(holdings['wallet'] as String);
    expect(data.tokens, isNotEmpty);
    expect(data.assets, isNotEmpty);
    expect(data.assets.every((a) => a.decimals == 0 && !a.discoveryComplete),
        true);
  },
      skip: snapshot == null
          ? 'Provide parent-captured public KForge data; no live network in tests'
          : false);
}
