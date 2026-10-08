import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kasvault_wallet/src/screens/k_agora_screen.dart';
import 'package:kasvault_wallet/src/screens/nft_market_screen.dart';
import 'package:kasvault_wallet/src/services/nft_market_service.dart';

class FakeNftMarket extends NftMarketService {
  final calls = <Map<String, Object?>>[];
  String? ownedCollection;
  final entries = List.generate(
      21,
      (i) => <String, Object?>{
            'ticker': 'PUNKS',
            'tokenId': '$i',
            'priceSompi': 100000000 + i,
            'rarityRank': i + 1,
            'seller': 'other',
            'status': 'active',
            'listingTransactionId': 'tx$i',
            'createdAt': i
          });
  @override
  void guard() {}
  @override
  Future<bool> hasPendingBroadcast(String address) async => false;
  @override
  Future<Map<String, Object?>> browse(
      {String q = '',
      String? collection,
      Map<String, String> traits = const {},
      bool high = false,
      String? sort,
      int offset = 0,
      String? seller,
      bool refresh = false}) async {
    calls.add({
      'q': q,
      'collection': collection,
      'traits': Map.of(traits),
      'high': high,
      'sort': sort,
      'offset': offset,
      'seller': seller
    });
    return {
      'offers': entries.skip(offset).take(10).toList(),
      'nextOffset': offset + 10 < entries.length ? offset + 10 : null,
      'collections': ['PUNKS'],
      'traitOptions': {
        'Type': ['Alien', 'Human']
      }
    };
  }

  @override
  Future<List<Map<String, Object?>>> saved(String address) async => [];
  @override
  Future<void> save(String address, Map<String, Object?> record) async {}
  @override
  Future<List<String>> ownedCollections(String address) async => ['MYNFT'];
  @override
  Future<Map<String, Object?>> owned(String address,
      {String? cursor, String? collection}) async {
    ownedCollection = collection;
    return {
      'items': [
        {
          'ticker': 'MYNFT',
          'tokenId': '1',
          'rarityRank': 42,
          'status': {'state': 'unlisted'}
        }
      ],
      'next': null
    };
  }
}

