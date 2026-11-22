import 'dart:convert';
import 'package:http/http.dart' as http;
import 'native_security.dart';
import 'network_settings.dart';
import 'encrypted_store.dart';
import 'kaspa_api.dart';
import '../kaspa_address.dart';

typedef TrestlyRow = Map<String, Object?>;
TrestlyRow trestlyMap(Object? value) =>
    value is Map ? value.cast<String, Object?>() : <String, Object?>{};
int trestlyInt(Object? value) => int.parse(value.toString());

class TrestlySellBalance {
  TrestlySellBalance({required this.cells, required this.complete});
  final List<TrestlyRow> cells;
  final bool complete;
  BigInt get verifiedRaw => cells.fold(
      BigInt.zero,
      (sum, cell) =>
          sum + BigInt.parse(trestlyMap(cell['state'])['amount'].toString()));
  BigInt get maximumRaw => cells.fold(BigInt.zero, (largest, cell) {
        final n = BigInt.parse(trestlyMap(cell['state'])['amount'].toString());
        return n > largest ? n : largest;
      });
  String get maximumAmount {
    final raw = maximumRaw.toString().padLeft(7, '0');
    final fraction =
        raw.substring(raw.length - 6).replaceFirst(RegExp(r'0+$'), '');
    return raw.substring(0, raw.length - 6) +
        (fraction.isEmpty ? '' : '.$fraction');
  }
}

class TrestlyService {
  TrestlyService(this.address,
      {http.Client? client, NativeSecurity? security, EncryptedStore? store})
      : client = client ?? http.Client(),
        security = security ?? NativeSecurity(),
        store = store ?? const KeystoreEncryptedStore();
  static const tokenId =
      '50b3477e7368d0c5bfbd64483b4607350ec411377972f33e40b2d4b6d1513fd3';
  static const poolId =
      '28e7758e6fc0e2054cceb7f87f9da44a53accfa0a1795c8075c80fb99c83aaad';
  static const api = 'https://api.trestly.io/api/v1';
  static const node = 'https://kaspire.kaslab.space/api/local-node';
  static const relay = 'https://kaspire.kaslab.space/api/native-kusdt';
  final String address;
  final http.Client client;
  final NativeSecurity security;
  final EncryptedStore store;
  static final _active = <String>{};
  String get key => 'trestly.pending.v1.$address';
  void guard() {
    if (NetworkSettings.network.value != KaspaNetwork.mainnet ||
        !address.startsWith('kaspa:'))
      throw StateError('KAS / kUSDT native swaps require Kaspa Mainnet.');
  }

