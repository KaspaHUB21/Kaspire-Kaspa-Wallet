import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/screens/braid_screen.dart';
import 'package:kasvault_wallet/src/services/braid_service.dart';
import 'package:kasvault_wallet/src/services/encrypted_store.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';

class _Memory implements EncryptedStore {
  final data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async {
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }
}

void main() {
  for (final mainnet in [true, false]) {
    test(
        'real ${mainnet ? 'Mainnet' : 'TN10'} notes method uses read-only merge-notes with exact owner and token',
        () async {
      NetworkSettings.network.value =
          mainnet ? KaspaNetwork.mainnet : KaspaNetwork.tn10;
      var calls = 0;
      late BraidService service;
      service = BraidService(client: MockClient((request) async {
        calls++;
        expect(request.method, 'GET');
        expect(request.url.toString().split('?').first,
            '${service.currentApi}/merge-notes');
        expect(request.url.queryParameters, {
          'userPk': BraidService.feeOwner,
          'token': BraidService.tokens[1].id
        });
        expect(request.body, isEmpty);
        return http.Response(
            jsonEncode({
              'net': service.net,
              'tokenId': BraidService.tokens[1].id,
              'notes': [
                {'amount': '29978'}
              ]
            }),
            200);
      }));
      final result =
          await service.notes(service.feeAddress, BraidService.tokens[1]);
      expect((result['notes'] as List).single['amount'], '29978');
      expect(calls, 1);
    });
  }

  test(
      'empty successful list is zero; malformed, wrong network/token and failed reads remain unavailable',
      () async {
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    final token = BraidService.tokens[1];
    for (final failure in [
      'none',
      'network',
      'token',
      'missing',
      'row',
      'amount',
      'http'
    ]) {
      final service = BraidService(
          client: MockClient((_) async => http.Response(
              jsonEncode({
                'net': failure == 'network' ? 'tn10' : 'mainnet',
                'tokenId': failure == 'token' ? '0' * 64 : token.id,
                if (failure != 'missing')
                  'notes': failure == 'row'
                      ? ['invalid']
                      : failure == 'amount'
                          ? [
                              {'amount': 'NaN'}
                            ]
                          : [],
                if (failure == 'http') 'error': 'Unavailable',
              }),
              failure == 'http' ? 503 : 200)));
      final future = service.notes(service.feeAddress, token);
      if (failure == 'none') {
        expect((await future)['notes'], isEmpty);
      } else {
        await expectLater(future, throwsStateError, reason: failure);
      }
    }
  });

  for (final failure in [false, true]) {
    testWidgets(
        'select token-to-token using production HTTP notes path, failure=$failure',
        (tester) async {
      NetworkSettings.network.value = KaspaNetwork.mainnet;
      var reads = 0;
      final service = BraidService(
          store: _Memory(),
          client: MockClient((request) async {
            reads++;
            expect(request.method, 'GET');
            expect(request.url.path, '/api/mainnet/router/merge-notes');
            expect(
                request.url.queryParameters['userPk'], BraidService.feeOwner);
            expect(request.url.queryParameters['token'],
                BraidService.tokens[1].id);
            return http.Response(
                jsonEncode(failure
                    ? {'error': 'Temporarily unavailable'}
                    : {
                        'net': 'mainnet',
                        'tokenId': BraidService.tokens[1].id,
                        'notes': [
                          {'amount': '29978'}
                        ]
                      }),
                failure ? 503 : 200);
          }));
      await tester.pumpWidget(MaterialApp(
          home: BraidScreen(address: service.feeAddress, service: service)));
      await tester.pumpAndSettle();
      expect(reads, 0, reason: 'KAS input has no token-note query');
      for (final (key, token) in [
        ('braid-select-to', BraidService.tokens[2]),
        ('braid-select-from', BraidService.tokens[1]),
      ]) {
        await tester.tap(find.byKey(Key(key)));
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byKey(const Key('braid-token-search')), token.symbol);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('braid-token-${token.id}')));
        await tester.pumpAndSettle();
      }
      expect(reads, 1);
      expect(find.textContaining('POST required'), findsNothing);
      await tester.scrollUntilVisible(
          find.textContaining(
              failure ? 'Token balance unavailable / loading' : '29.978 THEN'),
          100,
          scrollable: find
              .descendant(
                  of: find.byType(ListView).first,
                  matching: find.byType(Scrollable))
              .first);
      expect(
          find.textContaining(
              failure ? 'Token balance unavailable / loading' : '29.978 THEN'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      service.client.close();
    });
  }
}
