import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/screens/dotk_market_screen.dart';
import 'package:kasvault_wallet/src/services/dotk_market_service.dart';
import 'package:kasvault_wallet/src/services/dotk_service.dart';

class MarketFixture extends DotkMarketService {
  final names = Completer<List<DotkName>>();
  final checked = <String>[];
  final proof = Completer<DotkOfferStatus>();
  @override
  Future<List<DotkName>> namesOf(String address) => names.future;
  @override
  Future<List<DotkOffer>> saved([String? seller]) async => [];
  @override
  Future<List<DotkOffer>> search(String query) async => List.generate(
      30,
      (i) => DotkOffer(terms: {
            'name': 'name${i.toString().padLeft(2, '0')}',
            'seller': 'other',
            'priceSompi': (i + 10) * 100000000
          }, listingTxId: i.toString().padLeft(64, '0'), saleId: 'a' * 64));
  @override
  Future<DotkOfferStatus> status(DotkOffer offer) {
    checked.add(offer.name);
    return proof.future;
  }
}

void main() {
  testWidgets(
      'Browse appears while holdings and proofs are blocked; search reaches later pages',
      (tester) async {
    final service = MarketFixture();
    await tester.pumpWidget(MaterialApp(
        home: DotkMarketScreen(address: 'buyer', service: service)));
    await tester.pump();
    await tester.pump();
    expect(find.text('name00.k'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(service.checked.length, 2);
    expect(service.names.isCompleted, false);
    expect(service.proof.isCompleted, false);
    await tester.enterText(find.byType(TextField), 'name29');
    await tester.pump();
    expect(find.text('name29.k'), findsOneWidget);
    expect(find.text('name00.k'), findsNothing);
    service.proof.complete(const DotkOfferStatus(DotkOfferState.active));
    await tester.pump();
    await tester.pump();
    expect(service.checked, contains('name29.k'));
    expect(service.checked.length, 3);
    await tester.pumpWidget(const SizedBox());
    service.names.complete([]);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('only first twelve offers are checked until Load more',
      (tester) async {
    final service = MarketFixture();
    service.proof.complete(const DotkOfferStatus(DotkOfferState.active));
    await tester.pumpWidget(MaterialApp(
        home: DotkMarketScreen(address: 'buyer', service: service)));
    for (var i = 0; i < 20; i++) {
      await tester.pump();
    }
    expect(service.checked.length, 12);
    await tester.scrollUntilVisible(find.text('Load more'), 600,
        scrollable: find.byType(Scrollable).first, maxScrolls: 40);
    await tester.tap(find.text('Load more'));
    for (var i = 0; i < 20; i++) {
      await tester.pump();
    }
    expect(service.checked.length, 24);
    await tester.pumpWidget(const SizedBox());
    service.names.complete([]);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
