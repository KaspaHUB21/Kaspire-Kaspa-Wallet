import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/wallet_snapshot.dart';

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
  KaspaRocketService({http.Client? client, String? apiKey})
      : _client = client ?? http.Client(),
        _apiKey = apiKey ?? _environmentKey;
  static const apiRoot = 'https://kasparocket.fun/pro-api';
  static const catalogueRoot = 'https://kasparocket.fun';
  static const origin = 'https://kaspire.kaslab.space';
  static const tokenDecimals = 3;
  static const _environmentKey = String.fromEnvironment('KASPAROCKET_API_KEY');
  final String _apiKey;
  final http.Client _client;
  Map<String, String> get _headers => {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'Origin': origin,
        'User-Agent': 'Kaspire-Android/KaspaRocket-test',
        if (_apiKey.isNotEmpty) 'Authorization': 'Bearer $_apiKey',
      };

  Future<Object?> _request(String method, Uri uri,
      {Map<String, Object?>? body, bool retry = true}) async {
    if (_apiKey.isEmpty) {
      throw StateError('This test build has no KaspaRocket SDK key.');
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
            throw StateError(
                'The live pool or wallet balance changed. Refresh the quote and try again.');
          }
          throw StateError('KaspaRocket: ${message ?? response.statusCode}');
        }
        return decoded;
      } catch (_) {
        if (!retry || attempt == 1) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
    }
    throw StateError('KaspaRocket request failed.');
  }

  Future<List<KaspaRocketToken>> tokens() async {
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
        priceKas: priceSompi == null ? null : priceSompi / 100000000,
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
    final summary =
        rawSummary is Map ? rawSummary.cast<String, Object?>() : null;
    return {
      ...plan,
      if (summary != null)
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
      'profile': 'kasparocket-testnet-v1',
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
