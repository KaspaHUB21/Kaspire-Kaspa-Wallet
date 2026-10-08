import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/screens/nexus_screen.dart';
import 'package:kasvault_wallet/src/services/nexus_service.dart';

class FakeNexus extends NexusService {
  FakeNexus() : super('kaspa:test');
  final calls = <Map<String, Object?>>[];
  @override
  bool get connected => true;
  @override
  Future<bool> connect([BuildContext? context]) async => true;
  @override
  Future<Object?> request(String path,
      {Map<String, String> query = const {},
      Map<String, Object?>? body,
      bool private = false}) async {
    calls.add({'path': path, 'query': query, 'body': body});
    if (path.startsWith('nft/')) {
      return {
        'tokenId': '12',
        'collectionId': 'hash',
        'currentOwnerWallet': 'kaspa:owner',
        'listingStatus': 'LISTED',
        'listingPriceSompi': null,
        'rarityRank': 1,
        'bestOffers': []
      };
    }
    if (path == 'offers') return {'id': 'created'};
    if (path == 'search') return {'kind': 'collection', 'collectionId': 'hash'};
    if (path.startsWith('collection/')) {
      return {'tokens': [], 'totalCount': 0, 'catalog': [], 'nextOffset': null};
    }
    if (path == 'dashboard/received') {
      return [
        {
          'id': 'ctestoffer0123456789',
          'nftCache': {'collectionId': 'hash', 'tokenId': '12'},
          'currentAmountSompi': '120000000',
          'status': 'OPEN',
          'expiresAt':
              DateTime.now().add(const Duration(days: 1)).toIso8601String(),
          'revisions': []
        }
      ];
    }
    return [];
  }
}

void main() {
  testWidgets('Nexus home uses the requested intro and native search',
      (tester) async {
    final fake = FakeNexus();
    await tester.pumpWidget(
        MaterialApp(home: NexusScreen(address: 'kaspa:test', service: fake)));
    expect(find.text(nexusIntro), findsOneWidget);
    expect(find.text('Browse active offers'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'HASH');
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    expect(fake.calls.first['query'], {'q': 'HASH'});
    expect(fake.calls.last['path'], 'collection/hash');
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'NFT detail keeps foreign listing price hidden; offer defaults to 30 days',
      (tester) async {
    final fake = FakeNexus();
    await tester.pumpWidget(MaterialApp(
        home: NexusScreen(
            address: 'kaspa:test',
            initialView: 'nft',
            collectionId: 'hash',
            tokenId: '12',
            service: fake)));
    await tester.pumpAndSettle();
    expect(find.text('Current listing status: LISTED'), findsOneWidget);
    expect(find.textContaining('Kaspire listing price:'), findsNothing);
    await tester.scrollUntilVisible(find.text('Make private offer'), 400);
    await tester
        .ensureVisible(find.widgetWithText(FilledButton, 'Make private offer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make private offer'));
    await tester.pumpAndSettle();
    expect(find.text('30 days'), findsOneWidget);
    expect(
        find.text(
            'Your offer is private and non-binding. No funds are locked.'),
        findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Submit'))
            .onPressed,
        isNull);
    await tester.enterText(find.byType(TextField), '1.25');
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Submit'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(fake.calls.last['path'], 'offers');
    expect(fake.calls.last['body'], {
      'amountKas': '1.25',
      'durationDays': 30,
      'acknowledgedNonBinding': true,
      'collectionId': 'hash',
      'tokenId': '12'
    });
    expect(find.text('Offer created successfully'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'agree to relist changes the offer only and requires confirmation',
      (tester) async {
    final fake = FakeNexus();
    await tester.pumpWidget(MaterialApp(
        home: NexusScreen(
            address: 'kaspa:test', initialView: 'dashboard', service: fake)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Agree to relist'), 300);
    await tester.tap(find.text('Agree to relist'));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'This changes only your non-binding offer. No funds are locked or spent.'),
        findsOneWidget);
    expect(fake.calls.where((c) => c['body'] != null), isEmpty);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(
        fake.calls.any(
            (c) => c['path'] == 'offers/ctestoffer0123456789/agree-to-relist'),
        isTrue);
    expect(tester.takeException(), isNull);
  });
}
