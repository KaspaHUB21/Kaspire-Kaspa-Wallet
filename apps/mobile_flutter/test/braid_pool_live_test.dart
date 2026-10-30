import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kasvault_wallet/src/kaspa_address.dart';
import 'package:kasvault_wallet/src/services/braid_service.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';

/// Exercise production discovery, pool verification and fees without any write.
class _ReadOnlyClient extends http.BaseClient {
  final _inner = http.Client();
  int reads = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.method != 'GET') throw StateError('Live probe forbids writes');
    reads++;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

void main() {
  for (final pair in [
    ('THEN', 'KRON', '1000000', false),
    ('KRON', 'THEN', '100000', false),
    ('GUZA', 'THEN', '100000', true),
    ('THEN', 'GUZA', '100000', true),
    ('KRON', 'PEPE', '100000', true),
  ]) {
    test(
        'live read-only Mainnet ${pair.$1} to ${pair.$2} quote verifies pool and 1% fee',
        () async {
      NetworkSettings.network.value = KaspaNetwork.mainnet;
      final fixture = jsonDecode(File(
              '../../crates/kaspa_secure_core/src/fixtures/braid-tn10-kas-buy.json')
          .readAsStringSync()) as Map;
      final address = kaspaAddressFromOwnerId(
          kaspaOwnerIdFromAddress('${fixture['sender']}'));
      final client = _ReadOnlyClient(), service = BraidService(client: client);
      try {
        final from =
            BraidService.tokens.singleWhere((t) => t.symbol == pair.$1);
        final to = BraidService.tokens.singleWhere((t) => t.symbol == pair.$2);
        final q = await service.quote(address, from, to, pair.$3, 100);
        expect(q['staged'], pair.$4);
        expect(q['localFromId'], from.id);
        expect(q['localToId'], to.id);
        expect(BraidService.integer(q['localFloor']) > BigInt.zero, true);
        expect(q['localValuation'], isA<Map>());
        expect((q['walletFee'] as Map)['bps'], 100);
        expect((q['walletFee'] as Map)['address'], service.feeAddress);
        if (pair.$4) {
          expect(q['walletFee']['unit'], 'KAS');
          expect(q['walletFee']['basisKind'], 'tradeKas');
          expect(BraidService.integer(q['localMidMin']) > BigInt.zero, true);
        }
        print(
            '${pair.$1} → ${pair.$2}: independently verified pool, quote and fee; ${client.reads} GETs, no build/sign/submit');
      } finally {
        client.close();
      }
    }, skip: Platform.environment['KASPIRE_BRAID_POOL_LIVE'] != '1');
  }
}
