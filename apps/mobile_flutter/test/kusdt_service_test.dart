import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/kcc20_standard_service.dart';
import 'kcc20_standard_service_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  MockClient source(
      {bool foreign = false,
      int? decimals,
      int borrow = 0,
      bool extended = false,
      bool addressRoute = false}) {
    final original = fixture.source();
    addTearDown(original.close);
    return MockClient((request) async {
      final selectedId =
          foreign ? 'd' * 64 : Kcc20StandardService.kusdtCovenantId;
      final response = addressRoute && request.url.path.contains('/addresses/')
          ? http.Response(
              jsonEncode({
                'meta': fixture.meta,
                'address_context': {
                  'address': fixture.address,
                  'network': 'mainnet',
                  'owner_scheme': 0,
                  'owner_value': fixture.owner,
                  'balances_complete': true
                },
                'data': [
                  {
                    'covenant_id': selectedId,
                    'owner_scheme': 0,
                    'owner_value': fixture.owner,
                    'balance_raw': '100000000000000',
                    'balance_complete': true
                  }
                ],
                'pagination': {'has_more': false},
              }),
              200)
          : request.url.path.endsWith('/tokens/$selectedId')
              ? fixture.envelope(fixture.token)
              : await original.get(request.url);
      if (response.statusCode != 200) return response;
      final text = response.body.replaceAll(fixture.cid,
          foreign ? 'd' * 64 : Kcc20StandardService.kusdtCovenantId);
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        return http.Response(jsonEncode(decoded), response.statusCode);
      }
      final value = decoded;
      void token(Map row) {
        if (row['recognition'] == 'hash_proven_reference_actor_family') {
          row['metadata'] = decimals == null
              ? null
              : {
                  'binding_verified': true,
                  'decimals': decimals,
                };
          row['token_units'] = {'decimals': null, 'status': 'unknown'};
        }
      }

      final data = value['data'];
      if (data is Map) {
        token(data);
        if (data['outputs'] is List &&
            request.url.path.contains('/transactions/')) {
          for (final state in data['outputs'] as List) {
            (state as Map)['borrow_scheme'] = borrow;
            if (extended) state['extension_commitment'] = '1' * 64;
          }
        }
      } else if (data is List) {
        for (final row in data.whereType<Map>()) {
          token(row);
        }
      }
      return http.Response(jsonEncode(value), response.statusCode);
    });
  }

  test(
      'kUSDT discovery pins six units and identity despite absent indexer metadata',
      () async {
    final client = source();
    addTearDown(client.close);
    final wallet = await Kcc20StandardService(client)
        .load(fixture.address, historyLimit: 0);
    final asset = wallet.assets.single;
    expect(asset.symbol, 'KUSDT');
    expect(asset.decimals, 6);
    expect(asset.rawBalance, '100000000000000');
    expect(asset.balance, 100000000);
    expect(asset.covenantId, Kcc20StandardService.kusdtCovenantId);
    expect(asset.standard, 'kusdt-kcc20');
    expect(asset.templateHash, Kcc20StandardService.kusdtOwnerTemplateId);
    expect(Kcc20StandardService.isStandard(asset.standard), isTrue);
    expect(
        Kcc20StandardService.supportsBorrowedReceive(asset.standard), isFalse);
  });
  test(
      'kUSDT sends retain live own-node checks and use the dedicated native profile',
      () async {
    final client = source();
    addTearDown(client.close);
    final batch = await Kcc20StandardService(client).signingBatch(
        fixture.address, Kcc20StandardService.kusdtCovenantId, 1000001,
        fullPlan: true);
    expect(batch.cells, hasLength(1));
    expect(batch.templateId, Kcc20StandardService.kusdtOwnerTemplateId);
    expect(batch.inputLimit, 3);
    expect(batch.amount, 1000001);
    expect(batch.cells.single.redeemScript, isNotEmpty);
  });
  test(
      'kUSDT conflicting verified units fail closed rather than rescaling funds',
      () async {
    final client = source(decimals: 8);
    addTearDown(client.close);
    await expectLater(
        Kcc20StandardService(client).get(
            'https://kasvio.network/api/kcc20/v4/tokens/${Kcc20StandardService.kusdtCovenantId}'),
        throwsStateError);
  });
  test(
      'kUSDT owner can spend incoming borrowing policies without borrowing recipient cells',
      () async {
    final client = source(borrow: 1);
    addTearDown(client.close);
    final batch = await Kcc20StandardService(client)
        .signingBatch(fixture.address, Kcc20StandardService.kusdtCovenantId, 1);
    expect(batch.templateId, Kcc20StandardService.kusdtOwnerTemplateId);
    expect(
        await Kcc20StandardService(client).borrowedReceive(
            fixture.address,
            Kcc20StandardService.kusdtCovenantId,
            1,
            batch.cells.single,
            Kcc20StandardService.kusdtOwnerTemplateId),
        isNull);
  });
  test(
      'kUSDT primary address route uses pinned units before any optional history',
      () async {
    final client = source(addressRoute: true);
    addTearDown(client.close);
    final wallet = await Kcc20StandardService(client)
        .load(fixture.address, historyLimit: 0);
    expect(wallet.assets.single.decimals, 6);
    expect(wallet.assets.single.standard, 'kusdt-kcc20');
    expect(wallet.assets.single.rawBalance, '100000000000000');
  });
  test(
      'kUSDT extended identities do not enter the plain-token transfer profile',
      () async {
    final client = source(extended: true);
    addTearDown(client.close);
    await expectLater(
        Kcc20StandardService(client).signingBatch(
            fixture.address, Kcc20StandardService.kusdtCovenantId, 1),
        throwsStateError);
  });
  test('a lookalike covenant cannot inherit the kUSDT identity or native mode',
      () async {
    final client = source(foreign: true);
    addTearDown(client.close);
    final token = await Kcc20StandardService(client)
        .get('https://kasvio.network/api/kcc20/v4/tokens/${'d' * 64}');
    expect((token['data'] as Map)['wallet_standard'], isNull);
    expect(Kcc20StandardService.tokenTemplate(token['data'] as Map),
        Kcc20StandardService.templateId);
  });
}
