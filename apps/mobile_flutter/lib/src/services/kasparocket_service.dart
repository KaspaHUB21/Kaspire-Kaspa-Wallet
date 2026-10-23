import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/wallet_snapshot.dart';
import 'encrypted_store.dart';
import 'kaspa_api.dart';
import 'activity_store.dart';
import 'kron_dex_service.dart';
import 'swap_conflict_lookup.dart';
import '../kaspa_address.dart';
import 'kcc20_compound.dart';
import 'kcc20_standard_service.dart';

class KaspaRocketConflict extends StateError {
  KaspaRocketConflict(this.detail)
      : super(
            'The swap could not use the current pool or wallet state. $detail');
  final String detail;
}

class KaspaRocketQuoteExpired extends StateError {
  KaspaRocketQuoteExpired()
      : super(
            'The pool changed before this swap executed. The obsolete swap was archived. Refresh the quote to try again.');
}

class KaspaRocketToken {
  const KaspaRocketToken(
      {required this.tokenId,
      required this.ticker,
      required this.name,
      required this.image,
      required this.description,
      this.priceKas,
      this.marketCapKas,
      this.volume24hKas,
      this.change24h,
      this.poolValueKas,
      this.phase});
  final String tokenId, ticker, name, image, description;
  final double? priceKas, marketCapKas, volume24hKas, change24h, poolValueKas;
  final String? phase;
}

class KaspaRocketService {
  KaspaRocketService(
      {http.Client? client,
      String? apiKey,
      this.mainnet = false,
      EncryptedStore? store})
      : _client = client ?? http.Client(),
        _store = store ?? const KeystoreEncryptedStore(),
        _apiKey = apiKey ?? _environmentKey;
  final bool mainnet;
  final EncryptedStore _store;
  String _pendingKey(String address) =>
      'kasparocket_swap_v1_${networkId}_$address';
  Future<Map<String, Object?>?> pending(String address) async {
    final text = await _store.read(_pendingKey(address));
    return text == null
        ? null
        : (jsonDecode(text) as Map).cast<String, Object?>();
  }

  Future<void> retain(String address, Map<String, Object?> receipt) =>
      _store.write(_pendingKey(address), jsonEncode(receipt));

  /// A missing transaction/UTXO is NOT proof of failure. Only a different,
  /// accepted own-node transaction spending the exact input can retire a swap.
  /// A plan with an already completed leg must remain recoverable, not restart.
  Future<bool> retireConflictedSwap(String address,
      {Future<bool> Function(String)? accepted,
      Future<String?> Function(Map<String, Object?>, Set<String>)?
          conflict}) async {
    final receipt = await pending(address);
    if (receipt == null ||
        receipt['network'] != networkId ||
        receipt['address'] != address ||
        receipt['next'] != 0) {
      return false;
    }
    final ids = (receipt['transactionIds'] as List).cast<String>();
    final transactions = (receipt['signed'] as List).whereType<Map>().toList();
    if (ids.isEmpty || ids.length != transactions.length) return false;
    final check = accepted ?? KaspaApi().kcc20PlanTransactionAccepted;
    if (await check(ids.first)) return false;
    final competing = await (conflict ?? _confirmedConflictingSpend)(
        transactions.first.cast<String, Object?>(), ids.toSet());
    if (competing == null || ids.contains(competing)) return false;
    // Recheck after obtaining the proof, including older recovery journals.
    if (await check(ids.first)) return false;
    await _store.write(
        '${_pendingKey(address)}_last_obsolete',
        jsonEncode({
          ...receipt,
          'retiredReason': 'confirmed-conflicting-spend',
          'conflictingTransactionId': competing,
          'retiredAt': DateTime.now().toIso8601String(),
        }));
    await _store.delete(_pendingKey(address));
    return true;
  }

