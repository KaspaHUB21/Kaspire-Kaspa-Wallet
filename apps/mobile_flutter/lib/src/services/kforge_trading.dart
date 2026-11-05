import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../kaspa_address.dart';
import '../number_format.dart';
import 'braid_clock.dart';
import 'encrypted_store.dart';
import 'kforge_service.dart';
import 'native_security.dart';
import 'swap_conflict_lookup.dart';

class KForgeLookupUnavailable implements Exception {
  const KForgeLookupUnavailable({this.statusCode});
  final int? statusCode;
  @override
  String toString() =>
      'Independent node verification is temporarily unavailable. Please retry shortly. Any saved transaction remains preserved.';
}

/// Atomic KForge swaps, NOT sequenced KasForge orders. Never persist a
/// mere unsigned quote as a pending payment. Signed bytes are retained before
/// the first submission and are never dropped on 404, timeout or missing UTXO.
class KForgeTrading {
  static final changes = ValueNotifier<int>(0);
  KForgeTrading(
      {http.Client? client,
      EncryptedStore? store,
      NativeSecurity? security,
      bool? mainnet,
      Future<void> Function(Duration)? lookupWait})
      : client = client ?? http.Client(),
        store = store ?? const KeystoreEncryptedStore(),
        security = security ?? NativeSecurity(),
        _lookupWait = lookupWait ?? ((delay) => Future<void>.delayed(delay)),
        service = KForgeService(client: client, mainnet: mainnet);
  final http.Client client;
  final EncryptedStore store;
  final NativeSecurity security;
  final Future<void> Function(Duration) _lookupWait;
  final KForgeService service;
  bool get mainnet => service.mainnet;
  String get network => service.network;
  String get node => mainnet
      ? 'https://kaspire.kaslab.space/api/local-node'
      : 'https://api-tn10.kaspa.org';
  final progress = ValueNotifier<String?>(null);
  static final _busy = <String>{};
  void guard(String address) => service.guard(address);
  String key(String address) => mainnet
      ? 'kforge_mainnet_atomic_v1_$address'
      : 'kforge_tn10_atomic_v1_$address';
  Future<T> exclusive<T>(String address, Future<T> Function() action) async {
    guard(address);
    if (!_busy.add(address))
      throw StateError('A KForge swap is already being processed.');
    try {
      return await action();
    } finally {
      _busy.remove(address);
      progress.value = null;
    }
  }

