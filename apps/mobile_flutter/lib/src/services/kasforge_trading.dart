import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../kaspa_address.dart';
import 'braid_clock.dart';
import 'braid_service.dart';
import 'encrypted_store.dart';
import 'kasforge_service.dart';
import 'native_security.dart';
import 'swap_conflict_lookup.dart';

class KasForgeApiError extends StateError {
  KasForgeApiError(this.statusCode, this.detail) : super('KasForge: $detail');
  final int statusCode;
  final String detail;
}

class KasForgeConfirmationPending extends StateError {
  KasForgeConfirmationPending()
      : super('Waiting for independent transaction confirmation.');
}

/// TN10 orders only. API responses never grant permission to sign a generic PSKT.
class KasForgeTrading {
  KasForgeTrading(
      {http.Client? client, EncryptedStore? store, NativeSecurity? security})
      : client = client ?? http.Client(),
        store = store ?? const KeystoreEncryptedStore(),
        security = security ?? NativeSecurity();
  final http.Client client;
  final EncryptedStore store;
  final NativeSecurity security;
  static final _busy = <String>{};
  static const api = '${KasForgeService.origin}/api/v1';
  void guard(String address) => KasForgeService().guard(address);
  String _key(String address) => 'kasforge_tn10_orders_v1_$address';
  Future<T> exclusive<T>(String address, Future<T> Function() f) async {
    if (!_busy.add(address)) {
      throw StateError('A Forge order is already being processed.');
    }
    try {
      return await f();
    } finally {
      _busy.remove(address);
    }
  }

  Future<Map<String, dynamic>> call(String address, String path,
      {Map? body}) async {
    guard(address);
    final uri = Uri.parse('$api/$path');
    final r = await (body == null
            ? client.get(uri)
            : client.post(uri,
                headers: {'content-type': 'application/json'},
                body: jsonEncode(body)))
        .timeout(const Duration(seconds: 30));
    guard(address);
    if (r.bodyBytes.length > 2 * 1024 * 1024) {
      throw StateError('Forge response is too large.');
    }
    final d = jsonDecode(r.body);
    if (r.statusCode != 200 ||
        d is! Map ||
        d['ok'] == false ||
        d['error'] != null) {
      throw KasForgeApiError(r.statusCode,
          '${d is Map ? d['error'] ?? 'HTTP ${r.statusCode}' : 'invalid response'}');
    }
    return Map<String, dynamic>.from(d);
  }

  Future<List<Map<String, dynamic>>> saved(String address) async {
    guard(address);
    final raw = await store.read(_key(address));
    if (raw == null) return [];
    final rows = jsonDecode(raw);
    if (rows is! List) {
      throw StateError(
          'Saved Forge orders are unreadable. Do not create a replacement.');
    }
    return rows.map((r) => Map<String, dynamic>.from(r as Map)).toList();
  }

  Future<Map<String, dynamic>?> pending(String address) async {
    for (final r in (await saved(address)).reversed) {
      if (r['signed'] is List && r['finalVerified'] != true) return r;
    }
    return null;
  }

  Future<void> retain(String address, Map<String, dynamic> receipt) async {
    guard(address);
    if (receipt['address'] != address || receipt['network'] != 'testnet-10') {
      throw StateError(
          'Saved Forge order belongs to another wallet or network.');
    }
    final rows = await saved(address);
    final i = rows.indexWhere((r) => r['buildId'] == receipt['buildId']);
    if (i < 0) {
      rows.add(receipt);
    } else {
      rows[i] = receipt;
    }
    if (rows.length > 200) {
      throw StateError('Export your saved Forge orders before continuing.');
    }
    final text = jsonEncode(rows);
    await store.write(_key(address), text);
    if (await store.read(_key(address)) != text) {
      throw StateError(
          'Forge recovery data could not be saved. Nothing may be submitted.');
    }
  }

  Future<Map<String, dynamic>> _template() async =>
      Map<String, dynamic>.from(jsonDecode(await rootBundle
          .loadString('assets/kcc20_standard_template.json')) as Map);
  String _note(Map t, String owner, BigInt amount,
      {int scheme = 0, int borrow = 0, String? guard}) {
    var n = amount;
    var le = '';
    for (var i = 0; i < 8; i++) {
      le += (n & BigInt.from(255)).toInt().toRadixString(16).padLeft(2, '0');
      n >>= 8;
    }
    if (n != BigInt.zero || amount.isNegative) {
      throw StateError('Forge amount overflow.');
    }
    return '${t['prefix']}08${le}20${owner}01${scheme.toRadixString(16).padLeft(2, '0')}01${borrow.toRadixString(16).padLeft(2, '0')}20${guard ?? '0' * 64}20${'0' * 64}${t['suffix']}';
  }

  String _packed(String program) => BraidService.scriptHash(program);
  String _address(String packed) {
    if (RegExp(r'^000020[a-f0-9]{64}ac$').hasMatch(packed)) {
      return kaspaAddressFromOwnerId(packed.substring(6, 70),
          prefix: 'kaspatest');
    }
    if (RegExp(r'^0000aa20[a-f0-9]{64}87$').hasMatch(packed)) {
      return kaspaScriptHashAddress(packed.substring(8, 72),
          prefix: 'kaspatest');
    }
    throw StateError('Unsupported Forge input script.');
  }

  Future<List> live(String address) async {
    final r = await client
        .get(Uri.parse('https://kaspire.kaslab.space/dex-test-v1/kasseal/utxos')
            .replace(queryParameters: {'address': address}))
        .timeout(const Duration(seconds: 15));
    final d = jsonDecode(r.body);
    if (r.statusCode != 200 ||
        d is! Map ||
        d['network'] != 'testnet-10' ||
        d['covenantIdsIncluded'] != true ||
        d['entries'] is! List) {
      throw StateError(
          'Independent Forge input lookup unavailable. Saved orders are preserved.');
    }
    return d['entries'] as List;
  }