  Future<String?> _confirmedConflictingSpend(
      Map<String, Object?> tx, Set<String> savedIds) async {
    if (!mainnet) return null;
    const node = 'https://kaspire.kaslab.space/api/local-node';
    Future<Object?> read(String url) async {
      final response =
          await _client.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
      if (response.statusCode == 404) return null;
      if (response.statusCode != 200) {
        throw StateError(
            'Own-node swap status is temporarily unavailable. The saved swap is preserved.');
      }
      return jsonDecode(response.body);
    }

    return findConfirmedSwapConflict(
        tx: tx, savedIds: savedIds, node: node, prefix: 'kaspa:', read: read);
  }

  /// Reuse the same strict own-node UTXO/origin checks as the existing DEX.
  /// Planned child inputs must match a preceding locally reviewed output.
  Future<void> verifyInputs(List<Map<String, Object?>> requests,
      List<Map<String, Object?>> reviews) async {
    if (!mainnet) return;
    final parents = <String, Map>{};
    for (var i = 0; i < requests.length; i++) {
      final tx = jsonDecode(requests[i]['txJsonString'] as String) as Map;
      final inputs = (tx['inputs'] as List).whereType<Map>().toList();
      final reviewed = (reviews[i]['inputs'] as List).whereType<Map>().toList();
      final external = <Map>[];
      final addresses = <String>[];
      for (var j = 0; j < inputs.length; j++) {
        final input = inputs[j], embedded = input['utxo'] as Map;
        final parent = parents['${input['transactionId']}:${input['index']}'];
        if (parent != null) {
          if (parent['amountSompi'].toString() !=
                  embedded['amount'].toString() ||
              parent['scriptPublicKey'] != embedded['scriptPublicKey'] ||
              parent['covenantId'] != embedded['covenantId']) {
            throw StateError(
                'KaspaRocket child input differs from the locally reviewed parent.');
          }
        } else {
          external.add(input);
          final address = reviewed[j]['address'];
          if (address is! String) {
            throw StateError(
                'Cannot independently verify the swap input address.');
          }
          addresses.add(address);
        }
      }
      if (external.isNotEmpty) {
        await KronDexService(client: _client).verifyInputs({
          'txJsonString': jsonEncode({...tx, 'inputs': external}),
          'tradeSummary': {'inputAddresses': addresses},
        });
      }
      for (final output in (reviews[i]['outputs'] as List).whereType<Map>()) {
        parents['${reviews[i]['transactionId']}:${output['index']}'] = output;
      }
    }
  }

