import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'kaspa_api.dart';
import 'marketplace_reads.dart';
import 'native_security.dart';
import 'network_settings.dart';
import 'signer_service.dart';
import 'krc721_reads.dart';

typedef NftReview = Future<bool> Function(
    String title, Map<String, Object?> details);
Map<String, Object?> nftMap(Object? value) =>
    (value as Map).cast<String, Object?>();

class NftMarketService {
  NftMarketService({http.Client? client}) : client = client ?? http.Client() {
    reads = MarketplaceReads(this.client);
  }
  static const directory = 'https://kaspire.kaslab.space/nft-market-test-v1';
  // Transaction authority, never replace with the local display gateway.
  static const indexer =
      'https://krc721-indexer.kaspa.com/api/v1/krc721/mainnet';
  static const node = 'https://kaspire.kaslab.space/api/local-node';
  static final changes = ValueNotifier<int>(0);
  final http.Client client;
  Krc721Reads get displayReads => Krc721Reads(client);
  late final MarketplaceReads reads;
  final api = KaspaApi();
  final security = NativeSecurity();
  final signer = SignerService();
  bool _closed = false;
  final Map<String, Future<void>> _publishing = {};

  Future<List<String>> ownedCollections(String address) async {
    final ticks = <String>{};
    final seen = <String>{};
    String? cursor;
    do {
      guard();
      final raw = await displayReads.walletPage(address, cursor: cursor);
      for (final row in (raw['result'] as List? ?? [])) {
        final tick = row['tick']?.toString().toUpperCase() ?? '';
        if (tick.isNotEmpty) ticks.add(tick);
      }
      cursor = raw['next']?.toString();
      if (cursor != null && !seen.add(cursor)) {
        throw StateError('NFT indexer repeated a page. Please reload.');
      }
    } while (cursor != null && cursor.isNotEmpty);
    return ticks.toList()..sort();
  }

  Future<void> publishPending(String address) async {
    for (final record in await saved(address)) {
      if (_closed) return;
      if (record['stage'] == 'complete' &&
          record['published'] != true &&
          record['publicationBlocked'] != true &&
          !['sold', 'cancelled'].contains(record['status'])) {
        try {
          await publish(record);
        } catch (_) {/* Persisted for next retry. */}
      }
    }
  }

  void close() {
    _closed = true;
    reads.close();
    client.close();
  }

  void guard() {
    if (_closed) {
      throw StateError('Marketplace closed. Reopen and review again.');
    }
    if (NetworkSettings.network.value != KaspaNetwork.mainnet) {
      throw StateError(
          'NFT Market is available on Kaspa Layer 1 only. Switch back and review again.');
    }
  }

  String key(String address) => 'kaspire_nft_market_v1_$address';
  Future<List<Map<String, Object?>>> saved(String address) async {
    final raw = (await SharedPreferences.getInstance()).getString(key(address));
    return raw == null ? [] : (jsonDecode(raw) as List).map(nftMap).toList();
  }

  Future<void> save(String address, Map<String, Object?> record) async {
    final records = await saved(address);
    records.removeWhere((r) => r['localId'] == record['localId']);
    records.add(record);
    if (!await (await SharedPreferences.getInstance())
        .setString(key(address), jsonEncode(records))) {
      throw StateError(
          'Could not save listing recovery data. No new transaction will be broadcast.');
    }
    changes.value++;
  }

  Future<Map<String, Object?>> browse(
      {String q = '',
      String? collection,
      Map<String, String> traits = const {},
      bool high = false,
      int offset = 0,
      String? seller,
      bool refresh = false}) async {
    final url = Uri.parse('$directory/offers').replace(queryParameters: {
      'q': q,
      'offset': '$offset',
      'sort': high ? 'high' : 'low',
      if (collection != null) 'collection': collection,
      if (traits.isNotEmpty) 'traits': jsonEncode(traits),
      if (seller != null) 'seller': seller,
      if (refresh) 'refresh': '1',
    });
    return nftMap(await reads.get('$url'));
  }

