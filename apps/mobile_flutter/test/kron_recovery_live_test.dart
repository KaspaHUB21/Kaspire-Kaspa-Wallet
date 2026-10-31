import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kasvault_wallet/src/services/kron_dex_service.dart';
import 'kron_recovery_test.dart' show Memory;

class ReadOnly extends http.BaseClient {
  final inner = http.Client();
  int reads = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.method != 'GET') {
      throw StateError('Live check forbids any broadcast or write');
    }
    reads++;
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}

void main() {
  test(
      'live exact-outpoint conflict recovery reads only; never signs or broadcasts',
      () async {
    final client = ReadOnly(), store = Memory();
    try {
      final head = jsonDecode((await client.get(Uri.parse(
              'https://idx.kron.technology/v1/kcc20/token/KRON/poolhead')))
          .body) as Map;
      final candidate = head['result']['pool']['transactionId'];
      final tx = jsonDecode((await client.get(Uri.parse(
              'https://kaspire.kaslab.space/api/local-node/transactions/$candidate?resolve_previous_outpoints=no')))
          .body) as Map;
      expect(tx['is_accepted'], true);
      expect(tx['transaction_id'], candidate);
      final prior = (tx['inputs'] as List).first as Map;
      final original = prior['previous_outpoint_hash'],
          index = prior['previous_outpoint_index'];
      const address = 'kaspa:synthetic-read-only-journal';
      final id = 'f1' * 32;
      final service = KronDexService(client: client, store: store);
      final receipt = <String, dynamic>{
        'transactionId': id,
        'signedTxJson': jsonEncode({
          'id': id,
          'inputs': [
            {'transactionId': original, 'index': index}
          ]
        })
      };
      // Synthetic journal only: there is no signature, funded wallet or submit call.
      await service.retain(address, receipt);
      expect(await service.checkSaved(address, receipt),
          KronRecoveryState.obsolete);
      final archived = jsonDecode(
          store.values['${KronDexService.key(address)}_last_obsolete']!);
      expect(archived['signedTxJson'], receipt['signedTxJson']);
      expect(archived['conflictingTransactionId'], candidate);
      expect(await service.pending(address), isNull);
      // ignore: avoid_print
      print(
          'Own-node exact conflict confirmed against live KRON history in ${client.reads} GETs. No sign, broadcast or external write.');
    } finally {
      client.close();
    }
  }, skip: Platform.environment['KASPIRE_KRON_RECOVERY_LIVE'] != '1');
}
