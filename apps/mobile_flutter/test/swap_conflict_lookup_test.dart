import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/swap_conflict_lookup.dart';

String id(int n) => n.toRadixString(16).padLeft(64, '0');
Map input(int n, {int index = 0}) => {
      'previousOutpoint': {'transactionId': id(n), 'index': index}
    };
Map rival(int origin, {int index = 0, bool accepted = true}) => {
      'transaction_id': id(9999),
      'is_accepted': accepted,
      'inputs': [
        {
          'previous_outpoint_hash': id(origin),
          'previous_outpoint_index': '$index'
        }
      ]
    };
Future<String?> find(List<Map> inputs, Future<Object?> Function(String) read) =>
    findConfirmedSwapConflict(
        tx: {'inputs': inputs},
        savedIds: {id(9000)},
        node: 'https://node.invalid',
        prefix: 'kaspa:',
        read: read);

void main() {
  test(
      'Finds a confirmed conflict after 50 transactions at the fourth input address',
      () async {
    final offsets = <int>[];
    final result =
        await find(List.generate(4, (i) => input(i + 1)), (url) async {
      final u = Uri.parse(url);
      if (u.path.endsWith('/${id(9999)}')) return rival(4);
      if (u.path.contains('/transactions/')) {
        final n = int.parse(u.pathSegments.last, radix: 16);
        return {
          'transaction_id': id(n),
          'is_accepted': true,
          'outputs': [
            {'index': 0, 'script_public_key_address': 'kaspa:q$n'}
          ]
        };
      }
      if (!u.path.contains('kaspa%3Aq4') &&
          !Uri.decodeComponent(u.path).contains('kaspa:q4')) return [];
      final offset = int.parse(u.queryParameters['offset']!);
      offsets.add(offset);
      if (offset == 0)
        return List.generate(
            50, (i) => {'transaction_id': id(100 + i), 'inputs': []});
      return [rival(4)];
    });
    expect(result, id(9999));
    expect(offsets, [0, 50]);
  });
  test(
      'Every outpoint sharing one origin address is checked, not just the first',
      () async {
    var historyReads = 0;
    final result = await find([input(1), input(1, index: 1)], (url) async {
      if (url.endsWith('/${id(9999)}')) return rival(1, index: 1);
      if (url.contains('/full-transactions')) {
        historyReads++;
        return [rival(1, index: 1)];
      }
      return {
        'transaction_id': id(1),
        'is_accepted': true,
        'outputs': [
          for (var i = 0; i < 2; i++)
            {'index': i, 'script_public_key_address': 'kaspa:qpool'}
        ]
      };
    });
    expect(result, id(9999));
    expect(historyReads, 1);
  });
  for (final accepted in [false, true]) {
    test(
        'Wrong exact outpoint or unaccepted spender never proves obsolescence ($accepted)',
        () async {
      expect(
          await find([input(1)], (url) async {
            if (url.contains('/full-transactions'))
              return [rival(1, index: accepted ? 1 : 0, accepted: accepted)];
            if (url.endsWith('/${id(9999)}')) return rival(1, accepted: false);
            return {
              'transaction_id': id(1),
              'is_accepted': true,
              'outputs': [
                {'index': 0, 'script_public_key_address': 'kaspa:qpool'}
              ]
            };
          }),
          isNull);
    });
  }
  test(
      'Repeated pages and missing origins explicitly report unable to determine',
      () async {
    for (final missing in [false, true]) {
      await expectLater(
          find([input(1)], (url) async {
            if (missing) return null;
            if (url.contains('/full-transactions'))
              return List.generate(
                  50, (i) => {'transaction_id': id(i + 100), 'inputs': []});
            return {
              'transaction_id': id(1),
              'is_accepted': true,
              'outputs': [
                {'index': 0, 'script_public_key_address': 'kaspa:qpool'}
              ]
            };
          }),
          throwsA(isA<SwapConflictUnknown>()));
    }
  });
  test('Rate limits remain errors, never empty history or proof', () async {
    await expectLater(find([input(1)], (_) async => throw StateError('429')),
        throwsStateError);
  });
}
