import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/krc721_reads.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';
import 'package:kasvault_wallet/src/services/nft_market_service.dart';
import 'package:kasvault_wallet/src/widgets/krc721_image.dart';

void main() {
  const owner =
      'kaspa:qz03mracsz6c0pjxmsdaql39453tn3jgmrldkqpy24ea39rxtvd9xxynslpyc';
  bool local(http.Request r) => r.url.path.startsWith('/krc721-read-v1/');
  test('healthy local ownership including empty result never queries official',
      () async {
    var official = 0;
    final client = MockClient((r) async {
      if (!local(r)) {
        official++;
        return http.Response('{}', 503);
      }
      return http.Response(
          '{"message":"success","result":[],"next":null}', 200);
    });
    expect((await Krc721Reads(client).walletPage(owner))['result'], isEmpty);
    expect(official, 0);
  });
  test('unavailable local source selects official, not both in parallel',
      () async {
    final calls = <String>[];
    final client = MockClient((r) async {
      calls.add(r.url.host);
      return local(r)
          ? http.Response('{}', 503)
          : http.Response(
              '{"result":[{"tick":"KASZOMBIES","tokenId":"41"}]}', 200);
    });
    expect(
        (await Krc721Reads(client).walletPage(owner))['result'], hasLength(1));
    expect(calls, ['kaspire.kaslab.space', 'krc721-indexer.kaspa.com']);
  });
  test('timeout or client transport failure uses official fallback', () async {
    final client = MockClient((r) async => local(r)
        ? throw http.ClientException('offline')
        : http.Response('{"result":[]}', 200));
    expect((await Krc721Reads(client).walletPage(owner))['result'], isEmpty);
    final timed = MockClient((r) => local(r)
        ? Completer<http.Response>().future
        : Future.value(http.Response('{"result":[]}', 200)));
    expect(
        (await Krc721Reads(timed, timeout: const Duration(milliseconds: 5))
            .walletPage(owner))['result'],
        isEmpty);
  });
  test('broken local responses use emergency fallback', () async {
    for (final code in [403, 404, 200]) {
      var calls = 0;
      final client = MockClient((r) async {
        calls++;
        return local(r)
            ? http.Response('{}', code)
            : http.Response('{"result":[{"tick":"TEST","tokenId":"1"}]}', 200);
      });
      expect((await Krc721Reads(client).walletPage(owner))['result'],
          hasLength(1));
      expect(calls, 2);
    }
  });
  test('local ranks and unknown ranks do not trigger provider calls', () async {
    var calls = 0;
    final client = MockClient((r) async {
      calls++;
      expect(local(r), true);
      return http.Response(
          '{"ranksAvailable":true,"items":[{"tokenId":"41","rarityRank":100},{"tokenId":"42","rarityRank":null}]}',
          200);
    });
    final rows = await Krc721Reads(client).metadata('KASZOMBIES', ['41', '42']);
    expect(rows.first['rarityRank'], 100);
    expect(rows.last['rarityRank'], null);
    expect(calls, 1);
  });
  test('missing rank files may use provider without replacing local traits',
      () async {
    final client = MockClient((r) async => local(r)
        ? http.Response(
            '{"ranksAvailable":false,"items":[{"tokenId":"41","attributes":[{"trait_type":"Eyes","value":"Green"}],"rarityRank":null}]}',
            200)
        : http.Response('{"items":[{"tokenId":"41","rarityRank":100}]}', 200));
    final row =
        (await Krc721Reads(client).metadata('KASZOMBIES', ['41'])).single;
    expect(row['rarityRank'], 100);
    expect(row['attributes'], hasLength(1));
  });
  test(
      'optional metadata outage does not hide assets or marketplace owned NFTs',
      () async {
    final client = MockClient((r) async {
      if (local(r) && r.url.path.contains('/address/')) {
        return http.Response(
            '{"result":[{"tick":"KASZOMBIES","tokenId":"41","owner":"$owner","status":{"state":"unlisted"}}],"next":null}',
            200);
      }
      return http.Response('{}', 503);
    });
    final page =
        await KaspaApi(client: client).loadNftCollection(owner, 'KASZOMBIES');
    expect(page.nfts.single.tokenId, '41');
    expect(page.nfts.single.rarityRank, null);
    expect(page.nfts.single.imageUrl, Krc721Reads.image('KASZOMBIES', '41'));
    final market = NftMarketService(client: client);
    expect((await market.owned(owner))['items'], hasLength(1));
    market.close();
  });
  test('assets and My NFTs read the same local rarity', () async {
    final client = MockClient((r) async {
      if (!local(r)) {
        throw StateError('Unnecessary provider request');
      }
      return http.Response(
          jsonEncode(r.url.path.contains('/metadata/')
              ? {
                  'ranksAvailable': true,
                  'items': [
                    {'tokenId': '41', 'rarityRank': 100}
                  ]
                }
              : {
                  'result': [
                    {'tick': 'KASZOMBIES', 'tokenId': '41'}
                  ],
                  'next': null
                }),
          200);
    });
    expect(
        (await KaspaApi(client: client).loadNftCollection(owner, 'KASZOMBIES'))
            .nfts
            .single
            .rarityRank,
        100);
    final market = NftMarketService(client: client);
    expect(((await market.owned(owner))['items'] as List).single['rarityRank'],
        100);
    market.close();
  });
  test('transaction ownership preflight is exclusively official', () async {
    var calls = 0;
    final client = MockClient((r) async {
      calls++;
      expect(r.url.host, 'krc721-indexer.kaspa.com');
      return http.Response(
          '{"result":{"owner":"$owner","status":{"state":"unlisted"}}}', 200);
    });
    await requireOfficialNftOwner(client, owner, 'KASZOMBIES', '41');
    expect(calls, 1);
    final offline = MockClient((r) async {
      expect(r.url.host, 'krc721-indexer.kaspa.com');
      return http.Response('{}', 503);
    });
    await expectLater(
        requireOfficialNftOwner(offline, owner, 'KASZOMBIES', '41'),
        throwsStateError);
  });
  test('image fallback accepts only the fixed local NFT image route', () {
    expect(Krc721Image.fallback(Krc721Reads.image('KASZOMBIES', '41')),
        'https://krc721-cache.kaspa.com/krc721/mainnet/optimized/kaszombies/41');
    expect(Krc721Image.fallback('https://evil.invalid/images/KASZOMBIES/41'),
        null);
    expect(
        Krc721Image.fallback('https://kaspire.kaslab.space/api/admin'), null);
  });
  test(
      'healthy empty local NFT ownership cannot be overwritten by stale aggregator data',
      () async {
    var official = 0;
    final client = MockClient((r) async {
      if (local(r) && r.url.path.contains('/address/')) {
        return http.Response('{"result":[],"next":null}', 200);
      }
      if (r.url.host == 'krc721-indexer.kaspa.com') {
        official++;
        return http.Response('{}', 503);
      }
      if (r.url.host == 'kaspatoken.kaslab.space') {
        return http.Response(
            '{"data":{"krc721_tokens":[{"symbol":"STALE","balance":1,"decimals":0}]}}',
            200);
      }
      if (r.url.path.endsWith('/balance')) {
        return http.Response('{"balance":0}', 200);
      }
      if (r.url.path.endsWith('/utxos')) return http.Response('[]', 200);
      if (r.url.path.endsWith('/info/price')) {
        return http.Response('{"price":0}', 200);
      }
      return http.Response('{}', 503);
    });
    final wallet = await KaspaApi(client: client)
        .loadWallet(owner, includeNativeTransactions: false);
    expect(wallet.krc721Collections, isEmpty);
    expect(official, 0);
  });
}