  Future<Map<String, Object?>> owned(String address,
      {String? cursor, String? collection}) async {
    final rows = <Map<String, Object?>>[];
    final seen = <String>{};
    String? next = cursor;
    do {
      guard();
      final raw =
          await displayReads.walletPage(address, cursor: next, limit: 10);
      rows.addAll((raw['result'] as List? ?? []).map(nftMap).where((r) =>
          collection == null ||
          r['tick'].toString().toUpperCase() == collection));
      next = raw['next']?.toString();
      if (next != null && !seen.add(next)) {
        throw StateError('NFT indexer repeated a page. Please reload.');
      }
    } while (
        collection != null && rows.isEmpty && next != null && next.isNotEmpty);
    for (final row in rows) {
      row['ticker'] = (row['tick'] ?? '').toString().toUpperCase();
      row['tokenId'] = row['tokenId'].toString();
      row['imageUrl'] = Krc721Reads.image(
          row['ticker'].toString(), row['tokenId'].toString());
    }
    await Future.wait(
        rows.map((r) => r['ticker'].toString()).toSet().map((ticker) async {
      try {
        final metadata = await displayReads.metadata(
            ticker,
            rows
                .where((r) => r['ticker'] == ticker)
                .map((r) => r['tokenId'].toString())
                .toList());
        for (final row in rows.where((r) => r['ticker'] == ticker)) {
          final matches =
              metadata.where((m) => m['tokenId'].toString() == row['tokenId']);
          if (matches.isNotEmpty) {
            row['rarityRank'] = matches.first['rarityRank'];
          }
        }
      } catch (_) {/* Rarity metadata is optional; never invent a rank. */}
    }));
    return {'items': rows, 'next': next == '' ? null : next};
  }

  Future<Map<String, Object?>> descriptor(Map<String, Object?> r) =>
      security.prepareNftMarket({
        'action': 'describe',
        'sender': r['seller'],
        'seller': r['seller'],
        'ticker': r['ticker'],
        'tokenId': r['tokenId'],
      });
  Future<Map<String, Object?>> live(Map<String, Object?> offer) async {
    guard();
    final d = await descriptor(offer);
    final nft = nftMap(nftMap(await reads.get(
            '$indexer/nfts/${offer['ticker'].toString().toLowerCase()}/${offer['tokenId']}'))[
        'result']);
    final status = nftMap(nft['status']);
    if (nft['owner'] != offer['seller'] ||
        status['state'] != 'listed' ||
        status['listingTxId'] != offer['listingTransactionId']) {
      throw StateError(
          'This NFT is not currently listed by this seller. Refresh the market.');
    }
    final proof = nftMap(
        await reads.get('$node/transactions/${offer['listingTransactionId']}'));
    if (proof['is_accepted'] != true ||
        proof['transaction_id'] != offer['listingTransactionId']) {
      throw StateError('The NFT listing has not been accepted yet.');
    }
    final cells = await api.loadUtxos(d['listingAddress']! as String);
    if (!(jsonDecode(cells) as List).any((c) =>
        c['outpoint']['transactionId'] == offer['listingTransactionId'] &&
        c['outpoint']['index'] == 0)) {
      throw StateError(
          'The NFT listing is pending, sold or cancelled. Refresh and retry.');
    }
    return {...offer, 'listingUtxosJson': cells};
  }

  Future<void> publish(Map<String, Object?> record) {
    final id = record['localId']?.toString() ??
        record['listingTransactionId'].toString();
    return _publishing.putIfAbsent(
        id,
        () => _publish(record).whenComplete(() {
              _publishing.remove(id);
            }));
  }

