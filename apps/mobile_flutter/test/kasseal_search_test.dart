import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/screens/kasseal_screen.dart';
import 'package:kasvault_wallet/src/services/kasseal_service.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';

final unnachodId =
    'ffc20f9076918a7703619afec525c292287da8d29c15c5a0039785e4d89028d6';
Map<String, dynamic> token(String id, String ticker) => {
      'meta': {'covenantId': id, 'ticker': ticker, 'name': ticker},
      'verification': 'verified',
      'phase': 'bonding'
    };

class SearchService extends KassealService {
  final calls = <(String, String?)>[];
  final delayed = <String, Completer<Map<String, dynamic>>>{};
  Completer<Map<String, dynamic>>? firstPage;
  int browseCalls = 0;
  @override
  Future<Map<String, dynamic>> tokens([String? cursor]) async {
    browseCalls++;
    return firstPage == null
        ? {
            'tokens': [token('a' * 64, 'TOP20')],
            'nextCursor': 'browse-page-2'
          }
        : firstPage!.future;
  }

  @override
  Future<Map<String, dynamic>> searchTokens(String query,
      [String? cursor]) async {
    calls.add((query, cursor));
    if (delayed.containsKey(query)) return delayed[query]!.future;
    return {
      'tokens': cursor == null
          ? [token(unnachodId, 'UNNACHOD')]
          : [token(unnachodId, 'UNNACHOD'), token('b' * 64, 'NEXTMATCH')],
      'nextCursor':
          cursor == null && query != unnachodId ? 'query-page-2' : null
    };
  }

  @override
  Future<List<Map<String, dynamic>>> history(String address) async => [];
  @override
  Future<BigInt> kasBalance(String address) async => BigInt.zero;
  @override
  Future<Map<String, dynamic>?> pending(String address) async => null;
  @override
  Future<Map<String, dynamic>> wallet(String address) async => {'holdings': []};
}

void main() {
  setUp(() => NetworkSettings.network.value = KaspaNetwork.tn10);
  Future<void> open(WidgetTester tester, SearchService service,
      {String? id}) async {
    await tester.pumpWidget(MaterialApp(
        home: KassealScreen(
            address: 'kaspatest:qfixture', service: service, tokenId: id)));
    await tester.pump();
  }

  Future<void> search(WidgetTester tester, String value) async {
    await tester.enterText(find.byType(TextField).first, value);
    await tester.pump(const Duration(milliseconds: 351));
    await tester.pump();
  }

  testWidgets(
      'UNNACHOD is found globally outside the first page, pages retain the query, clear resets browsing',
      (tester) async {
    final service = SearchService();
    await open(tester, service);
    await tester.pumpAndSettle();
    expect(find.text('TOP20'), findsOneWidget);
    expect(find.text('UNNACHOD'), findsNothing);
    await search(tester, 'unnachod');
    await tester.pumpAndSettle();
    expect(service.calls, contains(('unnachod', null)));
    expect(find.text('UNNACHOD'), findsOneWidget);
    expect(find.text('TOP20'), findsNothing);
    await tester.ensureVisible(find.text('Load more'));
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    expect(service.calls.last, ('unnachod', 'query-page-2'));
    expect(find.text('UNNACHOD'), findsOneWidget);
    expect(find.text('NEXTMATCH'), findsOneWidget);
    expect(find.text('Load more'), findsNothing);
    await tester.ensureVisible(find.byTooltip('Clear search'));
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pump(const Duration(milliseconds: 351));
    await tester.pumpAndSettle();
    expect(find.text('TOP20'), findsOneWidget);
    expect(find.text('UNNACHOD'), findsNothing);
    expect(service.browseCalls, 2);
  });
  for (final fail in [false, true]) {
    testWidgets(
        'Late ${fail ? 'errors' : 'results'} cannot overwrite the latest query',
        (tester) async {
      final service = SearchService(), old = Completer<Map<String, dynamic>>();
      service.delayed['old'] = old;
      await open(tester, service);
      await tester.pumpAndSettle();
      await search(tester, 'old');
      await search(tester, 'unnachod');
      await tester.pumpAndSettle();
      if (fail) {
        old.completeError(StateError('STALE ERROR'));
      } else {
        old.complete({
          'tokens': [token('c' * 64, 'STALE TOKEN')],
          'nextCursor': null
        });
      }
      await tester.pumpAndSettle();
      expect(find.text('UNNACHOD'), findsOneWidget);
      expect(find.text('STALE TOKEN'), findsNothing);
      expect(find.textContaining('STALE ERROR'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('Typing during first-page loading does not lose the search',
      (tester) async {
    final service = SearchService()
      ..firstPage = Completer<Map<String, dynamic>>();
    await open(tester, service);
    await search(tester, 'unnachod');
    await tester.pumpAndSettle();
    service.firstPage!.complete({
      'tokens': [token('a' * 64, 'TOP20')],
      'nextCursor': 'old-page'
    });
    await tester.pumpAndSettle();
    expect(find.text('UNNACHOD'), findsOneWidget);
    expect(find.text('TOP20'), findsNothing);
  });
  testWidgets(
      'Opening a held token outside the first page resolves its exact covenant ID',
      (tester) async {
    final service = SearchService();
    await open(tester, service, id: unnachodId);
    await tester.pumpAndSettle();
    expect(service.calls, contains((unnachodId, null)));
    expect(find.text('UNNACHOD · Kasseal'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.refresh).first);
    await tester.pumpAndSettle();
    expect(find.text('UNNACHOD · Kasseal'), findsNothing);
    expect(service.calls.where((c) => c.$1 == unnachodId).length, 1);
  });
}
