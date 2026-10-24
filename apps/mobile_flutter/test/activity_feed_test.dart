import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/models/wallet_snapshot.dart';
import 'package:kasvault_wallet/src/services/activity_feed.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';

WalletTransaction tx(String id, {String kind = 'KAS'}) => WalletTransaction(
      id: id,
      timestamp: DateTime.utc(2026, 10, 24),
      amountSompi: 100000000,
      incoming: true,
      assetKind: kind,
      status: TransactionStatus.confirmed,
    );
Map<String, Object?> nativeRow(String id, String address) => {
      'transaction_id': id,
      'block_time': 1792843200000,
      'inputs': [],
      'outputs': [
        {'amount': 100000000, 'script_public_key_address': address}
      ],
    };
Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  test('newest 50 merged entries only; load more reveals next 50 and ends',
      () async {
    final feed = ActivityFeed();
    final rows = List.generate(
        121,
        (i) => WalletTransaction(
            id: '$i',
            timestamp: DateTime.utc(2026, 1, 1).add(Duration(seconds: i)),
            amountSompi: 1,
            incoming: true));
    await feed.reload({'KAS history': (_, __) async => rows});
    expect(feed.value.items, hasLength(50));
    expect(feed.value.items.first.id, '120');
    expect(feed.value.items.last.id, '71');
    expect(feed.value.hasMore, true);
    feed.showMore();
    expect(feed.value.items, hasLength(100));
    expect(feed.value.items.last.id, '21');
    expect(feed.value.hasMore, true);
    feed.showMore();
    expect(feed.value.items, hasLength(121));
    expect(feed.value.hasMore, false);
    feed.dispose();
  });
  test('native history fetches bounded backend pages beyond 100 entries',
      () async {
    final offsets = <int>[];
    final api = KaspaApi(
        baseUrl: 'https://own.invalid',
        client: MockClient((r) async {
          final size = int.parse(r.url.queryParameters['limit']!);
          final offset = int.parse(r.url.queryParameters['offset']!);
          offsets.add(offset);
          expect(size, lessThanOrEqualTo(100));
          return http.Response(
              jsonEncode(List.generate(
                  size, (i) => nativeRow('${offset + i}', 'kaspa:qone'))),
              200);
        }));
    final rows = await api
        .loadNativeTransactionsForAddresses(['kaspa:qone'], limit: 151);
    expect(offsets, [0, 100]);
    expect(rows, hasLength(151));
  });
  test('large KRC20 transfers parse canonically and stop at requested limit',
      () async {
    final queries = <String>[];
    final wallet =
        'kaspa:qqnvxvumjvzwmn755v8nrp4jxm2w50dv9mr2u4qrfqpq3h2hzyjx7tgkdtdgs';
    final api = KaspaApi(client: MockClient((r) async {
      queries.add(r.url.toString());
      final next = r.url.queryParameters['next'];
      return http.Response(
          jsonEncode({
            'result': List.generate(
                50,
                (i) => {
                      'tick': 'SOULS',
                      'amt': '2100000000000',
                      'dec': 8,
                      'from': wallet,
                      'to': wallet,
                      'mtsAdd':
                          DateTime.now().millisecondsSinceEpoch.toString(),
                      'hashRev': '${next ?? "first"}-$i',
                    }),
            'next': next == null ? 'page2' : 'page3'
          }),
          200);
    }));
    final rows = await api.loadKrc20Transactions(wallet, limit: 51);
    expect(rows, hasLength(51));
    expect(rows.first.displayAmount, '21000');
    expect(rows.first.amountLabel, '21,000 SOULS');
    expect(queries, hasLength(2));
    expect(
        queries.every((u) => u.startsWith('https://api.kasplex.org/')), true);
  });
  test('fresh native history wins over stale snapshot receipts', () async {
    final feed = ActivityFeed();
    final receipt = WalletTransaction(
        id: 'shared',
        timestamp: DateTime.utc(2026),
        amountSompi: 1,
        incoming: true,
        status: TransactionStatus.accepted);
    await feed.reload({
      'KAS history': (_, __) async => [tx('shared')]
    });
    await feed.reload({
      'Other asset history': (_, __) async => [receipt]
    });
    expect(feed.value.items.single.amountSompi, 100000000);
    expect(feed.value.items.single.status, TransactionStatus.confirmed);
    feed.dispose();
  });
  test('an older overlapping refresh cannot replace a newer history', () async {
    final feed = ActivityFeed();
    final old = Completer<List<WalletTransaction>>();
    final first = feed.reload({'KAS history': (_, __) => old.future});
    await feed.reload({
      'KAS history': (_, __) async => [tx('new')]
    });
    old.complete([tx('old')]);
    await first;
    expect(feed.value.items.single.id, 'new');
    expect(feed.value.loading, isEmpty);
    feed.dispose();
  });
  test('KAS and token history appear without waiting for asset discovery',
      () async {
    final feed = ActivityFeed();
    final assets = Completer<List<WalletTransaction>>();
    final loading = feed.reload({
      'Other asset history': (_, __) => assets.future,
      'KAS history': (_, __) async => [tx('kas')],
      'KRC20 history': (_, __) async => [tx('token', kind: 'KRC-20')],
    });
    await flush();
    expect(feed.value.items.map((t) => t.id), containsAll(['kas', 'token']));
    expect(feed.value.loading, {'Other asset history'});
    assets.complete([tx('nft', kind: 'KRC-721')]);
    await loading;
    expect(feed.value.items, hasLength(3));
    expect(feed.value.loading, isEmpty);
    feed.dispose();
  });
  test('failed KAS fetch is explicit, retains loaded KAS and allows retry',
      () async {
    final feed = ActivityFeed();
    await feed.reload({
      'KAS history': (_, __) async => [tx('kas')]
    });
    await feed.reload({
      'KAS history': (_, __) async => throw StateError('429'),
      'KRC20 history': (_, __) async => [tx('token', kind: 'KRC-20')],
    });
    expect(feed.value.items.map((t) => t.id), containsAll(['kas', 'token']));
    expect(feed.value.warnings.keys, contains('KAS history'));
    await feed.reload({
      'KAS history': (_, __) async => [tx('new')]
    });
    expect(feed.value.warnings, isEmpty);
    expect(feed.value.items.map((t) => t.id), containsAll(['new', 'token']));
    expect(feed.value.items.any((t) => t.id == 'kas'), false);
    feed.dispose();
  });
  test('timeouts end loading and ignore late callbacks and stale refreshes',
      () async {
    final feed = ActivityFeed(timeout: const Duration(milliseconds: 20));
    final slow = Completer<List<WalletTransaction>>();
    late void Function(List<WalletTransaction>) latePublish;
    await feed.reload({
      'KAS history': (publish, _) {
        latePublish = publish;
        return slow.future;
      }
    });
    expect(feed.value.loading, isEmpty);
    expect(feed.value.warnings, isNotEmpty);
    await feed.reload({
      'KAS history': (_, __) async => [tx('fresh')]
    });
    latePublish([tx('stale')]);
    slow.complete([tx('stale')]);
    await flush();
    expect(feed.value.items.single.id, 'fresh');
    feed.dispose();
  });
  test('local receipt changes do not restart native or indexer queries',
      () async {
    final feed = ActivityFeed();
    final native = Completer<List<WalletTransaction>>();
    final first = feed.reload({'KAS history': (_, __) => native.future});
    await feed.reload({
      'Saved activity': (_, __) async => [tx('local')]
    });
    expect(feed.value.loading, {'KAS history'});
    native.complete([tx('native')]);
    await first;
    expect(feed.value.items.map((t) => t.id), containsAll(['native', 'local']));
    feed.dispose();
  });
  test(
      'partial address results preserve cached entries and show incompleteness',
      () async {
    final feed = ActivityFeed();
    await feed.reload({
      'KAS history': (_, __) async => [tx('older-address')]
    });
    await feed.reload({
      'KAS history': (publish, warn) async {
        publish([tx('healthy-address')]);
        warn('Another address is unavailable.');
        return [tx('healthy-address')];
      }
    });
    expect(feed.value.items, hasLength(2));
    expect(feed.value.warnings, isNotEmpty);
    feed.dispose();
  });
  test('late asset enrichment appears after its original loading deadline',
      () async {
    final feed = ActivityFeed(timeout: const Duration(milliseconds: 20));
    final assets = Completer<List<WalletTransaction>>();
    await feed.reload({'Other asset history': (_, __) => assets.future});
    feed.seed('Other asset history', [tx('early-nft', kind: 'KRC-721')]);
    expect(feed.value.items.single.id, 'early-nft');
    await feed.reload({
      'Other asset history': (_, __) async => [tx('final-nft', kind: 'KRC-721')]
    });
    expect(feed.value.warnings, isEmpty);
    expect(feed.value.items.single.id, 'final-nft');
    assets.complete([]);
    await flush();
    expect(feed.value.items.single.id, 'final-nft');
    feed.dispose();
  });
  test('disposing with pending sources does not publish or throw later',
      () async {
    final feed = ActivityFeed();
    final source = Completer<List<WalletTransaction>>();
    final loading = feed.reload({'KAS history': (_, __) => source.future});
    feed.dispose();
    source.complete([tx('late')]);
    await loading;
  });

  test(
      'native history publishes healthy addresses before an unavailable address',
      () async {
    const a = 'kaspa:qhealthy', b = 'kaspa:qbroken';
    final broken = Completer<http.Response>();
    final warning = <String>[], progress = <List<WalletTransaction>>[];
    final api = KaspaApi(
        baseUrl: 'https://own.invalid',
        client: MockClient((r) async {
          if (r.url.path.contains('qbroken')) return broken.future;
          return http.Response(jsonEncode([nativeRow('native', a)]), 200);
        }));
    final loading = api.loadNativeTransactionsForAddresses([a, b],
        onProgress: progress.add, onWarning: warning.add);
    await flush();
    expect(progress.single.single.id, 'native');
    broken.complete(http.Response('{}', 503));
    final result = await loading;
    expect(result.single.id, 'native');
    expect(warning.single, contains('incomplete'));
  });
  test('an all-failed KAS lookup never masquerades as an empty history',
      () async {
    final api = KaspaApi(
        baseUrl: 'https://own.invalid',
        client: MockClient((r) async => http.Response('{}', 429)));
    expect(
        api.loadNativeTransactionsForAddresses(['kaspa:qone'],
            onWarning: (_) {}),
        throwsA(isA<KaspaApiException>()));
  });
  test('malformed primary history uses the independent fallback', () async {
    const address = 'kaspa:qwallet';
    final api = KaspaApi(
        baseUrl: 'https://own.invalid',
        client: MockClient((r) async {
          if (r.url.host == 'own.invalid') return http.Response('{}', 200);
          return http.Response(
              jsonEncode([nativeRow('fallback', address)]), 200);
        }));
    final result = await api.loadNativeTransactionsForAddresses([address]);
    expect(result.single.id, 'fallback');
  });
  test('native address concurrency is bounded and duplicates are removed',
      () async {
    var active = 0, maxActive = 0;
    final gates = <Completer<http.Response>>[];
    final api = KaspaApi(
        baseUrl: 'https://own.invalid',
        client: MockClient((r) async {
          active++;
          if (active > maxActive) maxActive = active;
          final gate = Completer<http.Response>();
          gates.add(gate);
          final response = await gate.future;
          active--;
          return response;
        }));
    final loading = api.loadNativeTransactionsForAddresses(
        List.generate(9, (i) => 'kaspa:q$i'));
    for (var round = 0; round < 3; round++) {
      await flush();
      for (final gate in gates.toList()) {
        if (!gate.isCompleted) {
          gate.complete(http.Response(
              jsonEncode([nativeRow('shared', 'kaspa:q0')]), 200));
        }
      }
    }
    final result = await loading;
    expect(maxActive, lessThanOrEqualTo(4));
    expect(result, hasLength(1));
    expect(gates, hasLength(9));
  });
}
