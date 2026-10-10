import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import '../models/wallet_snapshot.dart';

/// KRON is the balance source. Kasvio is optional presentation data only.
/// Neither source authorizes a signature: cells are checked on our node and
/// the native covenant engine validates the redeem script before approval.
class KronHoldings {
  KronHoldings(
    this.client, {
    this.indexer = 'https://idx.kron.technology/v1/kcc20',
    this.kasvio = 'https://kasvio.network',
  });
  final http.Client client;
  final String indexer;
  final String kasvio;

  Future<dynamic> get(String url) async {
    final response = await client.get(Uri.parse(url), headers: {
      'accept': 'application/json'
    }).timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) {
      throw StateError('KRON data request failed (${response.statusCode}).');
    }
    return jsonDecode(response.body);
  }

  Future<List<Map<String, dynamic>>> balances(String address) async {
    final data = await Future.wait([
      get('$indexer/info'),
      get('$indexer/address/${Uri.encodeComponent(address)}/tokenlist'),
    ]);
    final info = data[0]['result'];
    if (info is! Map ||
        info['network'] != 'mainnet' ||
        info['networkOk'] != true ||
        info['synced'] != true ||
        info['divergent'] == true) {
      throw StateError('KRON indexer is not synchronized with mainnet.');
    }
    final rows = data[1]['result'];
    if (rows is! List || rows.length > 1000) {
      throw StateError('Invalid KRON holdings response.');
    }
    final seen = <String>{};
    return rows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .where((row) {
      final id = row['covenantId']?.toString().toLowerCase() ?? '';
      final amount = BigInt.tryParse(row['balance'].toString());
      final dec = int.tryParse(row['dec'].toString());
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(id) ||
          amount == null ||
          amount < BigInt.zero ||
          dec == null ||
          dec < 0 ||
          dec > 18 ||
          !seen.add(id)) {
        throw StateError('Invalid or duplicate KRON holding.');
      }
      return amount > BigInt.zero;
    }).toList();
  }

  Future<Map<String, dynamic>> metadata(Map<String, dynamic> row) async {
    final data = await get(
        '$indexer/token/${Uri.encodeComponent(row['tick'].toString())}');
    final tokens = data['result'];
    if (tokens is! List) throw StateError('Invalid KRON metadata.');
    final matches = tokens
        .whereType<Map>()
        .where((token) =>
            token['covenantId']?.toString().toLowerCase() ==
                row['covenantId'].toString().toLowerCase() &&
            token['dec'].toString() == row['dec'].toString())
        .toList();
    if (matches.length != 1) {
      throw StateError('KRON ticker does not resolve to this covenant.');
    }
    return Map<String, dynamic>.from(matches.single);
  }

  Future<List<WalletAsset>> load(String address,
      {void Function(List<WalletAsset>)? onProgress}) async {
    // One catalogue request, never one request per holding.
    final marketsFuture =
        get('$kasvio/api/dex?dex=kron&range=7d').catchError((_) => null);
    final rows = await balances(address);
    List<WalletAsset> mapAssets(Map<String, dynamic> markets) =>
        rows.map((row) {
          final id = row['covenantId'].toString().toLowerCase();
          final market = markets[id] as Map?;
          final decimals = int.parse(row['dec'].toString());
          final raw = row['balance'].toString();
          final price = double.tryParse(market?['price']?.toString() ?? '');
          final image = market?['logo']?.toString();
          return WalletAsset(
            symbol: row['tick'].toString().toUpperCase(),
            kind: 'KCC20',
            covenantId: id,
            id: id,
            balance: BigInt.parse(raw).toDouble() / math.pow(10, decimals),
            rawBalance: raw,
            decimals: decimals,
            standard: 'kron-native',
            validationStatus: 'observed',
            discoveryComplete: false,
            imageUrl: image != null && Uri.tryParse(image)?.scheme == 'https'
                ? image
                : null,
            priceKas: price != null && price.isFinite && price >= 0
                ? price * math.pow(10, decimals)
                : null,
          );
        }).toList();
    onProgress?.call(mapAssets({}));
    final response = await marketsFuture;
    final markets = <String, dynamic>{};
    if (response is Map &&
        response['stale'] == false &&
        response['source'] is Map &&
        response['source']['available'] == true &&
        response['tokens'] is List) {
      for (final token in (response['tokens'] as List).whereType<Map>()) {
        final id = token['id']?.toString().toLowerCase() ?? '';
        if (RegExp(r'^[0-9a-f]{64}$').hasMatch(id)) markets[id] = token;
      }
    }
    return mapAssets(markets);
  }

  Future<List<Map<String, dynamic>>> transferRows(
      String address, String covenantId, int amount) async {
    final rows = await balances(address);
    final row = rows.singleWhere(
        (row) => row['covenantId'].toString().toLowerCase() == covenantId,
        orElse: () => throw StateError('No KRON balance for this covenant.'));
    if (amount <= 0 ||
        BigInt.from(amount) > BigInt.parse(row['balance'].toString())) {
      throw StateError('Insufficient KRON token balance.');
    }
    await metadata(row); // A ticker must never select a different covenant.
    final result = (await get(
            '$indexer/token/${Uri.encodeComponent(row['tick'].toString())}/address/${Uri.encodeComponent(address)}/utxos'))[
        'result'];
    if (result is! List || result.length > 1000) {
      throw StateError('Invalid KRON signing data.');
    }
    final seen = <String>{};
    final cells = result
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    for (final cell in cells) {
      final outpoint = cell['outpoint'];
      final txid = outpoint?['transactionId']?.toString() ?? '';
      final index = outpoint?['index'];
      final raw = int.tryParse(cell['amount'].toString());
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(txid) ||
          index is! int ||
          index < 0 ||
          raw == null ||
          raw <= 0 ||
          cell['ownerAddress'] != address ||
          !RegExp(r'^(?:[0-9a-fA-F]{2})+$')
              .hasMatch(cell['redeemScriptHex']?.toString() ?? '') ||
          !seen.add('$txid:$index')) {
        throw StateError('Invalid or duplicate KRON signing cell.');
      }
    }
    cells.sort((a, b) => int.parse(b['amount'].toString())
        .compareTo(int.parse(a['amount'].toString())));
    final selected = <Map<String, dynamic>>[];
    var total = 0;
    for (final cell in cells.take(4)) {
      selected.add(cell);
      total += int.parse(cell['amount'].toString());
      if (total >= amount) return selected;
    }
    throw StateError(
        'This transfer needs more than four spendable KRON cells. Reduce the amount or consolidate in KRON.');
  }
}
