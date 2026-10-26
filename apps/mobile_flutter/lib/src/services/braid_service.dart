import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:pointycastle/digests/blake2b.dart';

import '../kaspa_address.dart';
import 'braid_clock.dart';
import 'encrypted_store.dart';
import 'network_settings.dart';

class BraidToken {
  const BraidToken(this.symbol, this.id, this.kind, this.template, this.prefix,
      this.suffixLength, this.codeHash);
  final String symbol, id, template, prefix, codeHash;
  final int kind, suffixLength;
  // These are the pinned TN10 test coins, not the similarly named Mainnet
  // coins. UI deliberately labels token amounts as raw units until KCC-23
  // unit declarations have been independently checked for each deployment.
  bool get isKas => symbol == 'KAS';
}

class BraidService {
  BraidService({http.Client? client, EncryptedStore? store, BraidClock? clock})
      : client = client ?? http.Client(),
        store = store ?? const KeystoreEncryptedStore() {
    this.clock = clock ?? BraidClock(this.client);
  }
  static const enabled =
      bool.fromEnvironment('KASPIRE_BRAID_TN10', defaultValue: true);
  static const origin = 'https://tn10-aggregator.braidswap.com';
  static const api = '$origin/api/venues/router';
  static const pin =
      '905df466072298313e1cc9e86132ba61f26e2a359f7a7dbd5028fa1963872646';
  static final zero = '0' * 64;
  static final tokens = [
    BraidToken('KAS', zero, 0, zero, '', 0, ''),
    const BraidToken(
        'ICE',
        'b20f807bed621ca3ea3aaf1f605c6d16d3e3efc766aedefd089db019ceb30526',
        1,
        '734850b0af0aeef49f009167bf9ddd238fd8c5cdbe214234f97181ac6f5cc498',
        '6b209703112ee6e3555107cd168858992b77d3b74f655205b2b463b1f9ec2ec73cf7',
        3885,
        '4f3c7aea48bde5ab8468fe4bbf0b1861758e776972af453a73805fa75d4db508'),
    const BraidToken(
        'FIRE',
        'a83d58c3a497efe86176939a0ed9d2df13441cb1897c48f89c5851edfad7f61e',
        1,
        '734850b0af0aeef49f009167bf9ddd238fd8c5cdbe214234f97181ac6f5cc498',
        '6b209703112ee6e3555107cd168858992b77d3b74f655205b2b463b1f9ec2ec73cf7',
        3885,
        '4f3c7aea48bde5ab8468fe4bbf0b1861758e776972af453a73805fa75d4db508'),
    const BraidToken(
        'ROCKET',
        'edca1f844ae0b252d0c11ab98ff850879afad1f04e19aff2754c9eb232b59734',
        1,
        '3d689d6273b7631e69f672d5ca744cb266ae997b04974196439858675cc04fe1',
        '6b20ff3ae732e3a2819bf9181f5aed6b1e9d0f7abea70a1dd655b8e777cbcbd2422b',
        11312,
        'b361e9dec692209f6ad5e086f09041cc06476c2642d3c0a3e2321c9341ce81a7'),
    for (final entry in const {
      'KAHA20':
          '0282cf6d53023ec08e241919c150d742f54b6f61bac2f1b8f81b7e6343845b9f',
      'KRKT20':
          '7a1568354b2c70e5919e400856e72f45e3621b674465739c33f0f7ed53fbd9d6',
      'KZEN20':
          '4a4eff44e065b60ccc9ea8175d818c4e17b2f12d15db50cd570c61f57f1dfb7d'
    }.entries)
      BraidToken(
          entry.key,
          entry.value,
          1,
          '5a93ff33a4791c1c4c2c0da21a24476aa3e06c0f62e3ceaadc491d72efa80b45',
          '6b20b9be0a8b1c3de1d2ddbddaee1478f8147b9f57ba22c8500b75d542c31221a796',
          4946,
          '11356bd4fd3f553e63b46efa5b2d37231658ada3877460b276b6f31ac797c049'),
    for (final entry in const {
      'mKRON':
          '86e3e4d1d1d2f41848d82fb732cb0bf3058cf7ee12bb78ba957ce5cc53941bb6',
      'mKPEPE':
          '7ca64292dbdd9672303788da5219f51277a3653c60dfddc1fc7696f842088e8c'
    }.entries)
      BraidToken(
          entry.key,
          entry.value,
          2,
          '2ed46a7edf5b168e67dba56998c58255235bebac436940a85115ca31d5c559f2',
          '',
          2387,
          '7dc133ff0889fd856c8c92d671a06f8851093097ee4b132f86f7d1f6bccc9642'),
  ];
  final http.Client client;
  final EncryptedStore store;
  late final BraidClock clock;
  static final _busy = <String>{};
  void guard(String address) {
    if (!NetworkSettings.isTestnet ||
        !address.startsWith('kaspatest:') ||
        kaspaOwnerIdFromAddress(address).isEmpty) {
      throw StateError('Braid is enabled only for Testnet 10 Schnorr wallets.');
    }
  }

