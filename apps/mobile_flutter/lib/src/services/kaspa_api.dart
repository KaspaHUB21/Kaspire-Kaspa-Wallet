import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/wallet_snapshot.dart';
import '../kaspa_address.dart';
import '../number_format.dart';
import 'network_settings.dart';

class KaspaApiException implements Exception {
  KaspaApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class KaspaApi {
  KaspaApi({
    http.Client? client,
    String? baseUrl,
    this.tokenExplorerBaseUrl = 'https://kaspatoken.kaslab.space/api',
    this.nftMetadataBaseUrl = 'https://api.kaspa.com',
    this.kcc20IndexerBaseUrl = 'https://kcc20.info',
    this.kascovBaseUrl = 'https://kascov.io/data/mainnet',
    this.toccataBroadcastUrl =
        'https://gothdag.kaslab.space/api/covenant-broadcast',
  })  : _baseUrlOverride = baseUrl,
        _client = client ?? http.Client();

  final http.Client _client;
  final String? _baseUrlOverride;
  String get baseUrl => _baseUrlOverride ?? NetworkSettings.kaspaRestUrl;
  final String tokenExplorerBaseUrl;
  final String nftMetadataBaseUrl;
  final String kcc20IndexerBaseUrl;
  final String kascovBaseUrl;
  final String toccataBroadcastUrl;

  Future<WalletSnapshot> loadWallet(
    String address, {
    int transactionLimit = 20,
  }) async {
    final results = await Future.wait([
      _get('/addresses/${Uri.encodeComponent(address)}/balance'),
      _get('/info/price'),
      _get(
        '/addresses/${Uri.encodeComponent(address)}/full-transactions?limit=$transactionLimit&offset=0&resolve_previous_outpoints=light',
      ),
      _loadTokenWallet(address).catchError((_) => null),
      _loadKcc20Wallet(address)
          .then<Object?>((value) => value)
          .catchError((_) => null),
      loadUtxos(address).catchError((_) => '[]'),
    ]);
    final balanceJson = results[0];
    final priceJson = results[1];
    final transactionJson = results[2];
    final tokenWallet = results[3];
    final kcc20Wallet = results[4] as _Kcc20Wallet?;
    final utxoCount = (jsonDecode(results[5] as String) as List).length;
    final assets = _parseAssets(tokenWallet);
    final nativeTransactions = parseTransactions(transactionJson, address);
    final tokenTransactions = _parseTokenTransactions(tokenWallet, address);
    final krc20 = await Future.wait(
      assets.krc20.map(_withTokenImage),
    );
    final assetWarnings = <String>[
      if (tokenWallet == null)
        'KRC-20, KRC-721 and KNS data is temporarily unavailable.',
      if (kcc20Wallet == null)
        'KCC20 covenant data is temporarily unavailable.',
      if (kcc20Wallet != null && kcc20Wallet.warning.isNotEmpty)
        kcc20Wallet.warning,
    ];
    return WalletSnapshot(
      balanceSompi: _asInt(_map(balanceJson)['balance']),
      kasUsd: _asDouble(_map(priceJson)['price']),
      transactions: [
        ...nativeTransactions,
        ...tokenTransactions,
        ...?kcc20Wallet?.transactions,
      ]..sort((a, b) => b.timestamp.compareTo(a.timestamp)),
      krc20Tokens: krc20,
      kcc20Tokens: kcc20Wallet?.assets ?? const [],
      krc721Collections: assets.krc721,
      knsDomains: assets.domains,
      assetWarning: assetWarnings.isEmpty ? null : assetWarnings.join(' '),
      hasMoreTransactions: nativeTransactions.length >= transactionLimit,
      utxoCount: utxoCount,
    );
  }

  Future<String> resolveWalletInput(String input) async {
    final normalized = input.trim().toLowerCase();
    if (RegExp(r'^kaspa:[a-z0-9]{61,63}$').hasMatch(normalized)) {
      return normalized;
    }
    if (!RegExp(r'^[a-z0-9-]+\.kas$').hasMatch(normalized)) {
      throw KaspaApiException(
          'Enter a Kaspa address or a valid name.kas domain.');
    }
    final response = _map(await _loadTokenWallet(normalized));
    final data = _map(response['data']);
    final address = (data['address'] ?? '').toString().toLowerCase();
    if (!RegExp(r'^kaspa:[a-z0-9]{61,63}$').hasMatch(address)) {
      throw KaspaApiException('KNS domain not found or it has no Kaspa owner.');
    }
    return address;
  }

  Future<Object?> _loadTokenWallet(String addressOrDomain) async {
    final response = await _client
        .get(
          Uri.parse(
            '$tokenExplorerBaseUrl/wallet/krc20/${Uri.encodeComponent(addressOrDomain)}',
          ),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KaspaApiException('Token indexer returned ${response.statusCode}');
    }
    return jsonDecode(response.body);
  }

  Future<_Kcc20Wallet> _loadKcc20Wallet(String address) async {
    try {
      return await _loadKcc20WalletFromIndexer(address);
    } catch (_) {
      return _loadKcc20WalletFromKascov(
        address,
        warning:
            'The primary KCC20 indexer is unavailable; Kaspire is using Kascov fallback data.',
      );
    }
  }

  Future<_Kcc20Wallet> _loadKcc20WalletFromIndexer(String address) async {
    final pubkey = kaspaOwnerIdFromAddress(address);
    if (pubkey.isEmpty) {
      throw KaspaApiException('The wallet is not a valid Kaspa P2PK address.');
    }
    final status = _map(await _kcc20IndexerGet('/v1/status'));
    final capabilities = _map(status['capabilities']);
    if (capabilities['balances'] != true ||
        capabilities['owner_history'] != true ||
        capabilities['signing_data'] != true) {
      throw KaspaApiException(
        'The primary KCC20 indexer does not expose complete owner data.',
      );
    }
    final balances = await _loadKcc20OwnerBalances(pubkey);
    final cellData = _map(await _kcc20IndexerGet(
      '/v1/owners/$pubkey/cells?signing_ready=true&limit=1000',
    ));
    final historyData = _map(
      await _kcc20IndexerGet('/v1/owners/$pubkey/history?limit=200'),
    );
    final history = (historyData['history'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, Object?>())
        .toList();
    final tipDaa = _asInt(status['max_daa']);
    final tipAtMs = DateTime.now().millisecondsSinceEpoch;
    final details = await Future.wait(balances.map((balanceRow) async {
      final primary = await _tryLoadKcc20TokenFromIndexer(
        balanceRow,
        pubkey,
        address: address,
        cellData: cellData,
        history: history,
        tipDaa: tipDaa,
        tipAtMs: tipAtMs,
      );
      if (primary.asset != null && !primary.discoveryLimited) return primary;
      final tokenId = balanceRow['token_id']?.toString().toLowerCase() ?? '';
      final fallback = await _tryLoadKcc20Token(
        {
          'covenant_id': tokenId,
          'status': 'verified',
          'claimed_ticker': primary.asset?.symbol,
          'claimed_image': primary.asset?.imageUrl,
        },
        pubkey,
        tipDaa: tipDaa,
        tipAtMs: tipAtMs,
        expectedRawBalance: _asInt(balanceRow['balance']),
      );
      return fallback.asset != null && !fallback.sourceMismatch
          ? fallback
          : primary;
    }));
    final limited = details.any((item) =>
        item.asset == null || item.discoveryLimited || item.sourceMismatch);
    return _Kcc20Wallet(
      assets:
          details.map((item) => item.asset).whereType<WalletAsset>().toList(),
      transactions: details.expand((item) => item.transactions).toList()
        ..sort((a, b) => b.timestamp.compareTo(a.timestamp)),
      warning: [
        if (limited)
          'Some KCC20 balances could not be mapped to complete signing cells.',
      ].join(' '),
    );
  }

  Future<List<Map<String, Object?>>> _loadKcc20OwnerBalances(
    String pubkey,
  ) async {
    final balances = <Map<String, Object?>>[];
    String? cursor;
    for (var page = 0; page < 8; page++) {
      final suffix = cursor == null
          ? '?limit=1000'
          : '?limit=1000&after_token_id=${Uri.encodeQueryComponent(cursor)}';
      final response = _map(
        await _kcc20IndexerGet('/v1/owners/$pubkey/balances$suffix'),
      );
      balances.addAll(
        (response['balances'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => item.cast<String, Object?>())
            .where((item) =>
                item['validation_status']?.toString() == 'verified' &&
                _asInt(item['unresolved_cells']) == 0 &&
                _asInt(item['balance']) > 0),
      );
      final next = response['next_cursor']?.toString();
      if (next == null || next.isEmpty || next == cursor) return balances;
      cursor = next;
    }
    throw KaspaApiException(
      'The primary KCC20 owner-balance pagination limit was exceeded.',
    );
  }

  Future<_Kcc20TokenResult> _tryLoadKcc20TokenFromIndexer(
    Map<String, Object?> balanceRow,
    String pubkey, {
    required String address,
    required Map<String, Object?> cellData,
    required List<Map<String, Object?>> history,
    required int tipDaa,
    required int tipAtMs,
  }) async {
    try {
      final tokenId = balanceRow['token_id']?.toString().toLowerCase() ?? '';
      final rawBalance = _asInt(balanceRow['balance']);
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(tokenId) || rawBalance <= 0) {
        return const _Kcc20TokenResult();
      }
      final token = _map(await _kcc20IndexerGet('/v1/tokens/$tokenId'));
      if (token['validation_status']?.toString() != 'verified' ||
          _asInt(token['unresolved_cells']) > 0) {
        return const _Kcc20TokenResult(discoveryLimited: true);
      }
      final decimals =
          _asInt(token['decimals'] ?? token['claimed_decimals'] ?? 8);
      final ticker = (token['ticker'] ??
              token['claimed_name'] ??
              token['name'] ??
              token['fallback_name'] ??
              'KCC20')
          .toString()
          .toUpperCase();
      final cells = <Kcc20CellRecord>[];
      var templateHash =
          (token['template_hash'] ?? token['kcc1_template_hash'] ?? '')
              .toString()
              .toLowerCase();
      for (final raw
          in (cellData['cells'] as List? ?? const []).whereType<Map>()) {
        final item = raw.cast<String, Object?>();
        final covenantId =
            (item['token_id'] ?? item['covenant_id'] ?? '').toString();
        if (covenantId != tokenId || item['signing_ready'] == false) continue;
        final state = _map(item['state']);
        final stateFields = (state['state_fields'] as List? ??
                item['state_fields'] as List? ??
                const [])
            .whereType<Map>()
            .map((field) => field.cast<String, Object?>())
            .toList();
        String? stateField(String name) {
          for (final field in stateFields) {
            if (field['name']?.toString() == name) {
              return field['value']?.toString();
            }
          }
          return null;
        }

        final owner = (item['owner'] ?? stateField('owner_identifier'))
            ?.toString()
            .toLowerCase();
        if (owner != null && owner != pubkey) continue;
        final txid = (item['outpoint_tx_id'] ??
                item['transaction_id'] ??
                item['txid'] ??
                '')
            .toString();
        final index = _nullableInt(
          item['outpoint_index'] ?? item['index'] ?? item['output_index'],
        );
        final script =
            (item['script_public_key'] ?? item['script_hex'] ?? '').toString();
        final amount = _nullableInt(item['token_amount'] ?? item['amount']) ??
            _littleEndianHexInt(stateField('amount'));
        final candidateTemplate =
            (item['kcc1_template_hash'] ?? item['template_hash'] ?? '')
                .toString()
                .toLowerCase();
        if (templateHash.isEmpty && candidateTemplate.isNotEmpty) {
          templateHash = candidateTemplate;
        }
        if (txid.isEmpty ||
            index == null ||
            amount == null ||
            amount <= 0 ||
            !RegExp(r'^[0-9a-fA-F]+$').hasMatch(script)) {
          continue;
        }
        cells.add(Kcc20CellRecord(
          transactionId: txid,
          index: index,
          valueSompi: _asInt(item['value']),
          blockDaaScore: _asInt(item['created_daa']),
          scriptPublicKey: script,
          tokenAmount: amount,
          isMinter: item['is_minter'] == true,
        ));
      }
      final unmapped = (cellData['unmapped'] as List? ?? const [])
          .whereType<Map>()
          .any((item) => item['token_id']?.toString() == tokenId);
      final complete = !unmapped &&
          cells.isNotEmpty &&
          cells.fold<int>(0, (sum, cell) => sum + cell.tokenAmount) ==
              rawBalance &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(templateHash);
      final asset = WalletAsset(
        symbol: ticker,
        balance: rawBalance / _pow10(decimals),
        kind: 'KCC20',
        imageUrl: _absoluteImageUrl(token['image']?.toString()),
        id: tokenId,
        decimals: decimals,
        rawBalance: rawBalance.toString(),
        covenantId: tokenId,
        templateHash: templateHash,
        validationStatus: 'verified',
        kcc20Cells: cells,
        discoveryComplete: complete,
      );
      final transactions = history
          .where((item) =>
              (item['token_id'] ?? item['covenant_id'])?.toString() == tokenId)
          .map((item) {
        final delta =
            int.tryParse(item['balance_delta']?.toString() ?? '') ?? 0;
        final incoming = delta >= 0;
        final daa = _asInt(item['daa'] ?? item['accepting_daa']);
        final milliseconds = _asInt(item['timestamp_ms']);
        final estimatedMilliseconds =
            tipAtMs > 0 && tipDaa >= daa ? tipAtMs - ((tipDaa - daa) * 100) : 0;
        final ownerFrom = item['owner_from']?.toString().toLowerCase() ?? '';
        final ownerTo = item['owner_to']?.toString().toLowerCase() ?? '';
        final fromAddress = kaspaAddressFromOwnerId(ownerFrom);
        final toAddress = kaspaAddressFromOwnerId(ownerTo);
        return WalletTransaction(
          id: item['tx_id']?.toString() ?? 'kcc20-$tokenId-$daa',
          timestamp: DateTime.fromMillisecondsSinceEpoch(
            milliseconds > 0 ? milliseconds : estimatedMilliseconds,
          ),
          amountSompi: 0,
          incoming: incoming,
          assetKind: 'KCC20',
          assetSymbol: ticker,
          displayAmount: formatRawTokenAmount(
            BigInt.from(delta.abs()),
            decimals,
          ),
          counterparty: incoming
              ? (fromAddress.isEmpty ? ownerFrom : fromAddress)
              : (toAddress.isEmpty ? ownerTo : toAddress),
          from: [
            if (ownerFrom.isNotEmpty)
              TransactionParty(address: fromAddress, ownerId: ownerFrom),
            if (ownerFrom.isEmpty && !incoming)
              TransactionParty(address: address, ownerId: pubkey),
          ],
          to: [
            if (ownerTo.isNotEmpty)
              TransactionParty(address: toAddress, ownerId: ownerTo),
            if (ownerTo.isEmpty && incoming)
              TransactionParty(address: address, ownerId: pubkey),
          ],
          status: TransactionStatus.confirmed,
        );
      }).toList();
      return _Kcc20TokenResult(
        asset: asset,
        transactions: transactions,
        discoveryLimited: !complete,
      );
    } catch (_) {
      return const _Kcc20TokenResult(discoveryLimited: true);
    }
  }

  Future<_Kcc20Wallet> _loadKcc20WalletFromKascov(
    String address, {
    String warning = '',
  }) async {
    final addressData = _map(await _kascovGet(
      '/addr/${Uri.encodeComponent(address)}.json',
    ));
    final pubkey = (addressData['pubkey'] ?? '').toString().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(pubkey)) {
      throw KaspaApiException('Kascov did not resolve the wallet public key.');
    }
    final directory = _map(await _kascovGet('/tokens.json'));
    final rows = (directory['tokens'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, Object?>())
        .where((item) => item['status']?.toString() == 'verified')
        .take(64)
        .toList();
    final tipDaa = _asInt(directory['tip_daa']);
    final tipAtMs = _asInt(directory['tip_at_ms']);
    final details = await Future.wait(
      rows.map((row) => _tryLoadKcc20Token(
            row,
            pubkey,
            tipDaa: tipDaa,
            tipAtMs: tipAtMs,
          )),
    );
    final assets =
        details.map((item) => item.asset).whereType<WalletAsset>().toList();
    final transactions = details.expand((item) => item.transactions).toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final limited =
        rows.length >= 64 || details.any((item) => item.discoveryLimited);
    return _Kcc20Wallet(
      assets: assets,
      transactions: transactions,
      warning: [
        if (warning.isNotEmpty) warning,
        if (limited)
          'KCC20 discovery is conservative: Kascov exposes the top 100 holders per token; verify small or newly received balances before sending.',
      ].join(' '),
    );
  }

  Future<_Kcc20TokenResult> _tryLoadKcc20Token(
    Map<String, Object?> directoryRow,
    String pubkey, {
    required int tipDaa,
    required int tipAtMs,
    int? expectedRawBalance,
  }) async {
    try {
      return await _loadKcc20Token(
        directoryRow,
        pubkey,
        tipDaa: tipDaa,
        tipAtMs: tipAtMs,
        expectedRawBalance: expectedRawBalance,
      );
    } catch (_) {
      return const _Kcc20TokenResult(discoveryLimited: true);
    }
  }

  Future<_Kcc20TokenResult> _loadKcc20Token(
    Map<String, Object?> directoryRow,
    String pubkey, {
    required int tipDaa,
    required int tipAtMs,
    int? expectedRawBalance,
  }) async {
    final covenantId = directoryRow['covenant_id']?.toString() ?? '';
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(covenantId)) {
      return const _Kcc20TokenResult();
    }
    final detail = _map(await _kascovGet('/token/$covenantId'));
    final token = _map(detail['token']);
    if ((token['status'] ?? directoryRow['status'])?.toString() != 'verified') {
      return const _Kcc20TokenResult();
    }
    final balances = (detail['balances'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, Object?>())
        .toList();
    Map<String, Object?>? balanceRow;
    for (final item in balances) {
      if (item['owner']?.toString().toLowerCase() == pubkey) {
        balanceRow = item;
        break;
      }
    }
    final rawBalance = _asInt(balanceRow?['balance']);
    if (expectedRawBalance != null && rawBalance != expectedRawBalance) {
      return const _Kcc20TokenResult(sourceMismatch: true);
    }
    if (rawBalance <= 0) {
      return _Kcc20TokenResult(discoveryLimited: balances.length >= 100);
    }

    final coin = _map(await _kascovGet('/c/$covenantId.json'));
    final events = (detail['events'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, Object?>())
        .toList();
    final amountsByOutpoint = <String, int>{};
    for (final event in events) {
      if (event['owner_to']?.toString().toLowerCase() != pubkey) continue;
      final txid = event['txid']?.toString() ?? '';
      final index = _nullableInt(
        event['delta_idx'] ?? event['output_index'] ?? event['index'],
      );
      final amount = _asInt(
        event['balance_to'] ?? event['state_amount'] ?? event['amount'],
      );
      if (txid.isNotEmpty && index != null && amount > 0) {
        amountsByOutpoint['$txid:$index'] = amount;
      }
    }
    // Kascov's current coin response uses `live_utxos` as a numeric count and
    // stores the actual cell records in `utxos`. Older responses used a list
    // under `live_utxos`/`live_outputs`, so select the first list instead of
    // blindly casting the first non-null value.
    final liveRows = [
          coin['live_utxos'],
          coin['live_outputs'],
          coin['utxos'],
        ].whereType<List>().firstOrNull ??
        const [];
    final cells = <Kcc20CellRecord>[];
    for (final raw in liveRows.whereType<Map>()) {
      final item = raw.cast<String, Object?>();
      if (item['live'] == false) continue;
      final outpoint = _map(item['outpoint']);
      final outpointText =
          item['outpoint'] is String ? item['outpoint'].toString() : '';
      final outpointParts = outpointText.split(':');
      final txid = (outpoint['transaction_id'] ??
              outpoint['transactionId'] ??
              item['transaction_id'] ??
              item['txid'] ??
              (outpointParts.length == 2 ? outpointParts[0] : null) ??
              '')
          .toString();
      final index = _nullableInt(
        outpoint['index'] ??
            item['index'] ??
            item['output_index'] ??
            (outpointParts.length == 2 ? outpointParts[1] : null),
      );
      if (txid.isEmpty || index == null) continue;
      final stateFields = (item['state_fields'] as List? ?? const [])
          .whereType<Map>()
          .map((field) => field.cast<String, Object?>())
          .toList();
      String? stateField(String name) {
        for (final field in stateFields) {
          if (field['name']?.toString() == name) {
            return field['value']?.toString();
          }
        }
        return null;
      }

      final stateOwner = stateField('owner_identifier')?.toLowerCase();
      if (stateOwner != null && stateOwner != pubkey) continue;
      final tokenAmount = amountsByOutpoint['$txid:$index'] ??
          _littleEndianHexInt(stateField('amount'));
      if (tokenAmount == null || tokenAmount <= 0) continue;
      final script = (item['script_hex'] ??
              _map(item['script_public_key'])['script'] ??
              _map(item['scriptPublicKey'])['scriptPublicKey'] ??
              '')
          .toString();
      if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(script)) continue;
      cells.add(Kcc20CellRecord(
        transactionId: txid,
        index: index,
        valueSompi: _asInt(item['value'] ?? item['amount']),
        blockDaaScore: _asInt(item['created_daa'] ?? item['block_daa_score']),
        scriptPublicKey: script,
        tokenAmount: tokenAmount,
        isMinter: item['is_minter'] == true,
      ));
    }
    final fields = _map(token['fields'] ?? directoryRow['fields']);
    final decimals =
        _asInt(token['claimed_decimals'] ?? fields['decimals'] ?? 8);
    final ticker = (token['claimed_ticker'] ??
            directoryRow['claimed_ticker'] ??
            fields['tick'] ??
            token['name'] ??
            'KCC20')
        .toString()
        .toUpperCase();
    final templateHash = (coin['kcc1_template_hash'] ??
            token['template_hash'] ??
            directoryRow['template_hash'] ??
            '')
        .toString()
        .toLowerCase();
    final complete = cells.isNotEmpty &&
        coin['lineage_complete'] != false &&
        cells.fold<int>(0, (sum, cell) => sum + cell.tokenAmount) ==
            rawBalance &&
        RegExp(r'^[0-9a-f]{64}$').hasMatch(templateHash);
    final divisor = _pow10(decimals);
    final asset = WalletAsset(
      symbol: ticker,
      balance: rawBalance / divisor,
      kind: 'KCC20',
      imageUrl: _absoluteImageUrl(
        (token['claimed_image'] ?? directoryRow['claimed_image'])?.toString(),
      ),
      id: covenantId,
      decimals: decimals,
      rawBalance: rawBalance.toString(),
      covenantId: covenantId,
      templateHash: templateHash,
      validationStatus: 'verified',
      kcc20Cells: cells,
      discoveryComplete: complete,
    );
    final transactions = events
        .where((event) =>
            event['owner_from']?.toString().toLowerCase() == pubkey ||
            event['owner_to']?.toString().toLowerCase() == pubkey)
        .map((event) {
      final incoming = event['owner_to']?.toString().toLowerCase() == pubkey;
      final daa = _asInt(event['accepting_daa']);
      final milliseconds = _asInt(event['timestamp_ms']);
      final estimatedMilliseconds =
          tipAtMs > 0 && tipDaa >= daa ? tipAtMs - ((tipDaa - daa) * 100) : 0;
      final ownerFrom = event['owner_from']?.toString().toLowerCase() ?? '';
      final ownerTo = event['owner_to']?.toString().toLowerCase() ?? '';
      final fromAddress = kaspaAddressFromOwnerId(ownerFrom);
      final toAddress = kaspaAddressFromOwnerId(ownerTo);
      return WalletTransaction(
        id: event['txid']?.toString() ?? 'kcc20-$covenantId-$daa',
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          milliseconds > 0 ? milliseconds : estimatedMilliseconds,
        ),
        amountSompi: 0,
        incoming: incoming,
        assetKind: 'KCC20',
        assetSymbol: ticker,
        displayAmount: formatRawTokenAmount(
          BigInt.from(_asInt(event['amount'])),
          decimals,
        ),
        counterparty: incoming
            ? (fromAddress.isEmpty ? ownerFrom : fromAddress)
            : (toAddress.isEmpty ? ownerTo : toAddress),
        from: [
          if (ownerFrom.isNotEmpty)
            TransactionParty(
              address: fromAddress,
              ownerId: ownerFrom,
            ),
        ],
        to: [
          if (ownerTo.isNotEmpty)
            TransactionParty(
              address: toAddress,
              ownerId: ownerTo,
            ),
        ],
        status: TransactionStatus.confirmed,
      );
    }).toList();
    return _Kcc20TokenResult(
      asset: asset,
      transactions: transactions,
      discoveryLimited: balances.length >= 100 || !complete,
    );
  }

  Future<Object?> _kascovGet(String path) async {
    final response = await _client
        .get(Uri.parse('$kascovBaseUrl$path'))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KaspaApiException('Kascov returned ${response.statusCode}');
    }
    return jsonDecode(response.body);
  }

