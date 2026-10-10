import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'kaspa_api.dart';
import 'marketplace_reads.dart';
import 'native_security.dart';
import 'network_settings.dart';
import 'preferences_service.dart';
import 'signer_service.dart';
import 'kns_holdings_loader.dart';
import 'activity_store.dart';
import 'nft_market_service.dart';

typedef KaspaComReview = Future<bool> Function(
    String title, Map<String, Object?> details);

class KaspaComPurchaseResult {
  KaspaComPurchaseResult(Map<String, Object?> receipt)
      : receipt = Map.unmodifiable(receipt);
  final Map<String, Object?> receipt;
}

/// KaspaCom permits two decimals for total KAS. Multiply decimal strings
/// exactly, then round once to cents instead of using binary floating point.
String kcListingTotal(String quantity, String unitPrice) {
  (BigInt, int) decimal(String text, int maxDecimals) {
    text = text.trim().replaceAll(',', '.');
    if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(text)) {
      throw StateError('Enter a valid amount and price per token.');
    }
    final parts = text.split('.'), fraction = parts.length == 2 ? parts[1] : '';
    if (fraction.length > maxDecimals) {
      throw StateError('Too many decimal places.');
    }
    return (BigInt.parse(parts.first + fraction), fraction.length);
  }

  final (q, qd) = decimal(quantity, 18);
  final (p, pd) = decimal(unitPrice, 8);
  final divisor = BigInt.from(10).pow(qd + pd);
  final cents = (q * p * BigInt.from(100) + divisor ~/ BigInt.two) ~/ divisor;
  if (cents > BigInt.from(9000000000)) {
    throw StateError('Total price exceeds the marketplace limit.');
  }
  return '${cents ~/ BigInt.from(100)}.${(cents % BigInt.from(100)).toString().padLeft(2, '0')}';
}

const kcExchangeScript =
    '000020079ab96f3b42f1b3667010e6d855172bb8e905e3369fe5ad57b662c4bc365449ac';
int kcExchangeFee(Map<String, Object?> row) {
  if (row['exchangeQuote'] != true) return 0;
  final outputs =
      kcRows(kcMap(jsonDecode(row['psktSeller']! as String))['outputs']);
  // Commission 2 follows the platform commission. A royalty may happen to
  // use the same recipient, so do not search/count by destination alone.
  if (outputs.length < 3 || outputs[2]['scriptPublicKey'] != kcExchangeScript) {
    throw StateError(
        'The delegated KaspaCom quote is missing its exchange commission.');
  }
  final amount = int.tryParse(outputs[2]['value'].toString());
  if (amount == null || amount != kcSompi(row['currentFee'])) {
    throw StateError('Unexpected exchange commission in the KaspaCom quote.');
  }
  return amount;
}

Map<String, Object?> kcMap(Object? v) =>
    v is Map ? v.cast<String, Object?>() : {};
List<Map<String, Object?>> kcRows(Object? v) =>
    v is List ? v.map(kcMap).toList() : [];
int kcSompi(Object? v) {
  final s = v.toString();
  if (!RegExp(r'^\d+(\.\d{1,8})?$').hasMatch(s)) {
    throw StateError('Invalid KAS amount returned by KaspaCom.');
  }
  final parts = s.split('.');
  final n = BigInt.parse(parts.first) * BigInt.from(100000000) +
      BigInt.parse((parts.length == 1 ? '' : parts[1]).padRight(8, '0'));
  if (n > BigInt.from(9000000000000000)) {
    throw StateError('KAS amount exceeds the supported range.');
  }
  return n.toInt();
}

String kcKas(Object? v) {
  final n = (v as num).toInt();
  final decimal = (n % 100000000)
      .abs()
      .toString()
      .padLeft(8, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  return '${n ~/ 100000000}${decimal.isEmpty ? '' : '.$decimal'}';
}

String kcPrice(Object? value) {
  final n = value is num ? value.toDouble() : double.tryParse(value.toString());
  if (n == null || !n.isFinite || n < 0) return 'Unavailable';
  return n.toStringAsFixed(8).replaceFirst(RegExp(r'\.?0+$'), '');
}

class KaspaComCancelled implements Exception {
  const KaspaComCancelled();
}

String kcSignedPskt(Map<String, Object?> signed) {
  final tx = kcMap(jsonDecode(signed['signedTxJson']! as String));
  final id = signed['transactionId']! as String;
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) {
    throw StateError('Native signer returned an invalid transaction ID.');
  }
  // Assign only the ID independently calculated after constructing/signing it.
  tx['id'] = id;
  return jsonEncode(tx);
}

