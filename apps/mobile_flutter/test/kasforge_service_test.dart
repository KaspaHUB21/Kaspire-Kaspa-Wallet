import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/kaspa_address.dart';
import 'package:kasvault_wallet/src/services/kasforge_service.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

final cid = 'a' * 64, curve = 'b' * 64, pool = 'c' * 64, genesis = 'd' * 64;
final owner = '11' * 32;
final address = kaspaAddressFromOwnerId(owner, prefix: 'kaspatest');

Map<String, Object?> token({bool graduated = false, String? id}) => {
      'network': 'testnet-10',
      'covenantId': id ?? cid,
      'name': 'KasForge test coin',
      'symbol': 'SAME',
      'decimals': 0,
      'logoURI': 'https://kaspa.pumpforge.tech/kasforge/apple-touch-icon.png',
      'extensions': {
        'launchpad': 'kasforge',
        'curveCovenantId': curve,
        'poolCovenantId': graduated ? pool : null,
        'genesisTxid': genesis,
        'graduated': graduated
      },
    };
Map<String, Object?> market({bool graduated = false, String? id}) => {
      'network': 'testnet-10',
      'covenantId': id ?? cid,
      'genesisTxid': genesis,
      'id': curve,
      'graduated': graduated,
      'kind': graduated ? 'pool' : 'curve',
      'market': graduated ? pool : curve,
      'priceKas': 0.01,
      'mcapKas': 100,
      'volume24h': 5,
    };
Map<String, Object?> portfolio({Object? positions}) => {
      'ok': true,
      'address': address,
      'positions': positions ??
          [
            {'token': cid, 'tokens': 250, 'priceKas': 0.01}
          ],
      'orders': [],
      'activity': [],
    };
http.Response response(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);
http.Client source(
        {List<Map>? tokens, Object? holdings, bool unavailable = false}) =>
    MockClient((request) async {
      expect(request.method, 'GET',
          reason: 'This integration cannot build, sign or submit orders.');
      expect(request.url.host, 'kaspa.pumpforge.tech');
      if (unavailable) return response({'ok': false}, 503);
      if (request.url.path.endsWith('/tokenlist')) {
        return response({
          'network': 'testnet-10',
          'tokens': tokens ?? [token()]
        });
      }
      if (request.url.path.contains('/portfolio/')) {
        expect(request.url.pathSegments.last, owner);
        return response(portfolio(positions: holdings));
      }
      if (request.url.path.endsWith('/markets')) {
        return response({
          'ok': true,
          'markets': [market()]
        });
      }
      throw StateError('Unexpected path ${request.url}');
    });