  Future<Object?> _kcc20IndexerGet(String path) async {
    final response = await _client
        .get(Uri.parse('$kcc20IndexerBaseUrl$path'))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KaspaApiException(
        'Primary KCC20 indexer returned ${response.statusCode}',
      );
    }
    return jsonDecode(response.body);
  }

  Future<Map<String, Object?>> preflightKcc20(String transactionJson) async {
    final response = await _client
        .post(
          Uri.parse('$kascovBaseUrl/preflight'),
          headers: const {'content-type': 'application/json'},
          body: transactionJson,
        )
        .timeout(const Duration(seconds: 25));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KaspaApiException(
        'Kascov preflight failed (${response.statusCode}): ${response.body}',
      );
    }
    return _map(jsonDecode(response.body));
  }

  Future<WalletAsset> _withTokenImage(WalletAsset asset) async {
    if (asset.imageUrl != null || asset.id == null) return asset;
    try {
      final response = await _client
          .get(Uri.parse('$tokenExplorerBaseUrl/token/${asset.id}'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode < 200 || response.statusCode >= 300) return asset;
      final data = _map(_map(jsonDecode(response.body))['data']);
      final imageUrl = _absoluteImageUrl(data['image_url']?.toString());
      return WalletAsset(
        symbol: asset.symbol,
        balance: asset.balance,
        kind: asset.kind,
        imageUrl: imageUrl,
        id: asset.id,
        decimals: asset.decimals,
        rawBalance: asset.rawBalance,
      );
    } catch (_) {
      return asset;
    }
  }

  Future<NftCollectionPage> loadNftCollection(
    String address,
    String ticker, {
    int offset = 0,
  }) async {
    final response = await _client
        .get(
          Uri.parse(
            '$tokenExplorerBaseUrl/wallet/krc20/${Uri.encodeComponent(address)}/krc721/${Uri.encodeComponent(ticker)}?limit=48&offset=$offset',
          ),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KaspaApiException('NFT indexer returned ${response.statusCode}');
    }
    final data = _map(_map(jsonDecode(response.body))['data']);
    final nfts = (data['nfts'] as List? ?? const [])
        .whereType<Map>()
        .map((item) {
          final map = item.cast<String, Object?>();
          return WalletNft(
            ticker: (map['ticker'] ?? ticker).toString().toUpperCase(),
            tokenId: (map['token_id'] ?? '').toString(),
            imageUrl: _absoluteImageUrl(map['image_url']?.toString()),
            rarityRank: _nullableInt(map['rarity_rank']),
            nexusUrl: map['nexus_url']?.toString(),
          );
        })
        .where((nft) => nft.tokenId.isNotEmpty)
        .toList();
    final ranks = await _loadNftRanks(
      (data['ticker'] ?? ticker).toString(),
      nfts.map((nft) => nft.tokenId).toList(),
    );
    final rankedNfts = nfts
        .map(
          (nft) => WalletNft(
            ticker: nft.ticker,
            tokenId: nft.tokenId,
            imageUrl: nft.imageUrl,
            rarityRank: nft.rarityRank ?? ranks[nft.tokenId],
            nexusUrl: nft.nexusUrl,
          ),
        )
        .toList();
    return NftCollectionPage(
      ticker: (data['ticker'] ?? ticker).toString().toUpperCase(),
      total: _asInt(data['total']),
      nfts: rankedNfts,
      nextOffset: _nullableInt(data['next_offset']),
    );
  }

  Future<Map<String, int>> _loadNftRanks(
    String ticker,
    List<String> tokenIds,
  ) async {
    if (tokenIds.isEmpty) return const {};
    try {
      final response = await _client
          .post(
            Uri.parse('$nftMetadataBaseUrl/krc721/tokens'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({
              'ticker': ticker.toUpperCase(),
              'limit': tokenIds.length,
              'offset': 0,
              'sortField': 'tokenId',
              'sortDirection': 'asc',
              'traits': <String, Object?>{},
              'tokenIds': tokenIds,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const {};
      }
      final data = _map(jsonDecode(response.body));
      return Map.fromEntries(
        (data['items'] as List? ?? const []).whereType<Map>().map((item) {
          final id = (item['tokenId'] ?? '').toString();
          final rank = _nullableInt(item['rarityRank']);
          return rank == null || id.isEmpty ? null : MapEntry(id, rank);
        }).whereType<MapEntry<String, int>>(),
      );
    } catch (_) {
      return const {};
    }
  }

  _WalletAssets _parseAssets(Object? raw) {
    final data = _map(_map(raw)['data']);
    List<WalletAsset> assets(String key, String kind) {
      return (data[key] as List? ?? const [])
          .whereType<Map>()
          .map((item) {
            final map = item.cast<String, Object?>();
            return WalletAsset(
              symbol: (map['symbol'] ?? map['ticker'] ?? 'UNKNOWN')
                  .toString()
                  .toUpperCase(),
              balance: _asDouble(map['balance']) ?? 0,
              kind: kind,
              imageUrl: _absoluteImageUrl(map['image_url']?.toString()),
              id: (map['token_id'] ??
                      (kind == 'KRC-20'
                          ? 'krc20-${(map['symbol'] ?? map['ticker'] ?? '').toString().toLowerCase()}'
                          : null))
                  ?.toString(),
              decimals: _asInt(map['decimals']),
              rawBalance: map['raw_balance']?.toString(),
            );
          })
          .where((asset) => asset.balance > 0)
          .toList();
    }

    final domains = (data['domains'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (item) => KnsDomain(
            name: (item['name'] ?? '').toString(),
            status: item['status']?.toString(),
            assetId: item['asset_id']?.toString(),
          ),
        )
        .where((domain) => domain.name.isNotEmpty)
        .toList();
    return _WalletAssets(
      krc20: assets('tokens', 'KRC-20'),
      krc721: assets('krc721_tokens', 'KRC-721'),
      domains: domains,
    );
  }

  List<WalletTransaction> _parseTokenTransactions(
    Object? raw,
    String address,
  ) {
    final data = _map(_map(raw)['data']);
    return (data['transactions'] as List? ?? const [])
        .whereType<Map>()
        .map((item) {
      final map = item.cast<String, Object?>();
      final from = map['from_wallet']?.toString();
      final to = map['to_wallet']?.toString();
      final timestamp = DateTime.tryParse(map['timestamp']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final symbol = map['token_symbol']?.toString().toUpperCase() ??
          map['token_id']?.toString().replaceFirst('krc20-', '').toUpperCase();
      final rawKind = (map['asset_kind'] ?? map['kind'] ?? map['type'] ?? '')
          .toString()
          .toLowerCase();
      final assetKind = rawKind.contains('721')
          ? 'KRC-721'
          : rawKind.contains('kns')
              ? 'KNS'
              : 'KRC-20';
      return WalletTransaction(
        id: map['id']?.toString() ??
            'krc20-${timestamp.microsecondsSinceEpoch}',
        timestamp: timestamp,
        amountSompi: 0,
        incoming: to == address && from != address,
        assetKind: assetKind,
        assetSymbol: symbol,
        displayAmount: map['amount']?.toString(),
        tokenId: map['token_id']?.toString(),
        counterparty: to == address ? from : to,
        from: [
          if (from != null && from.isNotEmpty) TransactionParty(address: from),
        ],
        to: [
          if (to != null && to.isNotEmpty) TransactionParty(address: to),
        ],
        status: TransactionStatus.confirmed,
      );
    }).toList();
  }

  Future<String> loadUtxos(String address) async {
    final response = await _client
        .get(
          Uri.parse('$baseUrl/addresses/${Uri.encodeComponent(address)}/utxos'),
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KaspaApiException('Kaspa API returned ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! List) throw KaspaApiException('Invalid UTXO response');
    return jsonEncode(decoded);
  }

  Future<bool> addressHasActivity(String address) async {
    final balance = _map(
      await _get('/addresses/${Uri.encodeComponent(address)}/balance'),
    );
    if (_asInt(balance['balance']) > 0) return true;
    final history = await _get(
      '/addresses/${Uri.encodeComponent(address)}/full-transactions?limit=1&offset=0&resolve_previous_outpoints=no',
    );
    return history is List
        ? history.isNotEmpty
        : (_map(history)['transactions'] as List? ?? const []).isNotEmpty;
  }

  Future<double> loadFeeRate() async {
    final value = _map(await _get('/info/fee-estimate'));
    final priority = value['priorityBucket'];
    final rate = priority is Map ? _asDouble(priority['feerate']) : null;
    return (rate == null || rate < 100) ? 100.0 : rate;
  }

  Future<String> broadcast(String submitJson) async {
    final response = await _client
        .post(
          Uri.parse('$baseUrl/transactions'),
          headers: const {'content-type': 'application/json'},
          body: submitJson,
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KaspaApiException(
        'Broadcast rejected (${response.statusCode}): ${response.body}',
      );
    }
    final decoded = _map(jsonDecode(response.body));
    return (decoded['transactionId'] ?? decoded['transaction_id'] ?? '')
        .toString();
  }

  Future<String> broadcastKcc20(
    String signedTxJson, {
    required String expectedTransactionId,
  }) async {
    final response = await _client
        .post(
          Uri.parse(toccataBroadcastUrl),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({'signedTxJson': signedTxJson}),
        )
        .timeout(const Duration(seconds: 30));
    final decoded = _map(jsonDecode(response.body));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KaspaApiException(
        'Toccata wRPC broadcast rejected (${response.statusCode}): '
        '${decoded['error'] ?? response.body}',
      );
    }
    final transactionId =
        (decoded['txId'] ?? decoded['transactionId'] ?? '').toString();
    if (transactionId.isEmpty) {
      throw KaspaApiException(
          'Toccata wRPC broadcast returned no transaction ID.');
    }
    if (transactionId != expectedTransactionId) {
      throw KaspaApiException(
          'Toccata wRPC returned a mismatching transaction ID.');
    }
    return transactionId;
  }

  Future<Object?> _get(String path) async {
    final response = await _client
        .get(Uri.parse('$baseUrl$path'))
        .timeout(const Duration(seconds: 12));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KaspaApiException('Kaspa API returned ${response.statusCode}');
    }
    return jsonDecode(response.body);
  }

  static List<WalletTransaction> parseTransactions(
    Object? raw,
    String address,
  ) {
    final list =
        raw is List ? raw : (_map(raw)['transactions'] as List? ?? const []);
    return list.whereType<Map>().map((item) {
      final map = item.cast<String, Object?>();
      final outputs = (map['outputs'] as List? ?? const []).whereType<Map>();
      final inputs = (map['inputs'] as List? ?? const []).whereType<Map>();
      var received = 0;
      var spent = 0;
      var totalInput = 0;
      var totalOutput = 0;
      final from = <TransactionParty>[];
      final to = <TransactionParty>[];
      for (final output in outputs) {
        final amount = _asInt(output['amount']);
        totalOutput += amount;
        final outputAddress = output['script_public_key_address']?.toString();
        if (outputAddress != null && outputAddress.isNotEmpty) {
          to.add(TransactionParty(
            address: outputAddress,
            amountSompi: amount,
          ));
        }
        if (output['script_public_key_address'] == address) {
          received += amount;
        }
      }
      for (final input in inputs) {
        final previous =
            input['previous_outpoint_resolved'] ?? input['previous_outpoint'];
        String? inputAddress;
        var inputAmount = 0;
        if (previous is Map &&
            previous['script_public_key_address'] == address) {
          inputAddress = previous['script_public_key_address']?.toString();
          inputAmount = _asInt(previous['amount']);
          spent += inputAmount;
        } else if (input['previous_outpoint_address'] == address) {
          inputAddress = input['previous_outpoint_address']?.toString();
          inputAmount = _asInt(input['previous_outpoint_amount']);
          spent += inputAmount;
        } else if (previous is Map) {
          inputAddress = previous['script_public_key_address']?.toString();
          inputAmount = _asInt(previous['amount']);
        } else {
          inputAddress = input['previous_outpoint_address']?.toString();
          inputAmount = _asInt(input['previous_outpoint_amount']);
        }
        totalInput += inputAmount;
        if (inputAddress != null && inputAddress.isNotEmpty) {
          from.add(TransactionParty(
            address: inputAddress,
            amountSompi: inputAmount,
          ));
        }
      }
      final net = received - spent;
      final timestamp = _asInt(
        map['block_time'] ?? map['accepting_block_time'],
      );
      return WalletTransaction(
        id: (map['transaction_id'] ?? map['id'] ?? 'unknown').toString(),
        timestamp: timestamp > 0
            ? DateTime.fromMillisecondsSinceEpoch(timestamp)
            : DateTime.now(),
        amountSompi: net.abs(),
        incoming: net >= 0,
        from: from,
        to: to,
        totalInputSompi: totalInput > 0 ? totalInput : null,
        totalOutputSompi: totalOutput,
        feeSompi: totalInput >= totalOutput && totalInput > 0
            ? totalInput - totalOutput
            : null,
        inputCount: inputs.length,
        outputCount: outputs.length,
        blockDaaScore: _nullableInt(
          map['accepting_block_daa_score'] ?? map['block_daa_score'],
        ),
        mass: _nullableInt(map['mass']),
        isCoinbase: map['is_coinbase'] == true,
        status: TransactionStatus.confirmed,
      );
    }).toList();
  }

  static Map<String, Object?> _map(Object? value) =>
      value is Map ? value.cast<String, Object?>() : const {};
  static int _asInt(Object? value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;
  static int? _nullableInt(Object? value) => value == null
      ? null
      : value is num
          ? value.toInt()
          : int.tryParse('$value');
  static double? _asDouble(Object? value) =>
      value is num ? value.toDouble() : double.tryParse('$value');
  static double _pow10(int exponent) {
    var result = 1.0;
    for (var index = 0; index < exponent; index++) {
      result *= 10;
    }
    return result;
  }

  static int? _littleEndianHexInt(String? value) {
    if (value == null ||
        value.length.isOdd ||
        !RegExp(r'^[0-9a-fA-F]+$').hasMatch(value)) {
      return null;
    }
    final bytes = <String>[];
    for (var index = 0; index < value.length; index += 2) {
      bytes.add(value.substring(index, index + 2));
    }
    return int.tryParse(bytes.reversed.join(), radix: 16);
  }

  String? _absoluteImageUrl(String? value) {
    if (value == null || value.isEmpty || value.endsWith('.svg')) return null;
    if (value.startsWith('https://') || value.startsWith('http://')) {
      return value;
    }
    if (value.startsWith('/')) {
      final base = Uri.parse(tokenExplorerBaseUrl);
      return '${base.scheme}://${base.authority}$value';
    }
    return null;
  }
}

class _WalletAssets {
  const _WalletAssets({
    required this.krc20,
    required this.krc721,
    required this.domains,
  });
  final List<WalletAsset> krc20;
  final List<WalletAsset> krc721;
  final List<KnsDomain> domains;
}

class _Kcc20Wallet {
  const _Kcc20Wallet({
    required this.assets,
    required this.transactions,
    required this.warning,
  });
  final List<WalletAsset> assets;
  final List<WalletTransaction> transactions;
  final String warning;
}

class _Kcc20TokenResult {
  const _Kcc20TokenResult({
    this.asset,
    this.transactions = const [],
    this.discoveryLimited = false,
    this.sourceMismatch = false,
  });
  final WalletAsset? asset;
  final List<WalletTransaction> transactions;
  final bool discoveryLimited;
  final bool sourceMismatch;
}