class KaspaComMarketService {
  KaspaComMarketService(this.address,
      {http.Client? client, NativeSecurity? security, KaspaApi? api})
      : client = client ?? http.Client(),
        security = security ?? NativeSecurity() {
    reads = MarketplaceReads(this.client);
    this.api = api ?? KaspaApi(client: this.client);
  }
  static const base = 'https://kaspire.kaslab.space/kaspacom-market-test-v1';
  final String address;
  final http.Client client;
  final NativeSecurity security;
  late final KaspaApi api;
  late final MarketplaceReads reads;
  bool closed = false;
  String? token;
  int expires = 0;
  Map<String, Object?>? lastPurchaseReceipt;
  String? lastRecoveryMessage;
  Future<void> guard() async {
    if (closed || NetworkSettings.isTestnet || NetworkSettings.isEvm) {
      throw StateError(
          'KaspaCom marketplace is available on Kaspa Mainnet only.');
    }
    final current = await PreferencesService().getAddress();
    if (current != address) {
      throw StateError('Wallet changed. Reopen KaspaCom Marketplace.');
    }
  }

  void close() {
    closed = true;
    token = null;
    client.close();
  }

  Future<void> requireNoPending() async {
    for (final record in await saved()) {
      if (record['stage'] != 'done') await releaseInvalidatedPurchase(record);
    }
    if ((await saved()).any((r) => r['stage'] != 'done')) {
      throw StateError(
          'Resume your saved KaspaCom transaction before starting another.');
    }
  }

  Future<void> decorateNftListingStates(
      List<Map<String, Object?>> items) async {
    final records = await saved();
    final cancelled = records
        .where((r) =>
            r['kind'] == 'krc721' &&
            r['action'] == 'cancel' &&
            r['stage'] == 'done')
        .map((r) => r['orderId'])
        .toSet();
    await Future.wait(items.map((item) async {
      final ticker = item['ticker'].toString().toUpperCase(),
          id = item['tokenId'].toString();
      var listed = kcMap(item['status'])['state'] == 'listed';
      try {
        final nft = kcMap(kcMap(await reads.get(
                '${NftMarketService.indexer}/nfts/${ticker.toLowerCase()}/$id'))[
            'result']);
        if (nft['owner'] == address && nft['status'] is Map) {
          listed = kcMap(nft['status'])['state'] == 'listed';
        }
      } catch (_) {
        /* Display fallback only; signing still requires official proof. */
      }
      final local = records.where((r) =>
          r['kind'] == 'krc721' &&
          r['action'] == 'create' &&
          r['ticker'].toString().toUpperCase() == ticker &&
          r['tokenId'].toString() == id &&
          !cancelled.contains(r['orderId']));
      item['listingPending'] = local.any((r) => r['stage'] != 'done');
      if (!listed) {
        for (final record in local.where((r) => r['orderId'] is String)) {
          try {
            final order = await detail('krc721', record['orderId']! as String);
            if (order['status'] == 'LISTED_FOR_SALE' &&
                order['sellerWalletAddress'] == address &&
                order['ticker'].toString().toUpperCase() == ticker &&
                order['tokenId'].toString() == id) {
              listed = true;
              break;
            }
          } catch (_) {
            /* Missing/failed order reads do not invent a listing. */
          }
        }
      }
      item['marketplaceListed'] = listed;
    }));
  }

  Future<void> decorateKnsListingStates(
      List<Map<String, Object?>> items) async {
    final records = await saved();
    final cancelled = records
        .where((r) =>
            r['kind'] == 'kns' &&
            r['action'] == 'cancel' &&
            r['stage'] == 'done')
        .map((r) => r['orderId'])
        .toSet();
    await Future.wait(items.map((item) async {
      var listed = item['status'] == 'listed';
      final local = records.where((r) =>
          r['kind'] == 'kns' &&
          r['action'] == 'create' &&
          r['assetId'] == item['assetId'] &&
          item['assetId'] != null &&
          !cancelled.contains(r['orderId']));
      item['listingPending'] = local.any((r) => r['stage'] != 'done');
      for (final record in local.where((r) => r['orderId'] is String)) {
        try {
          final order = await detail('kns', record['orderId']! as String);
          if (order['sellerWalletAddress'] == address &&
              order['assetId'] == item['assetId']) {
            listed = order['status'] == 'LISTED_FOR_SALE';
            break;
          }
        } catch (_) {/* Existing display status survives a temporary outage. */}
      }
      item['marketplaceListed'] = listed;
    }));
  }