  String key(String address) => 'braid_tn10_receipts_v1_$address';
  Future<Map<String, dynamic>> call(String path,
      {Map<String, Object?>? body, Map<String, String>? query}) async {
    if (!NetworkSettings.isTestnet) {
      throw StateError('Braid requires Testnet 10.');
    }
    final uri = Uri.parse('$api/$path').replace(queryParameters: query);
    final response = await (body == null
            ? client.get(uri)
            : client.post(uri,
                headers: {'content-type': 'application/json'},
                body: jsonEncode(body)))
        .timeout(const Duration(seconds: 35));
    if (!NetworkSettings.isTestnet) {
      throw StateError('Network changed. The Braid result was discarded.');
    }
    if (response.bodyBytes.length > 2 * 1024 * 1024) {
      throw StateError('Braid response too large.');
    }
    final data = jsonDecode(response.body);
    if (response.statusCode != 200 || data is! Map || data['error'] != null) {
      throw StateError(
          'Braid ${data is Map ? data['code'] ?? response.statusCode : response.statusCode}: ${data is Map ? data['error'] ?? 'temporarily unavailable' : 'temporarily unavailable'}');
    }
    return Map<String, dynamic>.from(data);
  }

  Future<Map<String, dynamic>> info() async {
    final d = await call('info');
    if (d['net'] != 'tn10' ||
        d['pin'] != pin ||
        d['expectedPin'] != pin ||
        d['pinOk'] != true ||
        d['enabled'] != true ||
        (d['executorStatus'] as Map?)?['healthy'] != true) {
      throw StateError(
          'Braid router is unavailable or differs from the pinned release.');
    }
    return d;
  }

  Future<List<Map<String, dynamic>>> saved(String address) async {
    final raw = await store.read(key(address));
    if (raw == null) return [];
    final d = jsonDecode(raw);
    if (d is! List) {
      throw StateError(
          'Saved Braid receipts could not be read. Do not start a replacement swap.');
    }
    return d.map((r) => Map<String, dynamic>.from(r as Map)).toList();
  }

  Future<void> retain(String address, Map<String, dynamic> receipt) async {
    final rows = await saved(address);
    final old = rows.indexWhere((r) => r['ref'] == receipt['ref']);
    if (old < 0) {
      rows.add(receipt);
    } else {
      rows[old] = receipt;
    }
    if (rows.length > 200) {
      throw StateError(
          'Too many saved Braid receipts. Export them before continuing.');
    }
    final text = jsonEncode(rows);
    await store.write(key(address), text);
    if (await store.read(key(address)) != text) {
      throw StateError(
          'Braid recovery receipt could not be saved. Nothing may be submitted.');
    }
  }

  Future<Map<String, dynamic>?> pending(String address) async {
    for (final r in (await saved(address)).reversed) {
      if (r['signed'] != null && r['verifiedFinal'] != true) return r;
    }
    return null;
  }

  static BigInt integer(Object? value) {
    final s = '$value';
    if (!RegExp(r'^(0|[1-9][0-9]{0,18})$').hasMatch(s)) {
      throw StateError('Invalid Braid integer quantity.');
    }
    final n = BigInt.parse(s);
    if (n >= BigInt.one << 63) {
      throw StateError('Braid quantity exceeds the contract range.');
    }
    return n;
  }

  static String hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  static Uint8List bytes(String h) {
    if (!RegExp(r'^(?:[a-f0-9]{2})*$').hasMatch(h)) {
      throw StateError('Invalid Braid hex data.');
    }
    return Uint8List.fromList([
      for (var i = 0; i < h.length; i += 2)
        int.parse(h.substring(i, i + 2), radix: 16)
    ]);
  }

  static String digest(List<int> b) =>
      hex(Blake2bDigest(digestSize: 32).process(Uint8List.fromList(b)));
  static String scriptHash(String redeem) =>
      '0000aa20${digest(bytes(redeem))}87';
  static List<({int offset, Uint8List data})> pushes(String script) {
    final b = bytes(script);
    var i = 0;
    final out = <({int offset, Uint8List data})>[];
    while (i < b.length) {
      var n = b[i++];
      if (n == 0 || n == 79 || (n >= 81 && n <= 96)) continue;
      if (n >= 76 && n <= 78) {
        final size = n == 76
            ? 1
            : n == 77
                ? 2
                : 4;
        if (i + size > b.length) throw StateError('Truncated script push.');
        n = 0;
        for (var j = 0; j < size; j++) {
          n |= b[i++] << (8 * j);
        }
      } else if (n > 75) {
        throw StateError('Non-push Braid witness.');
      }
      if (n < 0 || i + n > b.length) throw StateError('Truncated script data.');
      out.add((offset: i, data: Uint8List.sublistView(b, i, i + n)));
      i += n;
    }
    return out;
  }

