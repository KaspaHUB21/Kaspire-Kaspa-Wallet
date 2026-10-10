import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kasvault_wallet/src/services/kaspacom_market_service.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/services/preferences_service.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/screens/kaspacom_market_screen.dart';
import 'package:kasvault_wallet/src/theme.dart';
import 'package:kasvault_wallet/src/services/native_security.dart';
import 'package:kasvault_wallet/src/services/nft_market_service.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';
import 'package:kasvault_wallet/src/models/wallet_snapshot.dart';

const wallet =
    'kaspa:qqnvxvumjvzwmn755v8nrp4jxm2w50dv9mr2u4qrfqpq3h2hzyjx7tgkdtdgs';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({'watch_address_v1': wallet});
    NetworkSettings.network.value = KaspaNetwork.mainnet;
  });
  test('KNS already listed status follows holdings and the live saved order',
      () async {
    final service = KaspaComMarketService(wallet,
        client: MockClient((r) async => http.Response(
            jsonEncode({
              'sellerWalletAddress': wallet,
              'assetId': 'name-id',
              'status': 'LISTED_FOR_SALE'
            }),
            200)));
    await service.save({
      'localId': 'name',
      'kind': 'kns',
      'action': 'create',
      'stage': 'done',
      'assetId': 'name-id',
      'orderId': 'order'
    });
    final rows = [
      <String, Object?>{
        'assetId': 'name-id',
        'asset': 'example.kas',
        'status': 'unlisted'
      },
      <String, Object?>{'assetId': 'other', 'status': 'listed'},
      <String, Object?>{'assetId': 'free', 'status': 'unlisted'}
    ];
    await service.decorateKnsListingStates(rows);
    expect(rows.map((r) => r['marketplaceListed']), [true, true, false]);
    service.close();
  });
  for (final kind in ['krc20', 'krc721', 'kns']) {
    test('$kind Sales includes only completed sales by the active wallet',
        () async {
      final service =
          KaspaComMarketService(wallet, client: MockClient((r) async {
        expect(r.url.queryParameters['role'], 'sales');
        return http.Response(
            jsonEncode({
              'orders': [
                {
                  'orderId': 'sold',
                  'status': 'COMPLETED',
                  'sellerWalletAddress': wallet
                },
                {
                  'orderId': 'active',
                  'status': 'LISTED_FOR_SALE',
                  'sellerWalletAddress': wallet
                },
                {
                  'orderId': 'cancelled',
                  'status': 'CANCELLED',
                  'sellerWalletAddress': wallet
                },
                {
                  'orderId': 'purchase',
                  'status': 'COMPLETED',
                  'sellerWalletAddress': 'someone-else'
                },
              ],
              'totalCount': 4
            }),
            200);
      }));
      service.token = 'session';
      service.expires = DateTime.now().millisecondsSinceEpoch + 60000;
      expect(
          kcRows((await service.history(kind, 0, role: 'sales'))['orders'])
              .map((r) => r['orderId']),
          ['sold']);
      service.close();
    });
    test('$kind confirmed purchases generate the common success receipt',
        () async {
      final id = 'c' * 64;
      final service = KaspaComMarketService(wallet,
          client: MockClient((r) async => http.Response(
              r.url.path.contains('/transactions/')
                  ? '{"is_accepted":true}'
                  : '{}',
              200)));
      service.token = 'session';
      service.expires = DateTime.now().millisecondsSinceEpoch + 60000;
      final record = <String, Object?>{
        'localId': id,
        'kind': kind,
        'stage': 'settle',
        'action': 'buy',
        'orderId': 'b' * 24,
        'signed': {'transactionId': id, 'signedTxJson': '{}'},
        'assetDetails': {
          'ticker': 'HASH',
          'tokenId': kind == 'krc721' ? '48' : null,
          if (kind == 'kns') 'asset': 'example.kas',
          'totalPrice': 11
        }
      };
      await service.save(record);
      await service.resume(record, (_, __) async => false);
      expect(service.lastPurchaseReceipt?['Transaction ID'], id);
      expect(service.lastPurchaseReceipt?['Order price'], '11 KAS');
      expect(
          service.lastPurchaseReceipt?['Asset'],
          kind == 'kns'
              ? 'example.kas'
              : kind == 'krc721'
                  ? 'HASH #48'
                  : 'HASH');
      service.close();
    });
  }
  test(
      'owned NFTs show official and live local order listing state, not stale cache',
      () async {
    final service = KaspaComMarketService(wallet, client: MockClient((r) async {
      if (r.url.path.endsWith('/orders/live')) {
        return http.Response(
            jsonEncode({
              'ticker': '21MCOVEN',
              'tokenId': '48',
              'sellerWalletAddress': wallet,
              'status': 'LISTED_FOR_SALE'
            }),
            200);
      }
      if (r.url.path.endsWith('/orders/cancelled')) {
        return http.Response('{"status":"CANCELLED"}', 200);
      }
      final id = r.url.path.split('/').last;
      return http.Response(
          jsonEncode({
            'result': {
              'owner': wallet,
              'status': {'state': id == '1' ? 'listed' : 'unlisted'}
            }
          }),
          200);
    }));
    await service.save({
      'localId': 'create48',
      'kind': 'krc721',
      'action': 'create',
      'stage': 'done',
      'ticker': '21MCOVEN',
      'tokenId': '48',
      'orderId': 'live'
    });
    await service.save({
      'localId': 'create49',
      'kind': 'krc721',
      'action': 'create',
      'stage': 'done',
      'ticker': '21MCOVEN',
      'tokenId': '49',
      'orderId': 'cancelled'
    });
    final items = [
      <String, Object?>{
        'ticker': '21MCOVEN',
        'tokenId': '48',
        'status': {'state': 'unlisted'}
      },
      <String, Object?>{
        'ticker': '21MCOVEN',
        'tokenId': '49',
        'status': {'state': 'listed'}
      },
      <String, Object?>{'ticker': 'HASH', 'tokenId': '1'},
    ];
    await service.decorateNftListingStates(items);
    expect(items.map((r) => r['marketplaceListed']), [true, false, true]);
    service.close();
  });
  test(
      'confirmed delistings are hidden from browse and source pagination stays correct',
      () async {
    final service = KaspaComMarketService(wallet, client: MockClient((r) async {
      final offset = int.parse(r.url.queryParameters['offset']!);
      return http.Response(
          jsonEncode({
            'orders': List.generate(
                offset == 0 ? 10 : 12 - offset,
                (i) => {
                      'orderId': 'order${offset + i}',
                      'status': 'LISTED_FOR_SALE'
                    }),
            'totalCount': 12
          }),
          200);
    }));
    await service.save({
      'localId': 'cancel',
      'kind': 'krc721',
      'action': 'cancel',
      'stage': 'done',
      'orderId': 'order0'
    });
    final first = await service.browse('krc721', 'HASH', 'recent', 0);
    expect(kcRows(first['orders']), hasLength(10));
    expect(
        kcRows(first['orders']).any((r) => r['orderId'] == 'order0'), isFalse);
    expect(first['nextOffset'], 11);
    final last = await service.browse('krc721', 'HASH', 'recent', 11);
    expect(kcRows(last['orders']).first['orderId'], 'order11');
    expect(kcRows(last['orders']), hasLength(1));
    expect(last['nextOffset'], isNull);
    service.close();
  });
  for (final scenario in [
    'cancelled',
    'sold',
    'accepted purchase',
    'still spendable',
    'no proof',
    'outage',
    'different input',
    'unaccepted spend',
    'superseded accepted'
  ]) {
    test('saved purchase release: $scenario', () async {
      final listing = 'a' * 64, buyer = 'b' * 64, other = 'c' * 64;
      final record = <String, Object?>{
        'localId': buyer,
        'kind': 'krc721',
        'action': 'buy',
        'stage': 'settle',
        'orderId': 'order',
        'signed': {
          'transactionId': buyer,
          'signedTxJson': jsonEncode({
            'inputs': [
              {'transactionId': listing, 'index': 0}
            ]
          })
        },
        if (scenario == 'superseded accepted')
          'supersededSigned': [
            {
              'transactionId': other,
              'signedTxJson': jsonEncode({
                'inputs': [
                  {'transactionId': listing, 'index': 0}
                ]
              })
            }
          ]
      };
      var submissions = 0;
      final service =
          KaspaComMarketService(wallet, client: MockClient((request) async {
        if (request.method != 'GET') submissions++;
        if (scenario == 'outage') return http.Response('{}', 404);
        if (request.url.path.endsWith('/transactions/$listing')) {
          return http.Response(
              jsonEncode({
                'transaction_id': listing,
                'is_accepted': true,
                'outputs': [
                  {'index': 0, 'script_public_key_address': wallet}
                ]
              }),
              200);
        }
        if (request.url.path.endsWith('/utxos')) {
          return http.Response(
              jsonEncode(scenario == 'still spendable'
                  ? [
                      {
                        'outpoint': {'transactionId': listing, 'index': 0}
                      }
                    ]
                  : []),
              200);
        }
        if (request.url.path.endsWith('/full-transactions')) {
          return http.Response(
              jsonEncode(scenario == 'no proof'
                  ? []
                  : [
                      {
                        'transaction_id':
                            scenario == 'accepted purchase' ? buyer : other,
                        'is_accepted': scenario != 'unaccepted spend',
                        'inputs': [
                          {
                            'previous_outpoint_hash':
                                scenario == 'different input' ? buyer : listing,
                            'previous_outpoint_index': 0
                          }
                        ]
                      }
                    ]),
              200);
        }
        throw StateError('Unexpected request');
      }));
      await service.save(record);
      final released = scenario == 'cancelled' || scenario == 'sold';
      expect(await service.releaseInvalidatedPurchase(record), released);
      final stored = (await service.saved()).single;
      expect(stored['stage'], released ? 'done' : 'settle');
      expect(stored['signed'], record['signed']);
      expect(stored['outcome'], released ? 'invalidated' : isNull);
      expect(submissions, 0);
      if (released) {
        await service.requireNoPending();
        expect(service.lastRecoveryMessage, contains('archived'));
      }
      service.close();
    });
  }
  test(
      'new transactions automatically release a proven invalidated saved purchase',
      () async {
    final listing = 'a' * 64, buyer = 'b' * 64;
    final service =
        KaspaComMarketService(wallet, client: MockClient((request) async {
      if (request.url.path.contains('/transactions/')) {
        return http.Response(
            jsonEncode({
              'transaction_id': listing,
              'is_accepted': true,
              'outputs': [
                {'index': 0, 'script_public_key_address': wallet}
              ]
            }),
            200);
      }
      if (request.url.path.endsWith('/utxos')) return http.Response('[]', 200);
      return http.Response(
          jsonEncode([
            {
              'transaction_id': 'c' * 64,
              'is_accepted': true,
              'inputs': [
                {
                  'previous_outpoint_hash': listing,
                  'previous_outpoint_index': 0
                }
              ]
            }
          ]),
          200);
    }));
    await service.save({
      'localId': buyer,
      'kind': 'krc721',
      'action': 'buy',
      'stage': 'settle',
      'signed': {
        'transactionId': buyer,
        'signedTxJson': jsonEncode({
          'inputs': [
            {'transactionId': listing, 'index': 0}
          ]
        })
      }
    });
    await service.requireNoPending();
    expect((await service.saved()).single['outcome'], 'invalidated');
    service.close();
  });
  test('unit-price listings compute exact totals with KaspaCom cent precision',
      () {
    expect(kcListingTotal('4', '0.915'), '3.66');
    expect(kcListingTotal('1000', '0.00017663'), '0.18');
    expect(kcListingTotal('1,5', '1,2'), '1.80');
    expect(kcListingTotal('0.1', '0.15'), '0.02');
    expect(() => kcListingTotal('-1', '1'), throwsStateError);
    expect(() => kcListingTotal('NaN', '1'), throwsStateError);
  });
  test('confirmed cancellations cannot reappear as active seller listings',
      () async {
    final service = KaspaComMarketService(wallet,
        client: MockClient((r) async => http.Response(
            '{"orders":[{"orderId":"cancelled","status":"LISTED_FOR_SALE"},{"orderId":"active","status":"LISTED_FOR_SALE"},{"orderId":"sold","status":"COMPLETED"}],"totalCount":3}',
            200)));
    service.token = 'session';
    service.expires = DateTime.now().millisecondsSinceEpoch + 60000;
    await service.save({
      'localId': 'cancel',
      'kind': 'krc721',
      'orderId': 'cancelled',
      'action': 'cancel',
      'stage': 'done'
    });
    final rows =
        kcRows((await service.history('krc721', 0, role: 'seller'))['orders']);
    expect(rows.map((r) => r['orderId']), ['active']);
    service.close();
  });
  test(
      'local listing fallback filters before filling a ten-item page with a source cursor',
      () async {
    final service = KaspaComMarketService(wallet, client: MockClient((r) async {
      if (r.url.path.endsWith('/history')) {
        return http.Response('{"orders":[],"totalCount":0}', 200);
      }
      final id = r.url.path.split('/').last, n = int.parse(id);
      return http.Response(
          jsonEncode({
            'orderId': id,
            'status': n > 13 ? 'COMPLETED' : 'LISTED_FOR_SALE'
          }),
          200);
    }));
    service.token = 'session';
    service.expires = DateTime.now().millisecondsSinceEpoch + 60000;
    for (var i = 1; i <= 25; i++) {
      await service.save({
        'localId': 'create$i',
        'kind': 'krc721',
        'action': 'create',
        'stage': 'done',
        'orderId': '$i'
      });
    }
    final first = await service.history('krc721', 0, role: 'seller');
    expect(kcRows(first['orders']), hasLength(10));
    expect(first['nextOffset'], 22);
    final last = await service.history('krc721', 22, role: 'seller');
    expect(kcRows(last['orders']), hasLength(3));
    expect(last['nextOffset'], isNull);
    service.close();
  });
  testWidgets(
      'KRC20 listing defaults to floor and recalculates total from unit price',
      (tester) async {
    final service = KaspaComMarketService(wallet,
        api: _AssetApi(),
        client: MockClient((r) async => http.Response(
            r.url.path.endsWith('/summary')
                ? '{"ticker":"KASBTC","floorPrice":0.915}'
                : '{"items":[]}',
            200)));
    await tester.pumpWidget(MaterialApp(
        home: KaspaComMarketScreen(address: wallet, service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('KRC-20'));
    await tester.pumpAndSettle();
    expect(find.text('Sort all offers'), findsNothing);
    await tester.tap(find.text('My assets'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('List on KaspaCom'));
    await tester.tap(find.text('List on KaspaCom'));
    await tester.pumpAndSettle();
    final quantity = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Token amount');
    final unit = find.byWidgetPredicate((w) =>
        w is TextField && w.decoration?.labelText == 'Price per token in KAS');
    final total = find.byWidgetPredicate((w) =>
        w is TextField && w.decoration?.labelText == 'Total price in KAS');
    expect(tester.widget<TextField>(unit).controller!.text, '0.915');
    await tester.enterText(quantity, '4');
    await tester.pump();
    expect(tester.widget<TextField>(total).controller!.text, '3.66');
    await tester.enterText(unit, '1.2');
    await tester.pump();
    expect(tester.widget<TextField>(total).controller!.text, '4.80');
    expect(tester.widget<TextField>(total).readOnly, isTrue);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
      'My NFT assets offer all owned collections and filter before loading',
      (tester) async {
    final service = KaspaComMarketService(wallet,
        client: MockClient((r) async => http.Response('{"items":[]}', 200)));
    final nfts = _OwnedNfts();
    await tester.pumpWidget(MaterialApp(
        home: KaspaComMarketScreen(
            address: wallet, service: service, nftService: nfts)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My assets'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All collections'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('HASH').last);
    await tester.pumpAndSettle();
    expect(nfts.selections, [null, 'HASH']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  test('KAS prices use exact decimal amounts, never token/raw unit guessing',
      () {
    for (final pair in {
      '0': 0,
      '0.00000001': 1,
      '0.5': 50000000,
      '22.55': 2255000000,
      '90000000': 9000000000000000
    }.entries) {
      expect(kcSompi(pair.key), pair.value);
      expect(kcSompi(kcKas(pair.value)), pair.value);
    }
    for (final v in ['-1', '1e8', 'NaN', '1.000000001', '90000001', null]) {
      expect(() => kcSompi(v), throwsStateError);
    }
  });
  test('my orders delegates role filtering before pagination', () async {
    final service = KaspaComMarketService(wallet, client: MockClient((r) async {
      expect(r.url.queryParameters, {'offset': '10', 'role': 'buyer'});
      return http.Response('{"orders":[],"totalCount":20}', 200);
    }));
    service.token = 'session';
    service.expires = DateTime.now().millisecondsSinceEpoch + 60000;
    expect(
        (await service.history('krc20', 10, role: 'buyer'))['totalCount'], 20);
    service.close();
  });
  testWidgets(
      'purchase success is a full themed screen with an explicit return button',
      (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final theme in [
      KaspireTheme.hub21,
      KaspireTheme.glacier,
      KaspireTheme.neptune
    ]) {
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: const KaspaComPurchaseSuccess(receipt: {
            'Asset': 'KASBTC',
            'Quantity': '4',
            'Order price': '4.83 KAS',
            'Transaction ID': 'test'
          })));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Return to marketplace'));
      expect(find.text('Purchase successful'), findsOneWidget);
      expect(find.text('4.83 KAS'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: theme.name);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
  test('partner JSON receives only the native calculated ID', () {
    final id = 'a' * 64;
    final tx = jsonDecode(kcSignedPskt(
        {'signedTxJson': '{"id":"stale","inputs":[]}', 'transactionId': id}));
    expect(tx['id'], id);
    expect(() => kcSignedPskt({'signedTxJson': '{}', 'transactionId': 'bad'}),
        throwsStateError);
  });
  test('price labels do not use raw token units or scientific notation', () {
    expect(kcPrice(0.00020988), '0.00020988');
    expect(kcPrice(1000), '1000');
    expect(kcPrice(null), 'Unavailable');
    expect(kcPrice(0), '0');
  });
  test('delegated quotes distinguish commission from same-recipient royalties',
      () {
    final row = <String, Object?>{
      'exchangeQuote': true,
      'currentFee': 0.5,
      'psktSeller': jsonEncode({
        'outputs': [
          {'value': '583001627', 'scriptPublicKey': 'seller'},
          {'value': '50000000', 'scriptPublicKey': 'platform'},
          {'value': '50000000', 'scriptPublicKey': kcExchangeScript},
          {'value': '90000000', 'scriptPublicKey': kcExchangeScript}
        ]
      })
    };
    expect(kcExchangeFee(row), 50000000);
    expect(kcExchangeFee({...row, 'exchangeQuote': false}), 0);
    expect(() => kcExchangeFee({...row, 'currentFee': 0.6}), throwsStateError);
    expect(() => kcExchangeFee({...row, 'psktSeller': '{"outputs":[]}'}),
        throwsStateError);
  });
  test('purchase details bind the delegated quote to the authenticated wallet',
      () async {
    final service = KaspaComMarketService(wallet, client: MockClient((r) async {
      expect(r.url.queryParameters, {'quote': '1'});
      expect(r.headers['authorization'], 'Bearer wallet-session');
      return http.Response('{"exchangeQuote":true}', 200);
    }));
    service.token = 'wallet-session';
    expect(
        (await service.detail('krc20', 'b' * 24, quote: true))['exchangeQuote'],
        true);
    service.close();
  });
  test('legacy recovery requires fresh approval before signing additional fees',
      () async {
    final listing = 'a' * 64, old = 'c' * 64;
    final security = _RecoverySecurity();
    final row = <String, Object?>{
      'orderId': 'b' * 24,
      'status': 'LISTED_FOR_SALE',
      'sellerWalletAddress': wallet,
      'psktTransactionId': listing,
      'ticker': 'NACHO',
      'totalPrice': 5,
      'currentFee': 0.5,
      'exchangeQuote': true,
      'psktSeller': jsonEncode({
        'outputs': [
          {},
          {},
          {'value': '50000000', 'scriptPublicKey': kcExchangeScript}
        ]
      })
    };
    final service = KaspaComMarketService(wallet, security: security,
        client: MockClient((r) async {
      expect(r.url.path, isNot(endsWith('/buy')));
      if (r.url.path.contains('/transactions/')) {
        return http.Response('{}', 404);
      }
      if (r.url.path.endsWith('/proof')) {
        return http.Response(
            jsonEncode({
              'result': [
                {
                  'from': wallet,
                  'uTxid': listing,
                  'tick': 'NACHO',
                  'uAddr': wallet,
                  'uScript': 'aabb'
                }
              ]
            }),
            200);
      }
      if (r.url.path.endsWith('/utxos')) {
        return http.Response(
            jsonEncode([
              {
                'outpoint': {'transactionId': listing, 'index': 0},
                'utxoEntry': {'amount': '105000000'}
              }
            ]),
            200);
      }
      if (r.url.path.endsWith('/fee-estimate')) {
        return http.Response('{"priorityBucket":{"feerate":100}}', 200);
      }
      expect(r.url.queryParameters['quote'], '1');
      return http.Response(jsonEncode(row), 200);
    }));
    service.token = 'session';
    service.expires = DateTime.now().millisecondsSinceEpoch + 60000;
    final record = <String, Object?>{
      'localId': old,
      'kind': 'krc20',
      'action': 'buy',
      'stage': 'settle',
      'orderId': 'b' * 24,
      'signed': {
        'transactionId': old,
        'signedTxJson': jsonEncode({
          'inputs': [
            {'transactionId': listing, 'index': 0}
          ],
          'outputs': []
        })
      }
    };
    await service.save(record);
    var reviews = 0;
    await expectLater(
        service.resume(record, (title, details) async {
          reviews++;
          expect(details['KaspaCom fee (sompi)'], 50000000);
          expect(details['External exchange fee (sompi)'], 50000000);
          return false;
        }),
        throwsA(isA<KaspaComCancelled>()));
    expect(reviews, 1);
    expect(security.signCalls, 0);
    expect((await service.saved()).single['signed'], record['signed']);
    expect(record['quoteVersion'], isNull);
    service.close();
  });
  test('NFT filters and rank sort reach the global marketplace query',
      () async {
    final service = KaspaComMarketService(wallet, client: MockClient((r) async {
      expect(r.url.queryParameters['sort'], 'rankLow');
      expect(jsonDecode(r.url.queryParameters['traits']!),
          {'Background': 'bloodDAG'});
      expect(r.url.queryParameters['offset'], '10');
      return http.Response('{"orders":[],"totalCount":0}', 200);
    }));
    await service.browse('krc721', 'KASZOMBIES', 'rankLow', 10,
        traits: {'Background': 'bloodDAG'});
    service.close();
  });
  test(
      'accepted legacy purchases verify once without a second signing or purchase',
      () async {
    final old = 'c' * 64;
    final service = KaspaComMarketService(wallet, client: MockClient((r) async {
      if (r.url.path.endsWith('/transactions/$old')) {
        return http.Response('{"is_accepted":true}', 200);
      }
      expect(r.url.path, endsWith('/verify'));
      expect(jsonDecode(r.body)['transactionId'], old);
      return http.Response('{}', 200);
    }));
    service.token = 'session';
    service.expires = DateTime.now().millisecondsSinceEpoch + 60000;
    final record = <String, Object?>{
      'localId': old,
      'kind': 'krc20',
      'action': 'buy',
      'stage': 'settle',
      'orderId': 'b' * 24,
      'signed': {'transactionId': old, 'signedTxJson': '{}'}
    };
    await service.save(record);
    await service.resume(
        record,
        (_, __) async =>
            throw StateError('Must not sign an accepted purchase'));
    expect(record['stage'], 'done');
    expect(record['signed'], {'transactionId': old, 'signedTxJson': '{}'});
    expect((await service.saved()), hasLength(1));
    service.close();
  });
  test(
      'KRC20 preflight uses the official relay and current node UTXO, not an archive lookup',
      () async {
    final id = 'a' * 64;
    var proofRead = false, nodeRead = false;
    final service = KaspaComMarketService(wallet,
        security: _DescriptorSecurity(), client: MockClient((r) async {
      expect(r.url.host, isNot('api.kasplex.org'));
      expect(r.url.path, isNot(contains('/transactions/')));
      if (r.url.path.endsWith('/proof')) {
        proofRead = true;
        return http.Response(
            jsonEncode({
              'result': [
                {
                  'from': wallet,
                  'uTxid': id,
                  'tick': 'NACHO',
                  'uAddr': wallet,
                  'uScript': 'aabb'
                }
              ]
            }),
            200);
      }
      if (r.url.path.endsWith('/utxos')) {
        nodeRead = true;
        expect(r.url.path, contains('/api/local-node/addresses/'));
        return http.Response(
            jsonEncode([
              {
                'outpoint': {'transactionId': id, 'index': 0},
                'utxoEntry': {'amount': '105000000'}
              }
            ]),
            200);
      }
      if (r.url.path.endsWith('/info/fee-estimate')) {
        return http.Response('{"priorityBucket":{"feerate":100}}', 200);
      }
      return http.Response('{}', 200);
    }));
    final result = await service.live('krc20', {
      'status': 'LISTED_FOR_SALE',
      'orderId': 'b' * 24,
      'sellerWalletAddress': wallet,
      'psktTransactionId': id,
      'ticker': 'NACHO',
      'totalPrice': 5,
      'currentFee': 0.5,
      'psktSeller': '{}'
    });
    expect(proofRead, true);
    expect(nodeRead, true);
    expect(jsonDecode(result['listingUtxosJson']! as String), hasLength(1));
    service.close();
  });
  testWidgets('my orders visibly separates seller listings and buyer purchases',
      (tester) async {
    final roles = <String>[];
    final service = KaspaComMarketService(wallet, client: MockClient((r) async {
      if (r.url.path.endsWith('/history')) {
        roles.add(r.url.queryParameters['role']!);
      }
      return http.Response('{"items":[],"orders":[],"totalCount":0}', 200);
    }));
    service.token = 'session';
    service.expires = DateTime.now().millisecondsSinceEpoch + 60000;
    await tester.pumpWidget(MaterialApp(
        home: KaspaComMarketScreen(address: wallet, service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My orders'));
    await tester.pumpAndSettle();
    expect(find.text('My listings'), findsOneWidget);
    await tester.tap(find.text('Purchases'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sales'));
    await tester.pumpAndSettle();
    expect(roles, ['seller', 'buyer', 'sales']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('KRC20 browse shows logo, floor and both order price units',
      (tester) async {
    final service = KaspaComMarketService(wallet, client: MockClient((r) async {
      if (r.url.path.endsWith('/catalog')) {
        return http.Response('{"items":[{"ticker":"NACHO"}]}', 200);
      }
      if (r.url.path.endsWith('/summary')) {
        return http.Response(
            '{"ticker":"NACHO","imageUrl":"https://example.com/nacho.png","floorPrice":0.0002}',
            200);
      }
      return http.Response(
          '{"orders":[{"ticker":"NACHO","logoUrl":"","totalPrice":5,"quantity":10000,"pricePerToken":0.0005}],"totalCount":1}',
          200);
    }));
    await tester.pumpWidget(MaterialApp(
        home: KaspaComMarketScreen(address: wallet, service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('KRC-20'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('NACHO'));
    await tester.tap(find.text('NACHO'));
    await tester.pumpAndSettle();
    expect(find.text('Floor: 0.0002 KAS / NACHO'), findsOneWidget);
    expect(find.text('Price: 0.0005 KAS / NACHO'), findsOneWidget);
    expect(find.text('1 KAS = 2000 NACHO'), findsOneWidget);
    final logos = tester.widgetList<Image>(find.byType(Image));
    expect(logos.length, 2);
    expect(
        logos.every((logo) =>
            (logo.image as NetworkImage).url ==
            'https://example.com/nacho.png'),
        isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('marketplace catalog and recovery fit all decorative themes',
      (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final previous = AppSettings.theme.value;
    addTearDown(() => AppSettings.theme.value = previous);
    for (final theme in [
      KaspireTheme.hub21,
      KaspireTheme.glacier,
      KaspireTheme.neptune
    ]) {
      AppSettings.theme.value = theme;
      final service = KaspaComMarketService(wallet,
          client: MockClient((r) async => http.Response(
              '{"items":[{"ticker":"KASZOMBIES","price":100,"totalHolders":25}],"totalCount":1}',
              200)));
      await service.save({
        'localId': 'pending',
        'kind': 'krc20',
        'action': 'create',
        'stage': 'commit'
      });
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: KaspaComMarketScreen(address: wallet, service: service)));
      await tester.pumpAndSettle();
      expect(find.text('Check / resume saved transaction'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('KASZOMBIES'), 100,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Floor Price: 100 KAS · 25 holders'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: theme.name);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
  testWidgets(
      'compact KRC20 orders fit narrow themes and keep floor header pinned',
      (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final theme in [
      KaspireTheme.hub21,
      KaspireTheme.glacier,
      KaspireTheme.neptune
    ]) {
      final service =
          KaspaComMarketService(wallet, client: MockClient((r) async {
        if (r.url.path.endsWith('/catalog')) {
          return http.Response('{"items":[{"ticker":"KASBTC"}]}', 200);
        }
        if (r.url.path.endsWith('/summary')) {
          return http.Response('{"ticker":"KASBTC","floorPrice":0.915}', 200);
        }
        return http.Response(
            '{"orders":[{"ticker":"KASBTC","totalPrice":4.83,"quantity":4}],"totalCount":1}',
            200);
      }));
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: KaspaComMarketScreen(address: wallet, service: service)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('KRC-20'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('KASBTC'), 100,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('KASBTC'));
      await tester.pumpAndSettle();
      final before = tester.getTopLeft(find.text('Floor: 0.915 KAS / KASBTC'));
      await tester.scrollUntilVisible(find.text('View order'), 100,
          scrollable: find.byType(Scrollable).first);
      expect(tester.getTopLeft(find.text('Floor: 0.915 KAS / KASBTC')), before);
      expect(find.text('4.83 KAS'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: theme.name);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
  test('public marketplace reads have no partner credential or wallet bearer',
      () async {
    final service = KaspaComMarketService(wallet, client: MockClient((r) async {
      expect(r.url.host, 'kaspire.kaslab.space');
      expect(r.url.path, '/kaspacom-market-test-v1/krc721/browse');
      expect(r.url.queryParameters,
          {'search': 'KASZOMBIES', 'sort': 'high', 'offset': '10'});
      expect(r.headers.containsKey('authorization'), false);
      return http.Response(jsonEncode({'orders': [], 'totalCount': 0}), 200);
    }));
    expect(
        (await service.browse(
            'krc721', 'KASZOMBIES', 'high', 10))['nextOffset'],
        isNull);
    service.close();
  });
  test('network/account changes invalidate a pending response', () async {
    final service = KaspaComMarketService(wallet, client: MockClient((r) async {
      await PreferencesService().setAddress('another wallet');
      return http.Response('{}', 200);
    }));
    await expectLater(service.catalog('krc20', 0), throwsStateError);
    service.close();
    final blocked = KaspaComMarketService(wallet,
        client: MockClient((_) async => throw StateError('must not request')));
    NetworkSettings.network.value = KaspaNetwork.tn10;
    await expectLater(blocked.catalog('krc20', 0), throwsStateError);
    blocked.close();
  });
  test(
      'recovery is persisted by wallet and blocks duplicate fresh transactions',
      () async {
    final service = KaspaComMarketService(wallet);
    await service.save({'localId': 'one', 'stage': 'commit'});
    await expectLater(service.requireNoPending(), throwsStateError);
    await service.save({'localId': 'one', 'stage': 'done'});
    await service.requireNoPending();
    expect((await service.saved()).length, 1);
    expect((await KaspaComMarketService('another wallet').saved()), isEmpty);
    service.close();
  });
  test('401 clears the wallet session and shows a readable error', () async {
    final service = KaspaComMarketService(wallet,
        client: MockClient((_) async => http.Response(
            '{"error":"Unlock and authenticate this wallet first"}', 401)));
    service.token = 'old';
    service.expires = 123;
    await expectLater(
        service.request('/krc20/history', private: true), throwsStateError);
    expect(service.token, isNull);
    expect(service.expires, 0);
    service.close();
  });
}

class _DescriptorSecurity extends NativeSecurity {
  @override
  Future<Map<String, Object?>> prepareKaspacomMarket(
          Map<String, Object?> request) async =>
      {'listingAddress': wallet, 'redeemScript': 'aabb'};
}

class _AssetApi extends KaspaApi {
  @override
  Future<WalletSnapshot> loadWallet(String address,
          {int transactionLimit = 20,
          bool includeNativeTransactions = true,
          void Function(WalletSnapshot)? onProgress}) async =>
      const WalletSnapshot(
          balanceSompi: 1000000000,
          kasUsd: 0.03,
          transactions: [],
          krc20Tokens: [
            WalletAsset(
                symbol: 'KASBTC',
                balance: 4,
                kind: 'KRC-20',
                decimals: 8,
                rawBalance: '400000000')
          ],
          krc721Collections: [],
          knsDomains: []);
}

class _OwnedNfts extends NftMarketService {
  final selections = <String?>[];
  @override
  Future<List<String>> ownedCollections(String address) async =>
      ['HASH', 'KASRANKS'];
  @override
  Future<Map<String, Object?>> owned(String address,
      {String? cursor, String? collection}) async {
    selections.add(collection);
    return {'items': [], 'next': null};
  }
}

class _RecoverySecurity extends _DescriptorSecurity {
  int signCalls = 0;
  @override
  Future<Map<String, Object?>> prepareKaspacomMarket(
          Map<String, Object?> request) async =>
      request['action'] == 'describe'
          ? super.prepareKaspacomMarket(request)
          : {
              'request': {'sender': wallet},
              'networkFeeSompi': 100
            };
  @override
  Future<Map<String, Object?>> preparePskt(
          Map<String, Object?> request) async =>
      {'outputs': [], 'reviewHash': 'review'};
  @override
  Future<Map<String, Object?>> signPskt(
      Map<String, Object?> request, String hash) async {
    signCalls++;
    throw StateError('Must not sign without approval');
  }
}