  Future<Map<String, Object?>> resume(String address,
      {Future<bool> Function(String)? accepted,
      Future<String?> Function(Map<String, Object?>, Set<String>)? conflict,
      bool checkConflict = true,
      ActivityStore? activity}) async {
    final receipt = await pending(address);
    if (receipt == null ||
        receipt['network'] != networkId ||
        receipt['address'] != address) {
      throw StateError('No saved swap for this wallet and network.');
    }
    Future<bool> retireOrKeep() async {
      try {
        return await retireConflictedSwap(address,
            accepted: accepted, conflict: conflict);
      } on SwapConflictUnknown {
        return false;
      } // Never replace an uncertain payment; exact bytes may be retried.
    }

    if (checkConflict && await retireOrKeep()) {
      throw KaspaRocketQuoteExpired();
    }
    final transactions = (receipt['signed'] as List).whereType<Map>().toList();
    final ids = (receipt['transactionIds'] as List).cast<String>();
    final receipts = (receipt['receipts'] as List).toList();
    final check = accepted ?? KaspaApi().kcc20PlanTransactionAccepted;
    for (var i = (receipt['next'] as num).toInt();
        i < transactions.length;
        i++) {
      // Confirm before any replay; a timeout never permits a new payment.
      if (!await check(ids[i])) {
        await verifyNetwork();
        Map<String, Object?> result;
        try {
          result = await submit(transactions[i].cast<String, Object?>(),
              orderRow: i == transactions.length - 1 && receipt['order'] is Map
                  ? (receipt['order'] as Map).cast<String, Object?>()
                  : null);
        } on KaspaRocketConflict {
          if (await retireOrKeep()) {
            throw KaspaRocketQuoteExpired();
          }
          rethrow;
        }
        receipts.add(result);
        receipt['receipts'] = receipts;
        await retain(address, receipt);
        var confirmed = false;
        for (var attempt = 0; attempt < 12; attempt++) {
          if (await check(ids[i])) {
            confirmed = true;
            break;
          }
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        if (!confirmed) {
          throw StateError(
              'Swap submitted; confirmation is still pending. The signed swap is safely saved. Resume checks the same transaction, never a second purchase.');
        }
      }
      receipt['next'] = i + 1;
      await retain(address, receipt);
    }
    final summary = receipt['summary'] as Map;
    await (activity ?? ActivityStore()).recordAssetTransfer(
        wallet: address,
        transactionId: ids.last,
        timestamp: DateTime.parse(receipt['timestamp'] as String),
        incoming: receipt['side'] == 'buy',
        operation: {
          'kind': 'kcc20',
          'ticker': receipt['token'],
          'covenantId': receipt['tokenCovenant'],
          'displayAmount': amountTokensDisplay(summary),
          'operationLabel':
              receipt['side'] == 'buy' ? 'KaspaRocket Buy' : 'KaspaRocket Sell',
        });
    await _store.delete(_pendingKey(address));
    return receipt;
  }

  String get apiRoot => mainnet
      ? 'https://kaspire.kaslab.space/api/kasparocket/pro-api'
      : 'https://kasparocket.fun/pro-api';
  String get catalogueRoot => mainnet
      ? 'https://kaspire.kaslab.space/api/kasparocket'
      : 'https://kasparocket.fun';
  String get networkId => mainnet ? 'mainnet' : 'testnet-10';
  Future<void>? _networkCheck;

  Future<void> verifyNetwork() => _networkCheck ??= _verifyNetwork();
  Future<void> _verifyNetwork() async {
    try {
      final result = await _request('GET', Uri.parse('$apiRoot/protocol'));
      if (result is! Map || result['network'] != networkId) {
        throw StateError(
            'KaspaRocket is not serving the selected network. Nothing was signed.');
      }
    } catch (_) {
      _networkCheck = null;
      rethrow;
    }
  }

  static const origin = 'https://kaspire.kaslab.space';
  static const tokenDecimals = 3;
  static const _environmentKey = String.fromEnvironment('KASPAROCKET_API_KEY');
  final String _apiKey;
  final http.Client _client;
  Map<String, String> get _headers => {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'Origin': origin,
        'User-Agent': 'Kaspire-Android/KaspaRocket',
        if (!mainnet && _apiKey.isNotEmpty) 'Authorization': 'Bearer $_apiKey',
      };

  Future<Object?> _request(String method, Uri uri,
      {Map<String, Object?>? body, bool retry = true}) async {
    if (!mainnet && _apiKey.isEmpty) {
      throw StateError(
          'KaspaRocket connection configuration is missing. Please install the latest official Kaspire update.');
    }
    for (var attempt = 0; attempt < (retry ? 2 : 1); attempt++) {
      try {
        final response = method == 'GET'
            ? await _client
                .get(uri, headers: _headers)
                .timeout(const Duration(seconds: 25))
            : await _client
                .post(uri, headers: _headers, body: jsonEncode(body))
                .timeout(const Duration(seconds: 40));
        final decoded = response.body.isEmpty
            ? <String, Object?>{}
            : jsonDecode(response.body);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final message = decoded is Map
              ? decoded['message'] ?? decoded['error'] ?? response.reasonPhrase
              : response.reasonPhrase;
          if (response.statusCode == 409) {
            final error = decoded is Map ? decoded['error'] : null;
            final detail =
                (error is Map ? error['message'] ?? error['detail'] : null) ??
                    (decoded is Map
                        ? decoded['message'] ?? decoded['detail']
                        : null) ??
                    message;
            throw KaspaRocketConflict(detail.toString());
          }
          throw StateError('KaspaRocket: ${message ?? response.statusCode}');
        }
        return decoded;
      } on KaspaRocketConflict {
        rethrow;
      } catch (_) {
        if (!retry || attempt == 1) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
    }
    throw StateError('KaspaRocket request failed.');
  }

  Future<List<KaspaRocketToken>> tokens() async {
    await verifyNetwork();
    final result = await Future.wait([
      _request('GET', Uri.parse('$catalogueRoot/api/tokens')),
      _request(
          'GET', Uri.parse('$catalogueRoot/api/analytics?page=1&limit=500')),
    ]);
    final analytics = (result[1] as Map)['tokens'] as List? ?? const [];
    final stats = {
      for (final raw in analytics.whereType<Map>())
        raw['token_id'].toString(): raw
    };
    final list = (result[0] as List).whereType<Map>().map((raw) {
      final id = raw['token_id'].toString(), stat = stats[id];
      return KaspaRocketToken(
          tokenId: id,
          ticker: (raw['ticker'] ?? stat?['ticker'] ?? 'TOKEN')
              .toString()
              .toUpperCase(),
          name: (raw['token_name'] ?? stat?['name'] ?? 'KaspaRocket token')
              .toString(),
          image: (raw['image_url'] ?? stat?['image'] ?? '').toString(),
          description: (raw['description'] ?? '').toString(),
          priceKas: _double(stat?['price']),
          marketCapKas: _double(stat?['marketCap']),
          volume24hKas: _double(stat?['volume24h']),
          change24h: _double(stat?['change24h']),
          poolValueKas: _double(stat?['pool_value_kas']),
          phase: stat?['phase']?.toString());
    }).toList();
    list.sort((a, b) {
      final liquidity = (b.poolValueKas ?? -1).compareTo(a.poolValueKas ?? -1);
      return liquidity != 0 ? liquidity : a.ticker.compareTo(b.ticker);
    });
    return list;
  }

  Future<String> poolCovenant(String tokenId) async {
    final raw = await _request(
        'GET', Uri.parse('$catalogueRoot/api/covenants/by-token/$tokenId'));
    for (final item in (raw as List).whereType<Map>()) {
      if (item['utxo_type'] == 'amm' &&
          item['lp_amm_covenant_id']?.toString().isNotEmpty == true) {
        return item['lp_amm_covenant_id'].toString();
      }
    }
    throw StateError('This token has no active KaspaRocket pool covenant.');
  }

  Future<Map<String, Object?>> holding(String address, String tokenId) async =>
      (await _request('GET', Uri.parse('$apiRoot/tokens/$address/$tokenId'))
              as Map)
          .cast<String, Object?>();

  /// Provider outpoints are only hints. The read-only resolver reconstructs
  /// the pinned 10x10 program and checks live full UTXOs on our own node.
  /// The native core independently rebuilds and simulates the actual payment.
  Future<Kcc20Step> signingBatch(String address, String tokenId, int amount,
      {bool fullPlan = false,
      bool Function()? isCancelled,
      void Function(String)? onProgress}) async {
    if (!mainnet ||
        !address.startsWith('kaspa:') ||
        kaspaOwnerIdFromAddress(address).isEmpty ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(tokenId) ||
        amount <= 0) {
      throw StateError(
          'Rocket token transfers require a valid Mainnet wallet and amount.');
    }
    void check() {
      if (isCancelled?.call() == true)
        throw StateError('Token preparation cancelled.');
    }

    check();
    await verifyNetwork();
    onProgress?.call('Verifying KaspaRocket token cells with the local node…');
    final uri = Uri.parse(
            'https://kaspire.kaslab.space/dex-test-v1/kasseal-mainnet/rocket-cells')
        .replace(queryParameters: {
      'address': address,
      'tokenId': tokenId,
      'amount': '$amount',
      'fullPlan': fullPlan ? '1' : '0'
    });
    final result = await _request('GET', uri);
    check();
    if (result is! Map ||
        result['network'] != 'mainnet' ||
        result['address'] != address ||
        result['tokenId'] != tokenId ||
        result['requestedAmount'] != '$amount' ||
        result['templateId'] != Kcc20StandardService.tenTemplateId ||
        result['inputLimit'] != 10 ||
        result['cells'] is! List ||
        (result['cells'] as List).isEmpty ||
        (result['cells'] as List).length > 65) {
      throw StateError(
          'Rocket signing-cell identity or configuration differs.');
    }
    int positive(Object? v) {
      final n = BigInt.tryParse('$v');
      if (n == null || n <= BigInt.zero || n > BigInt.from(0x7fffffffffffffff))
        throw StateError('Invalid Rocket cell amount.');
      return n.toInt();
    }

    final seen = <String>{}, cells = <Kcc20CellRecord>[];
    var total = BigInt.zero;
    for (final row in (result['cells'] as List)) {
      if (row is! Map) throw StateError('Invalid Rocket cell.');
      final id = '${row['transactionId']}',
          index = int.tryParse('${row['index']}'),
          daa = int.tryParse('${row['blockDaaScore']}'),
          script = '${row['scriptPublicKey']}',
          redeem = '${row['redeemScript']}';
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
          index == null ||
          index < 0 ||
          index > 0xffffffff ||
          daa == null ||
          daa < 0 ||
          !RegExp(r'^aa20[a-f0-9]{64}87$').hasMatch(script) ||
          redeem.length > 100000 ||
          !RegExp(r'^[a-f0-9]+$').hasMatch(redeem) ||
          !seen.add('$id:$index'))
        throw StateError('Malformed or duplicate Rocket signing cell.');
      final units = positive(row['tokenAmount']);
      total += BigInt.from(units);
      cells.add(Kcc20CellRecord(
          covenantId: tokenId,
          transactionId: id,
          index: index,
          valueSompi: positive(row['valueSompi']),
          blockDaaScore: daa,
          scriptPublicKey: script,
          tokenAmount: units,
          redeemScript: redeem));
    }
    final required = positive(result['requiredCells']);
    if (total > BigInt.from(0x7fffffffffffffff) ||
        required > 1000 ||
        (fullPlan && (required > 65 || total < BigInt.from(amount))) ||
        (!fullPlan && cells.length > 10))
      throw StateError('Rocket token coverage or input limit differs.');
    return Kcc20Step(
        cells,
        total < BigInt.from(amount) ? total.toInt() : amount,
        total < BigInt.from(amount),
        requiredCells: required,
        transactionCount: kcc20TransactionCount(required, 10),
        inputLimit: 10,
        templateId: Kcc20StandardService.tenTemplateId);
  }

