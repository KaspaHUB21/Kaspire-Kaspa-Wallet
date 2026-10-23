import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/wallet_snapshot.dart';
import 'activity_store.dart';
import 'encrypted_store.dart';
import 'network_settings.dart';
import 'swap_conflict_lookup.dart';

class KassealService {
  static const enabled = true;
  KassealService(
      {http.Client? client, EncryptedStore? store, ActivityStore? activity})
      : mainnet = NetworkSettings.network.value == KaspaNetwork.mainnet,
        client = client ?? http.Client(),
        store = store ?? const KeystoreEncryptedStore(),
        activity = activity ?? ActivityStore();
  final http.Client client;
  final EncryptedStore store;
  final ActivityStore activity;
  final bool mainnet;
  String get network => mainnet ? 'mainnet' : 'testnet-10';
  String get networkLabel => mainnet ? 'Mainnet' : 'Testnet 10';
  String get prefix => mainnet ? 'kaspa:' : 'kaspatest:';
  String profile(String kind) =>
      'kasseal-${mainnet ? 'mainnet' : 'tn10'}-$kind-v1';
  String get api =>
      mainnet ? 'https://app.kasseal.com/v1' : 'https://testnet.kasseal.com/v1';
  String get planner =>
      'https://kaspire.kaslab.space/dex-test-v1/${mainnet ? 'kasseal-mainnet' : 'kasseal'}';
  String get node => mainnet
      ? 'https://kaspire.kaslab.space/api/local-node'
      : 'https://api-tn10.kaspa.org';
  void guard(String address) {
    if (!NetworkSettings.isKaspa ||
        NetworkSettings.isTestnet == mainnet ||
        !address.startsWith(prefix)) {
      throw StateError(
          'Kasseal wallet does not match the selected network. Reopen Swap on the correct network.');
    }
  }

  Future<dynamic> request(String url, [Map<String, Object?>? body]) async {
    final response = await (body == null
            ? client.get(Uri.parse(url))
            : client.post(Uri.parse(url),
                headers: const {'content-type': 'application/json'},
                body: jsonEncode(body)))
        .timeout(const Duration(seconds: 55));
    dynamic data;
    try {
      data = jsonDecode(response.body);
    } catch (_) {
      throw StateError(
          'Kasseal returned an unreadable response (${response.statusCode}).');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(data is Map
          ? '${data['detail'] ?? data['error'] ?? data['title'] ?? 'Kasseal temporarily unavailable'}'
          : 'Kasseal unavailable (${response.statusCode}).');
    }
    return data;
  }

  Future<Map<String, dynamic>> tokens([String? cursor]) =>
      searchTokens('', cursor);

  Future<Map<String, dynamic>> searchTokens(String query,
      [String? cursor]) async {
    final search = query.trim();
    if (search.length > 64 || (cursor?.length ?? 0) > 1024)
      throw StateError('Invalid Kasseal search or page cursor.');
    final uri = Uri.parse('$planner/tokens').replace(queryParameters: {
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      if (search.isNotEmpty) 'search': search,
    });
    return Map<String, dynamic>.from(await request(uri.toString()));
  }

  Future<Map<String, dynamic>> wallet(String address) async {
    guard(address);
    return Map<String, dynamic>.from(
        await request('$api/address/${Uri.encodeComponent(address)}/tokens'));
  }

  Future<List<WalletAsset>> walletAssets(String address) async {
    final data = await wallet(address), metadata = <String, Map>{};
    for (final token
        in (data['tokens'] as List? ?? const []).whereType<Map>()) {
      final meta = (token['meta'] as Map? ?? token);
      metadata['${meta['covenantId']}'] = meta;
    }
    return (data['holdings'] as List? ?? const [])
        .whereType<Map>()
        .where((r) =>
            (BigInt.tryParse('${r['balance']}') ?? BigInt.zero) > BigInt.zero)
        .map((row) {
      final id = '${row['tokenId']}',
          meta = metadata[id] ?? const <String, dynamic>{};
      return WalletAsset(
          symbol: '${meta['ticker'] ?? meta['name'] ?? id.substring(0, 8)}',
          balance: double.parse('${row['balance']}'),
          kind: 'KCC20',
          id: id,
          covenantId: id,
          decimals: 0,
          rawBalance: '${row['balance']}',
          imageUrl: image(meta),
          standard: 'kasseal-kcc20',
          discoveryComplete: false,
          validationStatus: 'kasseal-indexed');
    }).toList();
  }

