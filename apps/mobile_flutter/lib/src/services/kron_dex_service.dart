import 'dart:convert';
import 'package:http/http.dart' as http;
import 'encrypted_store.dart';
import 'kaspa_api.dart';
import 'activity_store.dart';

class KronDexService {
  KronDexService({http.Client? client}) : client = client ?? http.Client();
  final http.Client client;
  static const base = 'https://kaspire.kaslab.space/dex-test-v1/kron';
  static const store = KeystoreEncryptedStore();
  Future<dynamic> call(String path, [Map<String, Object?>? body]) async {
    final uri = Uri.parse('$base/$path');
    final response = await (body == null
            ? client.get(uri)
            : client.post(uri,
                headers: {'content-type': 'application/json'},
                body: jsonEncode(body)))
        .timeout(const Duration(seconds: 45));
    final data = jsonDecode(response.body);
    if (response.statusCode != 200) {
      throw StateError(
          data['error']?.toString() ?? 'KRON temporarily unavailable');
    }
    return data;
  }

  Future<List<Map<String, dynamic>>> tokens() async =>
      (await call('tokens') as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
  Future<Map<String, dynamic>> quote(
          String id, String side, String raw) async =>
      Map<String, dynamic>.from(
          await call('quote', {'tokenId': id, 'side': side, 'rawAmount': raw}));
  Future<Map<String, Object?>> plan(String address, String id, String side,
      String raw, String minimum) async {
    final data = Map<String, dynamic>.from(await call('plan', {
      'address': address,
      'tokenId': id,
      'side': side,
      'rawAmount': raw,
      'minimumReceive': minimum
    }));
    final request = Map<String, Object?>.from(data['request']);
    final summary = request['tradeSummary'] as Map;
    if (request['sender'] != address ||
        request['profile'] != 'kron-swap-v1' ||
        request['tokenId'] != id ||
        request['side'] != side ||
        summary['rawAmount'] != raw ||
        summary['minimumReceive'] != minimum ||
        summary['ref'] != 'kaspirewallet') {
      throw StateError('KRON plan does not match your selected trade.');
    }
    return request;
  }

  /// Independently checks every embedded input against spendable node state.
  /// A server-provided address is only a lookup hint, never ownership evidence.
  Future<void> verifyInputs(Map<String, Object?> request) async {
    final tx = jsonDecode(request['txJsonString'].toString()) as Map;
    final inputs = tx['inputs'] as List;
    final addresses =
        (request['tradeSummary'] as Map)['inputAddresses'] as List;
    if (inputs.length != addresses.length) {
      throw StateError('Incomplete KRON input verification data');
    }
    final lookups = <String, List>{};
    final transactions = <String, Map>{};
    for (final address in addresses.toSet()) {
      final uri = Uri.parse(
          'https://kaspire.kaslab.space/api/local-node/addresses/${Uri.encodeComponent(address.toString())}/utxos');
      final response =
          await client.get(uri).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw StateError(
            'Could not verify spendable swap inputs. Please retry.');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! List) throw StateError('Invalid node UTXO response');
      lookups[address.toString()] = decoded;
    }
    for (var i = 0; i < inputs.length; i++) {
      final input = inputs[i] as Map, embedded = input['utxo'] as Map;
      final matches = lookups[addresses[i]]!
          .whereType<Map>()
          .where((row) =>
              (row['outpoint'] as Map)['transactionId'] ==
                  input['transactionId'] &&
              (row['outpoint'] as Map)['index'] == input['index'])
          .toList();
      if (matches.length != 1) {
        throw StateError(
            'The market or wallet output was already spent. Get a fresh quote.');
      }
      final live = matches.single['utxoEntry'] as Map,
          spk = live['scriptPublicKey'] as Map;
      final script = ((spk['version'] ?? 0) as num)
              .toInt()
              .toRadixString(16)
              .padLeft(4, '0') +
          (spk['script'] ?? spk['scriptPublicKey']).toString();
      final txid = input['transactionId'].toString();
      if (!transactions.containsKey(txid)) {
        final response = await client
            .get(Uri.parse(
                'https://kaspire.kaslab.space/api/local-node/transactions/$txid'))
            .timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) {
          throw StateError('Could not verify the swap covenant origin.');
        }
        transactions[txid] = jsonDecode(response.body) as Map;
      }
      final origin = transactions[txid]!;
      final outputs = (origin['outputs'] as List)
          .whereType<Map>()
          .where((o) => o['index'] == input['index'])
          .toList();
      if (origin['is_accepted'] != true ||
          origin['transaction_id'] != txid ||
          outputs.length != 1 ||
          outputs.single['covenant_id'] != embedded['covenantId']) {
        throw StateError(
            'Swap covenant differs from the confirmed node transaction.');
      }
      if (live['amount'].toString() != embedded['amount'].toString() ||
          script != embedded['scriptPublicKey'] ||
          live['blockDaaScore'].toString() !=
              embedded['blockDaaScore'].toString() ||
          live['isCoinbase'] != embedded['isCoinbase']) {
        throw StateError('Swap UTXO data differs from the own-node result.');
      }
    }
  }

  static String key(String address) => 'kron_swap_recovery_v1_$address';
  Future<Map<String, dynamic>?> pending(String address) async {
    final text = await store.read(key(address));
    return text == null ? null : Map<String, dynamic>.from(jsonDecode(text));
  }

  Future<void> retain(String address, Map<String, dynamic> receipt) =>
      store.write(key(address), jsonEncode(receipt));
  Future<String> submit(String address, Map<String, dynamic> receipt) async {
    final id = await KaspaApi().broadcastKcc20(receipt['signedTxJson'],
        expectedTransactionId: receipt['transactionId']);
    await recordReceipt(address, receipt, id);
    await store.delete(key(address));
    return id;
  }

  static Future<void> recordReceipt(String address, Map receipt, String id,
      {ActivityStore? activity}) async {
    final summary = receipt['summary'] as Map;
    await (activity ?? ActivityStore()).recordAssetTransfer(
      wallet: address,
      transactionId: id,
      timestamp: DateTime.tryParse(receipt['timestamp']?.toString() ?? '') ??
          DateTime.now(),
      incoming: summary['side'] == 'buy',
      operation: {
        'kind': 'kcc20',
        'ticker': receipt['ticker'],
        'covenantId': receipt['tokenId'],
        'displayAmount':
            display(summary['tokenAmount'], receipt['decimals'] as int),
        'operationLabel': summary['side'] == 'buy' ? 'KRON Buy' : 'KRON Sell',
      },
    );
  }

  static BigInt parseAmount(String text, int decimals) {
    final value = text.trim();
    if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(value)) {
      throw StateError('Enter a positive amount using a decimal point.');
    }
    final parts = value.split('.'),
        fraction = parts.length == 2 ? parts[1] : '';
    if (fraction.length > decimals) {
      throw StateError(
          'This amount supports at most $decimals decimal places.');
    }
    final amount = BigInt.parse(parts[0] + fraction.padRight(decimals, '0'));
    if (amount <= BigInt.zero) {
      throw StateError('Enter an amount greater than zero.');
    }
    return amount;
  }

  static String display(Object? raw, int decimals) {
    final value = BigInt.tryParse(raw.toString()) ?? BigInt.zero;
    final digits = value.abs().toString().padLeft(decimals + 1, '0');
    final formatted = decimals == 0
        ? digits
        : '${digits.substring(0, digits.length - decimals)}.${digits.substring(digits.length - decimals)}'
            .replaceFirst(RegExp(r'0+$'), '')
            .replaceFirst(RegExp(r'\.$'), '');
    return '${value.isNegative ? '-' : ''}$formatted';
  }
}
