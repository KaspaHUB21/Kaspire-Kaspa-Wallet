import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/marketplace_reads.dart';

void main() {
  MarketplaceReads reads(http.Client client) => MarketplaceReads(client,
      scheduler: MarketplaceReadScheduler(interval: Duration.zero),
      retryDelay: Duration.zero);

  test('transient rate limits and outages retry with a bound', () async {
    var calls = 0;
    final reader = reads(MockClient((_) async => http.Response(
        '{}', [429, 503, 200][calls++],
        headers: {'retry-after': '0'})));
    expect(await reader.get('https://example.test/a'), {});
    expect(calls, 3);
    calls = 0;
    final failed = reads(MockClient((_) async {
      calls++;
      return http.Response('{}', 429);
    }));
    await expectLater(failed.get('https://example.test/a'),
        throwsA(isA<MarketplaceReadUnavailable>()));
    expect(calls, 4);
  });

  test('permanent errors and invalid JSON are not retried', () async {
    for (final code in [404, 200]) {
      var calls = 0;
      final reader = reads(MockClient((_) async {
        calls++;
        return http.Response('invalid', code);
      }));
      await expectLater(
          reader.get('https://example.test/a'), throwsA(anything));
      expect(calls, 1);
    }
  });

  test('coalesces concurrent proofs but never caches a completed proof',
      () async {
    var calls = 0;
    final gate = Completer<void>();
    final reader = reads(MockClient((_) async {
      calls++;
      await gate.future;
      return http.Response('{}', 200);
    }));
    final first = reader.get('https://example.test/a');
    final second = reader.get('https://example.test/a');
    gate.complete();
    await Future.wait([first, second]);
    expect(calls, 1);
    await reader.get('https://example.test/a');
    expect(calls, 2);
  });

  test('scheduler bounds concurrency and recovers from failed work', () async {
    final scheduler = MarketplaceReadScheduler(interval: Duration.zero);
    var active = 0;
    var peak = 0;
    await Future.wait(List.generate(
        12,
        (_) => scheduler.run(() async {
              active++;
              if (active > peak) peak = active;
              await Future<void>.delayed(const Duration(milliseconds: 2));
              active--;
            })));
    expect(peak, 2);
    await expectLater(
        scheduler.run(() async => throw StateError('test')), throwsStateError);
    expect(await scheduler.run(() async => 42), 42);
  });

  test('closed reader cannot start queued requests', () async {
    var calls = 0;
    final reader = reads(MockClient((_) async {
      calls++;
      return http.Response('{}', 200);
    }));
    final pending = reader.get('https://example.test/a');
    reader.close();
    await expectLater(pending, throwsA(isA<MarketplaceReadUnavailable>()));
    expect(calls, 0);
  });
}