  String? image(Map meta) {
    final url = meta['imageUrl'];
    if (meta['imageSource'] != 'verified' ||
        url is! String ||
        !RegExp(r'^/v1/images/[a-f0-9]{64}$').hasMatch(url)) return null;
    return '${mainnet ? 'https://app.kasseal.com' : 'https://testnet.kasseal.com'}$url';
  }

  Future<BigInt> kasBalance(String address) async {
    guard(address);
    final data =
        await request('$planner/utxos?address=${Uri.encodeComponent(address)}');
    if (data is! Map ||
        data['network'] != network ||
        data['covenantIdsIncluded'] != true ||
        data['entries'] is! List) {
      throw StateError('KAS balance is temporarily unavailable.');
    }
    return (data['entries'] as List).whereType<Map>().fold<BigInt>(BigInt.zero,
        (sum, row) {
      final entry = row['utxoEntry'] as Map;
      return entry['isCoinbase'] == false &&
              entry.containsKey('covenantId') &&
              entry['covenantId'] == null
          ? sum + BigInt.parse('${entry['amount']}')
          : sum;
    });
  }

  Future<List<Map<String, dynamic>>> history(String address) async {
    guard(address);
    final saved = await store.read('${key(address)}_history');
    final rows = <String, Map<String, dynamic>>{};
    if (saved != null) {
      for (final row in (jsonDecode(saved) as List).whereType<Map>()) {
        rows['${row['transactionId']}'] = Map<String, dynamic>.from(row);
      }
    }
    for (final item in await activity.load(address)) {
      if (!(item.operationLabel ?? '').startsWith('Kasseal ')) continue;
      rows.putIfAbsent(
          item.id,
          () => {
                'transactionId': item.id,
                'ticker': item.assetSymbol,
                'timestamp': item.timestamp.toIso8601String(),
                'summary': {
                  'side': item.incoming ? 'buy' : 'sell',
                  'tokenAmount': item.displayAmount
                }
              });
    }
    int timestamp(Map row) =>
        DateTime.tryParse('${row['timestamp']}')?.millisecondsSinceEpoch ?? 0;
    return rows.values.toList()
      ..sort((a, b) => timestamp(b).compareTo(timestamp(a)));
  }