  Future<void> verify(String address, Map tx, Map<String, Map> parents) async {
    guard(address);
    final seen = <String>{}, cache = <String, List>{};
    for (final input in (tx['inputs'] as List).cast<Map>()) {
      final outpoint = '${input['transactionId']}:${input['index']}';
      if (!RegExp(r'^[a-f0-9]{64}:[0-9]+$').hasMatch(outpoint) ||
          !seen.add(outpoint)) {
        throw StateError('Invalid or duplicate Forge input.');
      }
      final u = input['utxo'] as Map;
      final spk = '${u['scriptPublicKey']}';
      final parent = parents['${input['transactionId']}'];
      if (parent != null) {
        final outputs = parent['outputs'] as List;
        final index = input['index'] as int;
        if (index < 0 || index >= outputs.length) {
          throw StateError('Unknown Forge parent output.');
        }
        final out = outputs[index] as Map;
        if (out['scriptPublicKey'] != spk ||
            '${out['value']}' != '${u['amount']}' ||
            (out['covenant'] as Map?)?['covenantId'] != u['covenantId']) {
          throw StateError(
              'Forge chained input differs from locally reviewed parent.');
        }
        u['blockDaaScore'] = '0';
        continue;
      }
      final owner = _address(spk);
      final rows = cache[owner] ??= await live(owner);
      final matches = rows
          .whereType<Map>()
          .where((r) =>
              r['outpoint']['transactionId'] == input['transactionId'] &&
              r['outpoint']['index'] == input['index'])
          .toList();
      if (matches.length != 1) {
        throw StateError(
            'Forge input is spent or unavailable. Refresh before signing.');
      }
      final e = matches.single['utxoEntry'] as Map;
      final script = e['scriptPublicKey'] as Map;
      final packed =
          '${(script['version'] as int).toRadixString(16).padLeft(4, '0')}${script['script']}';
      if (packed != spk ||
          '${e['amount']}' != '${u['amount']}' ||
          e['isCoinbase'] != false ||
          e['covenantId'] != u['covenantId']) {
        throw StateError('Forge input differs from the independent node.');
      }
      u['address'] = owner;
      u['blockDaaScore'] = '${e['blockDaaScore']}';
    }
    guard(address);
  }

  Future<Map<String, dynamic>> build(String address, KasForgeToken token,
      String side, String amount, Map quote) async {
    guard(address);
    if (quote['tokenId'] != token.id ||
        quote['side'] != side ||
        quote['localAmount'] != amount ||
        quote['localAt'] is! int ||
        DateTime.now().millisecondsSinceEpoch - (quote['localAt'] as int) >
            60000) {
      throw StateError(
          'Forge quote changed or expired. Refresh it before reviewing.');
    }
    if (await pending(address) != null) {
      throw StateError('Check your saved Forge order before creating another.');
    }
    if (!['buy', 'sell'].contains(side)) {
      throw StateError('Invalid Forge direction.');
    }
    final market = await call(address, 'market/${token.id}');
    final current = token.withMarket(market['market'] as Map);
    if (current.activeMarket != quote['marketId'] ||
        (market['market'] as Map)['contracts'] != '3.3') {
      throw StateError(
          'Forge market or contract changed. Reload before quoting.');
    }
    final clocks = await BraidClock(client).read();
    final b = await call(address, 'build', body: {
      'action': 'order-$side',
      'pub': kaspaOwnerIdFromAddress(address),
      'market': token.id,
      side == 'buy' ? 'kas' : 'amount': amount,
      'slippage': 1
    });
    final summary = b['summary'] as Map, order = summary['order'];
    if (order is! Map ||
        order['state'] is! Map ||
        b['txs'] is! List ||
        (b['txs'] as List).isEmpty ||
        (b['txs'] as List).length > 32 ||
        b['buildId'] is! String) {
      throw StateError('Forge build lacks complete order and recovery data.');
    }
    final template = await _template();
    final pub = kaspaOwnerIdFromAddress(address);
    final account = side == 'sell'
        ? await call(address, 'account/$pub?market=${token.id}')
        : <String, dynamic>{};
    final pieces = <String, BigInt>{
      for (final h in (account['holdings'] as List? ?? []).whereType<Map>())
        '${h['id']}': KasForgeService.exactUnsigned(h['tokens'])
    };
    final amountRaw = side == 'buy'
        ? kasSompi(amount)
        : KasForgeService.exactUnsigned(amount);
    final minimum = side == 'buy'
        ? (KasForgeService.exactUnsigned(quote['receiveTokens']) *
            BigInt.from(99) ~/
            BigInt.from(100))
        : kasSompi('${quote['receiveKas']}') *
            BigInt.from(99) ~/
            BigInt.from(100);
    final requests = <Map<String, Object?>>[],
        reviews = <Map<String, Object?>>[],
        parents = <String, Map>{};
    for (var step = 0; step < (b['txs'] as List).length; step++) {
      final item = (b['txs'] as List)[step] as Map;
      final tx = Map<String, dynamic>.from(
          jsonDecode('${item['txJsonString']}') as Map)
        ..remove('id');
      final finalStep = step == (b['txs'] as List).length - 1;
      await verify(address, tx, parents);
      final inputRedeems = <String, String>{},
          outputRedeems = <String, String>{};
      final tokenIndexes = <int>[], next = <String>[];
      var total = BigInt.zero;
      final inputs = (tx['inputs'] as List).cast<Map>();
      for (var i = 0; i < inputs.length; i++) {
        final u = inputs[i]['utxo'] as Map;
        if (u['covenantId'] == null) continue;
        if (u['covenantId'] != token.id) {
          throw StateError('Forge build spends another token.');
        }
        final qty =
            pieces['${inputs[i]['transactionId']}:${inputs[i]['index']}'];
        if (qty == null) {
          throw StateError('Forge token input state is incomplete.');
        }
        String? program;
        for (final policy in [0, 1, 2]) {
          final candidate = _note(template, pub, qty,
              borrow: policy,
              guard: policy == 2 ? '${order['state']['refundGuard']}' : null);
          if (_packed(candidate) == u['scriptPublicKey']) program = candidate;
        }
        if (program == null) {
          throw StateError(
              'Forge token policy does not match its live program.');
        }
        inputRedeems['$i'] = program;
        tokenIndexes.add(i);
        total += qty;
      }
      final outputs = (tx['outputs'] as List).cast<Map>();
      for (var i = 0; i < outputs.length; i++) {
        if (outputs[i]['covenant'] == null) continue;
        final isOrder = finalStep &&
            side == 'sell' &&
            i == order['tokens']['output']['index'];
        final qty =
            isOrder ? amountRaw : total - (finalStep ? amountRaw : BigInt.zero);
        String? program;
        for (final policy in isOrder ? [0] : [0, 1, 2]) {
          final candidate = _note(
              template, isOrder ? '${order['scriptHash']}' : pub, qty,
              scheme: isOrder ? 3 : 0,
              borrow: policy,
              guard: policy == 2 ? '${order['state']['refundGuard']}' : null);
          if (_packed(candidate) == outputs[i]['scriptPublicKey']) {
            program = candidate;
          }
        }
        if (program == null) {
          throw StateError('Forge token change or order output differs.');
        }
        outputRedeems['$i'] = program;
        next.add(program.substring('${template['prefix']}'.length,
            program.length - '${template['suffix']}'.length));
      }
      final scripts = <Map<String, Object?>>[];
      for (var n = 0; n < tokenIndexes.length; n++) {
        final i = tokenIndexes[n];
        final program = inputRedeems['$i']!;
        final columns = next.map((s) => BraidService.bytes(s)).toList();
        final args = <Map<String, Object?>>[];
        if (n == 0) {
          for (final span in [
            (1, 9),
            (10, 42),
            (43, 44),
            (45, 46),
            (47, 79),
            (80, 112)
          ]) {
            final data = BraidService.hex(
                columns.expand((v) => v.sublist(span.$1, span.$2)).toList());
            args.add({'type': 'data', 'hex': data});
          }
        }
        args.add({'type': 'signature', 'prefixHex': n == 0 ? '00' : ''});
        args.add({'type': 'data', 'hex': n == 0 ? '79c71c23' : 'fd3ef14a'});
        inputs[i]['signatureScript'] = '';
        inputs[i]['computeBudget'] = 150;
        scripts.add({
          'inputIndex': i,
          'scriptHex': program,
          'signType': 1,
          'signatureScript': {'mode': 'ordered-args', 'args': args}
        });
      }
      final request = <String, Object?>{
        'sender': address,
        'profile': 'kasforge-tn10-order-v1',
        'txJsonString': jsonEncode(tx),
        'signInputs': item['signInputs'],
        'scripts': scripts,
        'tradeSummary': {
          'action': finalStep ? 'order-$side' : 'merge',
          'order': order,
          'tokenId': token.id,
          'marketId': current.activeMarket,
          'amount': '$amountRaw',
          'minimumOut': '$minimum',
          'maximumDebit': '${amountRaw + BigInt.from(101000000)}',
          'chainDaa': '${clocks[0]}',
          'secondChainDaa': '${clocks[1]}',
          'inputRedeems': inputRedeems,
          'outputRedeems': outputRedeems
        }
      };
      final review = await security.preparePskt(request);
      final id = '${review['transactionId']}';
      parents[id] = tx;
      for (final entry in outputRedeems.entries) {
        final program = BraidService.bytes(entry.value);
        pieces['$id:${entry.key}'] = BigInt.from(program
            .sublist('${template['prefix']}'.length ~/ 2 + 1,
                '${template['prefix']}'.length ~/ 2 + 9)
            .asMap()
            .entries
            .fold<int>(0, (sum, e) => sum + (e.value << (8 * e.key))));
      }
      requests.add(request);
      reviews.add(review);
    }
    return {
      'buildId': b['buildId'],
      'address': address,
      'network': 'testnet-10',
      'tokenId': token.id,
      'symbol': token.symbol,
      'side': side,
      'amount': amount,
      'minimumOut': '$minimum',
      'order': order,
      'summary': summary,
      'requests': requests,
      'reviews': reviews,
      'transactionIds': reviews.map((r) => r['transactionId']).toList(),
      'createdAt': DateTime.now().toIso8601String(),
      'state': 'prepared'
    };
  }