  Future<void> _publish(Map<String, Object?> record) async {
    for (var attempt = 0; attempt < 12; attempt++) {
      guard();
      try {
        final response = await client
            .post(Uri.parse('$directory/offers'),
                headers: {'content-type': 'application/json'},
                body: jsonEncode(record))
            .timeout(const Duration(seconds: 30));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          String message = 'Publication temporarily unavailable.';
          try {
            message = nftMap(jsonDecode(response.body))['error']?.toString() ??
                message;
          } catch (_) {/* Proxy errors may not be JSON. */}
          final transient = response.statusCode == 429 ||
              response.statusCode >= 500 ||
              message.contains('Indexer has not confirmed') ||
              message.contains('Verification source unavailable');
          if (!transient) {
            record['publicationBlocked'] = true;
            record['publicationError'] = message;
            await save(record['seller']! as String, record);
            throw StateError(message);
          }
          if (attempt == 11) {
            throw StateError(
                'Listing saved. Publication will retry automatically when NFT Market is open. $message');
          }
        } else {
          guard();
          final latest = (await saved(record['seller']! as String))
              .where((r) => r['localId'] == record['localId']);
          if (latest.isNotEmpty &&
              ['sold', 'cancelled'].contains(latest.first['status'])) {
            return;
          }
          record['published'] = true;
          record.remove('publicationError');
          record.remove('publicationBlocked');
          record['status'] = 'active';
          await save(record['seller']! as String, record);
          return;
        }
      } on TimeoutException {
        if (attempt == 11) rethrow;
      } on http.ClientException {
        if (attempt == 11) rethrow;
      }
      await Future<void>.delayed(Duration(seconds: attempt < 3 ? 2 : 5));
    }
  }

  Future<void> create(String address, Map<String, Object?> nft, int price,
      NftReview approve) async {
    guard();
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(
        'kaspire_pending_inscription_v2_${address.toLowerCase()}')) {
      throw StateError(
          'Complete your pending asset reveal in Send → Assets first.');
    }
    final previous = await saved(address);
    if (previous.any((r) =>
        r['ticker'] == nft['ticker'] &&
        r['tokenId'] == nft['tokenId'] &&
        !['sold', 'cancelled'].contains(r['status']))) {
      throw StateError(
          'This NFT already has a saved listing. Use My listings to resume or cancel it.');
    }
    final owner = nftMap(nftMap(await reads.get(
            '$indexer/nfts/${nft['ticker'].toString().toLowerCase()}/${nft['tokenId']}'))[
        'result']);
    if (owner['owner'] != address) {
      throw StateError('This wallet does not own this NFT. Refresh My NFTs.');
    }
    if (nftMap(owner['status'])['state'] == 'listed') {
      throw StateError(
          'This NFT is already listed. Cancel its existing listing first.');
    }
    final feeAddress = await api.resolveWalletInput('hub21.kas');
    final operation = <String, Object?>{
      'kind': 'krc721-list',
      'sender': address,
      'recipient': address,
      'ticker': nft['ticker'],
      'tokenId': nft['tokenId']
    };
    final plan = await security.prepareInscription(operation);
    final commit = await signer.prepare(
        sender: address,
        recipient: plan['commitAddress']! as String,
        amountSompi: (plan['commitAmountSompi'] as num).toInt(),
        feeRate: await api.loadFeeRate(),
        utxosJson: await api.loadUtxos(address));
    if (!await approve('List NFT', {
      'NFT': '${nft['ticker']} #${nft['tokenId']}',
      'Seller': address,
      'Price (sompi)': price,
      'Marketplace fee (sompi)': (price * 21 + 999) ~/ 1000,
      'Fee recipient': feeAddress,
      'Listing reserve (sompi)': plan['commitAmountSompi'],
      'Commit network fee (sompi)': commit.feeSompi,
      'Settlement': 'PSKT · SINGLE|ANYONECANPAY · no escrow',
      'Note':
          'Listing reserve is returned with the seller payout. Reveal requires a separate authorization.'
    })) {
      return;
    }
    guard();
    final signed = await signer.sign(commit);
    final record = <String, Object?>{
      ...nft,
      'localId': signed.transactionId,
      'seller': address,
      'priceSompi': price,
      'feeAddress': feeAddress,
      'operation': operation,
      'plan': plan,
      'commitTransactionId': signed.transactionId,
      'commitSubmitJson': signed.submitJson,
      'status': 'pending',
      'stage': 'commit',
      'createdAt': DateTime.now().millisecondsSinceEpoch
    };
    // Persist BEFORE broadcast, including exact public transaction, so ambiguous
    // network failures never generate a second commit for the same NFT.
    await save(address, record);
    await resume(record, approve);
  }

  Future<String> waitCells(String address, String txid) async {
    for (var attempt = 0; attempt < 12; attempt++) {
      guard();
      final cells = await api.loadUtxos(address);
      if ((jsonDecode(cells) as List).any((c) =>
          c['outpoint']['transactionId'] == txid &&
          c['outpoint']['index'] == 0)) {
        return cells;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw StateError(
        'Transaction saved but not spendable yet. Open My listings and tap Resume.');
  }

  Future<void> acceptedOrBroadcast(String txid, String submitJson) async {
    guard();
    try {
      final tx = nftMap(await reads.get('$node/transactions/$txid'));
      if (tx['is_accepted'] == true) return;
    } catch (_) {/* rebroadcast only the same signed transaction */}
    await api.broadcast(submitJson);
  }

  Future<void> resume(Map<String, Object?> record, NftReview approve) async {
    guard();
    final address = record['seller']! as String;
    if (record['stage'] == 'commit') {
      final plan = nftMap(record['plan']);
      await acceptedOrBroadcast(record['commitTransactionId']! as String,
          record['commitSubmitJson']! as String);
      final cells = await waitCells(plan['commitAddress']! as String,
          record['commitTransactionId']! as String);
      final request = <String, Object?>{
        'operation': record['operation'],
        'commitTransactionId': record['commitTransactionId'],
        'commitUtxosJson': cells,
        'feeRate': await api.loadFeeRate()
      };
      final review = await security.prepareReveal(request);
      if (!await approve('Confirm NFT listing reveal', {
        'NFT': '${record['ticker']} #${record['tokenId']}',
        'Network fee (sompi)': review['feeSompi'],
        'Listing reserve (sompi)': review['returnSompi'],
        'Seller': address
      })) {
        return;
      }
      guard();
      final signed =
          await security.signReveal(request, review['reviewHash']! as String);
      record.addAll({
        'listingTransactionId': signed['transactionId'],
        'revealSubmitJson': signed['submitJson'],
        'stage': 'reveal'
      });
      await save(address, record);
    }
    if (record['stage'] == 'reveal') {
      await acceptedOrBroadcast(record['listingTransactionId']! as String,
          record['revealSubmitJson']! as String);
      record['stage'] = 'offer';
      await save(address, record);
    }
    if (record['stage'] == 'offer') {
      final d = await descriptor(record);
      final cells = await waitCells(d['listingAddress']! as String,
          record['listingTransactionId']! as String);
      final args = marketArgs(record, address, 'offer', cells);
      final built = await security.prepareNftMarket(args);
      final request = nftMap(built['request']);
      final review = await security.preparePskt(request);
      if (!await approve('Authorize seller PSKT', {
        'NFT': '${record['ticker']} #${record['tokenId']}',
        'Seller': address,
        'Price (sompi)': record['priceSompi'],
        'Seller payout including reserve (sompi)':
            (review['outputs'] as List).first['amountSompi'],
        'Marketplace fee (sompi)': built['feeSompi'],
        'Fee recipient': record['feeAddress'],
        'Signature': 'SINGLE|ANYONECANPAY · buyer adds funding',
        'Note':
            'Kaspire enforces the marketplace fee on purchases. An external PSKT consumer could omit this fee.'
      })) {
        return;
      }
      guard();
      final signed =
          await security.signPskt(request, review['reviewHash']! as String);
      record.addAll({
        'sellerPskt': signed['signedTxJson'],
        'status': 'active',
        'stage': 'complete',
        'published': false
      });
      await save(address, record);
    }
    if (record['stage'] == 'complete' && record['published'] != true) {
      await publish(record);
    }
  }

  Map<String, Object?> marketArgs(Map<String, Object?> offer, String sender,
          String action, String cells) =>
      {
        'action': action,
        'sender': sender,
        'seller': offer['seller'],
        'ticker': offer['ticker'],
        'tokenId': offer['tokenId'],
        'listingTransactionId': offer['listingTransactionId'],
        'listingUtxosJson': cells,
        'priceSompi': offer['priceSompi'],
        'feeAddress': offer['feeAddress'],
        if (action == 'buy') 'sellerPskt': offer['sellerPskt'],
      };
  Future<void> transact(String address, Map<String, Object?> offer,
      String action, NftReview approve) async {
    guard();
    if (await hasPendingBroadcast(address)) {
      throw StateError(
          'A signed marketplace transaction is awaiting submission. Open My listings → Resume saved transaction first.');
    }
    final checked = await live(offer);
    final args = marketArgs(
        offer, address, action, checked['listingUtxosJson']! as String);
    args['feeRate'] = await api.loadFeeRate();
    if (action == 'buy') args['walletUtxosJson'] = await api.loadUtxos(address);
    final built = await security.prepareNftMarket(args);
    final request = nftMap(built['request']);
    final review = await security.preparePskt(request);
    if (!await approve(action == 'buy' ? 'Buy NFT' : 'Cancel NFT listing', {
      'NFT': '${offer['ticker']} #${offer['tokenId']}',
      'Seller': offer['seller'],
      if (action == 'buy') 'Buyer': address,
      'Price (sompi)': action == 'buy' ? offer['priceSompi'] : 0,
      'Marketplace fee (sompi)': built['feeSompi'],
      'Fee recipient': offer['feeAddress'],
      'Network fee (sompi)': built['networkFeeSompi'],
      'Outputs': review['outputs'],
      'Transaction ID': review['transactionId']
    })) {
      return;
    }
    guard();
    await live(offer); // Recheck spendability after the review dialog.
    final signed =
        await security.signPskt(request, review['reviewHash']! as String);
    guard();
    if (signed['submitJson'] == null) {
      throw StateError(
          'NFT transaction is not fully funded. Nothing was broadcast.');
    }
    // Keep the exact signed transaction for ambiguous network failures.
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(
        'kaspire_nft_market_broadcast_$address',
        jsonEncode({
          ...signed,
          'listingTransactionId': offer['listingTransactionId']
        }))) {
      throw StateError(
          'Could not save transaction recovery. Nothing was broadcast.');
    }
    await api.broadcast(signed['submitJson']! as String);
    await notifyCompletion(offer['listingTransactionId']! as String,
        signed['transactionId']! as String);
    await prefs.remove('kaspire_nft_market_broadcast_$address');
    if (action == 'cancel') {
      offer['status'] = 'cancelled';
      if (offer['localId'] != null) await save(address, offer);
    }
    changes.value++;
  }

  Future<bool> hasPendingBroadcast(String address) async =>
      (await SharedPreferences.getInstance())
          .containsKey('kaspire_nft_market_broadcast_$address');
  Future<void> resumeBroadcast(String address) async {
    guard();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('kaspire_nft_market_broadcast_$address');
    if (raw == null) return;
    final signed = nftMap(jsonDecode(raw));
    await acceptedOrBroadcast(
        signed['transactionId']! as String, signed['submitJson']! as String);
    if (signed['listingTransactionId'] != null) {
      await notifyCompletion(signed['listingTransactionId']! as String,
          signed['transactionId']! as String);
    }
    await prefs.remove('kaspire_nft_market_broadcast_$address');
    changes.value++;
  }

  Future<void> notifyCompletion(String listingId, String transactionId) async {
    // Optional discovery notification: never turn a successful broadcast into
    // a transaction failure merely because the directory is unavailable.
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final response = await client
            .post(Uri.parse('$directory/completion'),
                headers: {'content-type': 'application/json'},
                body: jsonEncode({
                  'listingTransactionId': listingId,
                  'transactionId': transactionId
                }))
            .timeout(const Duration(seconds: 5));
        if (response.statusCode == 200) return;
      } catch (_) {}
      if (attempt < 2) await Future<void>.delayed(const Duration(seconds: 1));
    }
  }
}