  Map<String, Object?> order(
      String address, String id, String side, String raw) {
    guard(address);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
        !['buy', 'sell'].contains(side) ||
        !RegExp(r'^[1-9][0-9]{0,17}$').hasMatch(raw))
      throw StateError('Enter a valid positive trade amount.');
    return {
      'network': network,
      'address': address,
      'tokenId': id,
      'side': side,
      'rawAmount': raw
    };
  }

  Future<Map<String, dynamic>> quote(
      String address, String id, String side, String raw) async {
    guard(address);
    if (await pending(address) != null && !await retireConflict(address))
      throw StateError(
          'Check the saved swap first. An uncertain payment cannot be replaced.');
    final body = order(address, id, side, raw);
    final result =
        Map<String, dynamic>.from(await request('$planner/quote', body));
    for (final key in ['network', 'tokenId', 'side', 'rawAmount']) {
      if (result[key] != body[key])
        throw StateError('Kasseal quote differs from the requested trade.');
    }
    guard(address);
    return result;
  }

  Future<Map<String, Object?>> plan(
      String address, Map<String, dynamic> quote) async {
    guard(address);
    if (await pending(address) != null)
      throw StateError('Resolve the saved swap before starting another trade.');
    if (DateTime.now().millisecondsSinceEpoch >
        (quote['quoteExpiresAt'] as num))
      throw StateError('Quote expired. Refresh the quote.');
    final body = order(address, '${quote['tokenId']}', '${quote['side']}',
        '${quote['rawAmount']}');
    final expected = BigInt.parse(
        '${quote[quote['side'] == 'buy' ? 'tokenAmount' : 'kasSompi']}');
    body['minimumReceive'] =
        (expected * BigInt.from(99) ~/ BigInt.from(100)).toString();
    body['maxSpendSompi'] = quote['maxSpendSompi'];
    body['allowPreparation'] = true;
    final data = await request('$planner/plan', body);
    final result = Map<String, Object?>.from(data['request'] as Map),
        terms = result['tradeSummary'] as Map;
    if (data['proofStatus'] != 'bound' ||
        ![profile('swap'), profile('prepare')].contains(result['profile']) ||
        result['sender'] != address ||
        result['tokenId'] != body['tokenId'] ||
        result['side'] != body['side'])
      throw StateError('Kasseal plan identity verification failed.');
    if (result['profile'] == profile('prepare') &&
        (body['side'] != 'sell' ||
            terms['stage'] != 'preparation' ||
            !['split', 'merge'].contains(terms['operation']) ||
            terms['maxPreparationDebitSompi'] != '700000000')) {
      throw StateError(
          'Kasseal preparation differs from the approved self-owned token operation.');
    }
    if (result['profile'] == profile('swap') && terms['stage'] == 'preparation')
      throw StateError('Invalid swap stage.');
    for (final key in [
      'network',
      'tokenId',
      'side',
      'rawAmount',
      'minimumReceive',
      'maxSpendSompi'
    ]) {
      if ('${terms[key]}' != '${body[key]}')
        throw StateError('Kasseal changed the reviewed trade limits.');
    }
    guard(address);
    return result;
  }

  Future<void> verifyInputs(String address, Map<String, Object?> signingRequest,
      [Map<String, Object?>? review]) async {
    guard(address);
    final tx = jsonDecode('${signingRequest['txJsonString']}') as Map,
        inputs = tx['inputs'] as List;
    final rows = review?['inputs'] as List?, lookups = <String, List>{};
    for (var i = 0; i < inputs.length; i++) {
      final hint =
          '${rows == null ? inputs[i]['utxo']['address'] : (rows[i] as Map)['address']}';
      if (!hint.startsWith(prefix))
        throw StateError('Swap input is on another network.');
      if (!lookups.containsKey(hint)) {
        final state = await request(
            '$planner/utxos?address=${Uri.encodeComponent(hint)}');
        if (state is! Map ||
            state['network'] != network ||
            state['covenantIdsIncluded'] != true ||
            state['entries'] is! List) {
          throw StateError(
              'Independent node UTXO verification is unavailable. Nothing has been signed.');
        }
        lookups[hint] = state['entries'] as List;
      }
      final input = inputs[i] as Map, embedded = input['utxo'] as Map;
      final found = lookups[hint]!
          .whereType<Map>()
          .where((r) =>
              r['outpoint']['transactionId'] == input['transactionId'] &&
              r['outpoint']['index'] == input['index'])
          .toList();
      if (found.length != 1)
        throw StateError(
            'The pool or wallet balance changed. Refresh the quote. Nothing has been signed.');
      final live = found.single['utxoEntry'] as Map,
          spk = live['scriptPublicKey'] as Map;
      final script = ((spk['version'] ?? 0) as num)
              .toInt()
              .toRadixString(16)
              .padLeft(4, '0') +
          '${spk['script'] ?? spk['scriptPublicKey']}';
      if ('${live['amount']}' != '${embedded['amount']}' ||
          script != embedded['scriptPublicKey'] ||
          live['isCoinbase'] != false ||
          !live.containsKey('covenantId') ||
          live['covenantId'] != embedded['covenantId'] ||
          !RegExp(r'^[0-9]+$').hasMatch('${live['blockDaaScore']}'))
        throw StateError(
            'Kasseal embedded input differs from the independent node.');
      // Full live node entries include covenant IDs even when origin history is pruned.
      // The SDK uses zero DAA metadata for covenant cells. Resolve it independently before review.
      if (review == null) {
        embedded['blockDaaScore'] = '${live['blockDaaScore']}';
        embedded['isCoinbase'] = false;
      } else if ('${live['blockDaaScore']}' != '${embedded['blockDaaScore']}')
        throw StateError(
            'Kasseal input DAA score differs from the selected network. Refresh the quote.');
    }
    if (review == null) signingRequest['txJsonString'] = jsonEncode(tx);
    guard(address);
  }

  String key(String address) => 'kasseal_swap_v1_${network}_$address';
  Future<Map<String, dynamic>?> pending(String address) async {
    final raw = await store.read(key(address));
    return raw == null ? null : Map<String, dynamic>.from(jsonDecode(raw));
  }

  Future<void> retain(String address, Map<String, dynamic> receipt) async {
    guard(address);
    if (await pending(address) != null)
      throw StateError(
          'A swap is already saved. Check it before signing another trade.');
    await store.write(key(address), jsonEncode(receipt));
  }

  Future<bool> accepted(String id) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id))
      throw StateError('Invalid saved transaction ID.');
    final r = await client
        .get(Uri.parse('$node/transactions/$id'))
        .timeout(const Duration(seconds: 12));
    if (r.statusCode == 404) return false;
    if (r.statusCode != 200)
      throw StateError(
          'Independent node confirmation is temporarily unavailable. The swap remains saved.');
    final tx = jsonDecode(r.body) as Map;
    return tx['transaction_id'] == id && tx['is_accepted'] == true;
  }

  Future<bool> retireConflict(String address) async {
    guard(address);
    final saved = await pending(address);
    if (saved == null) return false;
    final id = '${saved['transactionId']}';
    if (await accepted(id)) return false;
    final tx = jsonDecode('${saved['signedTxJson']}') as Map;
    final competing = await findConfirmedSwapConflict(
        tx: tx,
        savedIds: {id},
        node: node,
        prefix: prefix,
        read: (url) async {
          final r = await client
              .get(Uri.parse(url))
              .timeout(const Duration(seconds: 12));
          if (r.statusCode == 404) return null;
          if (r.statusCode != 200)
            throw StateError(
                'Independent node conflict verification is temporarily unavailable. The swap remains saved.');
          return jsonDecode(r.body);
        });
    if (competing == null || await accepted(id)) return false;
    guard(address);
    await store.write('${key(address)}_obsolete',
        jsonEncode({...saved, 'conflict': competing}));
    await store.delete(key(address));
    return true;
  }

  Future<bool> _retireOrKeep(String address) async {
    try {
      return await retireConflict(address);
    } on SwapConflictUnknown {
      return false;
    } // Exact-byte resubmission is safe; replacement is not.
  }

  Future<String> resume(String address) async {
    guard(address);
    final receipt = await pending(address);
    if (receipt == null) throw StateError('No saved Kasseal swap.');
    if (receipt['address'] != address || receipt['network'] != network)
      throw StateError('Saved swap belongs to another account or network.');
    final id = '${receipt['transactionId']}';
    if (!await accepted(id)) {
      if (await _retireOrKeep(address))
        throw StateError(
            'The old pool state was spent by another confirmed transaction. Refresh the quote to try again.');
      try {
        await request('$api/tx', {'txJson': receipt['signedTxJson']});
      } catch (e) {
        if (await _retireOrKeep(address))
          throw StateError(
              'Pool changed before execution. The old swap was archived. Refresh the quote.');
        rethrow;
      }
      var confirmed = false;
      for (var i = 0; i < 12; i++) {
        guard(address);
        if (await accepted(id)) {
          confirmed = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      }
      if (!confirmed)
        throw StateError(
            'Swap submitted; confirmation is pending. The same signed transaction is saved. Check its status; do not create a second trade.');
    }
    guard(address);
    final terms = receipt['summary'] as Map;
    if (terms['stage'] == 'preparation') {
      final archiveKey = '${key(address)}_preparations';
      final raw = await store.read(archiveKey);
      final archive = raw == null ? <dynamic>[] : jsonDecode(raw) as List;
      archive.removeWhere((row) => row['transactionId'] == id);
      archive.add(receipt);
      await store.write(archiveKey, jsonEncode(archive));
      var ready = false;
      for (var attempt = 0; attempt < 20; attempt++) {
        guard(address);
        final data = await request('$planner/prepared?${Uri(queryParameters: {
              'address': address,
              'tokenId': '${terms['tokenId']}',
              'transactionId': id
            }).query}');
        if (data['network'] != network ||
            data['tokenId'] != terms['tokenId'] ||
            data['transactionId'] != id)
          throw StateError(
              'Token preparation indexer response differs. The signed transaction remains saved.');
        if (data['ready'] == true) {
          ready = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      }
      if (!ready)
        throw StateError(
            'Token preparation is confirmed. Waiting for Kasseal to index the prepared tokens; use Check saved preparation to continue. No sale has been sent yet.');
      guard(address);
      await store.delete(key(address));
      return id;
    }
    await activity.recordAssetTransfer(
        wallet: address,
        transactionId: id,
        timestamp: DateTime.parse('${receipt['timestamp']}'),
        incoming: terms['side'] == 'buy',
        operation: {
          'kind': 'kcc20',
          'ticker': receipt['ticker'],
          'covenantId': terms['tokenId'],
          'displayAmount': terms['tokenAmount'],
          'operationLabel':
              terms['side'] == 'buy' ? 'Kasseal Buy' : 'Kasseal Sell'
        });
    final receipts = await history(address);
    receipts.removeWhere((row) => row['transactionId'] == id);
    receipts.insert(0, receipt);
    await store.write('${key(address)}_history', jsonEncode(receipts));
    await store.delete(key(address));
    return id;
  }
}