  Future<Object?> get(String url) async {
    final response = await client.get(Uri.parse(url), headers: {
      'accept': 'application/json'
    }).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200)
      throw StateError(
          'Swap data unavailable (${response.statusCode}). Please refresh.');
    if (response.bodyBytes.length > 4 * 1024 * 1024)
      throw StateError('Swap response too large.');
    return jsonDecode(response.body);
  }

  Future<List<TrestlyRow>> utxos(String a) async {
    final value = await get('$node/addresses/${Uri.encodeComponent(a)}/utxos');
    if (value is! List) throw StateError('Own-node UTXOs unavailable.');
    return value.map(trestlyMap).toList();
  }

  String spk(TrestlyRow e) {
    final s = trestlyMap(e['scriptPublicKey']);
    final v = trestlyInt(s['version']);
    if (v < 0 || v > 65535) throw StateError('Invalid script version');
    return v.toRadixString(16).padLeft(4, '0') +
        s['scriptPublicKey'].toString();
  }

  Future<TrestlyRow> proof(
      TrestlyRow point, String address, String expectedScript, String? covenant,
      {List<TrestlyRow>? rows}) async {
    final id = point['transactionId'].toString(),
        index = trestlyInt(point['index']);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(id) || index < 0)
      throw StateError('Invalid outpoint.');
    final matches = (rows ?? await utxos(address)).where((r) {
      final p = trestlyMap(r['outpoint']);
      return p['transactionId'] == id &&
          p['index'].toString() == index.toString();
    }).toList();
    if (matches.length != 1)
      throw StateError(
          'Pool or wallet coin changed. Refresh the quote; nothing was signed.');
    final e = trestlyMap(matches.single['utxoEntry']);
    if (spk(e) != expectedScript ||
        e['isCoinbase'] != false ||
        trestlyInt(e['blockDaaScore']) <= 0)
      throw StateError('Own-node coin proof differs.');
    var cid = e['covenantId'];
    // The local REST gateway may omit covenant IDs in UTXO responses. Bind them
    // to the accepted creating transaction, never to the coordinator's claim.
    if (cid == null) {
      final tx = trestlyMap(await get('$node/transactions/$id'));
      final outputs = (tx['outputs'] as List? ?? [])
          .map(trestlyMap)
          .where((o) => o['index'].toString() == index.toString())
          .toList();
      if (tx['transaction_id'] != id ||
          tx['is_accepted'] != true ||
          outputs.length != 1 ||
          outputs.single['amount'].toString() != e['amount'].toString())
        throw StateError('Own node cannot verify the creating transaction.');
      cid = outputs.single['covenant_id'] ??
          trestlyMap(outputs.single['covenant'])['covenantId'];
    }
    if (cid != covenant) throw StateError('Wrong covenant identity.');
    return {
      'transactionId': id,
      'index': index,
      'amount': e['amount'],
      'scriptPublicKey': expectedScript,
      'blockDaaScore': e['blockDaaScore'],
      'isCoinbase': false,
      'covenantId': cid
    };
  }

  Future<TrestlyRow?> pending() async {
    final raw = await store.read(key);
    return raw == null ? null : trestlyMap(jsonDecode(raw));
  }

  Future<void> _verifyDeployment() async {
    final status = trestlyMap(await get('$api/status'));
    final ids = trestlyMap(status['kaspa']);
    if (status['network'] != 'mainnet' ||
        ids['covenantId'] != tokenId ||
        ids['poolId'] != poolId) {
      throw StateError(
          'Trestly deployment identity differs from the reviewed Mainnet deployment.');
    }
    guard();
  }

  Future<TrestlySellBalance> sellBalance({TrestlyRow? poolState}) async {
    guard();
    if (poolState == null) await _verifyDeployment();
    final owner = kaspaOwnerIdFromAddress(address);
    final tokens = trestlyMap(await get('$api/tokens?owner=$owner'));
    guard();
    if (tokens['states'] is! List ||
        tokens.containsKey('unread') && tokens['unread'] is! List ||
        tokens.containsKey('stale') && tokens['stale'] is! bool ||
        tokens.containsKey('truncated') && tokens['truncated'] is! bool) {
      throw StateError('kUSDT balance unavailable.');
    }
    final rows = (tokens['states'] as List).map(trestlyMap).toList();
    var complete = tokens['stale'] != true &&
        tokens['truncated'] != true &&
        (tokens['unread'] as List? ?? []).isEmpty &&
        rows.length <= 64;
    final cells = <TrestlyRow>[], seen = <String>{};
    if (rows.isEmpty) {
      return TrestlySellBalance(cells: cells, complete: complete);
    }
    final pool = poolState ??
        trestlyMap(trestlyMap(await get('$api/pool'))['pool'])['state'];
    if (pool is! Map || pool.isEmpty)
      throw StateError('kUSDT balance verification is unavailable.');
    // Bound concurrent native/node work. Every counted cell is verified against
    // its compiled script and the own node, not merely an indexer balance.
    for (var offset = 0; offset < rows.length && offset < 64; offset += 4) {
      final batch = rows.skip(offset).take(4).toList();
      final verified = await Future.wait(batch.map((row) async {
        try {
          final state = trestlyMap(row['state']);
          final raw = BigInt.parse(state['amount'].toString());
          if (raw < BigInt.zero || raw > BigInt.from(1000000000000000))
            throw StateError('Invalid token amount.');
          if (raw == BigInt.zero) return <String, Object?>{'empty': true};
          if (state['owner'] != owner ||
              trestlyInt(state['ownerScheme']) != 0 ||
              trestlyInt(state['borrowScheme'] ?? 0) != 0 ||
              (state['extensionCommitment'] ?? '00' * 32) != '00' * 32) {
            throw StateError(
                'This cell is not available to the current swap profile.');
          }
          final description = await security
              .describeTrestly({'poolState': pool, 'payerState': state});
          final u = await proof(
              trestlyMap(row['utxo']),
              description['payerAddress'].toString(),
              description['payerScript'].toString(),
              tokenId);
          return <String, Object?>{'utxo': u, 'state': state};
        } catch (_) {
          return null;
        }
      }));
      guard();
      for (final cell in verified) {
        if (cell == null) {
          complete = false;
          continue;
        }
        if (cell['empty'] == true) continue;
        final u = trestlyMap(cell['utxo']),
            point = '${u['transactionId']}:${u['index']}';
        if (!seen.add(point)) {
          complete = false;
          continue;
        }
        cells.add(cell);
      }
    }
    return TrestlySellBalance(cells: cells, complete: complete);
  }

  Future<TrestlyRow> quote(String side, String amount) async {
    guard();
    if (await pending() != null)
      throw StateError('Check the saved swap before creating another.');
    final decimals = side == 'buy' ? 8 : 6;
    final input = parseTrestlyAmount(amount, decimals);
    if (input <= 0) throw StateError('Enter an amount above zero.');
    await _verifyDeployment();
    final data = trestlyMap(await get('$api/pool')),
        p = trestlyMap(data['pool']),
        r = trestlyMap(data['reserve']);
    if (p.isEmpty || r.isEmpty)
      throw StateError('Pool liquidity is unavailable.');
    final description =
        await security.describeTrestly({'poolState': p['state']});
    final pu = await proof(
        trestlyMap(p['utxo']),
        description['poolAddress'].toString(),
        description['poolScript'].toString(),
        poolId);
    if (pu['amount'].toString() != description['poolAmount'].toString())
      throw StateError('Pool reserve amount differs.');
    final ru = await proof(
        trestlyMap(r['utxo']),
        description['reserveAddress'].toString(),
        description['reserveScript'].toString(),
        tokenId);
    final own = await utxos(address), funding = <TrestlyRow>[];
    final publicScript = '000020${kaspaOwnerIdFromAddress(address)}ac';
    final candidates = own.where((r) {
      final e = trestlyMap(r['utxoEntry']);
      return e['isCoinbase'] == false &&
          e['covenantId'] == null &&
          spk(e) == publicScript;
    }).toList()
      ..sort((a, b) => trestlyInt(trestlyMap(b['utxoEntry'])['amount'])
          .compareTo(trestlyInt(trestlyMap(a['utxoEntry'])['amount'])));
    for (final c in candidates.take(side == 'buy' ? 6 : 5)) {
      funding.add(await proof(
          trestlyMap(c['outpoint']), address, publicScript, null,
          rows: own));
    }
    TrestlyRow? payer;
    if (side == 'sell') {
      final balance = await sellBalance(poolState: trestlyMap(p['state']));
      for (final cell in balance.cells) {
        if (BigInt.parse(trestlyMap(cell['state'])['amount'].toString()) >=
            BigInt.from(input)) {
          payer = cell;
          break;
        }
      }
      if (payer == null)
        throw StateError(
            'No verified single kUSDT cell covers this amount. Refresh, use a smaller amount, or consolidate your kUSDT first. Unavailable cells are not treated as zero.');
    }
    final clock = trestlyMap(await get('$node/info/blockdag'));
    final rate =
        (await KaspaApi(client: client, baseUrl: node).loadFeeRate()).ceil();
    if (rate < 100 || rate > 333)
      throw StateError(
          'Network fees are above this test build’s safety limit. Try again later.');
    final request = <String, Object?>{
      'sender': address,
      'side': side,
      'amountIn': input.toString(),
      'minOut': '1',
      'maxFeeSompi': (rate * 300000).toString(),
      'feerate': rate,
      'nowDaa': (trestlyInt(clock['virtualDaaScore']) - 10).toString(),
      'pool': {'utxo': pu, 'state': p['state']},
      'reserve': {'utxo': ru, 'state': description['reserveState']},
      'payer': payer,
      'funding': funding
    };
    var review = await security.prepareTrestly(request);
    // Exact-state swap: approve the exact quoted output, not an open-ended
    // slippage envelope. A newer state always requires a fresh user approval.
    request['minOut'] = review['amountOut'];
    review = await security.prepareTrestly(request);
    return {
      'request': request,
      'review': review,
      'createdAt': DateTime.now().millisecondsSinceEpoch
    };
  }

  Future<TrestlyRow> execute(TrestlyRow quote) async {
    guard();
    if (!_active.add(address))
      throw StateError('A swap is already being processed.');
    try {
      if (await pending() != null)
        throw StateError('Check the saved swap first.');
      if (DateTime.now().millisecondsSinceEpoch -
              trestlyInt(quote['createdAt']) >
          90000) throw StateError('Quote expired. Refresh before confirming.');
      final req = trestlyMap(quote['request']),
          review = trestlyMap(quote['review']);
      // Recheck all selected coins immediately before financial authorization.
      final pool = trestlyMap(req['pool']),
          reserve = trestlyMap(req['reserve']);
      final d = await security.describeTrestly({'poolState': pool['state']});
      await proof(trestlyMap(pool['utxo']), d['poolAddress'].toString(),
          d['poolScript'].toString(), poolId);
      await proof(trestlyMap(reserve['utxo']), d['reserveAddress'].toString(),
          d['reserveScript'].toString(), tokenId);
      final fundingScript = '000020${kaspaOwnerIdFromAddress(address)}ac';
      for (final coin in (req['funding'] as List).map(trestlyMap)) {
        await proof(coin, address, fundingScript, null);
      }
      if (req['payer'] != null) {
        final payer = trestlyMap(req['payer']);
        final p = await security.describeTrestly(
            {'poolState': pool['state'], 'payerState': payer['state']});
        await proof(trestlyMap(payer['utxo']), p['payerAddress'].toString(),
            p['payerScript'].toString(), tokenId);
      }
      guard();
      if (!await security.hasNativeWalletFor(address))
        throw StateError('This wallet cannot sign.');
      final signed =
          await security.signTrestly(req, review['reviewHash'].toString());
      final saved = <String, Object?>{
        ...signed,
        'request': req,
        'createdAt': DateTime.now().millisecondsSinceEpoch
      };
      await store.write(key, jsonEncode(saved));
      if (await store.read(key) != jsonEncode(saved))
        throw StateError('Could not save the signed swap. Nothing submitted.');
      return await _submit(saved);
    } finally {
      _active.remove(address);
    }
  }

  Future<TrestlyRow> resume() async {
    guard();
    if (!_active.add(address)) throw StateError('Swap is busy.');
    try {
      final p = await pending();
      if (p == null) throw StateError('No saved swap.');
      return await _submit(p);
    } finally {
      _active.remove(address);
    }
  }

  Future<TrestlyRow> _submit(TrestlyRow saved) async {
    guard();
    final id = saved['transactionId'].toString();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
        saved['wrpcJson'] is! String ||
        (saved['wrpcJson'] as String).length > 512 * 1024) {
      throw StateError(
          'Invalid saved native swap. Nothing was sent or erased.');
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
        saved['wrpcJson'] is! String) {
      throw StateError('Invalid saved swap. No transaction was sent.');
    }
    final before = await _status(id);
    if (before == 'unknown') {
      throw StateError(
          'Swap status is temporarily unavailable. The signed swap remains saved; nothing was resent.');
    }
    if (before == 'not_seen') {
      guard();
      // Never use the legacy SDK/Safe-JSON covenant relay here. Preserve the
      // original wRPC JSON, u64s, compute budgets and every covenant binding.
      final response = await client
          .post(Uri.parse('$relay/submit'),
              headers: const {'content-type': 'application/json'},
              body: jsonEncode(
                  {'transactionId': id, 'transactionJson': saved['wrpcJson']}))
          .timeout(const Duration(seconds: 30));
      guard();
      final result = _relayResponse(response, id);
      if (result['status'] != 'submitted') {
        throw StateError(
            'Unrecognized submission result. Keep the saved swap and check its status.');
      }
    }
    var confirmed = before == 'confirmed';
    for (var i = 0; !confirmed && i < 10; i++) {
      confirmed = await _status(id) == 'confirmed';
      if (!confirmed) await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (!confirmed) {
      throw StateError(
          'Swap is not yet confirmed. The same signed transaction remains saved; no new trade was created.');
    }
    await store.write(
        '$key.last', jsonEncode({...saved, 'status': 'confirmed'}));
    await store.delete(key);
    return {...saved, 'status': 'confirmed'};
  }

  TrestlyRow _relayResponse(http.Response response, String id) {
    if (response.bodyBytes.length > 16384)
      throw StateError(
          'Native swap response is too large. The signed swap remains saved.');
    TrestlyRow result;
    try {
      result = trestlyMap(jsonDecode(response.body));
    } catch (_) {
      throw StateError(
          'Native swap response is unavailable. The signed swap remains saved.');
    }
    if (response.statusCode != 200) {
      final text = result['error'] is String
          ? result['error'] as String
          : 'Kaspire node is temporarily unavailable.';
      final message = text.substring(0, text.length > 800 ? 800 : text.length);
      throw StateError('$message The signed swap remains saved.');
    }
    if (result['transactionId'] != id)
      throw StateError(
          'Native swap transaction identity differs. The signed swap remains saved.');
    return result;
  }

  Future<String> _status(String id) async {
    guard();
    final response = await client.get(Uri.parse('$relay/transactions/$id'),
        headers: const {
          'cache-control': 'no-store'
        }).timeout(const Duration(seconds: 20));
    guard();
    final status = _relayResponse(response, id)['status'];
    if (!['confirmed', 'mempool', 'not_seen', 'unknown'].contains(status)) {
      throw StateError(
          'Native swap status is unavailable. The signed swap remains saved.');
    }
    return status as String;
  }
}

int parseTrestlyAmount(String raw, int decimals) {
  final s = raw.trim().replaceAll(',', '.');
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(s))
    throw const FormatException('Use a positive decimal amount.');
  final p = s.split('.'), fraction = p.length == 2 ? p[1] : '';
  if (fraction.length > decimals)
    throw FormatException('Use at most $decimals decimal places.');
  final n = BigInt.parse(p[0] + fraction.padRight(decimals, '0'));
  if (n > BigInt.from(1000000000000000))
    throw const FormatException('Amount too large.');
  return n.toInt();
}
