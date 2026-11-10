import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/kaspa_address.dart';
import 'package:kasvault_wallet/src/models/wallet_snapshot.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';
import 'package:kasvault_wallet/src/services/kcc20_standard_service.dart';
import 'package:kasvault_wallet/src/services/kron_holdings.dart';

const address =
    'kaspa:qp30ahte7r7qq6lum8utxf99nftffwgeg6sewgs49fz89tzpc36mxk89jjqlf';
final owner = kaspaOwnerIdFromAddress(address);
final cid = 'c' * 64, origin = 'a' * 64;
Map<String, Object?> metadata({int decimals = 6}) => {
      'covenant_id': cid,
      'ticker': 'NACHO',
      'decimals': decimals,
      'binding_verified': true,
      'image_bytes_verified': true,
      'image_hash': 'e' * 64,
    };
Map<String, Object?> holding({String? id, String raw = '1250000'}) => {
      'covenant_id': id ?? cid,
      'owner_scheme': 0,
      'owner_value': owner,
      'balance_raw': raw,
      'balance_complete': true,
      'metadata': metadata(),
      'token_units': {'status': 'verified', 'decimals': 6},
    };
Map<String, Object?> token({String? id, int decimals = 6}) => {
      'covenant_id': id ?? cid,
      'profile_id': 'KCC20PublicMint@c8a0871',
      'recognition': 'hash_proven_reference_actor_family',
      'metadata': {...metadata(decimals: decimals), 'covenant_id': id ?? cid},
    };
http.Response reply(Object data,
        {Map<String, Object?>? context,
        Map<String, Object?>? pagination,
        Map<String, Object?>? meta}) =>
    http.Response(
        jsonEncode({
          'data': data,
          'meta': {
            'network': 'mainnet',
            'reference_commit': Kcc20StandardService.reference,
            'snapshot_id': 'snapshot-1',
            ...?meta
          },
          if (context != null) 'address_context': context,
          if (pagination != null) 'pagination': pagination
        }),
        200);
Map<String, Object?> context({bool complete = true}) => {
      'address': address,
      'network': 'mainnet',
      'owner_value': owner,
      'owner_scheme': 0,
      'balances_complete': complete,
    };
http.Response account(List<Object?> rows,
        {bool complete = true, Map<String, Object?>? pagination}) =>
    reply(rows,
        context: context(complete: complete),
        pagination: pagination ?? {'has_more': false, 'next_cursor': null});
http.Response balance() => reply({
      'covenant_id': cid,
      'owner_scheme': 0,
      'owner_value': owner,
      'available': true,
      'balance_raw': '1250000',
      'outputs': [
        {'txid': origin, 'acceptance_id': '1'}
      ],
    });