  Future<void> waitForCell(String address, String tokenId, String transactionId,
      {bool Function()? isCancelled, void Function(String)? onProgress}) async {
    if (!mainnet || !RegExp(r'^[a-f0-9]{64}$').hasMatch(transactionId))
      throw StateError('Invalid Rocket continuation.');
    for (var attempt = 0; attempt < 30; attempt++) {
      if (isCancelled?.call() == true)
        throw StateError('Token preparation cancelled.');
      onProgress?.call(
          'Waiting for the indexed Rocket consolidation; recipient NOT paid…');
      try {
        final data = await holding(address, tokenId);
        if (data['address'] == address &&
            data['kcc20_covenant_id'] == tokenId &&
            (data['utxos'] as List? ?? const [])
                .whereType<Map>()
                .any((r) => r['transactionId'] == transactionId)) return;
      } catch (_) {
        if (isCancelled?.call() == true) rethrow;
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    throw StateError(
        'Rocket consolidation is saved but not indexed yet. Continue the saved transfer later; recipient NOT paid.');
  }

  Future<List<WalletAsset>> walletAssets(String address) async {
    final root = (await _request(
            'GET', Uri.parse('$apiRoot/tokens/${Uri.encodeComponent(address)}'))
        as Map);
    final rows = (root['tokens'] as List? ?? const [])
        .whereType<Map>()
        .map((row) => row.cast<String, Object?>())
        .toList();
    final assets = <WalletAsset>[];
    for (final row in rows) {
      final tokenId = row['kcc20_covenant_id']?.toString().toLowerCase() ?? '';
      final raw = BigInt.tryParse(row['balance_tokens']?.toString() ?? '');
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(tokenId) ||
          raw == null ||
          raw <= BigInt.zero) {
        continue;
      }
      const decimals = tokenDecimals;
      final divisor = BigInt.from(10).pow(decimals).toDouble();
      final priceSompi = _double(row['price_sompi']);
      assets.add(WalletAsset(
        symbol: (row['ticker'] ?? 'KCC20').toString().toUpperCase(),
        balance: raw.toDouble() / divisor,
        kind: 'KCC20',
        imageUrl: row['image_url']?.toString(),
        id: tokenId,
        decimals: decimals,
        rawBalance: raw.toString(),
        // SDK prices are per raw unit; balances/display use three decimals.
        priceKas: priceSompi == null ? null : priceSompi * divisor / 100000000,
        covenantId: tokenId,
        validationStatus: 'kasparocket-indexed',
        discoveryComplete: false,
        standard: 'kasparocket-kcc20',
      ));
    }
    assets.sort((a, b) {
      final ticker = a.symbol.compareTo(b.symbol);
      return ticker != 0
          ? ticker
          : (a.covenantId ?? '').compareTo(b.covenantId ?? '');
    });
    return assets;
  }

  Future<Map<String, Object?>> quote(
      {required String tokenId,
      required String poolId,
      required String side,
      required String rawAmount}) async {
    final quote =
        (await _request('POST', Uri.parse('$apiRoot/pool/quote'), body: {
      'lp_covenant_id': poolId,
      'kcc20_covenant_id': tokenId,
      'direction': side,
      if (side == 'buy') 'kas_budget_sompi': rawAmount,
      if (side == 'sell') 'amount_tokens': rawAmount,
    }) as Map)
            .cast<String, Object?>();
    return {
      ...quote,
      'amountTokensDisplay': amountTokensDisplay(quote),
    };
  }

  Map<String, Object?> _tradeBody(
          {required String address,
          required String tokenId,
          required String poolId,
          required String side,
          required String rawAmount,
          Object? expected}) =>
      {
        'address': address,
        'lp_covenant_id': poolId,
        'kcc20_covenant_id': tokenId,
        'side': side,
        'kind': 'market',
        if (side == 'buy') 'budget_sompi': rawAmount,
        if (side == 'sell') 'tokens': rawAmount,
        'max_fills': 3,
        'attendu': expected,
        'apres_tx': null,
      };

  Future<Map<String, Object?>> plan(
      {required String address,
      required String tokenId,
      required String poolId,
      required String side,
      required String rawAmount}) async {
    await verifyNetwork();
    if (!address.startsWith(mainnet ? 'kaspa:' : 'kaspatest:')) {
      throw StateError(
          'The wallet address does not match the KaspaRocket network.');
    }
    final base = _tradeBody(
        address: address,
        tokenId: tokenId,
        poolId: poolId,
        side: side,
        rawAmount: rawAmount);
    final route =
        (await _request('POST', Uri.parse('$apiRoot/route'), body: base) as Map)
            .cast<String, Object?>();
    final plan = (await _request('POST', Uri.parse('$apiRoot/plan/trade'),
            body: _tradeBody(
                address: address,
                tokenId: tokenId,
                poolId: poolId,
                side: side,
                rawAmount: rawAmount,
                expected: route['attendu']),
            retry: false) as Map)
        .cast<String, Object?>();
    final rawSummary = plan['summary'];
    if (plan['networkId'] != null && plan['networkId'] != networkId) {
      throw StateError(
          'KaspaRocket returned a plan for another network. Nothing was signed.');
    }
    final summary =
        rawSummary is Map ? rawSummary.cast<String, Object?>() : null;
    if (summary == null ||
        summary['direction'] != side ||
        (plan['transactions'] as List? ?? const []).isEmpty ||
        BigInt.parse((side == 'buy'
                    ? summary['kasFlowSompi']
                    : summary['amountTokens'])
                .toString()) >
            BigInt.parse(rawAmount)) {
      throw StateError(
          'KaspaRocket plan differs from the requested trade. Nothing was signed.');
    }
    return {
      ...plan,
      'summary': {
        ...summary,
        'amountTokensDisplay': amountTokensDisplay(summary),
      },
      'route': route,
    };
  }

  Map<String, Object?> signingRequest(
      {required String address,
      required KaspaRocketToken token,
      required String poolId,
      required String side,
      required Map<String, Object?> summary,
      required Map<String, Object?> planned}) {
    final tx = (planned['tx'] as Map).cast<String, Object?>();
    final instructions = (planned['signingInstructions'] as List)
        .whereType<Map>()
        .map((v) => v.cast<String, Object?>());
    final signInputs = <Map<String, Object?>>[],
        scripts = <Map<String, Object?>>[];
    for (final item in instructions) {
      final kind = item['kind'], index = (item['inputIndex'] as num).toInt();
      if (kind == 'p2pkh') {
        signInputs.add({
          'index': index,
          'sighashType': 1,
          'expectedSighash': item['sighash']
        });
      } else if (kind == 'covenant-leader') {
        scripts.add({
          'inputIndex': index,
          'scriptHex': '',
          'signType': 1,
          'prebuiltSignatureScript': item['sigscript'],
          'signatureOffsets': item['sigOffsets'],
          'expectedSighash': item['sighash']
        });
      } else if (kind != 'final') {
        throw StateError('Unsupported KaspaRocket signing instruction: $kind');
      }
    }
    return {
      'sender': address,
      'profile': mainnet ? 'kasparocket-mainnet-v1' : 'kasparocket-testnet-v1',
      'tokenId': token.tokenId,
      'lpCovenantId': poolId,
      'ticker': token.ticker,
      'side': side,
      'tradeSummary': summary,
      'txJsonString': jsonEncode(_normalizeTransaction(tx)),
      'signInputs': signInputs,
      'scripts': scripts
    };
  }

  Map<String, Object?> _normalizeTransaction(Map<String, Object?> tx) {
    final providerTransactionId = tx['id']?.toString();
    if (providerTransactionId != null &&
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(providerTransactionId)) {
      throw StateError(
          'KaspaRocket returned an invalid provider transaction ID.');
    }

    String encodeScript(Object? raw) {
      final item = (raw as Map).cast<String, Object?>();
      return (item['version'] as num)
              .toInt()
              .toRadixString(16)
              .padLeft(4, '0') +
          item['script'].toString();
    }

    final inputs = (tx['inputs'] as List).whereType<Map>().map((raw) {
      final item = raw.cast<String, Object?>(),
          outpoint = (item['previousOutpoint'] as Map).cast<String, Object?>(),
          utxo = (item['utxo'] as Map).cast<String, Object?>();
      return {
        'transactionId': outpoint['transactionId'],
        'index': outpoint['index'],
        'sequence': item['sequence'],
        'computeBudget': item['computeBudget'],
        'signatureScript': item['signatureScript'] ?? '',
        'utxo': {
          ...utxo,
          'scriptPublicKey': encodeScript(utxo['scriptPublicKey'])
        }
      };
    }).toList();
    final outputs = (tx['outputs'] as List).whereType<Map>().map((raw) {
      final item = raw.cast<String, Object?>();
      return {
        ...item,
        'scriptPublicKey': encodeScript(item['scriptPublicKey'])
      };
    }).toList();
    final normalized = <String, Object?>{
      ...tx,
      'inputs': inputs,
      'outputs': outputs,
      'storageMass': tx['storageMass'] ?? tx['mass'] ?? 0
    };
    // KaspaRocket's plan ID is provider metadata and may be calculated before
    // its version-1 covenant scripts are finalized. Rusty Kaspa recomputes the
    // consensus transaction ID locally, while the provider value remains
    // review-bound metadata. Expected sighashes are still checked natively for
    // every input Kaspire signs.
    normalized.remove('id');
    if (providerTransactionId != null) {
      normalized['providerTransactionId'] = providerTransactionId.toLowerCase();
    }
    return normalized;
  }

  Map<String, Object?> mergeSignedTransaction(
      Map<String, Object?> original, String signedSafeJson) {
    final signed = (jsonDecode(signedSafeJson) as Map).cast<String, Object?>();
    final result = Map<String, Object?>.from(original);
    final originalInputs = (original['inputs'] as List)
        .whereType<Map>()
        .map((v) => Map<String, Object?>.from(v))
        .toList();
    final signedInputs = (signed['inputs'] as List).whereType<Map>().toList();
    if (originalInputs.length != signedInputs.length) {
      throw StateError('Signed transaction input count changed.');
    }
    for (var index = 0; index < originalInputs.length; index++) {
      originalInputs[index]['signatureScript'] =
          signedInputs[index]['signatureScript'];
    }
    result['inputs'] = originalInputs;
    return result;
  }

  Future<Map<String, Object?>> submit(Map<String, Object?> tx,
          {Map<String, Object?>? orderRow}) async =>
      (await _request('POST', Uri.parse('$apiRoot/submit'),
              body: {
                'transactions': [tx],
                if (orderRow != null) 'order_row': orderRow
              },
              retry: false) as Map)
          .cast<String, Object?>();

  Future<Map<String, Object?>> activity(String address) async =>
      (await _request(
                  'GET',
                  Uri.parse(
                      '$catalogueRoot/api/activity/$address?page=1&limit=100'))
              as Map)
          .cast<String, Object?>();

  static double? _double(Object? value) => value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '');