  Future<Map<String, dynamic>> quote(String address, BraidToken from,
      BraidToken to, String raw, int slippage) async {
    guard(address);
    if (from.id == to.id ||
        integer(raw) == BigInt.zero ||
        slippage < 1 ||
        slippage > 500) {
      throw StateError(
          'Choose different assets, a positive amount and 0.01–5% slippage.');
    }
    if (from.kind == 2 && to.kind == 2) {
      throw StateError(
          'Two-stage KRON routes are not enabled in this first integration.');
    }
    await info();
    final q = await call('quote', query: {
      'from': from.symbol,
      'to': to.symbol,
      from.isKas ? 'payTotal' : 'amountIn': raw,
      'slippageBps': '$slippage',
      'userPk': kaspaOwnerIdFromAddress(address)
    });
    if (q['net'] != 'tn10' ||
        q['from'] != from.symbol ||
        q['to'] != to.symbol ||
        q['pin'] != pin ||
        q['staged'] != false ||
        integer((q['walletFee'] as Map?)?['amount']) != BigInt.zero ||
        q[from.isKas ? 'payTotal' : 'amountIn'] != raw) {
      throw StateError('Braid quote differs from the selected swap.');
    }
    final output = integer(q['amountOut']);
    final back = !from.isKas && to.isKas ? BigInt.from(150000000) : BigInt.zero;
    if (output <= back) {
      throw StateError('Quote does not return a positive trade amount.');
    }
    final floor = output -
        ((output - back) * BigInt.from(slippage) + BigInt.from(9999)) ~/
            BigInt.from(10000);
    guard(address);
    return {
      ...q,
      'localFromId': from.id,
      'localToId': to.id,
      'localAmount': raw,
      'localFloor': '$floor',
      'localSlippage': slippage,
      'localAt': DateTime.now().millisecondsSinceEpoch
    };
  }

  Future<Map<String, dynamic>> notes(String address, BraidToken token) async {
    guard(address);
    if (token.isKas) throw StateError('KAS is not a token note.');
    final d = await call('notes',
        query: {'userPk': kaspaOwnerIdFromAddress(address), 'token': token.id});
    if (d['tokenId'] != token.id || d['notes'] is! List) {
      throw StateError('Token balance is unavailable, not zero.');
    }
    return d;
  }

  /// Parse a canonical server PSKT, then enrich it from independent live UTXOs.
  /// A different amount/script/covenant is rejected, never "corrected".
  Future<Map<String, dynamic>> verifyInputs(Map<String, dynamic> source,
      {bool reclaim = false}) async {
    final tx = Map<String, dynamic>.from(jsonDecode(jsonEncode(source)) as Map);
    void allowed(Map map, Set<String> keys) {
      if (map.keys.any((k) => !keys.contains(k))) {
        throw StateError('Unknown Braid transaction field.');
      }
    }

    allowed(tx, {
      'id',
      'version',
      'inputs',
      'outputs',
      'subnetworkId',
      'lockTime',
      'gas',
      'mass',
      'payload'
    });
    if (tx['id'] != null && tx['id'] != zero ||
        tx['version'] != 1 ||
        tx['mass'] != null && tx['mass'] != '0' ||
        tx['gas'] != '0' ||
        tx['subnetworkId'] != '0' * 40 ||
        tx['inputs'] is! List ||
        tx['outputs'] is! List) {
      throw StateError('Unsupported Braid transaction shape.');
    }
    tx.remove('id');
    tx.remove('mass');
    tx['storageMass'] = '0';
    final lookups = <String, List>{};
    for (final item in tx['inputs'] as List) {
      if (item is! Map) throw StateError('Invalid Braid input.');
      allowed(item, {
        'transactionId',
        'index',
        'sequence',
        'sigOpCount',
        'signatureScript',
        'utxo'
      });
      final u = item['utxo'];
      if (u is! Map) throw StateError('Missing Braid UTXO.');
      allowed(u, {
        'address',
        'amount',
        'scriptPublicKey',
        'blockDaaScore',
        'isCoinbase'
      });
      if (item['sequence'] != '0' || u['isCoinbase'] != false) {
        throw StateError('Unsafe Braid input.');
      }
      integer(u['amount']);
      final spk = '${u['scriptPublicKey']}';
      final address = _addressForScript(spk);
      if (u['address'] != null &&
          u['address'] != '' &&
          u['address'] != address) {
        throw StateError('Braid address/script mismatch.');
      }
      if (!lookups.containsKey(address)) {
        lookups[address] = await _liveUtxos(address);
      }
      final rows = lookups[address]!
          .whereType<Map>()
          .where((r) =>
              (r['outpoint'] as Map)['transactionId'] ==
                  item['transactionId'] &&
              (r['outpoint'] as Map)['index'] == item['index'])
          .toList();
      if (rows.length != 1) {
        throw StateError(
            'A swap input is no longer spendable. Refresh before signing.');
      }
      final live = rows.single['utxoEntry'] as Map,
          script = live['scriptPublicKey'] as Map;
      final packed =
          '${(script['version'] as int).toRadixString(16).padLeft(4, '0')}${script['script'] ?? script['scriptPublicKey']}';
      if (packed != spk ||
          '${live['amount']}' != '${u['amount']}' ||
          live['isCoinbase'] != false ||
          !live.containsKey('covenantId')) {
        throw StateError('Braid input differs from independent node data.');
      }
      u['blockDaaScore'] = '${live['blockDaaScore']}';
      u['covenantId'] = live['covenantId'];
      u['address'] = address;
      // v1 budgets are not signing inputs; our local consensus core still
      // executes every input with these bounded, explicit allowances.
      item['computeBudget'] = spk.startsWith('000020')
          ? 11
          : reclaim
              ? 100
              : 150;
    }
    for (final item in tx['outputs'] as List) {
      if (item is! Map) throw StateError('Invalid Braid output.');
      allowed(item, {'value', 'scriptPublicKey', 'covenant'});
      integer(item['value']);
      if (item['covenant'] is Map) {
        allowed(item['covenant'] as Map, {'authorizingInput', 'covenantId'});
      }
    }
    return tx;
  }

