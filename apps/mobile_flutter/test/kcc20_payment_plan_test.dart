import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/kcc20_payment_plan.dart';

Map<String, Object?> fixture() => {
      'sender': 'wallet-A',
      'reviewHash': 'a' * 64,
      'nextStep': 0,
      'transactions': [
        for (var i = 0; i < 3; i++)
          {
            'transactionId': '${i + 1}' * 64,
            'signedTxJson': 'exact-$i',
            'operation': <String, Object?>{},
          }
      ]
    };

void main() {
  test(
      'entire signed chain is saved first, accepted parents precede children, every step checkpoints',
      () async {
    final events = <String>[], confirmed = <String>{};
    Map? saved;
    final plan = fixture();
    final result = await runKcc20PaymentPlan(
      plan,
      'wallet-A',
      save: (value) async {
        saved = jsonDecode(jsonEncode(value)) as Map;
        events.add('save:${value['nextStep']}');
      },
      accepted: (id) async => confirmed.contains(id),
      broadcast: (bytes, id) async {
        expect((saved!['transactions'] as List).length, 3);
        final n = saved!['nextStep'] as int;
        expect(bytes, 'exact-$n');
        if (n > 0) expect(confirmed.contains('$n' * 64), isTrue);
        events.add('send:$n');
        confirmed.add(id);
      },
      record: (_) async {},
      check: () {},
      pause: () async {},
    );
    expect(result['transactionId'], '3' * 64);
    expect(events,
        ['save:0', 'send:0', 'save:1', 'send:1', 'save:2', 'send:2', 'save:3']);
  });
  test(
      'restart after ambiguous submission checks existing transaction instead of creating another payment',
      () async {
    final confirmed = <String>{}, sent = <String>[];
    Map<String, Object?>? saved;
    Future<void> save(Map<String, Object?> p) async {
      saved = (jsonDecode(jsonEncode(p)) as Map).cast<String, Object?>();
    }

    await expectLater(
        runKcc20PaymentPlan(fixture(), 'wallet-A',
            save: save,
            accepted: (id) async => confirmed.contains(id),
            broadcast: (bytes, id) async {
              sent.add(bytes);
              if (bytes == 'exact-1') throw StateError('offline');
              confirmed.add(id);
            },
            record: (_) async {},
            check: () {},
            pause: () async {}),
        throwsStateError);
    expect(saved!['nextStep'], 1);
    confirmed.add('2' * 64);
    await runKcc20PaymentPlan(saved!, 'wallet-A',
        save: save,
        accepted: (id) async => confirmed.contains(id),
        broadcast: (bytes, id) async {
          sent.add(bytes);
          confirmed.add(id);
        },
        record: (_) async {},
        check: () {},
        pause: () async {});
    expect(sent, ['exact-0', 'exact-1', 'exact-2']);
    expect(saved!['nextStep'], 3);
  });
  test('failed journal write or wrong wallet never broadcasts', () async {
    var sends = 0;
    for (final address in ['wallet-A', 'wallet-B']) {
      await expectLater(
          runKcc20PaymentPlan(fixture(), address,
              save: (_) async {
                throw StateError('storage full');
              },
              accepted: (_) async => false,
              broadcast: (_, id) async {
                sends++;
              },
              record: (_) async {},
              check: () {}),
          throwsStateError);
    }
    expect(sends, 0);
  });
}