  static BigInt kasSompi(String text) {
    if (!RegExp(r'^(0|[1-9][0-9]{0,10})(\.[0-9]{1,8})?$').hasMatch(text)) {
      throw StateError('Invalid KAS amount.');
    }
    final parts = text.split('.');
    return BigInt.parse(parts[0]) * BigInt.from(100000000) +
        (parts.length == 2
            ? BigInt.parse(parts[1].padRight(8, '0'))
            : BigInt.zero);
  }

  Future<void> sign(String address, Map<String, dynamic> receipt) async {
    guard(address);
    receipt['signed'] ??= <String>[];
    receipt['signedWrpc'] ??= <String>[];
    await retain(address, receipt);
    final signed = receipt['signed'] as List;
    final parents = <String, Map>{};
    final requests = receipt['requests'] as List,
        reviews = receipt['reviews'] as List;
    for (var i = 0; i < requests.length; i++) {
      final request = Map<String, Object?>.from(requests[i] as Map);
      final tx = Map<String, dynamic>.from(
          jsonDecode('${request['txJsonString']}') as Map);
      if (i >= signed.length) {
        final clocks = await BraidClock(client).read();
        final expiry = int.parse('${receipt['order']['state']['expiryDaa']}');
        if (clocks.reduce((a, b) => a > b ? a : b) + 1800 > expiry) {
          receipt['requestExpired'] = true;
          await retain(address, receipt);
          throw StateError(
              'The saved request expired. Use recovery to cancel it safely; nothing new was signed.');
        }
        await verify(address, tx, parents);
        final result =
            await security.signPskt(request, '${reviews[i]['reviewHash']}');
        if (result['transactionId'] != receipt['transactionIds'][i]) {
          throw StateError('Forge signed ID differs. Saved state retained.');
        }
        signed.add(result['signedTxJson']);
        (receipt['signedWrpc'] as List).add(result['wrpcJson']);
        await retain(address, receipt);
      }
      parents['${receipt['transactionIds'][i]}'] = tx;
    }
  }

  Future<void> submit(String address, Map<String, dynamic> receipt) async {
    guard(address);
    if ((receipt['signed'] as List?)?.length !=
        (receipt['requests'] as List).length) {
      throw StateError('Finish authorizing the saved order before submitting.');
    }
    // Forge's SDK deserializer requires `id` in the JSON envelope. The native
    // signer returns the computed ID separately; never trust a provider hint
    // or change/re-sign a saved transaction just to add this metadata.
    await _completeSubmissionIds(address, receipt);
    final apiSigned = <String>[];
    for (var i = 0; i < (receipt['signed'] as List).length; i++) {
      final request = receipt['requests'][i] as Map;
      final tx = jsonDecode('${receipt['signed'][i]}') as Map;
      final scripts =
          (request['scripts'] as List? ?? []).whereType<Map>().toList();
      for (final selection in (request['signInputs'] as List).cast<Map>()) {
        final index = selection['index'] as int;
        final script = scripts.where((s) => s['inputIndex'] == index).toList();
        if (script.length > 1) {
          throw StateError('Duplicate Forge signing descriptor.');
        }
        tx['inputs'][index]['signatureScript'] = forgeSignatureEnvelope(
            '${tx['inputs'][index]['signatureScript']}',
            script.isEmpty ? null : script.single);
      }
      apiSigned.add(jsonEncode(tx));
    }
    receipt['apiSigned'] = apiSigned;
    await retain(address, receipt);
    Map<String, dynamic> r;
    try {
      r = await call(address, 'submit',
          body: {'buildId': receipt['buildId'], 'signed': apiSigned});
    } catch (e) {
      // Only Forge /submit registers an order with its sequencer. A node
      // broadcast can lock the deposit on-chain without scheduling a swap.
      // Preserve the original error and exact signed plan, but never bypass
      // registration, including on timeouts (which have an unknown outcome).
      final detail = e.toString().replaceFirst('Bad state: ', '');
      receipt['submissionError'] =
          detail.substring(0, detail.length.clamp(0, 500));
      if (detail.toLowerCase().contains('expired')) {
        receipt['requestExpired'] = true;
      }
      await retain(address, receipt);
      rethrow;
    }
    if (r['txid'] != (receipt['transactionIds'] as List).last) {
      receipt['submissionError'] =
          'Forge submission returned a different transaction ID.';
      await retain(address, receipt);
      throw StateError(
          'Forge submission returned a different ID. Recovery data retained.');
    }
    receipt.remove('submissionError');
    receipt.remove('requestExpired');
    receipt['state'] = 'deposited';
    await retain(address, receipt);
  }

