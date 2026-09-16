import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kasvault_wallet/src/services/dotk_market_service.dart';
import 'package:kasvault_wallet/src/services/dotk_service.dart';

Map<String, Object?> offer(int id, {String name = 'market'}) => {
      'terms': {
        'name': name,
        'seller': 'kaspa:test',
        'feeAddress': 'kaspa:fee',
        'priceSompi': 1000000000
      },
      'listingTxId': id.toRadixString(16).padLeft(64, '0'),
      'saleId': 'a' * 64,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('own listings group active first and newest first within groups', () {
    final rows = List.generate(6, (i) => DotkOffer.fromJson(offer(i + 1)));
    final states = {
      rows[0].listingTxId: const DotkOfferStatus(DotkOfferState.active),
      rows[1].listingTxId: const DotkOfferStatus(DotkOfferState.sold),
      rows[2].listingTxId: const DotkOfferStatus(DotkOfferState.cancelled),
      rows[3].listingTxId: const DotkOfferStatus(DotkOfferState.active),
      rows[4].listingTxId: const DotkOfferStatus(DotkOfferState.pending),
    };
    expect(sortMyMarketOffers(rows, states),
        [rows[3], rows[0], rows[5], rows[4], rows[2], rows[1]]);
    expect(rows.first.listingTxId, DotkOffer.fromJson(offer(1)).listingTxId);
  });
  test('browse sorts exact sompi prices both ways without modifying input', () {
    final rows = [
      DotkOffer.fromJson(offer(1, name: 'z')),
      DotkOffer.fromJson(offer(2, name: 'a')),
      DotkOffer.fromJson(offer(3, name: 'b')),
    ];
    rows[2].terms['priceSompi'] = 1000000001;
    expect(sortMarketOffers(rows), [rows[1], rows[0], rows[2]]);
    expect(
        sortMarketOffers(rows, descending: true), [rows[2], rows[1], rows[0]]);
    expect(rows.first.name, 'z.k');
  });
  test('recovery metadata persists and deduplicates by signed listing ID',
      () async {
    final service = DotkMarketService();
    await service.save(DotkOffer.fromJson(offer(1)));
    await service.save(DotkOffer.fromJson(offer(1)));
    await service.save(DotkOffer.fromJson(offer(2)));
    expect((await service.saved('kaspa:test')).length, 2);
    expect(await service.saved('kaspa:other'), isEmpty);
    service.close();
  });
  test('directory search loads subsequent pages', () async {
    final offsets = <String>[];
    final service = DotkMarketService(client: MockClient((request) async {
      offsets.add(request.url.queryParameters['offset']!);
      return http.Response(
          jsonEncode({
            'offers': [offer(offsets.length)],
            'nextOffset': offsets.length == 1 ? 50 : null
          }),
          200);
    }));
    expect((await service.search('market')).length, 2);
    expect(offsets, ['0', '50']);
    service.close();
  });
  test('directory cannot loop pagination backwards', () async {
    final service = DotkMarketService(
        client: MockClient((_) async =>
            http.Response(jsonEncode({'offers': [], 'nextOffset': 0}), 200)));
    await expectLater(service.search(''), throwsFormatException);
    service.close();
  });
  test('malformed listing IDs and names are rejected', () {
    expect(
        () => DotkOffer.fromJson({...offer(1), 'listingTxId': '../anything'}),
        throwsFormatException);
    expect(
        () => DotkOffer.fromJson(offer(1, name: '../bad')), throwsA(anything));
  });
  test('failed publication preserves local recovery data', () async {
    final service = DotkMarketService(
        client: MockClient((_) async => http.Response('{}', 503)));
    final row = DotkOffer.fromJson(offer(1));
    await service.save(row);
    await expectLater(service.publish(row), throwsStateError);
    expect((await service.saved()).single.listingTxId, row.listingTxId);
    service.close();
  });
  Map<String, Object?> completed(bool sold) => {
        'transaction_id': 'b' * 64,
        'is_accepted': true,
        'inputs': [
          {
            'previous_outpoint_hash': '1'.padLeft(64, '0'),
            'previous_outpoint_index': '0'
          },
          {
            'previous_outpoint_hash': '1'.padLeft(64, '0'),
            'previous_outpoint_index': '1'
          },
        ],
        'outputs': [
          {
            'index': 0,
            'amount': 100000000,
            'covenant_id': DotkService.registry,
            'script_public_key': sold ? 'buyer-deed' : 'seller-deed'
          },
          {
            'index': 1,
            'amount': sold ? 1079000000 : 100000000,
            'script_public_key_address': 'kaspa:test',
            'covenant_id': null
          },
          if (sold)
            {
              'index': 2,
              'amount': 21000000,
              'script_public_key_address': 'kaspa:fee',
              'covenant_id': null
            },
        ],
      };
  test('sold and cancelled require accepted spend and exact payout evidence',
      () {
    final row = DotkOffer.fromJson(offer(1));
    expect(
        DotkMarketService.completionStatus(row, completed(true), 'seller-deed')!
            .state,
        DotkOfferState.sold);
    expect(
        DotkMarketService.completionStatus(
                row, completed(false), 'seller-deed')!
            .state,
        DotkOfferState.cancelled);
    expect(
        DotkMarketService.completionStatus(
            row, {...completed(true), 'is_accepted': false}, 'seller-deed'),
        isNull);
    expect(
        DotkMarketService.completionStatus(
            row, {...completed(true), 'inputs': []}, 'seller-deed'),
        isNull);
    expect(
        DotkMarketService.completionStatus(row, completed(false), 'wrong-deed'),
        isNull);
    final changed = completed(true);
    ((changed['outputs'] as List)[2] as Map)['amount'] = 1;
    expect(DotkMarketService.completionStatus(row, changed, 'seller-deed'),
        isNull);
  });
  test('spent listings classify from history instead of remaining cancellable',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('space.kasvault/security'),
            (call) async => jsonEncode({
                  'deed': {
                    'deedAddress': 'kaspa:deed',
                    'scriptPublicKey': 'seller-deed'
                  },
                  'saleAddress': 'kaspa:sale',
                  'saleScriptPublicKey': 'sale-script',
                }));
    for (final sold in [false, true]) {
      final service = DotkMarketService(client: MockClient((request) async {
        final p = request.url.path;
        if (p.endsWith('/utxos')) return http.Response('[]', 200);
        if (p.endsWith('/key')) {
          return http.Response(
              jsonEncode({
                'key': 'c' * 64,
                'registryCovenantId': DotkService.registry
              }),
              200);
        }
        if (p.endsWith('/history')) {
          return http.Response(
              jsonEncode({
                'registryCovenantId': DotkService.registry,
                'entries': [
                  {'txid': 'b' * 64}
                ],
                'complete': true
              }),
              200);
        }
        if (p.endsWith('b' * 64)) {
          return http.Response(jsonEncode(completed(sold)), 200);
        }
        return http.Response('{}', 503);
      }));
      expect((await service.status(DotkOffer.fromJson(offer(1)))).state,
          sold ? DotkOfferState.sold : DotkOfferState.cancelled);
      service.close();
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('space.kasvault/security'), null);
  });
  test('node errors never imply sold or cancelled', () async {
    final service = DotkMarketService(
        client: MockClient((_) async => http.Response('{}', 503)));
    expect((await service.status(DotkOffer.fromJson(offer(1)))).state,
        DotkOfferState.unavailable);
    service.close();
  });
}
