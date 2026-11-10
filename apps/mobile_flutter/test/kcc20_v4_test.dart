import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/kcc20_standard_service.dart';

Map<String, Object?> v4Meta() => {
      'network': 'mainnet',
      'adapter': 'kcc20',
      'reference_commit': null,
      'source_run': 'v4:test',
      'source_fingerprint': 'a' * 64,
      'decoder_fingerprint': 'b' * 64,
    };
http.Response response(Object data, {Map<String, Object?>? meta}) =>
    http.Response(jsonEncode({'data': data, 'meta': meta ?? v4Meta()}), 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('V4 is the default; mixed-family envelope is not a signing pin',
      () async {
    final service = Kcc20StandardService(MockClient((r) async {
      expect(r.url.path, '/api/kcc20/v4/status');
      return response({'status': 'ready', 'token_count': '580'});
    }));
    expect((await service.get('${service.base}/status'))['data']['token_count'],
        '580');
  });
  test('V4 still rejects wrong networks, foreign revisions and bad provenance',
      () async {
    for (final mutation in <Map<String, Object?>>[
      {'network': 'testnet-10'},
      {'reference_commit': 'c' * 40},
      {'adapter': 'other'},
      {'source_run': 'v3:test'},
      {'source_fingerprint': null},
      {'decoder_fingerprint': 'invalid'},
    ]) {
      final service = Kcc20StandardService(MockClient(
          (r) async => response({}, meta: {...v4Meta(), ...mutation})));
      await expectLater(
          service.get('${service.base}/status'), throwsStateError);
    }
  });
  test('null global revision is not accepted from an older API', () async {
    final service = Kcc20StandardService(MockClient((r) async => response({})),
        base: 'https://kasvio.network/api/kcc20/v1');
    await expectLater(service.get('${service.base}/status'), throwsStateError);
  });
  test('V4 Kasseal identity preserves the restricted owner-only signing mode',
      () async {
    final cid = 'c' * 64;
    final service = Kcc20StandardService(MockClient((r) async => response({
          'covenant_id': cid,
          'profile_id': 'KCC20PublicMint@c8a0871',
          'recognition': 'hash_proven_reference_actor_family',
          'market': {'venue': 'kasseal'},
          'token_units': {'status': 'verified', 'decimals': 0},
        })));
    final token = (await service.get('${service.base}/tokens/$cid'))['data'];
    expect(token['wallet_standard'], 'kasseal-kcc20');
    expect(
        Kcc20StandardService.supportsBorrowedReceive(token['wallet_standard']),
        false);
  });
  final capture = Platform.environment['KASPIRE_KASVIO_V4_SNAPSHOT'];
  test('recorded V4 catalogue, wallet, images and live cell proofs', () async {
    final snapshot = jsonDecode(File(capture!).readAsStringSync()) as Map;
    final replies = snapshot['responses'] as Map;
    final requested = <String>[];
    final client = MockClient((request) async {
      requested.add(request.url.toString());
      final captured = replies[request.url.toString()];
      if (captured == null) throw StateError('Uncaptured read: ${request.url}');
      return http.Response(
          jsonEncode(captured['body']), captured['status'] as int,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final service = Kcc20StandardService(client);
    final tokens = await service.directory();
    expect(tokens.length, snapshot['tokenCount']);
    expect(tokens.length, greaterThanOrEqualTo(580));
    final wallet = await service.load(snapshot['address'], historyLimit: 0);
    expect(wallet.assets.any((a) => a.symbol == 'KASPIREISTHEBESTKASPAWALLET'),
        true);
    expect(wallet.assets.any((a) => a.symbol == 'UNNACHOD'), true);
    expect(wallet.assets.any((a) => a.symbol.startsWith('BRAVE-')), false);
    for (final cid in (snapshot['samples'] as List).cast<String>()) {
      final asset = wallet.assets.singleWhere((a) => a.covenantId == cid);
      expect(asset.imageUrl, contains('/api/kcc20/v4/images/'));
      final amount = asset.symbol == 'UNNACHOD' ? 10000 : 1000000000000;
      final batch = await service.signingBatch(snapshot['address'], cid, amount,
          fullPlan: true, kassealOwnerOnly: asset.standard == 'kasseal-kcc20');
      expect(batch.amount, amount);
      expect(batch.cells, isNotEmpty);
    }
    expect(
        requested
            .where((u) => u.contains('kasvio.network/'))
            .every((u) => u.contains('/api/kcc20/v4/')),
        true);
  }, skip: capture == null ? 'Requires read-only V4/own-node capture' : false);
}