  /// Forge /submit takes the SDK's one 65-byte owner signature push and builds
  /// the covenant witness itself. Keep the complete locally executed witness
  /// in `signed`/`signedWrpc`; adapt only a separate API envelope.
  static String forgeSignatureEnvelope(String witness, Map? script) {
    final bytes = BraidService.bytes(witness);
    final pushes = <String>[];
    var offset = 0;
    while (offset < bytes.length) {
      final op = bytes[offset++];
      if (op == 0) {
        pushes.add('');
        continue;
      }
      if (op == 79) {
        pushes.add('81');
        continue;
      }
      if (op >= 81 && op <= 96) {
        pushes.add((op - 80).toRadixString(16).padLeft(2, '0'));
        continue;
      }
      var length = op;
      if (op >= 76 && op <= 78) {
        final size = op == 76
            ? 1
            : op == 77
                ? 2
                : 4;
        if (offset + size > bytes.length) {
          throw StateError('Truncated Forge witness.');
        }
        length = 0;
        for (var i = 0; i < size; i++) {
          length |= bytes[offset++] << (8 * i);
        }
      } else if (op > 75) {
        throw StateError('Unexpected Forge witness opcode.');
      }
      if (offset + length > bytes.length) {
        throw StateError('Truncated Forge witness.');
      }
      pushes.add(BraidService.hex(bytes.sublist(offset, offset + length)));
      offset += length;
    }
    String? signature;
    if (script == null) {
      if (pushes.length != 1) {
        throw StateError('Unexpected Forge owner signature.');
      }
      signature = pushes.single;
    } else {
      final template = script['signatureScript'] as Map;
      final args = (template['args'] as List).cast<Map>();
      if (template['mode'] != 'ordered-args' ||
          pushes.length != args.length + 1 ||
          pushes.last != script['scriptHex']) {
        throw StateError('Forge witness differs from its reviewed descriptor.');
      }
      for (var i = 0; i < args.length; i++) {
        if (args[i]['type'] == 'data') {
          if (pushes[i] != args[i]['hex']) {
            throw StateError('Forge witness arguments changed.');
          }
        } else if (args[i]['type'] == 'signature' && signature == null) {
          final prefix = '${args[i]['prefixHex'] ?? ''}';
          if (!pushes[i].startsWith(prefix)) {
            throw StateError('Forge signature prefix changed.');
          }
          signature = pushes[i].substring(prefix.length);
        } else {
          throw StateError('Unsupported Forge signature descriptor.');
        }
      }
    }
    if (signature == null ||
        !RegExp(r'^[a-f0-9]{128}01$').hasMatch(signature)) {
      throw StateError(
          'Forge requires a complete SIGHASH_ALL owner signature.');
    }
    return '41$signature';
  }

  Future<void> _completeSubmissionIds(
      String address, Map<String, dynamic> receipt,
      {bool partial = false}) async {
    final signed = receipt['signed'] as List;
    final requests = receipt['requests'] as List;
    final ids = receipt['transactionIds'] as List;
    final reviews = receipt['reviews'] as List?;
    if (signed.isEmpty ||
        (partial ? ids.length < signed.length : ids.length != signed.length) ||
        reviews == null ||
        reviews.length < signed.length) {
      throw StateError(
          'Saved Forge signing plan is incomplete. Recovery retained.');
    }
    final completed = <String>[];
    for (var i = 0; i < signed.length; i++) {
      final request = Map<String, Object?>.from(requests[i] as Map);
      final expected = '${ids[i]}';
      if (request['sender'] != address ||
          request['profile'] != 'kasforge-tn10-order-v1' ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(expected)) {
        throw StateError(
            'Saved Forge signing identity differs. Recovery retained.');
      }
      final checked = await security.preparePskt(request);
      if (checked['transactionId'] != expected ||
          checked['reviewHash'] != (reviews[i] as Map)['reviewHash']) {
        throw StateError(
            'Saved Forge transaction differs from its review. Recovery retained.');
      }
      final tx = Map<String, dynamic>.from(jsonDecode('${signed[i]}') as Map);
      if (tx['id'] != null && tx['id'] != expected) {
        throw StateError(
            'Saved Forge transaction ID differs. Recovery retained.');
      }
      final original = jsonDecode('${request['txJsonString']}') as Map;
      final comparable = (jsonDecode(jsonEncode(tx)) as Map)..remove('id');
      original.remove('id');
      final inputs = comparable['inputs'] as List;
      final oldInputs = original['inputs'] as List;
      if (inputs.length != oldInputs.length) {
        throw StateError('Saved Forge inputs differ. Recovery retained.');
      }
      for (final selection in (request['signInputs'] as List).cast<Map>()) {
        final index = selection['index'] as int;
        final witness = inputs[index]['signatureScript'];
        if (witness is! String ||
            !RegExp(r'^(?:[a-f0-9]{2})+$').hasMatch(witness)) {
          throw StateError(
              'Saved Forge signature is missing. Recovery retained.');
        }
        // Restore only the selected witnesses in a deep comparison copy.
        // All transaction terms and embedded UTXOs must be exactly unchanged.
        inputs[index] = Map<String, dynamic>.from(inputs[index] as Map)
          ..['signatureScript'] = oldInputs[index]['signatureScript'];
      }
      if (!_sameJson(comparable, original)) {
        throw StateError('Saved Forge signed terms differ. Recovery retained.');
      }
      tx['id'] = expected;
      completed.add(jsonEncode(tx));
    }
    receipt['signed'] = completed;
  }

