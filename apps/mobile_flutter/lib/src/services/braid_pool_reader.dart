import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../kaspa_address.dart';
import 'braid_pool_pins.dart';
import 'braid_service.dart';

/// Port of the hash-checked pool reader from the verified 2026-10-28 kit.
/// Only fixed independent node URLs are used; quote tips are not authority.
class BraidPoolReader {
  BraidPoolReader(this.client, {required this.mainnet})
      : _lookup = (Stopwatch()..start());
  final http.Client client;
  final bool mainnet;
  final Stopwatch _lookup;
  String get net => mainnet ? 'mainnet' : 'tn10';
  String get node => mainnet
      ? 'https://kaspire.kaslab.space/api/local-node'
      : 'https://api-tn10.kaspa.org';
  static final pins = jsonDecode(braidPoolPinsJson) as Map;
  static BigInt le(List<int> bytes) => bytes
      .asMap()
      .entries
      .fold(BigInt.zero, (n, e) => n + (BigInt.from(e.value) << (8 * e.key)));
  static String u64(BigInt n) {
    if (n.isNegative || n >= (BigInt.one << 63)) {
      throw StateError('Pool integer out of range.');
    }
    return BraidService.hex(
        List.generate(8, (i) => ((n >> (8 * i)) & BigInt.from(255)).toInt()));
  }

  static List<Uint8List> witness(String hex) {
    final b = BraidService.bytes(hex), result = <Uint8List>[];
    var i = 0;
    while (i < b.length) {
      final op = b[i++];
      if (op == 0) {
        result.add(Uint8List(0));
        continue;
      }
      if (op >= 81 && op <= 96) {
        result.add(Uint8List.fromList([op - 80]));
        continue;
      }
      if (op == 79) {
        result.add(Uint8List.fromList([129]));
        continue;
      }
      var size = op;
      if (op >= 76 && op <= 78) {
        final count = op == 76
            ? 1
            : op == 77
                ? 2
                : 4;
        if (i + count > b.length) throw StateError('Truncated pool witness.');
        size = 0;
        for (var j = 0; j < count; j++) {
          size |= b[i++] << (8 * j);
        }
      } else if (op > 75) {
        throw StateError('Non-push pool witness.');
      }
      if (i + size > b.length) throw StateError('Truncated pool argument.');
      result.add(Uint8List.sublistView(b, i, i + size));
      i += size;
    }
    return result;
  }

  static BigInt number(List<int> b) {
    if (b.length > 8 || (b.isNotEmpty && (b.last & 128) != 0)) {
      throw StateError('Negative/oversized pool argument.');
    }
    return le(b);
  }