void main() {
  setUp(() => NetworkSettings.network.value = KaspaNetwork.tn10);
  test(
      'TN10 balances use covenant identity, exact zero decimals, ticker and image',
      () async {
    final assets =
        await KasForgeService(client: source()).walletAssets(address);
    expect(assets.single.symbol, 'SAME');
    expect(assets.single.covenantId, cid);
    expect(assets.single.balance, 250);
    expect(assets.single.rawBalance, '250');
    expect(assets.single.decimals, 0);
    expect(assets.single.imageUrl, startsWith('https://'));
    expect(assets.single.standard, 'kasforge-kcc20');
    expect(assets.single.discoveryComplete, false);
    expect(assets.single.validationStatus, 'kasforge-indexed');
  });
  test('duplicate symbols never merge different covenant balances', () async {
    final second = 'e' * 64;
    final assets = await KasForgeService(
        client: source(tokens: [
      token(),
      token(id: second)
    ], holdings: [
      {'token': cid, 'tokens': 250},
      {'token': second, 'tokens': 7}
    ])).walletAssets(address);
    expect(assets.map((a) => a.rawBalance), ['250', '7']);
    expect(assets.map((a) => a.covenantId).toSet().length, 2);
  });
  test('known empty wallet and source failure are distinct', () async {
    expect(
        await KasForgeService(client: source(holdings: []))
            .walletAssets(address),
        isEmpty);
    await expectLater(
        KasForgeService(client: source(unavailable: true))
            .walletAssets(address),
        throwsStateError);
  });
  test('missing, malformed, negative and duplicate quantities never mean zero',
      () async {
    for (final holdings in [
      [
        {'token': cid}
      ],
      [
        {'token': cid, 'tokens': -1}
      ],
      [
        {'token': cid, 'tokens': '0.025'}
      ],
      [
        {'token': cid, 'tokens': 'unknown'}
      ],
      [
        {'token': cid, 'tokens': 1},
        {'token': cid, 'tokens': 1}
      ],
      [
        {'token': 'e' * 64, 'tokens': 1}
      ],
    ]) {
      await expectLater(
          KasForgeService(client: source(holdings: holdings))
              .walletAssets(address),
          throwsStateError);
    }
  });
  test('wrong wallet or incomplete portfolio fails explicitly', () async {
    for (final data in [
      {...portfolio(), 'address': 'kaspatest:wrong'},
      {...portfolio()}..remove('positions'),
      {...portfolio()}..remove('orders'),
      {...portfolio(), 'ok': false},
    ]) {
      final service =
          KasForgeService(client: MockClient((_) async => response(data)));
      await expectLater(service.portfolio(address), throwsStateError);
    }
  });
  test('Mainnet and other chains never query the testnet API', () async {
    var calls = 0;
    final service = KasForgeService(client: MockClient((_) async {
      calls++;
      return response({});
    }));
    for (final network in [
      KaspaNetwork.mainnet,
      KaspaNetwork.kasplex,
      KaspaNetwork.igra
    ]) {
      NetworkSettings.network.value = network;
      await expectLater(service.tokens(), throwsStateError);
      await expectLater(service.walletAssets(address), throwsStateError);
    }
    expect(calls, 0);
    NetworkSettings.network.value = KaspaNetwork.tn10;
    await expectLater(
        service.walletAssets(kaspaAddressFromOwnerId(owner)), throwsStateError);
    expect(calls, 0);
  });
  test(
      'wrong network, unsupported units, duplicate IDs and invalid pool are rejected',
      () async {
    for (final bad in [
      {...token(), 'network': 'mainnet'},
      {...token(), 'decimals': 8},
      {
        ...token(),
        'extensions': {...token()['extensions'] as Map, 'graduated': true}
      },
    ]) {
      await expectLater(KasForgeService(client: source(tokens: [bad])).tokens(),
          throwsStateError);
    }
    await expectLater(
        KasForgeService(client: source(tokens: [token(), token()])).tokens(),
        throwsStateError);
  });
  test('only HTTPS logo URLs without credentials are accepted', () {
    for (final url in [
      'javascript:alert(1)',
      'http://example.com/a.png',
      'file:///a.png',
      'https://user:pass@example.com/a.png'
    ]) {
      expect(KasForgeToken.fromJson({...token(), 'logoURI': url}).logo, isNull);
    }
  });
  for (final graduated in [false, true]) {
    test('quote targets the live ${graduated ? 'pool' : 'curve'} covenant',
        () async {
      final t = KasForgeToken.fromJson(token(graduated: graduated));
      final calls = <Uri>[];
      final service = KasForgeService(client: MockClient((request) async {
        calls.add(request.url);
        if (request.url.path.contains('/market/')) {
          return response({'ok': true, 'market': market(graduated: graduated)});
        }
        expect(request.url.path, endsWith('/${graduated ? pool : curve}'));
        expect(request.url.queryParameters, {'side': 'buy', 'kas': '10'});
        return response(
            {'ok': true, 'side': 'buy', 'payKas': 10, 'receiveTokens': 250});
      }));
      final quote = await service.quote(t, 'buy', '10');
      expect(quote['marketId'], graduated ? pool : curve);
      expect(quote['tokenId'], cid);
      expect(calls.length, 2);
    });
  }
  test('graduation change invalidates old quote rather than using stale curve',
      () async {
    var calls = 0;
    final service = KasForgeService(client: MockClient((_) async {
      calls++;
      return response({'ok': true, 'market': market(graduated: true)});
    }));
    await expectLater(
        service.quote(KasForgeToken.fromJson(token()), 'buy', '10'),
        throwsStateError);
    expect(calls, 1);
  });
  test('slow source arriving after a network switch is discarded', () async {
    final reply = Completer<http.Response>();
    final service = KasForgeService(client: MockClient((_) => reply.future));
    final pending = service.tokens();
    final check = expectLater(pending, throwsStateError);
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    reply.complete(response({
      'network': 'testnet-10',
      'tokens': [token()]
    }));
    await check;
  });
  test('trading cannot be enabled through a token list or server flag', () {
    expect(KasForgeService.tradingEnabled, false);
    expect(KasForgeService.tradingBlockReason, contains('contract artifacts'));
  });
  test(
      'positive KasForge balance publishes before another TN10 source finishes',
      () async {
    SharedPreferences.setMockInitialValues({});
    final slowSeal = Completer<http.Response>();
    final seen = Completer<void>();
    final client = MockClient((request) async {
      if (request.url.host == 'kaspa.pumpforge.tech') {
        if (request.url.path.endsWith('/tokenlist')) {
          return response({
            'network': 'testnet-10',
            'tokens': [token()]
          });
        }
        return response(portfolio());
      }
      if (request.url.host == 'testnet.kasseal.com') return slowSeal.future;
      if (request.url.path.endsWith('/utxos')) return response([]);
      if (request.url.path.endsWith('/balance')) {
        return response({'balance': 1000000000});
      }
      return response([]);
    });
    final loaded = KaspaApi(client: client).loadWallet(address,
        includeAssetHistory: false,
        includeNativeTransactions: false, onProgress: (snapshot) {
      if (snapshot.kcc20Tokens.any((a) => a.covenantId == cid) &&
          !seen.isCompleted) {
        seen.complete();
      }
    });
    await seen.future.timeout(const Duration(seconds: 2));
    expect(slowSeal.isCompleted, false);
    slowSeal.complete(response({'tokens': [], 'holdings': []}));
    final wallet = await loaded;
    expect(wallet.kcc20Tokens.single.rawBalance, '250');
    client.close();
  }, skip: !KasForgeService.enabled);
}