MockClient source(
        {List<String>? paths,
        http.Response? addressResponse,
        http.Response? tokenResponse,
        http.Response? balanceResponse}) =>
    MockClient((request) async {
      paths?.add(request.url.path);
      if (request.url.path.contains('/addresses/')) {
        expect(request.url.pathSegments.contains(address), true);
        expect(request.url.queryParameters['limit'], '100');
        return addressResponse ?? account([holding()]);
      }
      if (request.url.path.endsWith('/tokens/$cid')) {
        return tokenResponse ?? reply(token());
      }
      if (request.url.path.endsWith('/balance')) {
        return balanceResponse ?? balance();
      }
      throw StateError('Unexpected catalogue/global request: ${request.url}');
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'held tokens only: three reads, exact verified units, public image API and origins',
      () async {
    final paths = <String>[];
    final wallet = await Kcc20StandardService(source(paths: paths))
        .load(address, historyLimit: 0);
    final asset = wallet.assets.single;
    expect(paths, hasLength(3));
    expect(paths.any((p) => p.endsWith('/status') || p.endsWith('/v1/tokens')),
        false);
    expect(asset.symbol, 'NACHO');
    expect(asset.balance, 1.25);
    expect(asset.decimals, 6);
    expect(asset.rawBalance, '1250000');
    expect(asset.imageUrl,
        'https://kasvio.network/api/kcc20/v1/images/${'e' * 64}');
    expect(asset.standard, 'kcc20');
    expect(asset.discoveryComplete, false);
    expect(asset.kcc20Cells, isEmpty);
    expect(asset.activityOrigins, [origin]);
    expect(wallet.warning, isEmpty);
  });
  test('positive holding publishes before a slow/failing origin lookup',
      () async {
    final gate = Completer<http.Response>();
    final visible = Completer<StandardKcc20Wallet>();
    final upstream = source();
    final service = Kcc20StandardService(MockClient((r) =>
        r.url.path.endsWith('/balance') ? gate.future : upstream.get(r.url)));
    final loading = service.load(address, historyLimit: 0, onProgress: (value) {
      if (value.assets.isNotEmpty && !visible.isCompleted) {
        visible.complete(value);
      }
    });
    expect((await visible.future).assets.single.symbol, 'NACHO');
    gate.complete(http.Response('unavailable', 503));
    final value = await loading;
    expect(value.assets.single.balance, 1.25);
    expect(value.warning, contains('origins'));
  });
  test('empty incomplete address discovery is not reported as complete zero',
      () async {
    final value = await Kcc20StandardService(
            source(addressResponse: account([], complete: false)))
        .load(address, historyLimit: 0);
    expect(value.assets, isEmpty);
    expect(value.warning, contains('incomplete'));
  });
  test('known positive balances survive incomplete global token coverage',
      () async {
    final value = await Kcc20StandardService(
            source(addressResponse: account([holding()], complete: false)))
        .load(address, historyLimit: 0);
    expect(value.assets.single.rawBalance, '1250000');
    expect(value.warning, contains('incomplete'));
  });
  test('fully covered empty account requires only one request', () async {
    final paths = <String>[];
    final value = await Kcc20StandardService(
            source(paths: paths, addressResponse: account([])))
        .load(address, historyLimit: 0);
    expect(value.assets, isEmpty);
    expect(value.warning, isEmpty);
    expect(paths, hasLength(1));
  });
  test('non-attributable global gaps are not wallet errors or complete zero',
      () async {
    for (final rows in [
      <Object?>[],
      <Object?>[holding()]
    ]) {
      final response = reply(rows, context: {
        ...context(complete: false),
        'unknown_tokens_attributable_to_address': false
      }, pagination: {
        'has_more': false,
        'next_cursor': null
      });
      final value =
          await Kcc20StandardService(source(addressResponse: response))
              .load(address, historyLimit: 0);
      expect(value.assets.length, rows.length);
      expect(value.warning, isEmpty);
      expect(value.coverageComplete, false);
    }
  });
  test('recognized Rocket family delegates to its dedicated discovery only',
      () async {
    final value = await Kcc20StandardService(source(
        tokenResponse: reply({
      ...token(),
      'profile_id': 'KCC20Parameterized@v1-i10-o10',
      'recognition': 'hash_proven_parameterized_actor_family',
      'market': {'venue': 'kasparocket'},
    }))).load(address, historyLimit: 0);
    expect(value.assets, isEmpty);
    expect(value.warning, isEmpty);
  });
  test('KForge 6x6 holdings are delegated without a standard-token warning',
      () async {
    final value = await Kcc20StandardService(source(
        tokenResponse: reply({
      ...token(),
      'profile_id': 'KCC20Parameterized@v1-i6-o6',
      'recognition': 'hash_proven_parameterized_actor_family',
      'market': {'venue': 'kforge'},
      'token_units': {'status': 'unknown', 'decimals': null},
    }))).load(address, historyLimit: 0);
    expect(value.assets, isEmpty);
    expect(value.warning, isEmpty);
  });
  test('delegation cannot hide wrong identities or unknown venue programs',
      () async {
    for (final override in [
      {'covenant_id': 'd' * 64},
      {'profile_id': 'KCC20Parameterized@v1-i99-o99'},
      {
        'market': {'venue': 'other'}
      },
      {'recognition': 'unverified'},
    ]) {
      final value = await Kcc20StandardService(source(
          tokenResponse: reply({
        ...token(),
        'profile_id': 'KCC20Parameterized@v1-i6-o6',
        'recognition': 'hash_proven_parameterized_actor_family',
        'market': {'venue': 'kforge'},
        ...override,
      }))).load(address, historyLimit: 0);
      expect(value.warning, contains('could not be verified'));
      expect(value.coverageComplete, false);
    }
  });
  test('only the identified obsolete template is quietly excluded', () async {
    for (final legacy in Kcc20StandardService.obsoleteTemplateHashes) {
      for (final location in ['template_hash', 'program', 'configuration']) {
        final detail = {
          ...token(),
          location:
              location == 'template_hash' ? legacy : {'template_hash': legacy},
        };
        final value =
            await Kcc20StandardService(source(tokenResponse: reply(detail)))
                .load(address, historyLimit: 0);
        expect(value.assets, isEmpty);
        expect(value.warning, isEmpty);
        final mismatch = await Kcc20StandardService(source(
                tokenResponse: reply({...detail, 'covenant_id': 'd' * 64})))
            .load(address, historyLimit: 0);
        expect(mismatch.warning, isNotEmpty);
      }
    }
  });
  test('healthy Kasvio reads never query Kascov or the retiring legacy API',
      () async {
    for (final complete in [true, false]) {
      final fallbackReads = <String>[];
      final upstream = source(
          addressResponse: reply([
        holding()
      ], context: {
        ...context(complete: complete),
        'unknown_tokens_attributable_to_address': false,
      }, pagination: {
        'has_more': false,
        'next_cursor': null
      }));
      final api = KaspaApi(client: MockClient((r) async {
        if (r.url.host == 'kasvio.network' && r.url.path.contains('/kcc20/v1/'))
          return upstream.get(r.url);
        if (r.url.host == 'kascov.io' || r.url.host == 'kcc20.info') {
          fallbackReads.add(r.url.toString());
          return http.Response('{}', 503);
        }
        if (r.url.path.endsWith('/balance')) {
          return http.Response('{"balance":0}', 200);
        }
        if (r.url.path.endsWith('/utxos')) return http.Response('[]', 200);
        return http.Response('{}', 503);
      }));
      final snapshots = <WalletSnapshot>[];
      final result = await api.loadWallet(address,
          includeAssetHistory: false,
          includeNativeTransactions: false,
          includeMarketData: false,
          onProgress: snapshots.add);
      expect(result.kcc20Tokens.single.symbol, 'NACHO');
      expect(fallbackReads, isEmpty);
      for (final snapshot in [...snapshots, result]) {
        final warning = snapshot.assetWarning ?? '';
        expect(warning, isNot(contains('top 100')));
        expect(warning, isNot(contains('Legacy KCC20 sources')));
        expect(warning, isNot(contains('could not be verified')));
      }
      if (!complete) expect(result.assetDiscoveryComplete, false);
    }
  });
  test('Kasvio outage stays visible even when fallback reports no holdings',
      () async {
    var kasvioFailed = false;
    final api = KaspaApi(client: MockClient((r) async {
      if (r.url.host == 'kasvio.network' && r.url.path.contains('/kcc20/v1/')) {
        kasvioFailed = true;
        return http.Response('{}', 503);
      }
      if (r.url.host == 'kascov.io') {
        expect(kasvioFailed, true);
        return http.Response(
            jsonEncode({'pubkey': owner, 'token_holdings': []}), 200);
      }
      if (r.url.host == 'kcc20.info')
        fail('Not needed after a valid Kascov read');
      if (r.url.path.endsWith('/balance'))
        return http.Response('{"balance":0}', 200);
      if (r.url.path.endsWith('/utxos')) return http.Response('[]', 200);
      return http.Response('{}', 503);
    }));
    final result = await api.loadWallet(address,
        includeAssetHistory: false,
        includeNativeTransactions: false,
        includeMarketData: false);
    expect(result.assetWarning,
        contains('KCC20 account data is temporarily unavailable from Kasvio and Kascov'));
    expect(result.assetDiscoveryComplete, false);
  });
  test('verified 0, 3 and 8 decimal units remain exact on the address path',
      () async {
    for (final decimals in [0, 3, 8]) {
      final value = await Kcc20StandardService(source(
              addressResponse: account([
                {
                  ...holding(),
                  'metadata': metadata(decimals: decimals),
                  'token_units': {'status': 'verified', 'decimals': decimals},
                }
              ]),
              tokenResponse: reply(token(decimals: decimals))))
          .load(address, historyLimit: 0);
      expect(value.assets.single.decimals, decimals);
      expect(value.assets.single.rawBalance, '1250000');
      expect(
          value.assets.single.balance,
          decimals == 0
              ? 1250000
              : decimals == 3
                  ? 1250
                  : 0.0125);
    }
  });
  test('503 cannot turn into zero or trigger a global scan', () async {
    final paths = <String>[];
    await expectLater(
        Kcc20StandardService(source(
                paths: paths,
                addressResponse: http.Response('unavailable', 503)))
            .load(address),
        throwsStateError);
    expect(paths, hasLength(2));
    expect(paths.last, contains('/addr/'));
    expect(paths.contains('/api/kcc20/v1/tokens'), false);
  });
  test('wrong address, owner, chain and revision are rejected', () async {
    for (final response in [
      reply([], context: {...context(), 'address': 'kaspa:other'}),
      reply([], context: {...context(), 'owner_value': 'd' * 64}),
      reply([], context: context(), meta: {'network': 'testnet-10'}),
      reply([], context: context(), meta: {'reference_commit': 'wrong'}),
    ]) {
      await expectLater(
          Kcc20StandardService(source(addressResponse: response)).load(address),
          throwsStateError);
    }
  });
  test('unsupported template and conflicting units are not signing support',
      () async {
    for (final invalid in [
      {...token(), 'template_hash': 'f' * 64},
      token(decimals: 8),
      {...token(), 'covenant_id': 'd' * 64},
    ]) {
      final value =
          await Kcc20StandardService(source(tokenResponse: reply(invalid)))
              .load(address, historyLimit: 0);
      expect(value.assets, isEmpty);
      expect(value.warning, contains('could not be verified'));
    }
  });
  test('later page failure preserves already published holdings', () async {
    final upstream = source();
    final value = await Kcc20StandardService(MockClient((r) async {
      if (r.url.path.contains('/addresses/')) {
        if (r.url.queryParameters['cursor'] != null) {
          return http.Response('down', 503);
        }
        return account([holding()],
            pagination: {'has_more': true, 'next_cursor': 'next+/='});
      }
      return upstream.get(r.url);
    })).load(address, historyLimit: 0);
    expect(value.assets.single.symbol, 'NACHO');
    expect(value.warning, contains('retained'));
  });
  test('repeated cursor cannot loop or double the holding', () async {
    final upstream = source();
    var pages = 0;
    final value = await Kcc20StandardService(MockClient((r) async {
      if (r.url.path.contains('/addresses/')) {
        pages++;
        if (pages > 1) expect(r.url.queryParameters['cursor'], 'opaque+/=');
        return account(pages == 1 ? [holding()] : [],
            pagination: {'has_more': true, 'next_cursor': 'opaque+/='});
      }
      return upstream.get(r.url);
    })).load(address, historyLimit: 0);
    expect(pages, 2);
    expect(value.assets, hasLength(1));
    expect(value.warning, contains('pagination'));
  });
  test('newer page snapshot cannot silently replace the first page', () async {
    final upstream = source();
    final value = await Kcc20StandardService(MockClient((r) async {
      if (r.url.path.contains('/addresses/')) {
        if (r.url.queryParameters['cursor'] != null) {
          return reply([],
              context: context(),
              meta: {'snapshot_id': 'different'},
              pagination: {'has_more': false});
        }
        return account([holding()],
            pagination: {'has_more': true, 'next_cursor': 'next'});
      }
      return upstream.get(r.url);
    })).load(address, historyLimit: 0);
    expect(value.assets.single.symbol, 'NACHO');
    expect(value.warning, contains('retained'));
  });
  test('duplicate/wrong-owner/malformed rows never inflate a valid holding',
      () async {
    final value = await Kcc20StandardService(source(
        addressResponse: account([
      holding(),
      holding(),
      {...holding(), 'owner_value': 'f' * 64},
      {...holding(), 'balance_raw': '-1'},
    ]))).load(address, historyLimit: 0);
    expect(value.assets.single.balance, 1.25);
    expect(value.warning, isNotEmpty);
  });
  test('KRON-imported standard rows cannot replace the standard-token identity',
      () async {
    for (final nativeFirst in [true, false]) {
      final kronArrived = Completer<void>();
      final standardVisible = Completer<void>();
      final snapshots = <WalletSnapshot>[];
      final upstream = source();
      final api = KaspaApi(client: MockClient((r) async {
        if (r.url.host == 'kasvio.network' &&
            r.url.path.contains('/kcc20/v1/')) {
          if (nativeFirst && r.url.path.contains('/addresses/')) {
            await kronArrived.future;
          }
          return upstream.get(r.url);
        }
        if (r.url.host == 'idx.kron.technology') {
          if (r.url.path.endsWith('/info')) {
            return http.Response(
                jsonEncode({
                  'result': {
                    'network': 'mainnet',
                    'networkOk': true,
                    'synced': true,
                    'divergent': false
                  }
                }),
                200);
          }
          if (r.url.path.endsWith('/tokenlist')) {
            if (!nativeFirst) await standardVisible.future;
            if (!kronArrived.isCompleted) kronArrived.complete();
            return http.Response(
                jsonEncode({
                  'result': [
                    {
                      'covenantId': cid,
                      'tick': 'STD-CCCCCCCCCCCC',
                      'name': 'NACHO',
                      'symbol': 'NACHO',
                      'family': 'kcc20v1',
                      'imported': true,
                      'balance': '1250000',
                      'dec': 6
                    }
                  ]
                }),
                200);
          }
        }
        if (r.url.path.endsWith('/balance')) {
          return http.Response('{"balance":0}', 200);
        }
        if (r.url.path.endsWith('/utxos')) return http.Response('[]', 200);
        return http.Response('{}', 503);
      }));
      final value = await api.loadWallet(address,
          includeAssetHistory: false,
          includeNativeTransactions: false,
          includeMarketData: false, onProgress: (snapshot) {
        snapshots.add(snapshot);
        if (snapshot.kcc20Tokens.any((a) => a.standard == 'kcc20') &&
            !standardVisible.isCompleted) {
          standardVisible.complete();
        }
      });
      expect(value.kcc20Tokens.single.symbol, 'NACHO');
      expect(value.kcc20Tokens.single.standard, 'kcc20');
      expect(
          snapshots
              .expand((s) => s.kcc20Tokens)
              .any((a) => a.symbol.startsWith('STD-')),
          false);
    }
  });
  test('late positive response survives caller deadline and reopening',
      () async {
    final gate = Completer<http.Response>();
    final requested = Completer<void>();
    final upstream = source();
    var firstDetail = true;
    final client = MockClient((r) async {
      if (r.url.path.endsWith('/tokens/$cid') && firstDetail) {
        firstDetail = false;
        requested.complete();
        return gate.future;
      }
      return upstream.get(r.url);
    });
    final progress = <StandardKcc20Wallet>[];
    final first = Kcc20StandardService(client)
        .load(address, historyLimit: 0, onProgress: progress.add);
    await requested.future;
    await expectLater(first.timeout(const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()));
    final reopened =
        Kcc20StandardService(client).load(address, historyLimit: 0);
    gate.complete(reply(token()));
    expect((await first).assets.single.symbol, 'NACHO');
    expect((await reopened).assets.single.rawBalance, '1250000');
    expect(progress.any((w) => w.assets.isNotEmpty), true);
  });
  test('real KRON-native balances remain independent from imported standards',
      () async {
    final assets = await KronHoldings(MockClient((r) async {
      if (r.url.path.endsWith('/info')) {
        return http.Response(
            jsonEncode({
              'result': {
                'network': 'mainnet',
                'networkOk': true,
                'synced': true,
                'divergent': false
              }
            }),
            200);
      }
      if (r.url.path.endsWith('/tokenlist')) {
        return http.Response(
            jsonEncode({
              'result': [
                {
                  'covenantId': cid,
                  'tick': 'STD-CCCCCCCCCCCC',
                  'family': 'kcc20v1',
                  'balance': '1250000',
                  'dec': 6
                },
                {
                  'covenantId': 'd' * 64,
                  'tick': 'KRON',
                  'balance': '1000',
                  'dec': 3
                }
              ]
            }),
            200);
      }
      return http.Response('{}', 503);
    })).load(address);
    expect(assets.single.symbol, 'KRON');
    expect(assets.single.standard, 'kron-native');
    expect(assets.single.balance, 1);
  });
  final hotfixSnapshot = Platform.environment['KASPIRE_KCC20_HOTFIX_SNAPSHOT'];
  test('captured goatmilk Kasvio holdings have no spurious standard warning',
      () async {
    final snapshot =
        jsonDecode(File(hotfixSnapshot!).readAsStringSync()) as Map;
    final replies = snapshot['responses'] as Map;
    final result = await Kcc20StandardService(MockClient((request) async {
      final response = replies[request.url.toString()];
      if (response == null)
        throw StateError('Uncaptured request ${request.url}');
      return http.Response(jsonEncode(response), 200);
    })).load(snapshot['address'] as String, historyLimit: 0);
    expect(result.warning, isEmpty);
    expect(
        result.assets
            .any((asset) => asset.symbol == 'KASPIREISTHEBESTKASPAWALLET'),
        true);
    expect(result.assets.every((asset) => asset.standard == 'kcc20'), true);
    // Global unknown contracts are not silently re-labelled as full coverage.
    expect(result.coverageComplete, false);
  },
      skip: hotfixSnapshot == null
          ? 'Requires public read-only Kasvio capture'
          : false);
  test('live public address discovery (read-only, opt-in)', () async {
    final client = HttpOverrides.runWithHttpOverrides(
        () => http.Client(), _LiveHttpOverrides());
    try {
      final watch = Stopwatch()..start();
      final value = await Kcc20StandardService(client).load(
          'kaspa:qzhsygguxn7wr5qjzg6qs8ppn2wxq8kdapv3823n00v870sz7yu05lsd5w85z',
          historyLimit: 0, onProgress: (w) {
        if (w.assets.isNotEmpty) {
          print('Live first positive: ${watch.elapsedMilliseconds} ms');
        }
      });
      final nacho = value.assets.singleWhere((a) =>
          a.covenantId ==
          '41d44970ba6307bcec418f677fd253778d0ffa47750d179dff647061aa6c0d40');
      expect(nacho.symbol, 'NACHO');
      expect(nacho.decimals, 6);
      expect(BigInt.parse(nacho.rawBalance!), greaterThan(BigInt.zero));
      expect(nacho.imageUrl, contains('/api/kcc20/v1/images/'));
      print('Live discovery completed: ${watch.elapsedMilliseconds} ms');
    } finally {
      client.close();
    }
  }, skip: Platform.environment['KASPIRE_LIVE_KCC20_ADDRESS'] != '1');
}

// The default override creates a real client instead of Flutter's HTTP-400
// test stub. Only the explicitly opted-in read-only integration test uses it.
class _LiveHttpOverrides extends HttpOverrides {}