  /// Archive only when an accepted conflicting spend makes every saved buyer
  /// signature unusable. A missing listing, HTTP error or empty UTXO response
  /// is not sufficient proof. Keep signed bytes for diagnosis/recovery.
  Future<bool> releaseInvalidatedPurchase(Map<String, Object?> record) async {
    await guard();
    if (record['stage'] != 'settle' || record['action'] != 'buy') return false;
    String? conflict;
    try {
      final candidates = [
        kcMap(record['signed']),
        ...kcRows(record['supersededSigned'])
      ];
      final inputs = candidates
          .map((signed) =>
              kcRows(kcMap(jsonDecode(kcSignedPskt(signed)))['inputs']).first)
          .toList();
      final listing = inputs.first['transactionId'];
      final index = inputs.first['index'];
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch('$listing') ||
          index != 0 ||
          inputs.any((input) =>
              input['transactionId'] != listing || input['index'] != index)) {
        return false;
      }
      final tx =
          kcMap(await reads.get('${NftNode.base}/transactions/$listing'));
      if (tx['transaction_id'] != listing || tx['is_accepted'] != true) {
        return false;
      }
      final outputs = kcRows(tx['outputs'])
          .where((output) => output['index'] == index)
          .toList();
      if (outputs.length != 1) return false;
      final listingAddress = outputs.single['script_public_key_address'];
      if (listingAddress is! String || !listingAddress.startsWith('kaspa:')) {
        return false;
      }
      final path =
          '${NftNode.base}/addresses/${Uri.encodeComponent(listingAddress)}';
      final cells = await reads.get('$path/utxos');
      if (cells is! List ||
          kcRows(cells).any((cell) =>
              kcMap(cell['outpoint'])['transactionId'] == listing &&
              kcMap(cell['outpoint'])['index'] == index)) {
        return false;
      }
      final candidateIds =
          candidates.map((candidate) => candidate['transactionId']).toSet();
      for (var offset = 0; offset < 1000; offset += 100) {
        final history = await reads.get(
            '$path/full-transactions?limit=100&offset=$offset&resolve_previous_outpoints=light');
        if (history is! List) return false;
        for (final spend in kcRows(history)) {
          final id = spend['transaction_id'];
          if (spend['is_accepted'] != true ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch('$id') ||
              !kcRows(spend['inputs']).any((input) =>
                  input['previous_outpoint_hash'] == listing &&
                  input['previous_outpoint_index'].toString() == '$index')) {
            continue;
          }
          // An accepted saved purchase must complete normally, not be discarded.
          if (candidateIds.contains(id)) return false;
          conflict = id as String;
          break;
        }
        if (conflict != null || history.length < 100) break;
      }
    } catch (_) {
      return false;
    }
    if (conflict == null) return false;
    await guard();
    record.addAll({
      'stage': 'done',
      'outcome': 'invalidated',
      'conflictingTransactionId': conflict,
      'resolvedAt': DateTime.now().millisecondsSinceEpoch
    });
    await save(record);
    lastRecoveryMessage =
        'This listing was cancelled or purchased by someone else. '
        'The saved purchase can no longer settle and has been archived. You can start a new transaction.';
    return true;
  }

  Future<Map<String, Object?>> requireKnsOwner(String owner, String id,
      {String? listing}) async {
    final result = await loadKnsHoldingsPages(
        fetchPage: (page) async => kcMap(await reads.get(
            '${api.knsIndexerBaseUrl}/api/v1/assets?owner=$owner&page=$page&pageSize=100&type=domain')));
    final matches =
        result.records.where((r) => r['assetId'] == id && r['owner'] == owner);
    if (matches.isEmpty) {
      throw StateError(
          'The official KNS indexer does not confirm ownership of this name.');
    }
    final r = matches.first;
    if (listing != null &&
        (r['status'] != 'listed' ||
            kcMap(r['listed'])['transactionId'] != listing)) {
      throw StateError(
          'The official KNS indexer no longer confirms this listing.');
    }
    if (listing == null && r['status'] == 'listed') {
      throw StateError(
          'This name is already listed. Cancel its existing listing first.');
    }
    return r;
  }

  Future<Map<String, Object?>> request(String path,
      {Map<String, String>? query,
      Map<String, Object?>? body,
      bool private = false}) async {
    await guard();
    final uri = Uri.parse('$base$path').replace(queryParameters: query);
    final headers = {
      'content-type': 'application/json',
      if (private && token != null) 'authorization': 'Bearer $token'
    };
    final r = await (body == null
            ? client.get(uri, headers: headers)
            : client.post(uri, headers: headers, body: jsonEncode(body)))
        .timeout(const Duration(seconds: 40));
    Map<String, Object?> data;
    try {
      data = kcMap(jsonDecode(r.body));
    } catch (_) {
      throw StateError(
          'KaspaCom gateway temporarily unavailable. Please retry.');
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      if (r.statusCode == 401) {
        token = null;
        expires = 0;
      }
      throw StateError(data['error']?.toString() ??
          'KaspaCom request failed (${r.statusCode}).');
    }
    await guard();
    return data;
  }

  Future<void> authenticate() async {
    await guard();
    if (token != null && expires > DateTime.now().millisecondsSinceEpoch) {
      return;
    }
    final c = await request('/challenge', body: {'address': address});
    final signature =
        await security.signPersonalMessage(address, c['message']! as String);
    await guard();
    final r = await request('/authenticate', body: {
      'address': address,
      'nonce': c['nonce'],
      'signature': signature
    });
    token = r['token']! as String;
    expires = (r['expiresAt'] as num).toInt();
  }

  Future<Map<String, Object?>> browse(
      String kind, String search, String sort, int offset,
      {Map<String, String> traits = const {}}) async {
    final completed = (await saved())
        .where((r) =>
            r['kind'] == kind &&
            r['stage'] == 'done' &&
            (r['action'] == 'cancel' || r['action'] == 'buy'))
        .map((r) => r['orderId'])
        .toSet();
    final rows = <Map<String, Object?>>[];
    var cursor = offset, total = offset + 1;
    while (rows.length < 10 && cursor < total && cursor < offset + 40) {
      final data = await request('/$kind/browse', query: {
        'search': search,
        'sort': sort,
        'offset': '$cursor',
        if (traits.isNotEmpty) 'traits': jsonEncode(traits)
      });
      final source = kcRows(data['orders']);
      total = (data['totalCount'] as num?)?.toInt() ?? cursor + source.length;
      if (source.isEmpty) {
        total = cursor;
        break;
      }
      for (final row in source) {
        cursor++;
        if (!completed.contains(row['orderId']) &&
            (row['status'] == null || row['status'] == 'LISTED_FOR_SALE')) {
          rows.add(row);
        }
        if (rows.length == 10) break;
      }
    }
    return {'orders': rows, 'nextOffset': cursor < total ? cursor : null};
  }

  Future<Map<String, Object?>> tokenSummary(String ticker) =>
      request('/krc20/summary', query: {'ticker': ticker});
  Future<Map<String, Object?>> traitCatalog(String ticker) =>
      request('/krc721/traits', query: {'ticker': ticker});
  Future<Map<String, Object?>> catalog(String kind, int offset) =>
      request('/catalog', query: {'kind': kind, 'offset': '$offset'});
  Future<Map<String, Object?>> history(String kind, int offset,
      {String role = 'all'}) async {
    await authenticate();
    final result = await request('/$kind/history',
        query: {'offset': '$offset', 'role': role}, private: true);
    final records = await saved();
    final cancelledIds = records
        .where((r) =>
            r['kind'] == kind &&
            r['action'] == 'cancel' &&
            r['stage'] == 'done')
        .map((r) => r['orderId'])
        .toSet();
    if (role == 'seller' || role == 'sales') {
      final orders = kcRows(result['orders']);
      final next = offset + orders.length;
      if (orders.isNotEmpty || (result['totalCount'] as num? ?? 0) > 0) {
        return {
          'orders': orders
              .where((r) =>
                  r['status'] ==
                      (role == 'sales' ? 'COMPLETED' : 'LISTED_FOR_SALE') &&
                  (role != 'sales' || r['sellerWalletAddress'] == address) &&
                  !cancelledIds.contains(r['orderId']))
              .toList(),
          'nextOffset': next < (result['totalCount'] as num? ?? 0) ? next : null
        };
      }
    }
    if (result['totalCount'] != 0 || kcRows(result['orders']).isNotEmpty) {
      return result;
    }
    // Some partner histories omit orders created outside that partner context.
    // Preserve this wallet's locally saved order IDs and fetch their live state.
    final ids = <String>{};
    for (final r in records) {
      if (r['kind'] == kind &&
          r['outcome'] != 'invalidated' &&
          r['orderId'] is String &&
          !cancelledIds.contains(r['orderId']) &&
          (role == 'all' ||
              (role == 'buyer'
                  ? r['action'] == 'buy'
                  : r['action'] != 'buy'))) {
        ids.add(r['orderId']! as String);
      }
    }
    final rows = <Map<String, Object?>>[];
    // Bounded source cursor: filtering old/completed orders must not fetch
    // the wallet's entire lifetime history on every ten-item page.
    final ordered = ids.toList();
    var cursor = offset;
    while (
        rows.length < 10 && cursor < ordered.length && cursor < offset + 40) {
      final id = ordered[cursor++];
      final row = await detail(kind, id);
      if (role == 'sales') {
        if (row['status'] == 'COMPLETED' &&
            row['sellerWalletAddress'] == address) {
          rows.add(row);
        }
      } else if (role != 'seller' || row['status'] == 'LISTED_FOR_SALE') {
        rows.add(row);
      }
    }
    return {
      'orders': rows,
      'nextOffset': cursor < ordered.length ? cursor : null,
    };
  }

  Future<Map<String, Object?>> detail(String kind, String id,
          {bool quote = false}) =>
      request('/$kind/orders/$id',
          query: quote ? {'quote': '1'} : null, private: quote);
  String get recoveryKey => 'kaspire_kaspacom_recovery_v1:$address';
  Future<List<Map<String, Object?>>> saved() async {
    final p = await SharedPreferences.getInstance();
    return kcRows(jsonDecode(p.getString(recoveryKey) ?? '[]'));
  }

  Future<void> save(Map<String, Object?> record) async {
    await guard();
    final list = await saved();
    list.removeWhere((r) => r['localId'] == record['localId']);
    list.insert(0, record);
    if (!await (await SharedPreferences.getInstance())
        .setString(recoveryKey, jsonEncode(list))) {
      throw StateError(
          'Could not save transaction recovery. Nothing new was broadcast.');
    }
  }

  Future<void> acceptedOrBroadcast(String id, String json) async {
    await guard();
    try {
      final proof = kcMap(await reads.get('${NftNode.base}/transactions/$id'));
      if (proof['is_accepted'] == true) return;
    } catch (_) {/* retry identical signed transaction only */}
    await api.broadcast(json);
  }

  Future<String> waitCells(String target, String id) async {
    for (var i = 0; i < 16; i++) {
      await guard();
      final raw = await api.loadUtxos(target);
      if (kcRows(jsonDecode(raw)).any((c) =>
          kcMap(c['outpoint'])['transactionId'] == id &&
          kcMap(c['outpoint'])['index'] == 0)) {
        return raw;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw StateError(
        'Listing transaction is saved but not yet spendable. Tap Resume saved listing.');
  }

  Map<String, Object?> terms(String kind, Map<String, Object?> row,
          String action, String seller) =>
      {
        'action': action,
        'kind': kind,
        'sender': address,
        'seller': seller,
        'ticker': row['ticker']?.toString().toUpperCase() ?? '',
        'tokenId': row['tokenId']?.toString() ?? '',
        'assetId': row['assetId'] ?? '',
      };
  Future<Map<String, Object?>> live(
      String kind, Map<String, Object?> row) async {
    await guard();
    if (row['status'] != 'LISTED_FOR_SALE') {
      throw StateError('This order is not available. Refresh the market.');
    }
    final seller = row['sellerWalletAddress']! as String,
        id = row['psktTransactionId']! as String;
    final args = terms(kind, row, 'describe', seller);
    final descriptor = await security.prepareKaspacomMarket(args);
    if (kind == 'krc721') {
      final nft = kcMap(kcMap(await reads.get(
              '${api.krc721IndexerBaseUrl}/nfts/${row['ticker'].toString().toLowerCase()}/${row['tokenId']}'))[
          'result']);
      final status = kcMap(nft['status']);
      if (nft['owner'] != seller ||
          status['state'] != 'listed' ||
          status['listingTxId'] != id) {
        throw StateError(
            'The official NFT indexer no longer confirms this listing.');
      }
    } else if (kind == 'krc20') {
      // Same-host relay avoids client-specific Kasplex/CDN errors; the source
      // remains the official indexer and the proof is validated below.
      final market = await request('/krc20/orders/${row['orderId']}/proof');
      if (kcRows(market['result']).isEmpty) {
        throw StateError(
            'The official KRC20 indexer no longer confirms this listing.');
      }
      final rows = kcRows(market['result']);
      if (!rows.any((r) =>
          r['from'] == seller &&
          r['uTxid'] == id &&
          r['tick'].toString().toUpperCase() ==
              row['ticker'].toString().toUpperCase() &&
          r['uAddr'] == descriptor['listingAddress'] &&
          r['uScript'] == descriptor['redeemScript'])) {
        throw StateError(
            'KRC20 listing script or seller does not match its official indexer proof.');
      }
    } else if (kind == 'kns') {
      await requireKnsOwner(seller, row['assetId']! as String, listing: id);
    }
    // An archive lookup can return 404 for an old transaction even while its
    // output is spendable. Verify the exact current outpoint on our own node.
    final Object? cells;
    try {
      cells = await reads.get(
          '${NftNode.base}/addresses/${Uri.encodeComponent(descriptor['listingAddress']! as String)}/utxos');
    } catch (e) {
      throw StateError(
          'Kaspire node listing verification failed: $e. No transaction was sent.');
    }
    if (cells is! List ||
        !kcRows(cells).any((c) =>
            kcMap(c['outpoint'])['transactionId'] == id &&
            kcMap(c['outpoint'])['index'] == 0)) {
      throw StateError(
          'This listing output is no longer spendable. Refresh the market.');
    }
    return {
      ...terms(kind, row, 'buy', seller),
      'listingTransactionId': id,
      'listingUtxosJson': jsonEncode(cells),
      'sellerPskt': row['psktSeller'],
      'priceSompi': kcSompi(row['totalPrice']),
      'feeSompi': kcSompi(row['currentFee']),
      'exchangeFeeSompi': kcExchangeFee(row),
      'royaltySompi': kcSompi(row['royaltyFee'] ?? 0),
      'royaltyAddress': row['royaltyFeeAddress'] ?? '',
      'feeRate': await api.loadFeeRate()
    };
  }

  Future<KaspaComPurchaseResult?> transact(String kind,
      Map<String, Object?> row, bool buy, KaspaComReview approve) async {
    await requireNoPending();
    await authenticate();
    final fresh = await detail(kind, row['orderId'].toString(), quote: buy);
    final signed = await _signOrder(kind, fresh, buy, approve);
    final record = <String, Object?>{
      'localId': signed['transactionId'],
      'kind': kind,
      'orderId': row['orderId'],
      'action': buy ? 'buy' : 'cancel',
      'stage': 'settle',
      'signed': signed,
      'quoteVersion': 2,
      'assetDetails': {
        for (final key in [
          'ticker',
          'tokenId',
          'asset',
          'quantity',
          'totalPrice',
          'currentFee',
          'royaltyFee'
        ])
          if (fresh[key] != null) key: fresh[key],
        'exchangeFee': kcKas(kcExchangeFee(fresh)),
        'sellerWalletAddress': fresh['sellerWalletAddress'],
      },
      'createdAt': DateTime.now().millisecondsSinceEpoch
    };
    await save(record);
    await resume(record, approve);
    if (buy &&
        record['stage'] == 'done' &&
        record['outcome'] != 'invalidated') {
      return KaspaComPurchaseResult(lastPurchaseReceipt!);
    }
    return null;
  }

  Future<Map<String, Object?>> _signOrder(String kind,
      Map<String, Object?> fresh, bool buy, KaspaComReview approve) async {
    final args = await live(kind, fresh);
    if (!buy) {
      if (fresh['sellerWalletAddress'] != address) {
        throw StateError('Only the seller can cancel this listing.');
      }
      args['action'] = 'cancel';
    }
    if (buy) args['walletUtxosJson'] = await api.loadUtxos(address);
    final built = await security.prepareKaspacomMarket(args),
        req = kcMap(built['request']),
        review = await security.preparePskt(req);
    if (!await approve(buy ? 'Buy on KaspaCom' : 'Cancel KaspaCom listing', {
      'Asset': fresh['asset'] ??
          '${fresh['ticker']}${kind == 'krc721' ? ' #${fresh['tokenId']}' : ' · ${fresh['quantity']} tokens'}',
      'Seller': fresh['sellerWalletAddress'],
      'Price (sompi)': buy ? args['priceSompi'] : 0,
      'KaspaCom fee (sompi)': buy ? args['feeSompi'] : 0,
      'External exchange fee (sompi)': buy ? args['exchangeFeeSompi'] : 0,
      'NFT royalty (sompi)': buy ? args['royaltySompi'] : 0,
      if (buy && args['royaltySompi'] != 0)
        'Royalty recipient': args['royaltyAddress'],
      'Network fee (sompi)': built['networkFeeSompi'],
      'Outputs': review['outputs']
    })) {
      throw const KaspaComCancelled();
    }
    await guard();
    final latest = await detail(kind, fresh['orderId'].toString(), quote: buy);
    await live(kind, latest);
    for (final field in [
      'psktTransactionId',
      'totalPrice',
      'currentFee',
      'psktSeller',
      'royaltyFee',
      'royaltyFeeAddress'
    ]) {
      if (latest[field] != fresh[field]) {
        throw StateError(
            'The purchase quote changed. Review the updated offer again.');
      }
    }
    final signed =
        await security.signPskt(req, review['reviewHash']! as String);
    // Display metadata only: never inserted into the signed PSKT or request.
    return {...signed, 'receiptNetworkFeeSompi': built['networkFeeSompi']};
  }

  Future<void> create(String kind, Map<String, Object?> asset, int price,
      String rawAmount, num quantity, KaspaComReview approve) async {
    await requireNoPending();
    await authenticate();
    if (kind == 'kns') {
      await requireKnsOwner(address, asset['assetId']! as String);
    }
    if (kind == 'krc20') {
      final snapshot =
          await api.loadWallet(address, includeNativeTransactions: false);
      final matches = snapshot.krc20Tokens.where((a) =>
          a.symbol.toUpperCase() == asset['ticker'].toString().toUpperCase());
      if (matches.isEmpty ||
          matches.first.rawBalance == null ||
          BigInt.parse(rawAmount) > BigInt.parse(matches.first.rawBalance!)) {
        throw StateError(
            'Insufficient verified token balance. Refresh My assets.');
      }
    }
    if (price <= 0 || price % 1000000 != 0) {
      throw StateError('Enter a price with at most two decimals.');
    }
    final operation = <String, Object?>{
      'kind': '$kind-list',
      'sender': address,
      'recipient': address,
      'ticker': asset['ticker'] ?? '',
      'tokenId': asset['tokenId'] ?? '',
      'assetId': asset['assetId'] ?? '',
      'amount': rawAmount
    };
    final plan = await security.prepareInscription(operation);
    final signer = SignerService(security: security),
        payment = await SignerService(security: security).prepare(
            sender: address,
            recipient: plan['commitAddress']! as String,
            amountSompi: (plan['commitAmountSompi'] as num).toInt(),
            feeRate: await api.loadFeeRate(),
            utxosJson: await api.loadUtxos(address));
    if (!await approve('List on KaspaCom', {
      'Asset': asset['asset'] ??
          '${asset['ticker']}${kind == 'krc721' ? ' #${asset['tokenId']}' : ' · $quantity tokens'}',
      'Seller': address,
      'Price (sompi)': price,
      'Listing reserve (sompi)': plan['commitAmountSompi'],
      'Commit network fee (sompi)': payment.feeSompi,
      'Settlement': 'Decentralized PSKT · no escrow',
      'Marketplace':
          'KaspaCom applies its own platform fees and NFT royalties at purchase.'
    })) {
      throw const KaspaComCancelled();
    }
    await guard();
    final signed = await signer.sign(payment);
    final record = <String, Object?>{
      ...asset,
      'localId': signed.transactionId,
      'kind': kind,
      'action': 'create',
      'stage': 'commit',
      'priceSompi': price,
      'quantity': quantity,
      'rawAmount': rawAmount,
      'operation': operation,
      'plan': plan,
      'commitTransactionId': signed.transactionId,
      'commitSubmitJson': signed.submitJson,
      'createdAt': DateTime.now().millisecondsSinceEpoch
    };
    await save(record);
    await resume(record, approve);
  }

  Future<void> resume(Map<String, Object?> r, KaspaComReview approve) async {
    if (await releaseInvalidatedPurchase(r)) return;
    await authenticate();
    final kind = r['kind']! as String;
    if (r['stage'] == 'settle') {
      var signed = kcMap(r['signed']);
      var id = signed['transactionId']! as String;
      // Never recreate a signed purchase after an ambiguous backend response.
      var accepted = false;
      for (final candidate in [signed, ...kcRows(r['supersededSigned'])]) {
        final candidateId = candidate['transactionId']! as String;
        try {
          if (kcMap(await reads
                      .get('${NftNode.base}/transactions/$candidateId'))[
                  'is_accepted'] ==
              true) {
            signed = candidate;
            id = candidateId;
            accepted = true;
            break;
          }
        } catch (_) {}
      }
      if (!accepted) {
        if (r['action'] == 'buy') {
          final oldTx = kcMap(jsonDecode(kcSignedPskt(signed)));
          final needsUpdatedQuote = r['quoteVersion'] != 2;
          if (needsUpdatedQuote) {
            final fresh =
                await detail(kind, r['orderId'].toString(), quote: true);
            final originalInput = kcRows(oldTx['inputs']).first;
            if (originalInput['transactionId'] != fresh['psktTransactionId'] ||
                originalInput['index'] != 0 ||
                kcExchangeFee(fresh) == 0) {
              throw StateError(
                  'The saved order cannot be rebuilt from the current KaspaCom quote.');
            }
            // The same listing outpoint is retained. It cannot settle twice.
            // Never modify an old signature to pay an additional commission.
            final replacement = await _signOrder(kind, fresh, true, approve);
            r['supersededSigned'] = [...kcRows(r['supersededSigned']), signed];
            signed = replacement;
            id = signed['transactionId']! as String;
            r['signed'] = signed;
            r['quoteVersion'] = 2;
            await save(r);
          }
          final response = await request('/$kind/orders/${r['orderId']}/buy',
              body: {'signedBuyerPskt': kcSignedPskt(signed)}, private: true);
          if (response['success'] != true) {
            throw StateError(
                'KaspaCom did not confirm the purchase. Signed transaction retained for recovery.');
          }
        } else {
          await acceptedOrBroadcast(id, signed['submitJson']! as String);
        }
      }
      await request('/$kind/orders/${r['orderId']}/verify',
          body: {'transactionId': id}, private: true);
      r['stage'] = 'done';
      await save(r);
      if (r['action'] == 'buy') {
        var asset = kcMap(r['assetDetails']);
        if (asset.isEmpty) {
          try {
            asset = await detail(kind, r['orderId'].toString());
          } catch (_) {/* Completed purchases never become pending again. */}
        }
        lastPurchaseReceipt = {
          'Asset': asset['asset'] ??
              '${asset['ticker'] ?? kind}${asset['tokenId'] == null ? '' : ' #${asset['tokenId']}'}',
          if (asset['quantity'] != null) 'Quantity': kcPrice(asset['quantity']),
          if (asset['totalPrice'] != null)
            'Order price': '${kcPrice(asset['totalPrice'])} KAS',
          if (asset['currentFee'] != null)
            'KaspaCom fee': '${kcPrice(asset['currentFee'])} KAS',
          if (asset['exchangeFee'] != null)
            'Exchange fee': '${asset['exchangeFee']} KAS',
          if (asset['royaltyFee'] != null)
            'Royalty': '${kcPrice(asset['royaltyFee'])} KAS',
          if (signed['receiptNetworkFeeSompi'] != null)
            'Network fee': '${kcKas(signed['receiptNetworkFeeSompi'])} KAS',
          'Transaction ID': id,
        };
        try {
          if (asset.isNotEmpty) {
            await ActivityStore().recordAssetTransfer(
                wallet: address,
                incoming: true,
                transactionId: id,
                timestamp: DateTime.now(),
                operation: {
                  'kind': kind,
                  'ticker': asset['ticker'],
                  'tokenId': asset['tokenId'],
                  'domainName': asset['asset'],
                  'displayAmount':
                      kind == 'krc20' ? kcPrice(asset['quantity']) : '1',
                  'recipient': asset['sellerWalletAddress'],
                });
          }
        } catch (_) {/* Network activity remains the authoritative fallback. */}
      }
      return;
    }
    if (r['stage'] == 'commit') {
      await acceptedOrBroadcast(r['commitTransactionId']! as String,
          r['commitSubmitJson']! as String);
      final plan = kcMap(r['plan']),
          cells = await waitCells(plan['commitAddress']! as String,
              r['commitTransactionId']! as String);
      final req = <String, Object?>{
        'operation': r['operation'],
        'commitTransactionId': r['commitTransactionId'],
        'commitUtxosJson': cells,
        'feeRate': await api.loadFeeRate()
      };
      final review = await security.prepareReveal(req);
      if (!await approve('Confirm KaspaCom listing', {
        'Asset': r['asset'] ?? '${r['ticker']} ${r['tokenId'] ?? ''}',
        'Price (sompi)': r['priceSompi'],
        'Reveal network fee (sompi)': review['feeSompi'],
        'Listing reserve (sompi)': review['returnSompi']
      })) {
        throw const KaspaComCancelled();
      }
      await guard();
      final signed =
          await security.signReveal(req, review['reviewHash']! as String);
      r.addAll({
        'listingTransactionId': signed['transactionId'],
        'revealSubmitJson': signed['submitJson'],
        'stage': 'reveal'
      });
      await save(r);
    }
    if (r['stage'] == 'reveal') {
      await acceptedOrBroadcast(r['listingTransactionId']! as String,
          r['revealSubmitJson']! as String);
      r['stage'] = 'offer';
      await save(r);
    }
    if (r['stage'] == 'offer') {
      final args = terms(kind, r, 'offer', address),
          d = await security
              .prepareKaspacomMarket({...args, 'action': 'describe'});
      args.addAll({
        'listingTransactionId': r['listingTransactionId'],
        'listingUtxosJson': await waitCells(d['listingAddress']! as String,
            r['listingTransactionId']! as String),
        'priceSompi': r['priceSompi']
      });
      final built = await security.prepareKaspacomMarket(args),
          req = kcMap(built['request']),
          review = await security.preparePskt(req);
      if (!await approve('Authorize seller PSKT', {
        'Asset': r['asset'] ?? '${r['ticker']} ${r['tokenId'] ?? ''}',
        'Price (sompi)': r['priceSompi'],
        'Signature': 'SINGLE|ANYONECANPAY · buyer adds funding',
        'Seller': address
      })) {
        throw const KaspaComCancelled();
      }
      await guard();
      final signed =
          await security.signPskt(req, review['reviewHash']! as String);
      r.addAll({'sellerPskt': kcSignedPskt(signed), 'stage': 'publish'});
      await save(r);
    }
    if (r['stage'] == 'publish') {
      final b = <String, Object?>{
        'totalPrice': (r['priceSompi'] as num) / 100000000,
        'psktSeller': r['sellerPskt'],
        if (kind == 'kns') 'assetId': r['assetId'],
        if (kind != 'kns') 'ticker': r['ticker'],
        if (kind == 'krc721') 'tokenId': r['tokenId'],
        if (kind == 'krc20') 'quantity': r['quantity']
      };
      final response = await request('/$kind/orders', body: b, private: true);
      if (response['status'] != 'LISTED_FOR_SALE') {
        r['publicationStatus'] = response['status'];
        await save(r);
        throw StateError(
            'KaspaCom has not confirmed publication (${response['status']}). Listing recovery is saved.');
      }
      r.addAll({'orderId': response['id'], 'stage': 'done'});
      await save(r);
    }
  }
}

class NftNode {
  static const base = 'https://kaspire.kaslab.space/api/local-node';
}