  static bool _sameJson(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return a.length == b.length &&
          a.keys.every((k) => b.containsKey(k) && _sameJson(a[k], b[k]));
    }
    if (a is List && b is List) {
      return a.length == b.length &&
          List.generate(a.length, (i) => i).every((i) => _sameJson(a[i], b[i]));
    }
    return a == b;
  }

  Future<bool> accepted(String id) async {
    final response = await client
        .get(Uri.parse('https://api-tn10.kaspa.org/transactions/$id'))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 404) return false;
    if (response.statusCode != 200) {
      throw StateError(
          'Independent transaction status unavailable; signed order retained.');
    }
    final tx = jsonDecode(response.body);
    return tx is Map && tx['transaction_id'] == id && tx['is_accepted'] == true;
  }

  Future<Map<String, dynamic>> status(
      String address, Map<String, dynamic> receipt) async {
    guard(address);
    if (receipt['finalVerified'] == true) {
      return receipt['status'] is Map
          ? Map<String, dynamic>.from(receipt['status'] as Map)
          : {'status': receipt['state']};
    }
    if (receipt['recoveryPreparationId'] is String &&
        receipt['cancelId'] == null) {
      final ready = await accepted('${receipt['recoveryPreparationId']}');
      receipt['state'] =
          ready ? 'recovery-ready' : 'recovery-preparation-pending';
      receipt['status'] = {
        'status': receipt['state'],
        'message': ready
            ? 'Preparation confirmed. Continue recovery to authorize returning the KAS funding to your own wallet.'
            : 'Previously authorized wallet-only preparation is awaiting confirmation. Recovery will not create a swap deposit.'
      };
      await retain(address, receipt);
      return Map<String, dynamic>.from(receipt['status'] as Map);
    }
    if (receipt['cancelId'] is String) {
      try {
        if (receipt['cancelKind'] == 'invalidate-funding') {
          await _verifyFundingReturn(address, receipt);
        } else {
          await verifyFinal(
              address, receipt, receipt['cancelId'] as String, false);
        }
      } catch (_) {
        if (receipt['cancelKind'] == 'invalidate-funding' &&
            await accepted('${(receipt['transactionIds'] as List).last}')) {
          // The deposit can win the input race. Its accepted spend makes the
          // competing self-return obsolete, but not the order itself. Keep
          // that signed attempt and reopen ordinary contract recovery.
          receipt['fundingInvalidationAttempt'] = {
            'transactionId': receipt['cancelId'],
            'signed': receipt['cancelSigned'],
            'retiredReason': 'original-deposit-accepted',
          };
          receipt.remove('cancelId');
          receipt.remove('cancelSigned');
          receipt.remove('cancelKind');
          receipt['state'] = 'deposited';
          await retain(address, receipt);
          return status(address, receipt);
        }
        // A missing cancellation is not proof of failure, nor permission to
        // recreate the swap. Keep its exact signed bytes and show the pending
        // cancellation instead of hiding it behind Forge's missing index row.
        receipt['status'] = {
          'status': 'cancellation-pending',
          'txid': receipt['cancelId'],
          'message':
              'Cancellation is saved but its acceptance and return to your wallet are not independently verified yet. Check again or resume the same cancellation; do not create another order.'
        };
        await retain(address, receipt);
        return Map<String, dynamic>.from(receipt['status'] as Map);
      }
      receipt['state'] = 'cancelled';
      receipt['finalVerified'] = true;
      receipt['completedAt'] = DateTime.now().toUtc().toIso8601String();
      receipt['status'] = {'status': 'cancelled', 'txid': receipt['cancelId']};
      await retain(address, receipt);
      return Map<String, dynamic>.from(receipt['status'] as Map);
    }
    final id = '${(receipt['transactionIds'] as List).last}';
    Map<String, dynamic> d;
    try {
      d = await call(address,
          'order/$id?market=${Uri.encodeQueryComponent('${receipt['tokenId'] ?? receipt['order']['state']['kcc20']}')}');
    } on KasForgeApiError catch (e) {
      if (![400, 404].contains(e.statusCode) || e.detail != 'no such order') {
        rethrow;
      }
      // Recover the old direct-broadcast case without relying on the Forge
      // index. Missing registration never proves failure, refund or zero.
      if (!await accepted(id)) {
        throw StateError(
            'Forge has no registered order and the deposit is not independently confirmed. The signed order remains saved; do not create another order.');
      }
      final order = receipt['order'] as Map;
      final out = order['output'] as Map;
      final entries = await live('${order['address']}');
      final exact = entries.whereType<Map>().where((entry) {
        final point = entry['outpoint'] as Map;
        final u = entry['utxoEntry'] as Map;
        return '${point['transactionId']}:${point['index']}' ==
                out['outpoint'] &&
            '${u['amount']}' == '${out['sompi']}' &&
            u['covenantId'] == null &&
            u['isCoinbase'] == false &&
            u['scriptPublicKey']['version'] == 0 &&
            '0000${u['scriptPublicKey']['script']}' ==
                _packed('${order['redeemScript']}');
      });
      if (exact.length != 1) {
        throw StateError(
            'Forge has no registered order. The deposit was confirmed, but its current outcome could not be verified. Recovery data remains saved; do not create another order.');
      }
      d = {
        'status': 'deposited-untracked',
        'txid': id,
        'message':
            'Your deposit is confirmed and remains unspent in the order contract, but Forge has not registered the swap. It is not a completed trade. Use Cancel / recover unfilled order to return the deposit, or retry submitting the same saved order to Forge. Do not create another order.'
      };
      receipt['state'] = 'deposited-untracked';
    }
    receipt['status'] = d;
    final state =
        d['order'] is Map ? Map<String, dynamic>.from(d['order'] as Map) : d;
    if (['filled', 'refunded', 'cancelled'].contains(state['status'])) {
      final id = state['txid'] ?? receipt['cancelId'];
      if (id is String) {
        try {
          await verifyFinal(address, receipt, id, state['status'] == 'filled');
        } on KasForgeConfirmationPending {
          final waiting = {
            'status': 'verification-pending',
            'reportedStatus': state['status'],
            'txid': id,
            'message':
                'Forge reports completion. Waiting for independent confirmation; this is not a failed trade.'
          };
          receipt['status'] = waiting;
          await retain(address, receipt);
          return waiting;
        }
        receipt['state'] = state['status'];
        receipt['finalVerified'] = true;
        receipt['settlementId'] = id;
        receipt['completedAt'] = DateTime.now().toUtc().toIso8601String();
      }
    }
    await retain(address, receipt);
    return d;
  }

  Future<Map<String, Object?>> cancel(
      String address, Map<String, dynamic> receipt) async {
    guard(address);
    final order = receipt['order'] as Map, st = order['state'] as Map;
    final sell = st['unitsIn'] == null;
    final template = await _template();
    final inputs = <Map<String, Object?>>[],
        outputs = <Map<String, Object?>>[],
        inputRedeems = <String, String>{},
        outputRedeems = <String, String>{};
    if (sell) {
      final note = order['tokens'] as Map;
      final back = _note(template, kaspaOwnerIdFromAddress(address),
          KasForgeService.exactUnsigned(st['amount']));
      final state = back.substring('${template['prefix']}'.length,
          back.length - '${template['suffix']}'.length);
      inputs.add(_savedInput(
          note['output'] as Map,
          '${note['redeemScript']}',
          '${st['kcc20']}',
          '$state${BraidService.push('0001')}0479c71c23${BraidService.push('${note['redeemScript']}')}'));
      inputRedeems['0'] = '${note['redeemScript']}';
      outputRedeems['0'] = back;
      outputs.add({
        'value': '100000000',
        'scriptPublicKey': _packed(back),
        'covenant': {'authorizingInput': 0, 'covenantId': st['kcc20']}
      });
    }
    final ci = inputs.length;
    inputs.add(_savedInput(
        order['output'] as Map, '${order['redeemScript']}', null, ''));
    final value = KasForgeService.exactUnsigned(order['output']['sompi']);
    if (value <= BigInt.from(10000000)) {
      throw StateError('Order cannot fund cancellation.');
    }
    outputs.add({
      'value': '${value - BigInt.from(10000000)}',
      'scriptPublicKey': '000020${kaspaOwnerIdFromAddress(address)}ac'
    });
    final tx = <String, dynamic>{
      'version': 1,
      'inputs': inputs,
      'outputs': outputs,
      'subnetworkId': '0' * 40,
      'lockTime': '0',
      'gas': '0',
      'storageMass': '0',
      'payload': ''
    };
    await verify(address, tx, {});
    return {
      'sender': address,
      'profile': 'kasforge-tn10-order-v1',
      'txJsonString': jsonEncode(tx),
      'signInputs': [
        {'index': ci, 'sighashType': 1}
      ],
      'scripts': [
        {
          'inputIndex': ci,
          'scriptHex': order['redeemScript'],
          'signType': 1,
          'signatureScript': {
            'mode': 'ordered-args',
            'args': [
              {'type': 'signature', 'prefixHex': ''},
              {'type': 'data', 'hex': 'a0893109'}
            ]
          }
        }
      ],
      'tradeSummary': {
        'action': 'cancel',
        'order': order,
        'tokenId': receipt['tokenId'],
        'marketId': st['market'],
        'inputRedeems': inputRedeems,
        'outputRedeems': outputRedeems
      }
    };
  }

  Map<String, Object?> _savedInput(
      Map out, String program, String? cid, String witness) {
    final point = '${out['outpoint']}'.split(':');
    return {
      'transactionId': point[0],
      'index': int.parse(point[1]),
      'sequence': '0',
      'sigOpCount': 0,
      'computeBudget': cid == null ? 50 : 150,
      'signatureScript': witness,
      'utxo': {
        'amount': '${out['sompi']}',
        'scriptPublicKey': _packed(program),
        'blockDaaScore': '0',
        'isCoinbase': false,
        'covenantId': cid
      }
    };
  }

  Future<void> cancelAndSubmit(
      String address, Map<String, dynamic> receipt) async {
    guard(address);
    if (receipt['cancelSigned'] == null) {
      var deposited =
          await accepted('${(receipt['transactionIds'] as List).last}');
      if (!deposited && !await _prepareFundingRecovery(address, receipt)) {
        return;
      }
      if (!deposited) {
        deposited =
            await accepted('${(receipt['transactionIds'] as List).last}');
      }
      Map<String, Object?> request;
      try {
        request = deposited
            ? await cancel(address, receipt)
            : await fundingReturn(address, receipt);
      } catch (_) {
        if (!deposited && await _retireConflictedFunding(address, receipt)) {
          return;
        }
        rethrow;
      }
      final review = await security.preparePskt(request);
      if (review['feeSompi'].toString() != '10000000') {
        throw StateError(
            'Cancellation fee differs from the confirmed terms. Nothing was signed.');
      }
      final result =
          await security.signPskt(request, '${review['reviewHash']}');
      receipt['cancelSigned'] = result['wrpcJson'];
      receipt['cancelId'] = result['transactionId'];
      receipt['cancelKind'] =
          deposited ? 'order-contract' : 'invalidate-funding';
      if (!deposited) receipt['fundingReturnTerms'] = request['tradeSummary'];
      receipt.remove('recoveryPreparationId');
      await retain(address, receipt);
    }
    final tx = receipt['cancelSigned'] is String
        ? jsonDecode(receipt['cancelSigned'] as String)
        : receipt['cancelSigned'];
    if (!await accepted('${receipt['cancelId']}')) {
      await broadcastSaved(tx as Map, '${receipt['cancelId']}');
    }
    receipt['state'] = 'cancel-submitted';
    await retain(address, receipt);
  }

  Future<void> broadcastSaved(Map tx, String id) =>
      BraidClock(client).broadcast(tx, id).then((_) {});

  Future<bool> _prepareFundingRecovery(
      String address, Map<String, dynamic> receipt) async {
    final signed = receipt['signed'] as List? ?? [];
    final requests = receipt['requests'] as List;
    final ids = (receipt['transactionIds'] as List).cast<String>();
    if (receipt['address'] != address ||
        receipt['network'] != 'testnet-10' ||
        requests.isEmpty ||
        ids.length != requests.length ||
        signed.length > requests.length) {
      throw StateError(
          'Saved recovery plan is inconsistent. Nothing was discarded.');
    }
    if (signed.isEmpty) {
      if ((receipt['signedWrpc'] as List? ?? []).isNotEmpty ||
          !['prepared', 'signed'].contains(receipt['state'])) {
        throw StateError(
            'Cannot prove this saved plan was unsigned. Recovery retained.');
      }
      await _finishRecovery(address, receipt, 'unsigned-plan-cancelled');
      return false;
    }
    await _completeSubmissionIds(address, receipt, partial: true);
    final target = signed.length - 1;
    final raw = receipt['signedWrpc'] as List? ?? [];
    for (var i = 0; i <= target; i++) {
      if (await accepted(ids[i])) continue;
      // Only finish already-signed, locally-reviewed owner-preserving merge
      // preparations. Never broadcast a swap deposit outside Forge /submit.
      final request = requests[i] as Map;
      if (i == target && i == requests.length - 1) break;
      if ((request['tradeSummary'] as Map?)?['action'] != 'merge' ||
          raw.length <= i) {
        throw StateError(
            'Saved preparation cannot be recovered without its verified signed bytes.');
      }
      final tx = jsonDecode('${request['txJsonString']}') as Map;
      final needsCash = !(tx['inputs'] as List).whereType<Map>().any((input) =>
          input['utxo']['covenantId'] == null &&
          input['utxo']['scriptPublicKey'] ==
              '000020${kaspaOwnerIdFromAddress(address)}ac');
      if (i == target && !needsCash) {
        break; // invalidate this step's KAS funding
      }
      await verify(address, tx, {});
      await broadcastSaved(jsonDecode('${raw[i]}') as Map, ids[i]);
      var confirmed = false;
      for (var attempt = 0; attempt < 4; attempt++) {
        if (await accepted(ids[i])) {
          confirmed = true;
          break;
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (!confirmed) {
        receipt['state'] = 'recovery-preparation-pending';
        receipt['recoveryPreparationId'] = ids[i];
        await retain(address, receipt);
        return false;
      }
    }
    if (target < requests.length - 1 && await accepted(ids[target])) {
      // Every authorized preparation is accepted, but no order deposit was
      // signed. Keep the preparations and archive only the unsigned tail.
      await _finishRecovery(address, receipt, 'unsigned-order-tail-cancelled');
      return false;
    }
    receipt['recoveryStep'] = target;
    return true;
  }

  Future<void> _finishRecovery(
      String address, Map<String, dynamic> receipt, String reason) async {
    receipt['state'] = 'cancelled';
    receipt['retiredReason'] = reason;
    receipt['finalVerified'] = true;
    receipt['completedAt'] = DateTime.now().toUtc().toIso8601String();
    receipt['status'] = {
      'status': 'cancelled',
      'message':
          'Unsubmitted order cancelled. Saved recovery history is retained.'
    };
    await retain(address, receipt);
  }

  Future<bool> _retireConflictedFunding(
      String address, Map<String, dynamic> receipt) async {
    final index = receipt['recoveryStep'] as int?;
    if (index == null) return false;
    final ids = (receipt['transactionIds'] as List).cast<String>();
    if (await accepted(ids.last)) return false;
    final request = receipt['requests'][index] as Map;
    final conflict = await findConfirmedSwapConflict(
        tx: jsonDecode('${request['txJsonString']}') as Map,
        savedIds: ids.toSet(),
        node: 'https://api-tn10.kaspa.org',
        prefix: 'kaspatest:',
        read: (url) async {
          final response = await client
              .get(Uri.parse(url))
              .timeout(const Duration(seconds: 12));
          if (response.statusCode == 404) return null;
          if (response.statusCode != 200) {
            throw StateError(
                'Recovery conflict lookup unavailable. Saved order retained.');
          }
          return jsonDecode(response.body);
        });
    if (conflict == null || await accepted(ids.last)) return false;
    receipt['conflictingTransactionId'] = conflict;
    await _finishRecovery(address, receipt, 'confirmed-conflicting-spend');
    return true;
  }

  /// Explicit owner-confirmed self-payment of a saved step's own KAS funding.
  /// Spending these exact inputs invalidates that step and dependent deposit.
  /// Token inputs are never signed here; a 404 never clears the journal.
  Future<Map<String, Object?>> fundingReturn(
      String address, Map<String, dynamic> receipt) async {
    guard(address);
    final requests = receipt['requests'] as List;
    if (receipt['address'] != address || receipt['network'] != 'testnet-10') {
      throw StateError(
          'This saved plan requires its existing contract recovery. No payment was signed.');
    }
    final index = receipt['recoveryStep'] as int? ?? requests.length - 1;
    if (index < 0 || index >= requests.length) {
      throw StateError('Invalid recovery step.');
    }
    final source = jsonDecode('${requests[index]['txJsonString']}') as Map;
    final ownerScript = '000020${kaspaOwnerIdFromAddress(address)}ac';
    final inputs = (source['inputs'] as List)
        .cast<Map>()
        .where((i) =>
            i['utxo']['covenantId'] == null &&
            i['utxo']['scriptPublicKey'] == ownerScript)
        .toList();
    if (inputs.isEmpty || inputs.length > 64) {
      throw StateError(
          'Saved funding is not a simple wallet-owned KAS payment. No payment was signed.');
    }
    final total = inputs.fold<BigInt>(BigInt.zero,
        (n, i) => n + KasForgeService.exactUnsigned(i['utxo']['amount']));
    if (total <= BigInt.from(10000000)) {
      throw StateError(
          'Saved funding cannot cover the confirmed cancellation fee.');
    }
    for (final input in inputs) {
      input['signatureScript'] = '';
      input['sequence'] = '0';
      input['sigOpCount'] = 0;
      input['computeBudget'] = 11;
    }
    final tx = <String, dynamic>{
      'version': 1,
      'inputs': inputs,
      'outputs': [
        {
          'value': '${total - BigInt.from(10000000)}',
          'scriptPublicKey': ownerScript
        }
      ],
      'subnetworkId': '0' * 40,
      'lockTime': '0',
      'gas': '0',
      'storageMass': '0',
      'payload': ''
    };
    await verify(address, tx, {});
    return {
      'sender': address,
      'txJsonString': jsonEncode(tx),
      'signInputs': [
        for (var i = 0; i < inputs.length; i++) {'index': i, 'sighashType': 1}
      ],
      'scripts': <Map>[],
      'tradeSummary': {
        'kind': 'forge-funding-return',
        'sourceIndex': index,
        'points': [
          for (final i in inputs) '${i['transactionId']}:${i['index']}'
        ]
      }
    };
  }

  Future<void> _verifyFundingReturn(
      String address, Map<String, dynamic> receipt) async {
    guard(address);
    final id = '${receipt['cancelId']}';
    final response = await client
        .get(Uri.parse('https://api-tn10.kaspa.org/transactions/$id'))
        .timeout(const Duration(seconds: 15));
    final tx = jsonDecode(response.body);
    if (response.statusCode != 200 ||
        tx is! Map ||
        tx['transaction_id'] != id ||
        tx['is_accepted'] != true) {
      throw StateError('Funding return is not independently accepted yet.');
    }
    final requests = receipt['requests'] as List;
    final terms = receipt['fundingReturnTerms'] as Map?;
    final sourceIndex = terms?['sourceIndex'] as int? ?? 0;
    if (sourceIndex < 0 ||
        sourceIndex >= requests.length ||
        (terms == null && (receipt['side'] != 'buy' || requests.length != 1))) {
      throw StateError('Unsupported funding-return receipt.');
    }
    final original =
        jsonDecode('${requests[sourceIndex]['txJsonString']}') as Map;
    final ownerScript = '000020${kaspaOwnerIdFromAddress(address)}ac';
    final expected = (original['inputs'] as List)
        .cast<Map>()
        .where((i) =>
            terms == null ||
            (i['utxo']['covenantId'] == null &&
                i['utxo']['scriptPublicKey'] == ownerScript &&
                (terms['points'] as List)
                    .contains('${i['transactionId']}:${i['index']}')))
        .toList();
    if (expected.isEmpty ||
        (terms != null &&
            expected.length != (terms['points'] as List).length)) {
      throw StateError('Funding return does not invalidate the saved plan.');
    }
    for (var i = 0; i < sourceIndex; i++) {
      if (!await accepted('${receipt['transactionIds'][i]}')) {
        throw StateError(
            'Earlier signed preparation is not independently accepted.');
      }
    }
    final points =
        expected.map((i) => '${i['transactionId']}:${i['index']}').toSet();
    final actual = (tx['inputs'] as List).cast<Map>();
    final outputs = (tx['outputs'] as List).cast<Map>();
    final total = expected.fold<BigInt>(BigInt.zero,
        (n, i) => n + KasForgeService.exactUnsigned(i['utxo']['amount']));
    if (actual.length != points.length ||
        actual
                .map((i) =>
                    '${i['previous_outpoint_hash']}:${i['previous_outpoint_index']}')
                .toSet()
                .length !=
            points.length ||
        actual.any((i) => !points.contains(
            '${i['previous_outpoint_hash']}:${i['previous_outpoint_index']}')) ||
        outputs.length != 1 ||
        outputs.single['script_public_key'] !=
            '20${kaspaOwnerIdFromAddress(address)}ac' ||
        KasForgeService.exactUnsigned(outputs.single['amount']) !=
            total - BigInt.from(10000000)) {
      throw StateError(
          'Funding return differs from the confirmed recovery terms.');
    }
    guard(address);
  }

  Future<void> verifyFinal(String address, Map<String, dynamic> receipt,
      String id, bool filled) async {
    guard(address);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) {
      throw StateError('Invalid final Forge transaction ID.');
    }
    final r = await client
        .get(Uri.parse('https://api-tn10.kaspa.org/transactions/$id'))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode == 404) throw KasForgeConfirmationPending();
    if (r.statusCode != 200) {
      throw StateError(
          'Independent Forge completion lookup is unavailable. Saved order retained.');
    }
    final tx = jsonDecode(r.body);
    if (tx is! Map || tx['transaction_id'] != id || tx['is_accepted'] != true) {
      if (tx is Map &&
          tx['transaction_id'] == id &&
          tx['is_accepted'] != true) {
        throw KasForgeConfirmationPending();
      }
      throw StateError(
          'Independent Forge completion lookup is unavailable. Saved order retained.');
    }
    final order = receipt['order'] as Map, st = order['state'] as Map;
    final point = '${order['output']['outpoint']}'.split(':');
    final inputs = (tx['inputs'] as List).whereType<Map>().toList(),
        outputs = (tx['outputs'] as List).whereType<Map>().toList();
    if (!inputs.any((i) =>
        i['previous_outpoint_hash'] == point[0] &&
        '${i['previous_outpoint_index']}' == point[1])) {
      throw StateError('Final Forge transaction does not spend this order.');
    }
    final owner = kaspaOwnerIdFromAddress(address);
    final sell = st['unitsIn'] == null;
    BigInt? verifiedTokenAmount, verifiedKasAmount;
    if ((filled && sell) || (!filled && !sell)) {
      final returned = outputs
          .where((o) => o['script_public_key'] == '20${owner}ac')
          .fold<BigInt>(BigInt.zero,
              (n, o) => n + KasForgeService.exactUnsigned(o['amount']));
      final minimum = filled
          ? KasForgeService.exactUnsigned(st['minSompi'])
          : KasForgeService.exactUnsigned(order['output']['sompi']) -
              BigInt.from(id == receipt['cancelId'] ? 10000000 : 1000000);
      if (returned < minimum) {
        throw StateError('Forge KAS payout is below the saved guarantee.');
      }
      verifiedKasAmount = returned;
      if (filled && sell) {
        verifiedTokenAmount = KasForgeService.exactUnsigned(st['amount']);
      }
    } else {
      final template = await _template();
      var incoming = BigInt.zero, outgoing = BigInt.zero;
      final seen = <String>{};
      for (final input in inputs) {
        List<({int offset, Uint8List data})> pushes;
        try {
          pushes = BraidService.pushes('${input['signature_script']}');
        } catch (_) {
          continue;
        }
        if (pushes.isEmpty) continue;
        final old = BraidService.hex(pushes.last.data);
        final prefix = '${template['prefix']}',
            suffix = '${template['suffix']}';
        if (!old.startsWith(prefix) ||
            !old.endsWith(suffix) ||
            old.length != prefix.length + 224 + suffix.length) {
          continue;
        }
        final bytes = BraidService.bytes(
            old.substring(prefix.length, old.length - suffix.length));
        BigInt integer(List<int> v) => v.asMap().entries.fold<BigInt>(
            BigInt.zero, (n, e) => n + (BigInt.from(e.value) << (8 * e.key)));
        if (BraidService.hex(bytes.sublist(10, 42)) == owner &&
            bytes[43] == 0) {
          outgoing += integer(bytes.sublist(1, 9));
        }
        if (pushes.length < 8) continue;
        final c = pushes.take(6).map((p) => p.data).toList();
        final count = c[2].length;
        if (count < 1 ||
            count > 3 ||
            c[0].length != count * 8 ||
            c[1].length != count * 32 ||
            c[3].length != count ||
            c[4].length != count * 32 ||
            c[5].length != count * 32) {
          continue;
        }
        for (var i = 0; i < count; i++) {
          if (c[2][i] != 0 ||
              BraidService.hex(c[1].sublist(i * 32, (i + 1) * 32)) != owner) {
            continue;
          }
          final amount = integer(c[0].sublist(i * 8, (i + 1) * 8));
          final program =
              '$prefix${BraidService.push(BraidService.hex(c[0].sublist(i * 8, (i + 1) * 8)))}20${owner}010001${c[3][i].toRadixString(16).padLeft(2, '0')}20${BraidService.hex(c[4].sublist(i * 32, (i + 1) * 32))}20${BraidService.hex(c[5].sublist(i * 32, (i + 1) * 32))}$suffix';
          final spk = _packed(program).substring(4);
          for (var oi = 0; oi < outputs.length; oi++) {
            if (outputs[oi]['script_public_key'] == spk &&
                outputs[oi]['covenant_id'] == st['kcc20'] &&
                seen.add('$oi')) {
              incoming += amount;
            }
          }
        }
      }
      final min =
          KasForgeService.exactUnsigned(st[filled ? 'minTokens' : 'amount']);
      if (incoming - outgoing < min) {
        throw StateError(
            'Forge token payout is not independently verified yet.');
      }
      verifiedTokenAmount = incoming - outgoing;
      if (!filled) {
        final returned = outputs
            .where((o) => o['script_public_key'] == '20${owner}ac')
            .fold<BigInt>(BigInt.zero,
                (n, o) => n + KasForgeService.exactUnsigned(o['amount']));
        if (returned <
            KasForgeService.exactUnsigned(order['output']['sompi']) -
                BigInt.from(id == receipt['cancelId'] ? 10000000 : 1000000)) {
          throw StateError(
              'Forge refund did not return the saved KAS deposit.');
        }
      }
    }
    guard(address);
    receipt['verifiedDetails'] = {
      if (verifiedTokenAmount != null) 'tokenAmountRaw': '$verifiedTokenAmount',
      if (verifiedKasAmount != null) 'kasAmountSompi': '$verifiedKasAmount',
    };
  }
}
