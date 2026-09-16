import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dotk_service.dart';
import 'kaspa_api.dart';
import 'native_security.dart';
import 'network_settings.dart';
import 'marketplace_reads.dart';

typedef MarketMap = Map<String, Object?>;

enum DotkOfferState { active, pending, sold, cancelled, unavailable }

List<DotkOffer> sortMarketOffers(List<DotkOffer> offers,
    {bool descending = false}) {
  final sorted = [...offers];
  sorted.sort((a, b) {
    final price =
        (a.terms['priceSompi'] as int).compareTo(b.terms['priceSompi'] as int);
    return price == 0
        ? a.name.compareTo(b.name)
        : descending
            ? -price
            : price;
  });
  return sorted;
}

/// Recovery entries are persisted in creation order. Reverse within each
/// status group without changing persistence order on refresh/publication.
List<DotkOffer> sortMyMarketOffers(
    List<DotkOffer> saved, Map<String, DotkOfferStatus> states) {
  int group(DotkOffer offer) => switch (states[offer.listingTxId]?.state) {
        DotkOfferState.active => 0,
        DotkOfferState.sold || DotkOfferState.cancelled => 2,
        _ => 1,
      };
  return [
    for (var priority = 0; priority < 3; priority++)
      ...saved.reversed.where((offer) => group(offer) == priority),
  ];
}

class DotkOfferStatus {
  const DotkOfferStatus(this.state, {this.transactionId});
  final DotkOfferState state;
  final String? transactionId;
  String get label => switch (state) {
        DotkOfferState.active => 'Listed · locked in sale covenant',
        DotkOfferState.pending => 'Awaiting confirmation',
        DotkOfferState.sold => 'Sold',
        DotkOfferState.cancelled => 'Cancelled · name returned to seller',
        DotkOfferState.unavailable => 'Status unavailable · retry verification',
      };
}

class DotkOffer {
  DotkOffer(
      {required this.terms, required this.listingTxId, required this.saleId});
  final MarketMap terms;
  final String listingTxId;
  final String saleId;
  String get name => '${terms['name']}.k';
  String get seller => terms['seller'] as String;
  MarketMap toJson() =>
      {'terms': terms, 'listingTxId': listingTxId, 'saleId': saleId};
  factory DotkOffer.fromJson(Object? raw) {
    final row = (raw as Map).cast<String, Object?>();
    final terms = (row['terms'] as Map).cast<String, Object?>();
    DotkService.bareName('${terms['name']}.k');
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(row['listingTxId'].toString()) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(row['saleId'].toString()) ||
        terms['priceSompi'] is! int ||
        terms['seller'] is! String ||
        terms['feeAddress'] is! String) {
      throw const FormatException('Invalid marketplace offer');
    }
    return DotkOffer(
        terms: terms,
        listingTxId: row['listingTxId'] as String,
        saleId: row['saleId'] as String);
  }
}

class DotkMarketService {
  DotkMarketService({http.Client? client}) : _client = client ?? http.Client();
  static const enabled =
      bool.fromEnvironment('KASPIRE_DOTK_MARKET', defaultValue: true);
  static const directory = 'https://kaspire.kaslab.space/market-test-v1';
  static const node = 'https://kaspire.kaslab.space/api/local-node';
  static const _key = 'dotk_market_recovery_v1';
  static final changes = ValueNotifier<int>(0);
  final _native = NativeSecurity();
  final _api = KaspaApi();
  final http.Client _client;
  late final _reads = MarketplaceReads(_client);
  void close() {
    _reads.close();
    _client.close();
  }

  void _network() {
    if (!enabled || NetworkSettings.network.value != KaspaNetwork.mainnet) {
      throw StateError('The dot.k marketplace is available on Layer 1 only.');
    }
  }

  Future<Object?> _get(String url) => _reads.get(url);

  Future<List<DotkOffer>> search(String query) async {
    final result = <DotkOffer>[];
    int? offset = 0;
    while (offset != null && result.length < 1000) {
      final page = (await _get(
              '$directory/offers?q=${Uri.encodeComponent(query.trim().toLowerCase())}&offset=$offset')
          as Map);
      result.addAll((page['offers'] as List).map(DotkOffer.fromJson));
      final next = page['nextOffset'];
      if (next != null && (next is! int || next <= offset)) {
        throw const FormatException('Invalid marketplace pagination');
      }
      offset = next as int?;
    }
    return result;
  }

