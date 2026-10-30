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

/// Fault injection changes only the initial hint or an indexer-availability
/// reply. All returned chain state, UTXOs, pools and fee quotes remain LIVE.
class _FaultedReadOnlyClient extends _ReadOnlyClient {
  _FaultedReadOnlyClient(this.mode);
  final String mode;
  int discoveries = 0, indexMisses = 0, alteredHints = 0, ownUtxos = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method != 'GET') throw StateError('Live probe forbids writes');
    final uri = request.url;
    if (uri.path == '/api/mainnet/pools') discoveries++;
    if (uri.host == 'kaspire.kaslab.space' && uri.path.endsWith('/utxos')) {
      ownUtxos++;
    }
    if (mode == 'missing-and-lagging-index' &&
        uri.host == 'kaspire.kaslab.space' &&
        uri.path.contains('/transactions/')) {
      indexMisses++;
      return http.StreamedResponse(Stream.value(utf8.encode('{}')), 404,
          headers: {'content-type': 'application/json'});
    }
    final response = await super.send(request);
    if (uri.host == 'app.braidswap.com' &&
        uri.path.endsWith('/quote') &&
        !uri.queryParameters.containsKey('walletFeeBps') &&
        response.statusCode == 200) {
      final q = jsonDecode(await response.stream.bytesToString()) as Map;
      if (mode == 'stale-hint') {
        final old = jsonDecode(File(
                '../../crates/kaspa_secure_core/src/fixtures/braid-mainnet-guza-pool.json')
            .readAsStringSync()) as Map;
        q['poolTips'] = {
          old['tokenId']: {
            'transactionId': old['transactionId'],
            'index': old['index']
          }
        };
      } else {
        q.remove('poolTips');
      }
      alteredHints++;
      return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(q))), 200,
          headers: {'content-type': 'application/json'});
    }
    return response;
  }
}

void main() {
  for (final mode in [
    'missing-hint',
    'stale-hint',
    'missing-and-lagging-index'
  ]) {
    test('live Mainnet GUZA to THEN independently recovers from $mode',
        () async {
      NetworkSettings.network.value = KaspaNetwork.mainnet;
      final f = jsonDecode(File(
              '../../crates/kaspa_secure_core/src/fixtures/braid-tn10-kas-buy.json')
          .readAsStringSync()) as Map;
      final address =
          kaspaAddressFromOwnerId(kaspaOwnerIdFromAddress('${f['sender']}'));
      final client = _FaultedReadOnlyClient(mode),
          service = BraidService(client: client);
      try {
        final from = BraidService.tokens.singleWhere((t) => t.symbol == 'GUZA');
        final to = BraidService.tokens.singleWhere((t) => t.symbol == 'THEN');
        final q = await service.quote(address, from, to, '100000', 100);
        expect(q['localValuation']['tokenId'], from.id);
        expect(BraidService.integer(q['localValuation']['floor']) > BigInt.zero,
            true);
        expect(q['walletFee']['bps'], 100);
        expect(client.alteredHints, 1);
        expect(client.discoveries, 1);
        expect(client.ownUtxos, greaterThan(0));
        if (mode == 'missing-and-lagging-index') {
          expect(client.indexMisses, greaterThan(0));
        }
        // ignore: avoid_print
        print(
            '$mode: recovered using LIVE pool data and mandatory own-node UTXOs; no build/sign/submit');
      } finally {
        client.close();
      }
    }, skip: Platform.environment['KASPIRE_BRAID_POOL_LIVE'] != '1');
  }
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
        // ignore: avoid_print
        print(
            '${pair.$1} → ${pair.$2}: independently verified pool, quote and fee; ${client.reads} GETs, no build/sign/submit');
      } finally {
        client.close();
      }
    }, skip: Platform.environment['KASPIRE_BRAID_POOL_LIVE'] != '1');
  }
}