  String _addressForScript(String packed) {
    final h = bytes(packed);
    if (h.length == 36 &&
        packed.startsWith('000020') &&
        packed.endsWith('ac')) {
      return kaspaAddressFromOwnerId(packed.substring(6, 70),
          prefix: 'kaspatest');
    }
    if (h.length == 37 &&
        packed.startsWith('0000aa20') &&
        packed.endsWith('87')) {
      return kaspaScriptHashAddress(packed.substring(8, 72),
          prefix: 'kaspatest');
    }
    throw StateError('Unsupported deposit input script.');
  }

  Future<List> _liveUtxos(String address) async {
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
          'Independent live UTXOs unavailable. Saved swaps are preserved.');
    }
    return d['entries'] as List;
  }

  Future<Map<String, dynamic>> build(
      String address, Map<String, dynamic> q) async {
    guard(address);
    if (await pending(address) != null) {
      throw StateError('Check the saved swap before signing another deposit.');
    }
    if (DateTime.now().millisecondsSinceEpoch - (q['localAt'] as int) > 60000) {
      throw StateError('Quote expired. Refresh it.');
    }
    final clocks = await clock.read();
    final random = Random.secure();
    final nonce = hex(List.generate(32, (_) => random.nextInt(256)));
    final b = await call('deposit-build', body: {
      'from': q['from'],
      'to': q['to'],
      q['from'] == 'KAS' ? 'payTotal' : 'amountIn': q['localAmount'],
      'userPk': kaspaOwnerIdFromAddress(address),
      'minOut': q['localFloor'],
      'slippageBps': q['localSlippage'],
      'deadlineSec': 600,
      'nonce': nonce
    });
    guard(address);
    if (b['net'] != 'tn10' ||
        b['pskt'] is! Map ||
        b['terms'] is! Map ||
        b['router'] is! Map ||
        b['userSignInputs'] is! List) {
      throw StateError('Incomplete Braid deposit build.');
    }
    if ((await saved(address)).any((old) =>
        old['ref'] == b['ref'] ||
        (old['context'] as Map?)?['terms']?['intent'] ==
            (b['terms'] as Map)['intent'])) {
      throw StateError('Braid reused a previous deposit reference or intent.');
    }
    final tx = await verifyInputs(Map<String, dynamic>.from(b['pskt'] as Map));
    final from = tokens.singleWhere((t) => t.id == q['localFromId']);
    final redeems = <String, String>{};
    final scripts = <Map<String, Object?>>[];
    final selected = (b['userSignInputs'] as List).cast<int>();
    final rows = tx['inputs'] as List;
    final tokenIndexes = [
      for (var i = 0; i < rows.length; i++)
        if (!'${(rows[i]['utxo'] as Map)['scriptPublicKey']}'
            .startsWith('000020'))
          i
    ];
    final fundingIndex = rows.indexWhere((r) =>
        '${(r['utxo'] as Map)['scriptPublicKey']}' ==
        '000020${kaspaOwnerIdFromAddress(address)}ac');
    final nextStates = <Map<String, dynamic>>[];
    if (!from.isKas) {
      final tok = b['tokRedeems'];
      if (tok is! Map || tok['note'] is! String) {
        throw StateError('Router token note is missing.');
      }
      final noteProgram = '${tok['note']}';
      final prefixSize = from.prefix.length,
          stateSize = from.kind == 1 ? 224 : 92;
      final code = noteProgram.substring(prefixSize + stateSize);
      if (code.length != from.suffixLength * 2 ||
          digest(bytes(code)) != from.codeHash) {
        throw StateError('Unpinned token program.');
      }
      for (var oi = 0; oi < (tx['outputs'] as List).length; oi++) {
        final output = (tx['outputs'] as List)[oi] as Map;
        if ((output['covenant'] as Map?)?['covenantId'] != from.id) continue;
        final candidate = oi == b['noteIdx']
            ? noteProgram
            : (tok['change'] is String
                ? tok['change']
                : (tok['change'] as Map?)?['redeem']);
        // Change can be reconstructed from the independently supplied input
        // notes; no remote change script is accepted as authority.
        String r;
        if (candidate is String) {
          r = candidate;
        } else {
          var sum = BigInt.zero;
          final ri = tok['inputs'];
          for (final ti in tokenIndexes) {
            final rr = ri is List
                ? (ri
                    .whereType<Map>()
                    .where((x) => x['idx'] == ti)
                    .firstOrNull?['redeem'])
                : (ri is Map ? ri['$ti'] : null);
            if (rr is! String) throw StateError('Input token note is missing.');
            final state = bytes(rr).sublist(from.prefix.length ~/ 2);
            final at = from.kind == 1 ? 1 : 36;
            sum += BigInt.from(
                ByteData.sublistView(state).getUint64(at, Endian.little));
          }
          r = noteRedeem(from, kaspaOwnerIdFromAddress(address),
              sum - integer(q['localAmount']), false, bytes(code));
        }
        if (scriptHash(r) != output['scriptPublicKey']) {
          throw StateError('Token change/route note differs from its output.');
        }
        final state =
            bytes(r).sublist(prefixSize ~/ 2, prefixSize ~/ 2 + stateSize ~/ 2);
        nextStates.add({
          'amount':
              from.kind == 1 ? state.sublist(1, 9) : state.sublist(36, 44),
          'owner':
              from.kind == 1 ? state.sublist(10, 42) : state.sublist(1, 33),
          'scheme': from.kind == 1 ? state[43] : state[34]
        });
      }
    }
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i] as Map;
      if ('${(row['utxo'] as Map)['scriptPublicKey']}'.startsWith('000020')) {
        continue;
      }
      final list =
          b['tokRedeems'] is Map ? (b['tokRedeems'] as Map)['inputs'] : null;
      final entry = list is List
          ? list.whereType<Map>().where((r) => r['idx'] == i).firstOrNull
          : null;
      final redeem = entry?['redeem'] ?? (list is Map ? list['$i'] : null);
      if (redeem is! String) {
        throw StateError('Token input redeem script missing.');
      }
      redeems['$i'] = redeem;
      if (from.kind == 1) {
        final leader = i == tokenIndexes.first;
        final args = <String>[];
        if (leader) {
          args.add(hex(nextStates
              .expand((s) => (s['amount'] as List).cast<int>())
              .toList()));
          args.add(hex(nextStates
              .expand((s) => (s['owner'] as List).cast<int>())
              .toList()));
          args.add(hex(nextStates.map((s) => s['scheme'] as int).toList()));
          args.add('00' * nextStates.length);
          args.add(zero * nextStates.length);
          args.add(zero * nextStates.length);
        }
        args.add('00' * (leader ? 66 : 65));
        args.add(leader ? '79c71c23' : 'fd3ef14a');
        args.add(redeem);
        row['signatureScript'] = args.map(push).join();
        final pushes0 = pushes('${row['signatureScript']}');
        final slots = pushes0
            .where((p) =>
                p.data.length == (leader ? 66 : 65) &&
                p.data.every((b) => b == 0))
            .toList();
        if (slots.length != 1) {
          throw StateError('Token witness has no unique signature slot.');
        }
        final sighashes = b['sighashes'];
        final expected = sighashes is Map
            ? sighashes['$i']
            : sighashes is List && i < sighashes.length
                ? sighashes[i]
                : null;
        if (expected is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(expected)) {
          throw StateError(
              'Token signing hash is missing; the native core must cross-check it.');
        }
        scripts.add({
          'inputIndex': i,
          'scriptHex': '',
          'signType': 1,
          'prebuiltSignatureScript': row['signatureScript'],
          'signatureOffsets': [slots.single.offset + (leader ? 1 : 0)],
          'expectedSighash': expected
        });
      } else if (from.kind == 2) {
        if (fundingIndex < 0) {
          throw StateError('A signed funding input is required.');
        }
        row['signatureScript'] = [
          hex(nextStates
              .expand((s) => (s['owner'] as List).cast<int>())
              .toList()),
          hex(nextStates.map((s) => s['scheme'] as int).toList()),
          hex(nextStates
              .expand((s) => (s['amount'] as List).cast<int>())
              .toList()),
          '00' * nextStates.length,
          '',
          hex(List.filled(tokenIndexes.length, fundingIndex)),
          redeem
        ].map(push).join();
      }
    }
    final context = <String, dynamic>{
      'network': 'testnet-10',
      'ref': b['ref'],
      'terms': b['terms'],
      'router': b['router'],
      'fromId': q['localFromId'],
      'toId': q['localToId'],
      'amountIn': q['amountIn'],
      'payTotal': q['from'] == 'KAS' ? q['localAmount'] : '0',
      'minimumOut': q['localFloor'],
      'feeCap': q['braidFee'],
      'midMin': '0',
      'nonce': nonce,
      'coinIndex': '${b['coinIdx']}',
      'noteIndex': '${b['noteIdx']}',
      'chainDaa': '${clocks[0]}',
      'secondChainDaa': '${clocks[1]}',
      'inputRedeems': redeems
    };
    final request = <String, Object?>{
      'sender': address,
      'profile': 'braid-tn10-deposit-v1',
      'txJsonString': jsonEncode(tx),
      'signInputs': [
        for (final i in selected) {'index': i, 'sighashType': 1}
      ],
      'scripts': scripts,
      'tradeSummary': context
    };
    return {
      'ref': b['ref'],
      'address': address,
      'network': 'testnet-10',
      'from': q['from'],
      'to': q['to'],
      'quote': q,
      'context': context,
      'request': request,
      'build': b,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'state': 'prepared'
    };
  }

  Future<void> beforeSigning(
      String address, Map<String, dynamic> receipt) async {
    guard(address);
    final clocks = await clock.read(),
        deadline =
            int.parse('${(receipt['context'] as Map)['terms']['deadline']}');
    final now = clocks.reduce(max);
    if (deadline < now + 1800 || deadline > now + 12000) {
      throw StateError(
          'Deposit deadline changed or is too close. Refresh the quote.');
    }
    await verifyInputs(Map<String, dynamic>.from(
        jsonDecode('${(receipt['request'] as Map)['txJsonString']}') as Map)
      ..remove('storageMass')
      ..remove('id')
      ..update(
          'inputs',
          (v) => (v as List).map((r) {
                final i = Map<String, dynamic>.from(r as Map);
                i.remove('computeBudget');
                (i['utxo'] as Map).remove('covenantId');
                return i;
              }).toList()));
  }

  Future<T> exclusive<T>(String address, Future<T> Function() work) async {
    if (!_busy.add(address)) {
      throw StateError('A Braid operation is already in progress.');
    }
    try {
      return await work();
    } finally {
      _busy.remove(address);
    }
  }

  Future<Map<String, dynamic>> submit(
      String address, Map<String, dynamic> receipt) async {
    guard(address);
    final signed = receipt['signed'];
    if (signed is! Map) throw StateError('No signed deposit to submit.');
    await retain(address, receipt);
    final out = await call('deposit-submit',
        body: {'ref': receipt['ref'], 'signatures': signed});
    receipt['state'] = out['state'];
    await retain(address, receipt);
    return out;
  }

  Future<Map<String, dynamic>> status(
      String address, Map<String, dynamic> receipt) async {
    guard(address);
    final d = await call('status', query: {
      'ref': '${receipt['ref']}',
      'userPk': kaspaOwnerIdFromAddress(address)
    });
    if (d['ref'] != receipt['ref']) {
      throw StateError('Braid returned another swap status.');
    }
    final claimed = (d['deposit'] as Map?)?['txid'];
    if (claimed != null && claimed != receipt['transactionId']) {
      throw StateError('Braid reports a different deposit transaction.');
    }
    receipt['status'] = d;
    receipt['state'] = d['state'];
    // A server's "expired" or "missing" never erases a signed transaction.
    // Only an independently checked accepted final payout unlocks a new trade.
    if (['done', 'refunded', 'reclaimed'].contains(d['state'])) {
      await verifyFinal(address, receipt, d);
      receipt['verifiedFinal'] = true;
    }
    await retain(address, receipt);
    return d;
  }

  Future<void> verifyFinal(String address, Map<String, dynamic> receipt,
      Map<String, dynamic> status) async {
    final received = status['received'];
    final id = status['state'] == 'done'
        ? ((status['exec'] as Map?)?['txid'])
        : ((status['refund'] as Map?)?['txid'] ??
            (status['reclaim'] as Map?)?['txid']);
    if (id is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) {
      throw StateError('Final transaction is not independently confirmed yet.');
    }
    final r = await client
        .get(Uri.parse('https://api-tn10.kaspa.org/transactions/$id'))
        .timeout(const Duration(seconds: 15));
    final tx = jsonDecode(r.body);
    if (r.statusCode != 200 ||
        tx is! Map ||
        tx['transaction_id'] != id ||
        tx['is_accepted'] != true) {
      throw StateError(
          'Final transaction is not accepted by the independent node yet.');
    }
    final ctx = receipt['context'] as Map;
    if (!(tx['inputs'] as List).whereType<Map>().any((i) =>
        i['previous_outpoint_hash'] == receipt['transactionId'] &&
        '${i['previous_outpoint_index']}' ==
            '${receipt['depositCoinIndex']}')) {
      throw StateError('Final transaction does not spend this exact deposit.');
    }
    final toId = status['state'] == 'done' ? ctx['toId'] : ctx['fromId'];
    final token = tokens.singleWhere((t) => t.id == toId);
    final minimum = status['state'] == 'done'
        ? integer(ctx['minimumOut'])
        : token.isKas
            ? BigInt.from(0)
            : integer(ctx['amountIn']);
    final owner = kaspaOwnerIdFromAddress(address);
    if (token.isKas) {
      final sum = (tx['outputs'] as List)
          .whereType<Map>()
          .where((o) => o['script_public_key'] == '20${owner}ac')
          .fold<BigInt>(BigInt.zero, (n, o) => n + integer(o['amount']));
      final refundMin =
          integer(receipt['depositCoinValue']) - BigInt.from(5000000);
      if (sum < (status['state'] == 'done' ? minimum : refundMin)) {
        throw StateError('Final KAS payout is below the saved guarantee.');
      }
    } else {
      if (received is! Map && status['state'] == 'done') {
        throw StateError('Token payout proof is not available.');
      }
      final amount =
          status['state'] == 'done' ? integer(received['amount']) : minimum;
      if (amount < minimum) {
        throw StateError('Token payout is below the saved guarantee.');
      }
      var proved = false;
      for (final i in (tx['inputs'] as List).whereType<Map>()) {
        try {
          final p = pushes('${i['signature_script']}');
          if (p.isEmpty) continue;
          final redeem = p.last.data;
          final stateLen = token.kind == 1 ? 112 : 46;
          final offset = token.prefix.length ~/ 2 + stateLen;
          if (redeem.length != offset + token.suffixLength ||
              hex(redeem.sublist(0, token.prefix.length ~/ 2)) !=
                  token.prefix) {
            continue;
          }
          final code = redeem.sublist(offset);
          if (digest(code) != token.codeHash) continue;
          final expected =
              scriptHash(noteRedeem(token, owner, amount, false, code))
                  .substring(4);
          proved = (tx['outputs'] as List).whereType<Map>().any((o) =>
              o['script_public_key'] == expected &&
              o['covenant_id'] == token.id);
          if (proved) break;
        } catch (_) {/* Another transaction input is not a token witness. */}
      }
      if (!proved) {
        throw StateError(
            'Token payout has not been verified against the pinned token program.');
      }
      if (status['state'] != 'done') {
        final returnedKas = (tx['outputs'] as List)
            .whereType<Map>()
            .where((o) => o['script_public_key'] == '20${owner}ac')
            .fold<BigInt>(BigInt.zero, (n, o) => n + integer(o['amount']));
        if (returnedKas <
            integer(receipt['depositCoinValue']) - BigInt.from(5000000)) {
          throw StateError(
              'Token recovery has not returned the saved KAS deposit.');
        }
      }
    }
    guard(address);
  }

  static String push(String h) {
    final n = h.length ~/ 2;
    if (n <= 75) return '${n.toRadixString(16).padLeft(2, '0')}$h';
    if (n <= 255) return '4c${n.toRadixString(16).padLeft(2, '0')}$h';
    if (n <= 65535) {
      return '4d${(n & 255).toRadixString(16).padLeft(2, '0')}${(n >> 8).toRadixString(16).padLeft(2, '0')}$h';
    }
    throw StateError('Script push is too large.');
  }

  Future<Map<String, Object?>> reclaim(
      String address, Map<String, dynamic> receipt) async {
    guard(address);
    final context = Map<String, dynamic>.from(receipt['context'] as Map);
    final t = context['terms'] as Map;
    final clocks = await clock.read();
    if (clocks.reduce(max) <= int.parse('${t['deadline']}')) {
      throw StateError('The on-chain refund deadline has not passed yet.');
    }
    final redeem =
        '${(context['router'] as Map)['prefix']}${_state(t)}${(context['router'] as Map)['suffix']}';
    final spk = scriptHash(redeem);
    final inputs = <Map<String, Object?>>[], outputs = <Map<String, Object?>>[];
    Future<Map<String, Object?>> liveInput(String packed, int index,
        String expectedAmount, int budget, String witness) async {
      final rows = await _liveUtxos(_addressForScript(packed));
      final live = rows
          .whereType<Map>()
          .where((r) =>
              (r['outpoint'] as Map)['transactionId'] ==
                  receipt['transactionId'] &&
              (r['outpoint'] as Map)['index'] == index)
          .toList();
      if (live.length != 1) {
        throw StateError(
            'This deposit output is already spent or unavailable. Check the swap status before recovering.');
      }
      final e = live.single['utxoEntry'] as Map,
          p = e['scriptPublicKey'] as Map;
      if ('${e['amount']}' != expectedAmount ||
          '${(p['version'] as int).toRadixString(16).padLeft(4, '0')}${p['script'] ?? p['scriptPublicKey']}' !=
              packed ||
          e['isCoinbase'] != false) {
        throw StateError('Saved deposit differs from the independent node.');
      }
      return {
        'transactionId': receipt['transactionId'],
        'index': index,
        'sequence': '0',
        'sigOpCount': 0,
        'computeBudget': budget,
        'signatureScript': witness,
        'utxo': {
          'address': _addressForScript(packed),
          'amount': '${e['amount']}',
          'scriptPublicKey': packed,
          'blockDaaScore': '${e['blockDaaScore']}',
          'isCoinbase': false,
          'covenantId': e['covenantId']
        }
      };
    }

    final from = tokens.singleWhere((token) => token.id == context['fromId']);
    if (!from.isKas) {
      final oldNote = '${receipt['depositNoteRedeem']}';
      final n = bytes(oldNote),
          offset = from.prefix.length ~/ 2 + (from.kind == 1 ? 112 : 46);
      if (n.length != offset + from.suffixLength) {
        throw StateError('Saved token recovery code is incomplete.');
      }
      final code = n.sublist(offset);
      if (digest(code) != from.codeHash) {
        throw StateError('Saved token recovery code is not pinned.');
      }
      final amount = integer(context['amountIn']),
          pk = kaspaOwnerIdFromAddress(address);
      final back = noteRedeem(from, pk, amount, false, code);
      final stateOnly =
          back.substring(from.prefix.length, back.length - code.length * 2);
      final witness = from.kind == 1
          ? '$stateOnly${push('0001')}0479c71c23${push(oldNote)}'
          : '${stateOnly}00${push('01')}${push(oldNote)}';
      inputs.add(await liveInput(
          scriptHash(oldNote),
          receipt['depositNoteIndex'] as int,
          '${receipt['depositNoteValue']}',
          150,
          witness));
      outputs.add({
        'value': '${receipt['depositNoteValue']}',
        'scriptPublicKey': scriptHash(back),
        'covenant': {'authorizingInput': 0, 'covenantId': from.id}
      });
      context.addAll({
        'depositNoteIndex': '${receipt['depositNoteIndex']}',
        'depositNoteValue': '${receipt['depositNoteValue']}',
        'depositNoteRedeem': oldNote
      });
    }
    final ci = inputs.length;
    final coinValue = integer(receipt['depositCoinValue']);
    if (coinValue <= BigInt.from(7000000)) {
      throw StateError('Router coin cannot cover the bounded recovery fee.');
    }
    inputs.add(await liveInput(
        spk, receipt['depositCoinIndex'] as int, '$coinValue', 30, ''));
    outputs.add({
      'value': '${coinValue - BigInt.from(5000000)}',
      'scriptPublicKey': '000020${kaspaOwnerIdFromAddress(address)}ac'
    });
    context.addAll({
      'chainDaa': '${clocks[0]}',
      'secondChainDaa': '${clocks[1]}',
      'depositTransactionId': receipt['transactionId'],
      'depositCoinIndex': '${receipt['depositCoinIndex']}',
      'depositCoinValue': '$coinValue'
    });
    return {
      'sender': address,
      'profile': 'braid-tn10-reclaim-v1',
      'txJsonString': jsonEncode({
        'version': 1,
        'inputs': inputs,
        'outputs': outputs,
        'lockTime': '${t['deadline']}',
        'gas': '0',
        'subnetworkId': '0' * 40,
        'storageMass': '0',
        'payload': ''
      }),
      'signInputs': [
        {'index': ci, 'sighashType': 1}
      ],
      'scripts': [
        {
          'inputIndex': ci,
          'scriptHex': redeem,
          'signType': 1,
          'signatureScript': {
            'mode': 'ordered-args',
            'args': [
              {'type': 'signature', 'prefixHex': ''},
              {'type': 'data', 'hex': '35eecca6'}
            ]
          }
        }
      ],
      'tradeSummary': context
    };
  }

  String _state(Map t) {
    const binary = {
      'recipient',
      'refund',
      'outCovid',
      'outTpl',
      'inCovid',
      'inTpl',
      'wfeePk',
      'intent'
    };
    const fields = [
      'recipient',
      'refund',
      'outKind',
      'outCovid',
      'outTpl',
      'outPfl',
      'outSfl',
      'minOut',
      'inKind',
      'inCovid',
      'inTpl',
      'inPfl',
      'inSfl',
      'inAmount',
      'wfeePk',
      'wfee',
      'feeCap',
      'midMin',
      'deadline',
      'intent',
      'tkFloor'
    ];
    return fields.map((k) {
      if (binary.contains(k)) {
        final h = '${t[k]}';
        if (bytes(h).length != 32) {
          throw StateError('Invalid recovery identity');
        }
        return '20$h';
      }
      final b = ByteData(8)..setUint64(0, integer(t[k]).toInt(), Endian.little);
      return '08${hex(b.buffer.asUint8List())}';
    }).join();
  }

  Future<String> submitRecovery(
      String address, Map<String, dynamic> receipt) async {
    guard(address);
    final signed = receipt['recoverySigned'];
    if (signed is! Map) throw StateError('No saved signed recovery.');
    await retain(address, receipt);
    final id = '${signed['transactionId']}';
    final wrpc = jsonDecode('${signed['wrpcJson']}') as Map;
    await clock.broadcast(wrpc, id);
    return id;
  }

  static String noteRedeem(
      BraidToken t, String owner, BigInt amount, bool p2sh, List<int> code) {
    final b = ByteData(8)..setUint64(0, amount.toInt(), Endian.little);
    final a = hex(b.buffer.asUint8List());
    if (t.kind == 1) {
      return '${t.prefix}08${a}20${owner}01${p2sh ? '03' : '00'}010020${zero}20$zero${hex(code)}';
    }
    return '20${owner}01${p2sh ? '01' : '03'}08${a}0100${hex(code)}';
  }
}