  Future<List<DotkOffer>> saved([String? seller]) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    return (jsonDecode(raw) as List)
        .map(DotkOffer.fromJson)
        .where((o) => seller == null || o.seller == seller)
        .toList();
  }

  Future<void> save(DotkOffer offer) async {
    final rows = await saved();
    if (rows.any((o) => jsonEncode(o.toJson()) == jsonEncode(offer.toJson()))) {
      return;
    }
    rows.removeWhere((o) => o.listingTxId == offer.listingTxId);
    rows.add(offer);
    final success = await (await SharedPreferences.getInstance())
        .setString(_key, jsonEncode(rows.map((o) => o.toJson()).toList()));
    if (!success) {
      throw StateError(
          'Recovery data could not be saved. Nothing was broadcast.');
    }
    changes.value++;
  }

  Future<void> publish(DotkOffer offer) async {
    final response = await _client
        .post(Uri.parse('$directory/offers'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode(offer.toJson()))
        .timeout(const Duration(seconds: 25));
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw StateError(
          'Offer is saved on this device, but directory publication is pending. Retry Publish after confirmation.');
    }
  }

  Future<MarketMap> _cell(
      String address, String script, String covenant, int amount,
      {String? txid,
      int? index,
      Future<Map> Function()? transactionProof}) async {
    final rows =
        (await _get('$node/addresses/${Uri.encodeComponent(address)}/utxos')
            as List);
    for (final raw in rows.whereType<Map>()) {
      final point = raw['outpoint'] as Map;
      final entry = raw['utxoEntry'] as Map;
      final spk = entry['scriptPublicKey'] as Map;
      if (entry['amount'].toString() != '$amount' ||
          entry['isCoinbase'] != false ||
          spk['scriptPublicKey'] != script ||
          (txid != null && txid != point['transactionId']) ||
          (index != null && index != point['index'])) {
        continue;
      }
      final id = point['transactionId'].toString();
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(id)) continue;
      final tx = transactionProof == null
          ? (await _get('$node/transactions/$id') as Map)
          : await transactionProof();
      if (tx['transaction_id'] != id || tx['is_accepted'] != true) continue;
      if (!(tx['outputs'] as List).whereType<Map>().any((o) =>
          o['index'] == point['index'] &&
          o['covenant_id'] == covenant &&
          o['script_public_key'] == script &&
          o['amount'].toString() == '$amount')) {
        continue;
      }
      return {
        'transactionId': id,
        'index': point['index'],
        'valueSompi': amount,
        'blockDaaScore': int.parse(entry['blockDaaScore'].toString()),
        'scriptPublicKey': script,
        'covenantId': covenant
      };
    }
    throw StateError(
        'This name or listing is not currently spendable. It may be pending, sold or cancelled.');
  }

  Future<List<MarketMap>> verifiedCells(DotkOffer offer) async {
    final d = await _native
        .describeDotkMarket({'terms': offer.terms, 'saleId': offer.saleId});
    final deed = d['deed'] as Map;
    Future<Map>? proof;
    Future<Map> loadProof() =>
        proof ??= _get('$node/transactions/${offer.listingTxId}')
            .then((value) => value as Map);
    return Future.wait([
      _cell(deed['deedAddress'] as String, deed['scriptPublicKey'] as String,
          DotkService.registry, 100000000,
          txid: offer.listingTxId, index: 0, transactionProof: loadProof),
      _cell(d['saleAddress'] as String, d['saleScriptPublicKey'] as String,
          offer.saleId, 100000000,
          txid: offer.listingTxId, index: 1, transactionProof: loadProof),
    ]);
  }

  /// History is only a discovery source: classification requires an accepted
  /// node transaction consuming BOTH exact listing outpoints and the agreed
  /// payouts. A changed current owner alone never proves this offer sold.
  Future<DotkOfferStatus> status(DotkOffer offer) async {
    try {
      await verifiedCells(offer);
      return const DotkOfferStatus(DotkOfferState.active);
    } on MarketplaceReadUnavailable {
      // Do not amplify a rate limit/outage with unrelated history requests.
      return const DotkOfferStatus(DotkOfferState.unavailable);
    } catch (_) {/* Check for an accepted completion, never assume sold. */}
    try {
      final key = await _get(
          'https://api.dotk.name/v1/names/${offer.terms['name']}/key') as Map;
      if (key['registryCovenantId'] != DotkService.registry ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch('${key['key']}')) {
        return const DotkOfferStatus(DotkOfferState.unavailable);
      }
      final descriptor = await _native
          .describeDotkMarket({'terms': offer.terms, 'saleId': null});
      final sellerDeed =
          (descriptor['deed'] as Map)['scriptPublicKey'] as String;
      for (var offset = 0; offset < 2000; offset += 100) {
        final history = await _get(
                'https://api.dotk.name/v1/keys/${key['key']}/history?limit=100&offset=$offset')
            as Map;
        if (history['registryCovenantId'] != DotkService.registry) break;
        final entries = history['entries'] as List;
        for (final event in entries.whereType<Map>()) {
          final id = event['txid'].toString();
          if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) continue;
          if (id == offer.listingTxId) break;
          final tx = await _get('$node/transactions/$id') as Map;
          final result = completionStatus(offer, tx, sellerDeed);
          if (result != null) return result;
        }
        if (entries.length < 100 ||
            (history['total'] is int &&
                offset + entries.length >= (history['total'] as int)) ||
            entries
                .whereType<Map>()
                .any((e) => e['txid'] == offer.listingTxId)) {
          break;
        }
      }
      final listing =
          await _get('$node/transactions/${offer.listingTxId}') as Map;
      if (listing['transaction_id'] == offer.listingTxId &&
          listing['is_accepted'] == false) {
        return const DotkOfferStatus(DotkOfferState.pending);
      }
    } catch (_) {/* No terminal state without proof. */}
    return const DotkOfferStatus(DotkOfferState.unavailable);
  }

  static DotkOfferStatus? completionStatus(
      DotkOffer offer, Map tx, String sellerDeed) {
    if (tx['is_accepted'] != true ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch('${tx['transaction_id']}')) {
      return null;
    }
    final inputs = tx['inputs'];
    final outputs = tx['outputs'];
    if (inputs is! List || outputs is! List) return null;
    for (final index in [0, 1]) {
      if (inputs
              .whereType<Map>()
              .where((i) =>
                  i['previous_outpoint_hash'] == offer.listingTxId &&
                  i['previous_outpoint_index'].toString() == '$index')
              .length !=
          1) {
        return null;
      }
    }
    Map? out(int index) {
      final matches =
          outputs.whereType<Map>().where((o) => o['index'] == index).toList();
      return matches.length == 1 ? matches.single : null;
    }

    final deed = out(0), seller = out(1), fee = out(2);
    if (deed == null ||
        seller == null ||
        deed['covenant_id'] != DotkService.registry ||
        deed['amount'].toString() != '100000000' ||
        seller['script_public_key_address'] != offer.seller ||
        seller['covenant_id'] != null) {
      return null;
    }
    final price = BigInt.from(offer.terms['priceSompi'] as int);
    final commission = price * BigInt.from(21) ~/ BigInt.from(1000);
    if (seller['amount'].toString() ==
            (price - commission + BigInt.from(100000000)).toString() &&
        fee != null &&
        fee['amount'].toString() == commission.toString() &&
        fee['script_public_key_address'] == offer.terms['feeAddress'] &&
        fee['covenant_id'] == null) {
      return DotkOfferStatus(DotkOfferState.sold,
          transactionId: tx['transaction_id'] as String);
    }
    if (seller['amount'].toString() == '100000000' &&
        deed['script_public_key'] == sellerDeed) {
      return DotkOfferStatus(DotkOfferState.cancelled,
          transactionId: tx['transaction_id'] as String);
    }
    return null;
  }

  Future<Map<String, DotkOfferStatus>> statuses(
      Iterable<DotkOffer> offers) async {
    final unique =
        {for (final offer in offers) offer.listingTxId: offer}.values.toList();
    final result = <String, DotkOfferStatus>{};
    for (var i = 0; i < unique.length; i += 4) {
      await Future.wait(unique.skip(i).take(4).map((o) async {
        result[o.listingTxId] = await status(o);
      }));
    }
    return result;
  }

  Future<MarketMap> listingRequest(
      String sender, String name, int price) async {
    _network();
    final feeAddress = await _api.resolveWalletInput('hub21.kas');
    final terms = <String, Object?>{
      'name': DotkService.bareName(name),
      'seller': sender,
      'priceSompi': price,
      'feeAddress': feeAddress
    };
    final descriptor =
        await _native.describeDotkMarket({'terms': terms, 'saleId': null});
    final deed = descriptor['deed'] as Map;
    final input = await _cell(deed['deedAddress'] as String,
        deed['scriptPublicKey'] as String, DotkService.registry, 100000000);
    return _fund({
      'action': 'list',
      'sender': sender,
      'terms': terms,
      'deed': input,
      'sale': null
    });
  }

  Future<MarketMap> spendingRequest(String sender, DotkOffer offer,
      {required bool cancel}) async {
    _network();
    final cells = await verifiedCells(offer);
    return _fund({
      'action': cancel ? 'cancel' : 'buy',
      'sender': sender,
      'terms': offer.terms,
      'deed': cells[0],
      'sale': cells[1]
    });
  }

  Future<MarketMap> _fund(MarketMap request) async {
    final funding = await _get(
            '$node/addresses/${Uri.encodeComponent(request['sender'] as String)}/utxos')
        as List;
    final rows = funding
        .whereType<Map>()
        .where((r) => (r['utxoEntry'] as Map)['isCoinbase'] == false)
        .map((r) => {...r, 'address': request['sender']})
        .toList();
    request['fundingUtxosJson'] = jsonEncode(rows);
    request['feeRate'] = (await _api.loadFeeRate()).ceil();
    _network();
    return request;
  }

  Future<MarketMap> prepare(MarketMap request) {
    _network();
    return _native.prepareDotkMarket(request);
  }

  Future<MarketMap> sign(MarketMap request, MarketMap review) async {
    _network();
    final signed =
        await _native.signDotkMarket(request, review['reviewHash'] as String);
    _network();
    if (request['action'] == 'list') {
      await save(DotkOffer(
          terms: (request['terms'] as Map).cast<String, Object?>(),
          listingTxId: signed['transactionId'] as String,
          saleId: review['covenantId'] as String));
    }
    return signed;
  }

  Future<String> broadcast(MarketMap signed) {
    _network();
    return _api.broadcastKcc20(signed['wrpcJson'] as String,
        expectedTransactionId: signed['transactionId'] as String);
  }
}
