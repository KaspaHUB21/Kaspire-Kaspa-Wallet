import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/kcc20_standard_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final snapshotPath = Platform.environment['KASPIRE_KASCOV_SNAPSHOT'];
  test(
      'captured Kaspire/UNNACHOD programs reach native-ready plans with Kasvio offline',
      () async {
    final snapshot = jsonDecode(File(snapshotPath!).readAsStringSync()) as Map;
    final replies = snapshot['responses'] as Map;
    final client = MockClient((request) async {
      if (request.url.host == 'kasvio.network')
        return http.Response('{"error":"source_unavailable"}', 503);
      final captured = replies[request.url.toString()];
      if (captured == null)
        throw StateError('Uncaptured public read: ${request.url}');
      return http.Response(
          jsonEncode(captured['body']), captured['status'] as int,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final service = Kcc20StandardService(client),
        address = snapshot['address'] as String;
    final wallet = await service.load(address, historyLimit: 0);
    expect(wallet.assets.any((a) => a.symbol == 'KASPIREISTHEBESTKASPAWALLET'),
        true);
    expect(wallet.assets.any((a) => a.symbol == 'UNNACHOD'), true);
    expect(
        wallet.assets.every((a) => !Kcc20StandardService.obsoleteTemplateHashes
            .contains(a.templateHash)),
        true);
    final plans = <Map<String, Object?>>[];
    for (final cid in (snapshot['samples'] as List).cast<String>()) {
      final asset = wallet.assets.singleWhere((a) => a.covenantId == cid);
      final amount = asset.symbol == 'UNNACHOD' ? 10000 : 10000 * 100000000;
      final step = await service.signingBatch(address, cid, amount,
          fullPlan: true, kassealOwnerOnly: asset.standard == 'kasseal-kcc20');
      expect(step.amount, amount);
      expect(step.compound, false);
      final owner = snapshot['owner'] as String;
      plans.add({
        'sender': address, 'recipient': address, 'covenantId': cid,
        'ticker': asset.symbol, 'amount': amount, 'decimals': asset.decimals,
        'feeRate': 100.0, 'templateHash': step.templateId,
        'cells': step.cells
            .map((c) => {
                  'transactionId': c.transactionId,
                  'index': c.index,
                  'valueSompi': c.valueSompi,
                  'blockDaaScore': c.blockDaaScore,
                  'scriptPublicKey': c.scriptPublicKey,
                  'tokenAmount': c.tokenAmount,
                  'redeemScript': c.redeemScript
                })
            .toList(),
        // Invented funding is strictly local: this draft is never signed or sent.
        'fundingUtxosJson': jsonEncode([
          {
            'address': address,
            'outpoint': {'transactionId': 'ab' * 32, 'index': 0},
            'utxoEntry': {
              'amount': 10000000000,
              'blockDaaScore': 100,
              'isCoinbase': false,
              'scriptPublicKey': {
                'version': 0,
                'scriptPublicKey': '20${owner}ac'
              }
            }
          }
        ])
      });
    }
    final output = Platform.environment['KASPIRE_KASCOV_PLANS'];
    if (output != null) File(output).writeAsStringSync(jsonEncode(plans));
  },
      skip: snapshotPath == null
          ? 'Requires public read-only Kascov/own-node capture'
          : false);
}
