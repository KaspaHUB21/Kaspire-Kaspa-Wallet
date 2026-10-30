import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/screens/nexus_screen.dart';
import 'package:kasvault_wallet/src/services/nexus_service.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';

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

class FakeKaspaComNexus extends FakeNexus {
  @override
  Future<Object?> request(String path,
      {Map<String, String> query = const {},
      Map<String, Object?>? body,
      bool private = false}) async {
    if (path.startsWith('nft/')) {
      return {
        'tokenId': '12',
        'collectionId': 'hash',
        'currentOwnerWallet': 'kaspa:owner',
        'listingStatus': 'LISTED',
        'listingPriceSompi': '125000000',
        'kaspacomListing': {
          'source': 'kaspacom',
          'ticker': 'HASH',
          'orderId': 'bbbbbbbbbbbbbbbbbbbbbbbb',
          'tokenId': '12'
        },
        'attributes': [],
        'bestOffers': []
      };
    }
    return super.request(path, query: query, body: body, private: private);
  }
}

class LoginNexus extends FakeNexus {
  bool loggedIn = false;
  Object? failure;
  bool allow = true;
  Completer<bool>? pending;
  int attempts = 0;
  @override
  bool get connected => loggedIn;
  @override
  Future<bool> connect([BuildContext? context]) async {
    attempts++;
    if (failure != null) throw failure!;
    loggedIn = pending == null ? allow : await pending!.future;
    return loggedIn;
  }
}

Future<void> openOffer(WidgetTester tester, NexusService service) async {
  await tester.pumpWidget(MaterialApp(
      home: NexusScreen(
          address: 'kaspa:test',
          initialView: 'nft',
          collectionId: 'hash',
          tokenId: '12',
          service: service)));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(find.text('Make private offer'), 300);
  await tester.ensureVisible(find.text('Make private offer'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Make private offer'));
}

void main() {
  for (final theme in KaspireTheme.values) {
    testWidgets('Nexus offer dialog fits a narrow display with $theme',
        (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: NexusScreen(
              address: 'kaspa:test',
              initialView: 'nft',
              collectionId: 'hash',
              tokenId: '12',
              service: FakeNexus())));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Make private offer'), 200);
      await tester.ensureVisible(find.text('Make private offer'));
      await tester.tap(find.text('Make private offer'));
      await tester.pumpAndSettle();
      expect(find.text('30 days'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Submit'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets('offer login failure is visible at the button and retry works',
      (tester) async {
    final fake = LoginNexus()
      ..failure =
          StateError('Nexus login temporarily unavailable. Please try again.');
    await openOffer(tester, fake);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('Nexus login temporarily unavailable.'),
        findsWidgets);
    expect(fake.calls.where((c) => c['body'] != null), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    fake.failure = null;
    await tester.ensureVisible(find.text('Make private offer'));
    await tester.tap(find.text('Make private offer'));
    await tester.pumpAndSettle();
    expect(find.text('30 days'), findsOneWidget);
    expect(fake.attempts, 2);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Make private offer'))
            .onPressed,
        isNotNull);
  });
  testWidgets('locked offer login does not silently abandon the action',
      (tester) async {
    final fake = LoginNexus()..allow = false;
    await openOffer(tester, fake);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('Unlock Kaspire to connect'), findsWidgets);
    expect(find.text('Submit'), findsNothing);
    expect(fake.calls.where((c) => c['body'] != null), isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'slow authentication shows progress and prevents duplicate offers',
      (tester) async {
    final fake = LoginNexus()..pending = Completer<bool>();
    await openOffer(tester, fake);
    await tester.pump();
    expect(find.text('Connecting to Nexus Offers…'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(
                FilledButton, 'Connecting to Nexus Offers…'))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == 'My offers'))
            .onPressed,
        isNull);
    expect(fake.attempts, 1);
    fake.pending!.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('30 days'), findsOneWidget);
    expect(fake.calls.where((c) => c['body'] != null), isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'My offers reports login failure without showing a false empty list',
      (tester) async {
    final fake = LoginNexus()
      ..failure = StateError('Kaspire login unavailable. Try again.');
    await tester.pumpWidget(MaterialApp(
        home: NexusScreen(
            address: 'kaspa:test', initialView: 'dashboard', service: fake)));
    await tester.pumpAndSettle();
    expect(find.text('Kaspire login unavailable. Try again.'), findsOneWidget);
    expect(find.text('No results found.'), findsNothing);
    fake.failure = null;
    await tester.tap(find.byTooltip('Reload'));
    await tester.pumpAndSettle();
    expect(fake.calls.any((c) => c['path'] == 'dashboard/received'), isTrue);
    expect(fake.attempts, 2);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'verified KaspaCom listing has its own price and marketplace action',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: NexusScreen(
            address: 'kaspa:test',
            initialView: 'nft',
            collectionId: 'hash',
            tokenId: '12',
            service: FakeKaspaComNexus())));
    await tester.pumpAndSettle();
    expect(find.text('KaspaCom listing price: 1.25 KAS'), findsOneWidget);
    expect(find.text('Open KaspaCom listing'), findsOneWidget);
    expect(find.text('Open Kaspire listing'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
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