  static String amountTokensDisplay(Map source) {
    final display =
        source['amountTokensDisplay'] ?? source['amount_tokens_display'];
    if (display != null && display.toString().trim().isNotEmpty) {
      return display.toString().trim();
    }
    final raw = source['amountTokens'] ?? source['amount_tokens'];
    return displayRaw(raw, tokenDecimals);
  }

  static String rawFromDisplay(String input, int decimals) {
    final value = input.trim();
    if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(value)) {
      throw const FormatException('Enter a positive decimal amount.');
    }
    final parts = value.split('.');
    if (parts.length == 2 && parts[1].length > decimals) {
      throw FormatException('Enter no more than $decimals decimal places.');
    }
    final scale = BigInt.from(10).pow(decimals);
    final raw = BigInt.parse(parts[0]) * scale +
        (parts.length == 2
            ? BigInt.parse(parts[1].padRight(decimals, '0'))
            : BigInt.zero);
    if (raw <= BigInt.zero) {
      throw const FormatException('Amount must be positive.');
    }
    return raw.toString();
  }

  static BigInt holdingRaw(Map<String, Object?>? holding) {
    if (holding == null) return BigInt.zero;
    for (final key in const ['balance_tokens', 'raw_balance', 'balance']) {
      final raw = BigInt.tryParse(holding[key]?.toString() ?? '');
      if (raw != null && raw >= BigInt.zero) return raw;
    }
    return BigInt.zero;
  }

  static String displayRaw(Object? value, int decimals) {
    final raw = BigInt.tryParse(value?.toString() ?? '');
    if (raw == null) return '—';
    final negative = raw.isNegative;
    final magnitude = raw.abs();
    final scale = BigInt.from(10).pow(decimals);
    final whole = magnitude ~/ scale;
    final fraction = (magnitude % scale)
        .toString()
        .padLeft(decimals, '0')
        .replaceFirst(RegExp(r'0+$'), '');
    return '${negative ? '-' : ''}$whole${fraction.isEmpty ? '' : '.$fraction'}';
  }
}