  Future<Map<String, dynamic>> call(
      String address, String path, Map body) async {
    guard(address);
    const allowed = {
      '/v6/buy/direct/prepare',
      '/v6/sell/prepare',
      '/v6/swap/buy/prepare',
      '/v6/swap/sell/prepare',
      '/v6/buy/direct/submit',
      '/v6/sell/submit',
      '/v6/swap/submit'
    };
    if (!allowed.contains(path))
      throw StateError('Unsupported KForge request.');
    final r = await client
        .post(Uri.parse('${service.origin}$path'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    guard(address);
    if (r.bodyBytes.length > 1024 * 1024)
      throw StateError('KForge response exceeds the safety limit.');
    final d = jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode != 200 ||
        d is! Map ||
        d['error'] != null ||
        d['ok'] == false) {
      throw StateError(
          'KForge (${r.statusCode}): ${d is Map ? d['error'] ?? d['message'] ?? 'request unavailable' : 'invalid response'}');
    }
    return Map<String, dynamic>.from(d);
  }

  Future<List<Map<String, dynamic>>> saved(String address) async {
    guard(address);
    final text = await store.read(key(address));
    if (text == null) return [];
    final rows = jsonDecode(text);
    if (rows is! List || rows.length > 200)
      throw StateError(
          'Saved KForge swaps are unreadable. Do not create a replacement.');
    return rows.map((r) {
      if (r is! Map ||
          r['address'] != address ||
          r['network'] != network ||
          r['signed'] is! Map ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch('${r['id']}')) {
        throw StateError(
            'Saved KForge swap is invalid; its bytes remain preserved.');
      }
      return Map<String, dynamic>.from(r);
    }).toList();
  }

  Future<Map<String, dynamic>?> pending(String address) async =>
      (await saved(address)).where((r) => r['state'] == 'pending').firstOrNull;
  Future<void> retain(String address, Map<String, dynamic> receipt) async {
    guard(address);
    if (receipt['address'] != address || receipt['network'] != network)
      throw StateError('Wrong recovery wallet/network.');
    final rows = await saved(address), id = receipt['id'];
    final at = rows.indexWhere((r) => r['id'] == id);
    final previousState = at < 0 ? null : rows[at]['state'];
    if (at < 0) {
      if (rows.length >= 200)
        throw StateError('Export your KForge history before continuing.');
      rows.add(receipt);
    } else {
      rows[at] = receipt;
    }
    final text = jsonEncode(rows);
    await store.write(key(address), text);
    if (await store.read(key(address)) != text)
      throw StateError(
          'KForge recovery could not be saved; nothing may be submitted.');
    if (receipt['state'] == 'confirmed' &&
        (at < 0 || previousState != 'confirmed')) changes.value++;
  }

  String inputAddress(String spk) {
    if (RegExp(r'^000020[0-9a-f]{64}ac$').hasMatch(spk)) {
      return kaspaAddressFromOwnerId(spk.substring(6, 70),
          prefix: service.prefix);
    }
    if (RegExp(r'^0000aa20[0-9a-f]{64}87$').hasMatch(spk)) {
      return kaspaScriptHashAddress(spk.substring(8, 72),
          prefix: service.prefix);
    }
    throw StateError('Unsupported KForge input script.');
  }

  Future<Object?> read(String uri,
      {Duration timeout = const Duration(seconds: 15)}) async {
    // Retry read-only overload responses, never signing/submission requests.
    // All attempts and waits share one deadline; a timeout is never zero,
    // proof of a conflict or permission to discard a saved transaction.
    final elapsed = Stopwatch()..start();
    const delays = [250, 750, 1500];
    for (var attempt = 0;; attempt++) {
      final remaining = timeout - elapsed.elapsed;
      if (remaining <= Duration.zero) throw const KForgeLookupUnavailable();
      final http.Response response;
      try {
        response = await client.get(Uri.parse(uri)).timeout(remaining);
      } on TimeoutException {
        throw const KForgeLookupUnavailable();
      } on http.ClientException {
        throw const KForgeLookupUnavailable();
      }
      if (response.bodyBytes.length > 4 * 1024 * 1024) {
        throw const KForgeLookupUnavailable();
      }
      if (response.statusCode == 404) return null;
      if (response.statusCode == 200) {
        try {
          return jsonDecode(utf8.decode(response.bodyBytes));
        } on FormatException {
          throw const KForgeLookupUnavailable();
        }
      }
      if (!const {429, 502, 503, 504}.contains(response.statusCode) ||
          attempt == delays.length) {
        throw KForgeLookupUnavailable(statusCode: response.statusCode);
      }
      final retryAfter = int.tryParse(response.headers['retry-after'] ?? '');
      final delay = retryAfter != null && retryAfter > 0
          ? Duration(seconds: retryAfter.clamp(1, 2).toInt())
          : Duration(milliseconds: delays[attempt]);
      if (delay >= timeout - elapsed.elapsed) {
        throw KForgeLookupUnavailable(statusCode: response.statusCode);
      }
      await _lookupWait(delay);
    }
  }

  Future<void> verify(String address, Map tx) async {
    guard(address);
    final cache = <String, List>{}, seen = <String>{};
    final elapsed = Stopwatch()..start();
    final inputs = (tx['inputs'] as List).cast<Map>();
    if (inputs.length > 4) throw StateError('Unexpected KForge input count.');
    // One paced lookup at a time, deduplicated within THIS verification only.
    // Four concurrent inputs previously overflowed the reader's three slots.
    // Signing calls verify again with a fresh cache after user approval.
    for (final input in inputs) {
      guard(address);
      final point = '${input['transactionId']}:${input['index']}';
      if (!RegExp(r'^[a-f0-9]{64}:[0-9]+$').hasMatch(point) || !seen.add(point))
        throw StateError('Invalid or duplicate KForge input.');
      final u = input['utxo'] as Map,
          owner = inputAddress('${input['utxo']['scriptPublicKey']}');
      List rows;
      if (cache.containsKey(owner)) {
        rows = cache[owner]!;
      } else {
        if (cache.isNotEmpty) {
          await _lookupWait(const Duration(milliseconds: 220));
        }
        guard(address);
        final remaining = const Duration(seconds: 15) - elapsed.elapsed;
        if (remaining <= Duration.zero) throw const KForgeLookupUnavailable();
        // Our fixed wRPC-backed reader retains covenant IDs. The ordinary
        // REST UTXO route omits them and cannot authorize these inputs.
        final data = await read(
            Uri.parse(
                    'https://kaspire.kaslab.space/dex-test-v1/${mainnet ? 'kasseal-mainnet' : 'kasseal'}/utxos')
                .replace(queryParameters: {'address': owner}).toString(),
            timeout: remaining);
        guard(address);
        if (data is! Map ||
            data['network'] != network ||
            data['covenantIdsIncluded'] != true ||
            data['entries'] is! List)
          throw StateError('Independent KForge input discovery is incomplete.');
        rows = cache[owner] = data['entries'] as List;
      }
      final matches = rows
          .whereType<Map>()
          .where((r) =>
              r['outpoint']['transactionId'] == input['transactionId'] &&
              '${r['outpoint']['index']}' == '${input['index']}')
          .toList();
      if (matches.length != 1)
        throw StateError(
            'The pool or wallet changed. Refresh quote; nothing was signed.');
      final e = matches.single['utxoEntry'] as Map,
          s = e['scriptPublicKey'] as Map;
      final packed =
          '${(s['version'] as int).toRadixString(16).padLeft(4, '0')}${s['script']}';
      if (packed != u['scriptPublicKey'] ||
          '${e['amount']}' != '${u['amount']}' ||
          e['covenantId'] != u['covenantId'] ||
          e['isCoinbase'] != false)
        throw StateError('KForge input differs from the independent node.');
      u['address'] = owner;
      u['blockDaaScore'] = '${e['blockDaaScore']}';
    }
    guard(address);
  }

  /// Buy amounts are ALWAYS a KAS trade budget in sompi; sell amounts are
  /// whole tokens. Curve lots are an internal protocol detail, never UI units.
  @visibleForTesting
  static BigInt curveBuyCost(KForgeToken token, int lots) {
    final base = BigInt.parse('${token.market['base']}'),
        slope = BigInt.parse('${token.market['slope']}'),
        sold = BigInt.parse('${token.market['sold']}');
    if (base <= BigInt.zero ||
        slope < BigInt.zero ||
        sold < BigInt.zero ||
        sold > BigInt.from(650) ||
        lots < 0 ||
        lots > 650 - sold.toInt())
      throw StateError('The curve state is unavailable. Refresh the token.');
    final n = BigInt.from(lots);
    return n * base +
        slope * (sold * n + n * (n - BigInt.one) ~/ BigInt.from(2));
  }

  @visibleForTesting
  static int curveBuyLots(KForgeToken token, BigInt kasBudget) {
    final sold = int.parse('${token.market['sold']}');
    if (sold < 0 || sold >= 650)
      throw StateError(
          'This curve is graduating. Reopen the token for its current market.');
    var low = 0, high = 650 - sold;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      if (curveBuyCost(token, middle) <= kasBudget) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    if (low == 0)
      throw StateError('The minimum curve buy currently costs '
          '${formatRawTokenAmount(curveBuyCost(token, 1), 8)} KAS '
          'before network fees and token-cell reserves.');
    return low;
  }

  Future<Map<String, dynamic>> quote(
      String address, KForgeToken selected, String side, BigInt amount) async {
    guard(address);
    if (await pending(address) != null)
      throw StateError('Check the saved KForge swap before creating another.');
    if (amount <= BigInt.zero ||
        amount > BigInt.from(1 << 52) ||
        !['buy', 'sell'].contains(side))
      throw StateError('Enter a positive supported amount.');
    final rows = await service.catalogue();
    final token = rows.where((t) => t.id == selected.id).firstOrNull;
    if (token == null) throw StateError('KForge token is no longer indexed.');
    if (token.graduated != selected.graduated) {
      throw StateError(
          'This market changed between curve and pool. Reopen the token for a fresh quote. Nothing was signed.');
    }
    final buy = side == 'buy', pool = token.graduated;
    if (!buy && !pool && amount % BigInt.from(1000000) != BigInt.zero)
      throw StateError('Curve trades require whole lots of 1,000,000 tokens.');
    final requestAmount = pool
        ? amount
        : buy
            ? BigInt.from(curveBuyLots(token, amount))
            : amount ~/ BigInt.from(1000000);
    final path = pool
        ? '/v6/swap/$side/prepare'
        : buy
            ? '/v6/buy/direct/prepare'
            : '/v6/sell/prepare';
    final response = await call(address, path, {
      'token': token.curve,
      buy ? 'buyer' : 'seller': address,
      !pool
          ? 'qty'
          : buy
              ? 'kas'
              : 'tokens': requestAmount.toInt()
    });
    final tx = jsonDecode(response['txJson'] as String) as Map;
    if (response['inputIndex'] is! int ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch('${response['sighash']}'))
      throw StateError('Invalid KForge signing selection.');
    await verify(address, tx);
    var existing = response['mergedInto'] is Map
        ? (response['mergedInto'] as Map)['amount']
        : response['merged'] is Map
            ? (response['merged'] as Map)['amount']
            : null;
    if (buy && (tx['inputs'] as List).length == 4 && existing == null) {
      // An indexed quantity is only a hint: Rust still rebuilds the exact
      // program against the independently verified live input commitment.
      final data =
          await service.read('/v6/holdings/${Uri.encodeComponent(address)}');
      if (data is! Map ||
          data['wallet'] != address ||
          data['holdings'] is! List)
        throw StateError(
            'Existing KForge cell metadata is unavailable. Nothing was signed.');
      final cells = (data['holdings'] as List)
          .whereType<Map>()
          .where((h) =>
              h['tokenCovId'] == token.id && h['rungCovId'] == token.curve)
          .expand((h) => (h['utxos'] as List? ?? const []).whereType<Map>())
          .where((u) =>
              u['outpoint'] ==
              '${tx['inputs'][1]['transactionId']}:${tx['inputs'][1]['index']}')
          .toList();
      if (cells.length != 1)
        throw StateError(
            'Existing KForge cell metadata is incomplete. Refresh quote.');
      existing = cells.single['amount'];
    }
    final request = <String, Object?>{
      'sender': address,
      'profile': mainnet ? 'kforge-mainnet-swap-v1' : 'kforge-tn10-swap-v1',
      'tokenId': token.id,
      'lpCovenantId': pool ? token.pool : token.curve,
      'ticker': token.symbol,
      'side': side,
      'tradeSummary': {
        'network': network, 'market': token.market,
        'amount': '$requestAmount',
        if (buy) 'buyBudgetSompi': '$amount',
        // Exact totals are independently computed below, then bound into a
        // second native review before they are ever shown or approved.
        'maximumDebit': '4500000000000000', 'minimumOut': '1',
        'existingAmount': existing ?? 0,
        'leftover': response['leftover'] ?? 0
      },
      'txJsonString': jsonEncode(tx),
      'scripts': <Object?>[],
      'signInputs': [
        {
          'index': response['inputIndex'],
          'sighashType': 1,
          'expectedSighash': response['sighash']
        }
      ]
    };
    final preliminary = await security.preparePskt(request);
    final verified = ((preliminary['tradeSummary'] as Map)['verified'] as Map);
    final terms = request['tradeSummary'] as Map;
    terms['maximumDebit'] = verified['walletNet'];
    terms['minimumOut'] = buy ? verified['tokens'] : verified['walletNet'];
    final review = await security.preparePskt(request);
    return {
      'request': request,
      'review': review,
      'at': DateTime.now().millisecondsSinceEpoch,
      'path': pool
          ? '/v6/swap/submit'
          : buy
              ? '/v6/buy/direct/submit'
              : '/v6/sell/submit',
      'sighash': response['sighash'],
      'symbol': token.symbol,
      'side': side,
      'tokenId': token.id
    };
  }

  /// Extract exactly one signed wallet witness, not a signature at an arbitrary
  /// byte offset. A token witness is normal-path 00 || Schnorr || SIGHASH_ALL.
  @visibleForTesting
  static String signature(Map tx, int index) {
    final hex = '${tx['inputs'][index]['signatureScript']}';
    if (!RegExp(r'^[0-9a-f]+$').hasMatch(hex) || hex.length.isOdd)
      throw StateError('Invalid KForge signed witness.');
    final bytes = [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16)
    ];
    final pushes = <List<int>>[];
    for (var i = 0; i < bytes.length;) {
      var n = bytes[i++];
      if (n == 76) {
        if (i >= bytes.length) throw StateError('Truncated KForge witness.');
        n = bytes[i++];
      } else if (n == 77) {
        if (i + 1 >= bytes.length)
          throw StateError('Truncated KForge witness.');
        n = bytes[i] | bytes[i + 1] << 8;
        i += 2;
      } else if (n > 75) {
        throw StateError('Unexpected KForge witness opcode.');
      }
      if (i + n > bytes.length) throw StateError('Truncated KForge witness.');
      pushes.add(bytes.sublist(i, i + n));
      i += n;
    }
    List<int> sig;
    if (pushes.length == 1) {
      sig = pushes.single;
    } else {
      if (pushes.length != 9 ||
          pushes[7].join(',') != '121,199,28,35' ||
          pushes[6].length != 66 ||
          pushes[6][0] != 0)
        throw StateError('Unexpected KForge token signature layout.');
      sig = pushes[6].sublist(1);
    }
    if (sig.length != 65 || sig.last != 1)
      throw StateError('KForge requires a Schnorr SIGHASH_ALL signature.');
    return sig.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<Map<String, dynamic>> sign(String address, Map plan) async {
    guard(address);
    if (await pending(address) != null)
      throw StateError('A signed KForge swap is still pending.');
    if (DateTime.now().millisecondsSinceEpoch - (plan['at'] as int) > 60000)
      throw StateError('Quote expired. Refresh quote; nothing was signed.');
    final request = Map<String, Object?>.from(plan['request'] as Map),
        review = plan['review'] as Map;
    final tx = jsonDecode(request['txJsonString'] as String) as Map;
    await verify(address, tx);
    // The review hash includes the independent input metadata. Do not silently
    // swap it during a PIN prompt; a changed plan must get a new review.
    if (jsonEncode(tx) != request['txJsonString'])
      throw StateError('Input confirmation changed. Refresh quote.');
    final signed = await security.signPskt(request, '${review['reviewHash']}');
    final id = '${signed['transactionId']}',
        complete = jsonDecode(signed['signedTxJson'] as String) as Map;
    if (id != review['transactionId'] || signed['wrpcJson'] is! String)
      throw StateError('Signed KForge transaction differs from review.');
    complete['id'] = id;
    final sig = signature(complete,
        ((request['signInputs'] as List).single as Map)['index'] as int);
    final receipt = <String, dynamic>{
      'address': address,
      'network': network,
      'id': id,
      'state': 'pending',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'signed': complete,
      'wrpc': jsonDecode(signed['wrpcJson'] as String),
      'request': request,
      'path': plan['path'],
      'sighash': plan['sighash'],
      'signature': sig,
      'symbol': plan['symbol'],
      'side': plan['side'],
      'tokenId': plan['tokenId'],
      'verified': (review['tradeSummary'] as Map)['verified']
    };
    await retain(address, receipt);
    return receipt;
  }

  Future<bool> accepted(String id) async {
    final d = await read('$node/transactions/$id');
    return d is Map && d['transaction_id'] == id && d['is_accepted'] == true;
  }

  Future<Map<String, dynamic>> resume(
      String address, Map<String, dynamic> receipt,
      {bool submit = true}) async {
    guard(address);
    if (receipt['address'] != address || receipt['network'] != network)
      throw StateError('Wrong recovery wallet.');
    final id = '${receipt['id']}';
    if (receipt['state'] != 'pending') return receipt;
    progress.value = 'Checking saved transaction…';
    if (await accepted(id)) {
      receipt['state'] = 'confirmed';
      await retain(address, receipt);
      return receipt;
    }
    // If a positively confirmed competing spend exists, this exact atomic swap
    // can never execute. A negative lookup never counts as that proof.
    String? conflict;
    try {
      await verify(address, receipt['signed'] as Map);
    } catch (_) {
      conflict = await findConfirmedSwapConflict(
          tx: receipt['signed'] as Map,
          savedIds: {id},
          node: node,
          prefix: '${service.prefix}:',
          read: read);
      if (conflict != null) {
        receipt['state'] = 'obsolete';
        receipt['conflict'] = conflict;
        await retain(address, receipt);
        return receipt;
      }
      return receipt;
    }
    if (submit) {
      progress.value = 'Submitting the same saved swap…';
      try {
        await call(address, receipt['path'] as String,
            {'sighash': receipt['sighash'], 'signature': receipt['signature']});
      } catch (e) {
        receipt['submissionError'] = '$e';
        await retain(address, receipt);
        // Direct, atomic transactions have no off-chain sequencer requirement.
        // Recovery can therefore submit these exact VM-verified bytes to the
        // fixed independent TN10 nodes if the provider's prepare cache expired.
        try {
          await BraidClock(client, mainnet: mainnet)
              .broadcast(receipt['wrpc'] as Map, id);
        } catch (_) {/* Keep signed bytes. */}
      }
    }
    progress.value = 'Waiting for independent confirmation…';
    for (final seconds in [1, 1, 2, 3, 5, 8]) {
      await Future<void>.delayed(Duration(seconds: seconds));
      guard(address);
      if (await accepted(id)) {
        receipt['state'] = 'confirmed';
        await retain(address, receipt);
        return receipt;
      }
    }
    return receipt;
  }
}
