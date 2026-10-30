import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:kasvault_wallet/src/services/braid_service.dart';
import 'package:kasvault_wallet/src/services/braid_pool_reader.dart';
import 'package:kasvault_wallet/src/services/braid_clock.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';

Map<String, dynamic> proof() => Map<String, dynamic>.from(jsonDecode(File(
        '../../crates/kaspa_secure_core/src/fixtures/braid-mainnet-then-pool.json')
    .readAsStringSync()) as Map);
void main() {
  setUp(() => NetworkSettings.network.value = KaspaNetwork.mainnet);
  test('fee beneficiary round-trips to the exact user-approved Mainnet address',
      () {
    final s = BraidService();
    expect(s.feeAddress,
        'kaspa:qqre4wt08dp0rvmxwqgwdkz4zu4m36g9uvmfledd27mx939uxe2yjpmmd37zq');
    expect(s.feeBps, 100);
    expect(s.currentPin, BraidService.mainnetPin);
    expect(s.key(s.feeAddress), isNot(contains('tn10')));
    expect(BraidService.tokens.map((t) => t.symbol),
        ['KAS', 'THEN', 'GUZA', 'KRON', 'PEPE', 'IFWEN', 'ANSEM', 'KASCOV']);
    expect(BraidService.tokens[1].decimals, 3);
  });
  test(
      'independent actual Mainnet pool program uses exact integer contract sale math',
      () {
    final p = proof(), amount = BigInt.from(10000000);
    final price = BraidPoolReader.sale(
        'mainnet', '${p['tokenId']}', '${p['redeem']}', amount);
    expect(price.toString(), p['tradeKas']);
    expect((price * BigInt.from(9900) ~/ BigInt.from(10000)).toString(),
        p['floor']);
    expect(
        () => BraidPoolReader.sale(
            'tn10', '${p['tokenId']}', '${p['redeem']}', amount),
        throwsStateError);
    expect(
        () => BraidPoolReader.sale(
            'mainnet', '${p['tokenId']}', '${p['redeem']}00', amount),
        throwsStateError);
  });
  test('token fee includes carrier within 1%, never a separate surcharge', () {
    final s = BraidService(), p = proof(), f = BigInt.parse('${p['floor']}');
    final fee = BigInt.from(10000000) *
        (f ~/ BigInt.from(100) - BigInt.from(20000000)) ~/
        f;
    final w = <String, dynamic>{
      'mode': 'bps',
      'bps': 100,
      'address': s.feeAddress,
      'pk': BraidService.feeOwner,
      'unit': 'token',
      'basisKind': 'inAmount',
      'basis': '10000000',
      'amount': '$fee',
      'tkFloor': '$f',
      'carrier': '20000000',
      'carrierPaidBy': 'integrator'
    };
    final q = {'walletFee': w};
    s.validateFee(
        q, BraidService.tokens[1], BraidService.tokens[3], '10000000', 100, p);
    for (final field in [
      'amount',
      'pk',
      'carrier',
      'tkFloor',
      'bps',
      'carrierPaidBy'
    ]) {
      final mutated = {
        ...w,
        field: field == 'pk'
            ? '0' * 64
            : field == 'carrierPaidBy'
                ? 'user'
                : field == 'bps'
                    ? 200
                    : '999999999999'
      };
      expect(
          () => s.validateFee({'walletFee': mutated}, BraidService.tokens[1],
              BraidService.tokens[3], '10000000', 100, p),
          throwsStateError,
          reason: field);
    }
  });
  test('pool hint is verified from accepted chain witness and live output',
      () async {
    final p = proof();
    final tx = jsonDecode(File(
            '../../crates/kaspa_secure_core/src/fixtures/braid-mainnet-then-transaction.json')
        .readAsStringSync()) as Map;
    for (final bad in ['none', 'accepted', 'covenant', 'witness']) {
      final copy = jsonDecode(jsonEncode(tx)) as Map;
      if (bad == 'accepted') copy['is_accepted'] = false;
      if (bad == 'covenant') {
        (copy['outputs'] as List)[p['index']]['covenant_id'] = '0' * 64;
      }
      if (bad == 'witness') {
        for (final input in copy['inputs'] as List) {
          input['signature_script'] = '00';
        }
      }
      final reader = BraidPoolReader(MockClient((r) async {
        expect(['kaspire.kaslab.space', 'api.kaspa.org'], contains(r.url.host));
        return http.Response(
            jsonEncode(r.url.path.contains('/transactions/')
                ? copy
                : [
                    {
                      'outpoint': {
                        'transactionId': p['transactionId'],
                        'index': p['index']
                      },
                      'utxoEntry': {
                        'amount': '100000000',
                        'isCoinbase': false,
                        'scriptPublicKey': {
                          'version': 0,
                          'scriptPublicKey': p['scriptPublicKey']
                        }
                      }
                    }
                  ]),
            200);
      }), mainnet: true);
      final result = reader.value('${p['tokenId']}', BigInt.from(10000000), 100,
          {'transactionId': p['transactionId'], 'index': p['index']});
      if (bad == 'none') {
        expect((await result)['floor'], p['floor']);
      } else {
        await expectLater(result, throwsA(isA<StateError>()));
      }
    }
  });
  test(
      'Mainnet info must be enabled, healthy and out of canary with exact r2c pin',
      () async {
    for (final bad in ['none', 'canary', 'pin', 'network', 'health']) {
      final s = BraidService(client: MockClient((r) async {
        expect(r.url.origin, 'https://app.braidswap.com');
        expect(r.url.path, '/api/mainnet/router/info');
        return http.Response(
            jsonEncode({
              'net': bad == 'network' ? 'tn10' : 'mainnet',
              'enabled': true,
              'pin': bad == 'pin' ? '0' * 64 : BraidService.mainnetPin,
              'expectedPin': BraidService.mainnetPin,
              'pinOk': true,
              'canary': bad == 'canary',
              'executorStatus': {'healthy': bad != 'health'}
            }),
            200);
      }));
      if (bad == 'none') {
        expect((await s.info())['net'], 'mainnet');
      } else {
        await expectLater(s.info(), throwsStateError);
      }
    }
  });
  test(
      'Mainnet time requires agreement between own node and independent public source',
      () async {
    final seen = <String>[];
    final c = BraidClock(MockClient((r) async {
      seen.add(r.url.host);
      return http.Response(
          jsonEncode(
              {'networkName': 'kaspa-mainnet', 'virtualDaaScore': 123456}),
          200);
    }), mainnet: true);
    expect(await c.read(), [123456, 123456]);
    expect(seen.toSet(), {'api.kaspa.org', 'kaspire.kaslab.space'});
  });
}
