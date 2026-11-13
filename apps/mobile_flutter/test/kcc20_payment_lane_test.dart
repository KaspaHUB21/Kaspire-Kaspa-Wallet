import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/kcc20_standard_service.dart';

void main() {
  http.Response envelope() => http.Response(
      jsonEncode({
        'meta': {
          'network': 'mainnet',
          'reference_commit': Kcc20StandardService.reference
        },
        'data': {}
      }),
      200);
  test('slow discovery/history does not hold up selected-token payment reads',
      () async {
    final started = Completer<void>(), release = Completer<void>();
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/background')) {
        started.complete();
        await release.future;
      }
      return envelope();
    });
    final normal = Kcc20StandardService(client), payment = normal.forPayment;
    expect(payment.paymentReads, true);
    expect(payment.forPayment, same(payment));
    final slow = normal.get('${normal.base}/tokens/background', priority: true);
    await started.future;
    try {
      await payment
          .get('${payment.base}/tokens/selected', priority: true)
          .timeout(const Duration(seconds: 2));
    } finally {
      release.complete();
      await slow;
      client.close();
    }
  });
  test('payment lane is shared, serialized and paced across service instances',
      () async {
    var active = 0, maxActive = 0;
    final calls = <DateTime>[];
    final client = MockClient((request) async {
      active++;
      if (active > maxActive) maxActive = active;
      calls.add(DateTime.now());
      await Future<void>.delayed(const Duration(milliseconds: 10));
      active--;
      return envelope();
    });
    final first = Kcc20StandardService(client).forPayment,
        second = Kcc20StandardService(client).forPayment;
    await Future.wait([
      first.get('${first.base}/tokens/one'),
      second.get('${second.base}/tokens/two')
    ]);
    expect(maxActive, 1);
    expect(calls[1].difference(calls[0]).inMilliseconds,
        greaterThanOrEqualTo(250));
    client.close();
  });
  test('cancelled payment reads never issue a new network request', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return envelope();
    });
    final payment = Kcc20StandardService(client).forPayment;
    await expectLater(
        payment.get('${payment.base}/tokens/selected', isCancelled: () => true),
        throwsStateError);
    expect(calls, 0);
    client.close();
  });
}
