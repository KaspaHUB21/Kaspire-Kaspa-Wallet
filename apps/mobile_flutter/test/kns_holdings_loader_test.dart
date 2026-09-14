import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/kns_holdings_loader.dart';

Map<String, Object?> page(List<String> names,
        {Map<String, Object?>? pagination, bool outer = false}) =>
    {
      'data': {
        'assets': names.map((name) => {'asset': name}).toList(),
        if (!outer && pagination != null) 'pagination': pagination
      },
      if (outer && pagination != null) 'pagination': pagination,
    };

void main() {
  for (final outer in [false, true]) {
    test('follows short pages with explicit metadata (outer=$outer)', () async {
      final requested = <int>[];
      final result = await loadKnsHoldingsPages(fetchPage: (number) async {
        requested.add(number);
        return page(['domain$number.kas'],
            outer: outer, pagination: {'totalPages': 3});
      });
      expect(requested, [1, 2, 3]);
      expect(result.records, hasLength(3));
      expect(result.warning, isNull);
    });
  }

  test('without metadata short pages continue until empty', () async {
    final requested = <int>[];
    final result = await loadKnsHoldingsPages(fetchPage: (number) async {
      requested.add(number);
      return page(number <= 3 ? ['domain$number.kas'] : []);
    });
    expect(requested, [1, 2, 3, 4]);
    expect(result.records, hasLength(3));
    expect(result.warning, isNull);
  });

  test('honors hasMore and total item counts', () async {
    for (final mode in ['hasMore', 'total']) {
      final requested = <int>[];
      final result = await loadKnsHoldingsPages(fetchPage: (number) async {
        requested.add(number);
        return page(['d$number.kas'],
            pagination:
                mode == 'total' ? {'total': 2} : {'hasMore': number < 2});
      });
      expect(requested, [1, 2]);
      expect(result.warning, isNull);
    }
  });

  test('a later timeout preserves and publishes previously loaded names',
      () async {
    final progress = <int>[];
    final result = await loadKnsHoldingsPages(
        fetchPage: (number) async {
          if (number == 2) throw TimeoutException('fixture');
          return page(['one.kas'], pagination: {'totalPages': 2});
        },
        onProgress: (items) => progress.add(items.length));
    expect(progress, [1]);
    expect(result.records.single['asset'], 'one.kas');
    expect(result.warning, contains('KNS loading incomplete:'));
  });

  test('deduplicates overlapping pages', () async {
    final result = await loadKnsHoldingsPages(
        fetchPage: (number) async => page(
            number == 1 ? ['one.kas', 'two.kas'] : ['TWO.kas', 'three.kas'],
            pagination: {'totalPages': 2}));
    expect(result.records, hasLength(3));
    expect(result.warning, isNull);
  });

  test('repeated, missing and invalid pages never silently claim completion',
      () async {
    for (final kind in ['repeat', 'empty', 'invalid']) {
      final result = await loadKnsHoldingsPages(fetchPage: (number) async {
        if (number == 2 && kind == 'invalid') return {};
        return page(number == 2 && kind == 'empty' ? [] : ['one.kas'],
            pagination: {'totalPages': 4});
      });
      expect(result.records, hasLength(1));
      expect(result.warning, isNotNull);
    }
  });

  test('different asset IDs with the same display name remain separate',
      () async {
    final result = await loadKnsHoldingsPages(
        fetchPage: (_) async => {
              'assets': [
                {'asset': 'same.kas', 'assetId': 'first'},
                {'asset': 'same.kas', 'assetId': 'second'},
              ],
              'pagination': {'totalPages': 1},
            });
    expect(result.records, hasLength(2));
    expect(result.warning, isNull);
  });

  test('page limit returns loaded names with an explicit warning', () async {
    final result = await loadKnsHoldingsPages(
        maxPages: 2,
        fetchPage: (number) async =>
            page(['d$number.kas'], pagination: {'totalPages': 1000}));
    expect(result.records, hasLength(2));
    expect(result.warning, contains('safety limit'));
  });
}