void main() {
  test('owned collection loads ten per page and hides exhausted cursor',
      () async {
    final service = NftMarketService(client: MockClient((request) async {
      if (request.url.path.contains('/metadata/')) {
        return http.Response(
            jsonEncode({'items': [], 'ranksAvailable': true}), 200);
      }
      expect(request.url.path.endsWith('/TEST'), isTrue);
      final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
      final limit = int.parse(request.url.queryParameters['limit']!);
      final end = (offset + limit).clamp(0, 21);
      return http.Response(
          jsonEncode({
            'result': List.generate(end - offset,
                (i) => {'tick': 'TEST', 'tokenId': '${offset + i}'}),
            'next': end < 21 ? '$end' : null
          }),
          200);
    }));
    String? cursor;
    final sizes = <int>[];
    do {
      final page =
          await service.owned('wallet', collection: 'TEST', cursor: cursor);
      sizes.add((page['items'] as List).length);
      cursor = page['next'] as String?;
    } while (cursor != null);
    expect(sizes, [10, 10, 1]);
  });
  test('exact KAS price parsing, eight decimals and dust-safe fee', () {
    expect(nftPrice('10'), 1000000000);
    expect(nftPrice('1.00000001'), 100000001);
    expect(nftPrice('0.00476191'), 476191);
    for (final input in [
      '0',
      '0.00476190',
      '-1',
      '1,5',
      '1e8',
      'NaN',
      '1.123456789',
      '90000000000000000'
    ]) {
      expect(nftPrice(input), isNull, reason: input);
    }
  });
  testWidgets('K-Agora offers both markets without opening either',
      (tester) async {
    await tester
        .pumpWidget(const MaterialApp(home: KAgoraScreen(address: 'wallet')));
    expect(find.text('dot.k Market'), findsOneWidget);
    expect(find.text('NFT Market'), findsOneWidget);
    expect(find.text('Browse'), findsNothing);
  });
  testWidgets('browse uses ten listings, metadata and explicit load more',
      (tester) async {
    final service = FakeNftMarket();
    await tester.pumpWidget(MaterialApp(
        home: NftMarketScreen(address: 'wallet', service: service)));
    await tester.pumpAndSettle();
    expect(service.calls.single['offset'], 0);
    expect(find.text('PUNKS #0'), findsOneWidget);
    expect(find.text('Rarity rank #1'), findsOneWidget);
    expect(find.text('PUNKS #10'), findsNothing);
    await tester.scrollUntilVisible(find.text('Load more'), 1000,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    expect(service.calls.last['offset'], 10);
    expect(tester.takeException(), isNull);
  });
  testWidgets('search is debounced and reloads from the first page',
      (tester) async {
    final service = FakeNftMarket();
    await tester.pumpWidget(MaterialApp(
        home: NftMarketScreen(address: 'wallet', service: service)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'PUNKS #7');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(service.calls.last['q'], 'PUNKS #7');
    expect(service.calls.last['offset'], 0);
  });
  testWidgets('My NFTs has per-token list action and rarity', (tester) async {
    final service = FakeNftMarket();
    await tester.pumpWidget(MaterialApp(
        home: NftMarketScreen(address: 'wallet', service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My NFTs'));
    await tester.pumpAndSettle();
    expect(find.text('MYNFT #1'), findsOneWidget);
    expect(find.text('Rarity rank #42'), findsOneWidget);
    expect(find.text('List NFT'), findsOneWidget);
  });
  testWidgets('My listings load more retains the previous remote page',
      (tester) async {
    final service = FakeNftMarket();
    await tester.pumpWidget(MaterialApp(
        home: NftMarketScreen(
            address: 'wallet', initialTab: 2, service: service)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Load more'), 1000,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    expect(service.calls.last['offset'], 10);
    // Oldest retained item sorts to the end because My listings is newest-first.
    await tester.scrollUntilVisible(find.text('PUNKS #0'), 1000,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('PUNKS #0'), findsOneWidget);
  });
  testWidgets('traits stay collapsed until requested', (tester) async {
    final service = FakeNftMarket();
    await tester.pumpWidget(MaterialApp(
        home: NftMarketScreen(address: 'wallet', service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All listed collections'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PUNKS').last);
    await tester.pumpAndSettle();
    expect(find.text('Trait filters'), findsOneWidget);
    expect(find.text('Type'), findsNothing);
    await tester.scrollUntilVisible(find.text('Trait filters'), 150,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Trait filters'));
    await tester.pumpAndSettle();
    expect(find.text('Type'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('My NFTs collection choice reaches the paginated ownership query',
      (tester) async {
    final service = FakeNftMarket();
    await tester.pumpWidget(MaterialApp(
        home: NftMarketScreen(
            address: 'wallet', initialTab: 1, service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All my collections'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('MYNFT').last);
    await tester.pumpAndSettle();
    expect(service.ownedCollection, 'MYNFT');
    await tester.pumpWidget(const SizedBox());
  });
  test('indexer lag retries publication without another transaction', () async {
    SharedPreferences.setMockInitialValues({});
    var attempts = 0;
    final service = NftMarketService(client: MockClient((request) async {
      expect(request.url.path, '/nft-market-test-v1/offers');
      attempts++;
      return attempts == 1
          ? http.Response(
              '{"error":"Indexer has not confirmed this NFT listing yet; retry Publish"}',
              400)
          : http.Response('{}', 201);
    }));
    final record = <String, Object?>{
      'seller': 'wallet',
      'localId': 'listing',
      'stage': 'complete',
      'published': false
    };
    final publishing = service.publish(record);
    await publishing;
    expect(attempts, 2);
    expect(record['published'], true);
    expect((await service.saved('wallet')).single['published'], true);
    service.close();
  });
  test('invalid offers are not marked as published or retried indefinitely',
      () async {
    SharedPreferences.setMockInitialValues({});
    var attempts = 0;
    final service = NftMarketService(client: MockClient((_) async {
      attempts++;
      return http.Response(
          '{"error":"NFT listing or seller signature is invalid"}', 400);
    }));
    final record = <String, Object?>{
      'seller': 'wallet',
      'localId': 'invalid',
      'stage': 'complete',
      'published': false
    };
    await expectLater(service.publish(record), throwsStateError);
    await service.publishPending('wallet');
    expect(attempts, 1);
    expect(record['published'], false);
    expect(record['publicationBlocked'], true);
    service.close();
  });
}