  static String nextRedeem(String venue, String script, List outputs) {
    final p = witness(script);
    if (p.length < 2) throw StateError('Pool witness is incomplete.');
    final old = BraidService.hex(p.last);
    if (!old.startsWith('6b')) throw StateError('Unexpected pool program.');
    if (venue == 'kr') {
      if (p.length < 11 ||
          p[8].length != 32 ||
          p[9].length != 36 ||
          old.length < 286) {
        throw StateError('Unexpected Rocket pool state.');
      }
      return '6b${p.take(8).map((b) => '08${u64(number(b))}').join()}20${BraidService.hex(p[8])}24${BraidService.hex(p[9])}${old.substring(286)}';
    }
    if (old.length < 188) throw StateError('Unexpected KRON pool state.');
    final s = BraidService.bytes(old.substring(2, 188));
    if (s[0] != 8 || s[9] != 8 || s[18] != 32 || s[51] != 8 || s[60] != 32) {
      throw StateError('Unexpected KRON pool layout.');
    }
    var kas = le(s.sublist(1, 9)),
        tok = le(s.sublist(10, 18)),
        shares = le(s.sublist(52, 60));
    var lp = BraidService.hex(s.sublist(61, 93));
    final selector = number(p[p.length - 2]).toInt();
    BigInt a(int i) => number(p[i]);
    if (selector == 0 && p.length == 12) {
      kas += a(0);
      tok -= a(1);
    } else if (selector == 1 && p.length == 11) {
      kas -= a(0);
      tok = a(3);
    } else if (selector == 2 && p.length == 17) {
      kas += a(0);
      tok += a(1);
      shares += a(2);
    } else if (selector == 3 && p.length == 17) {
      shares -= a(0);
      kas -= a(1);
      tok -= a(2);
    } else if (selector == 4 && p.length == 6) {
      final row = outputs.whereType<Map>().where((o) => o['index'] == 1).single;
      lp = '${row['covenant_id']}';
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(lp)) {
        throw StateError('Missing LP covenant.');
      }
    } else {
      throw StateError('Unsupported KRON pool transition.');
    }
    return '6b08${u64(kas)}08${u64(tok)}20${BraidService.hex(s.sublist(19, 51))}08${u64(shares)}20$lp${old.substring(188)}';
  }

  /// Price only a verified current redeem; same integer math as the kit.
  static BigInt sale(String net, String token, String redeem, BigInt amount) =>
      saleAmounts(net, token, redeem, amount).net;

  /// Keep venue fees separate: staged partner fees use gross trade notional,
  /// whereas the intermediate payout and atomic token-fee floor use net KAS.
  static ({BigInt gross, BigInt net}) saleAmounts(
      String net, String token, String redeem, BigInt amount) {
    final pin = (pins[net] as Map?)?[token] as Map?;
    if (pin == null) {
      throw StateError('No independently pinned pool for this token.');
    }
    final b = BraidService.bytes(redeem),
        kr = pin['venue'] == 'kr',
        size = kr ? 143 : 94;
    if (amount <= BigInt.zero ||
        b.length != size + pin['codeLength'] ||
        b.first != 107 ||
        BraidService.digest(b.sublist(size)) != pin['codeHash']) {
      throw StateError('Pool code fingerprint differs.');
    }
    BigInt at(int offset) => le(b.sublist(offset, offset + 8));
    if (kr) {
      for (var i = 0; i < 8; i++) {
        if (b[1 + i * 9] != 8) throw StateError('Invalid pool state.');
      }
      if (b[73] != 32 ||
          b[106] != 36 ||
          at(2) != BigInt.one ||
          BraidService.hex(b.sublist(74, 106)) != token) {
        throw StateError('Wrong graduated Rocket token.');
      }
      final kas = at(65), tok = at(56);
      if (kas <= BigInt.zero || tok <= BigInt.zero) {
        throw StateError('Empty pool.');
      }
      final gross = kas * amount ~/ (tok + amount);
      final fee = gross *
          BigInt.from(net == 'mainnet' ? 100 : 30) ~/
          BigInt.from(10000);
      final result =
          gross - (fee < BigInt.from(10000000) ? BigInt.from(10000000) : fee);
      if (result <= BigInt.zero) {
        throw StateError('Sale does not cover venue fees.');
      }
      return (gross: gross, net: result);
    }
    if (b[1] != 8 ||
        b[10] != 8 ||
        b[19] != 32 ||
        b[52] != 8 ||
        b[61] != 32 ||
        BraidService.hex(b.sublist(20, 52)) != token) {
      throw StateError('Wrong KRON pool token.');
    }
    final kas = at(2),
        tok = at(11),
        shares = at(53),
        locked = BigInt.from(1000000);
    if (kas <= BigInt.one || tok <= BigInt.zero || shares < locked) {
      throw StateError('Invalid KRON reserves.');
    }
    BigInt retain(BigInt u) => shares == locked
        ? BigInt.zero
        : (u * BigInt.from(20) * (shares - locked) - BigInt.one) ~/
                (BigInt.from(10000) * shares) +
            BigInt.one;
    var lo = BigInt.zero, hi = kas - BigInt.one;
    while (lo < hi) {
      final m = (lo + hi + BigInt.one) ~/ BigInt.two;
      if ((kas - m - retain(m)) * (tok + amount) >= kas * tok) {
        lo = m;
      } else {
        hi = m - BigInt.one;
      }
    }
    final gross = lo * BigInt.from(1000000),
        lp = gross * BigInt.from(20) ~/ BigInt.from(10000);
    BigInt pad(BigInt n) =>
        n < BigInt.from(20000000) ? BigInt.from(20000000) : n;
    final result = gross -
        pad(gross ~/ BigInt.from(1000) + lp * locked ~/ shares) -
        pad(gross * BigInt.from(70) ~/ BigInt.from(10000));
    if (result <= BigInt.zero) {
      throw StateError('Sale does not cover venue fees.');
    }
    return (gross: gross, net: result);
  }

  Future<dynamic> read(String path, {bool publicNode = false}) async {
    final remaining = const Duration(seconds: 24) - _lookup.elapsed;
    if (remaining <= Duration.zero) {
      throw StateError(
          'Independent pool lookup timed out. Nothing was signed.');
    }
    final base = publicNode && mainnet ? 'https://api.kaspa.org' : node;
    final response = await client.get(Uri.parse('$base$path'), headers: {
      'cache-control': 'no-cache'
    }).timeout(remaining < const Duration(seconds: 8)
        ? remaining
        : const Duration(seconds: 8));
    if (response.statusCode != 200 ||
        response.bodyBytes.length > 4 * 1024 * 1024) {
      throw StateError(
          'Independent pool lookup unavailable. Refresh the quote.');
    }
    return jsonDecode(response.body);
  }

  // History indexing can lag behind the node's live UTXO set. Either fixed
  // independent indexer may supply a transaction, never its spendability.
  // The exact current outpoint is always checked against our own synced node.
  Future<Map> transaction(String id) async {
    for (final publicNode in [false, if (mainnet) true]) {
      try {
        final tx = await read('/transactions/$id?resolve_previous_outpoints=no',
            publicNode: publicNode);
        if (tx is Map &&
            tx['transaction_id'] == id &&
            tx['is_accepted'] == true &&
            tx['outputs'] is List &&
            tx['inputs'] is List) {
          return tx;
        }
      } catch (_) {/* Try the other fixed independent indexer. */}
    }
    throw StateError(
        'Pool transaction not independently accepted yet. Nothing was signed.');
  }

  String address(String script) =>
      kaspaScriptHashAddress(script.substring(4, 68),
          prefix: mainnet ? 'kaspa' : 'kaspatest');
  Future<bool> unspent(Map proof) async {
    final list = await read(
        '/addresses/${Uri.encodeComponent(address('${proof['scriptPublicKey']}'))}/utxos');
    if (list is! List) throw StateError('Independent pool UTXOs unavailable.');
    for (final r in list.whereType<Map>()) {
      final outpoint = r['outpoint'], entry = r['utxoEntry'];
      if (outpoint is! Map ||
          outpoint['transactionId'] != proof['transactionId'] ||
          outpoint['index'] != proof['index']) {
        continue;
      }
      if (entry is! Map) {
        throw StateError(
            'Independent pool UTXO data is incomplete. Nothing was signed.');
      }
      final script = entry['scriptPublicKey'];
      if (!(script is Map &&
          script['version'] == 0 &&
          (script['scriptPublicKey'] ?? script['script']) ==
              proof['scriptPublicKey'] &&
          entry['isCoinbase'] == false &&
          BigInt.tryParse('${entry['amount']}') != null &&
          BigInt.parse('${entry['amount']}') > BigInt.zero)) {
        throw StateError(
            'Independent pool UTXO data differs. Nothing was signed.');
      }
      return true;
    }
    return false;
  }

  Future<Map<String, dynamic>> value(
      String token, BigInt amount, int slippage, Map tip,
      {bool followSpends = true}) async {
    final pin = (pins[net] as Map?)?[token] as Map?;
    if (pin == null) {
      throw StateError(
          'Token→token fees require an independently pinned pool.');
    }
    var id = '${tip['transactionId']}', index = tip['index'];
    for (var step = 0; step < 8; step++) {
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
          index is! int ||
          index < 0) {
        throw StateError('Invalid pool hint.');
      }
      final tx = await transaction(id);
      final matches = (tx['outputs'] as List)
          .whereType<Map>()
          .where((o) => o['index'] == index && o['covenant_id'] == pin['pool'])
          .toList();
      if (matches.length != 1) {
        throw StateError('Pool hint does not identify the pinned pool output.');
      }
      final output = matches.single;
      String? redeem;
      for (final input in (tx['inputs'] as List).whereType<Map>()) {
        try {
          final candidate = nextRedeem('${pin['venue']}',
              '${input['signature_script']}', tx['outputs'] as List);
          if (BraidService.scriptHash(candidate).substring(4) ==
              output['script_public_key']) {
            sale(net, token, candidate, amount);
            redeem = candidate;
            break;
          }
        } catch (_) {/* Other inputs are not the pinned pool. */}
      }
      if (redeem == null) {
        throw StateError(
            'Pool state/code could not be independently verified.');
      }
      final proof = <String, dynamic>{
        'network': net,
        'tokenId': token,
        'poolCovenantId': pin['pool'],
        'transactionId': id,
        'index': index,
        'scriptPublicKey': output['script_public_key'],
        'redeem': redeem
      };
      if (await unspent(proof)) {
        final tradeKas = sale(net, token, redeem, amount),
            floor =
                tradeKas * BigInt.from(10000 - slippage) ~/ BigInt.from(10000);
        return {...proof, 'tradeKas': '$tradeKas', 'floor': '$floor'};
      }
      if (!followSpends) {
        throw StateError('Pool changed. A fresh pool hint is required.');
      }
      Map? spender;
      for (final publicNode in [false, if (mainnet) true]) {
        for (var page = 0; page < 5 && spender == null; page++) {
          dynamic rows;
          try {
            rows = await read(
                '/addresses/${Uri.encodeComponent(address('${output['script_public_key']}'))}/full-transactions?limit=50&offset=${page * 50}&resolve_previous_outpoints=no',
                publicNode: publicNode);
          } catch (_) {
            break;
          }
          if (rows is! List) break;
          for (final row in rows.whereType<Map>()) {
            if (row['is_accepted'] == true &&
                row['inputs'] is List &&
                RegExp(r'^[a-f0-9]{64}$')
                    .hasMatch('${row['transaction_id']}') &&
                (row['inputs'] as List).whereType<Map>().any((i) =>
                    i['previous_outpoint_hash'] == id &&
                    i['previous_outpoint_index'] == index)) {
              spender = row;
              break;
            }
          }
          if (rows.length < 50) break;
        }
        if (spender != null) break;
      }
      if (spender == null) {
        throw StateError(
            'Pool changed; its new state is not indexed yet. Refresh the quote.');
      }
      final nextOutputs = (spender['outputs'] as List? ?? [])
          .whereType<Map>()
          .where((o) => o['covenant_id'] == pin['pool'])
          .toList();
      if (nextOutputs.length != 1) {
        throw StateError(
            'Pool continuation is not uniquely verified. Nothing was signed.');
      }
      id = '${spender['transaction_id']}';
      index = nextOutputs.single['index'];
    }
    throw StateError('Pool changed too often. Refresh the quote.');
  }
}
