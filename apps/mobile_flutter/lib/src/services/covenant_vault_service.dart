import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'native_security.dart';
import 'network_settings.dart';
import 'kaspa_api.dart';

Map<String, Object?> vaultMap(Object? v) => (v as Map).cast<String, Object?>();
int vaultInt(Object? v) => int.tryParse('$v') ?? 0;

/// Internal test only. All spendability and final broadcast checks use our node.
/// Missing rows/errors are never evidence that a saved vault can be deleted.
class CovenantVaultService {
  CovenantVaultService(
      {http.Client? client, NativeSecurity? security, KaspaApi? api})
      : client = client ?? http.Client(),
        security = security ?? NativeSecurity(),
        api = api ?? KaspaApi();
  static const node = 'https://kaspire.kaslab.space/api/local-node';
  static const protocol = 'kaspire-covenant-vault-v1';
  final http.Client client;
  final NativeSecurity security;
  final KaspaApi api;
  bool _closed = false;
  void close() {
    _closed = true;
    client.close();
  }

  void guard() {
    if (_closed) {
      throw StateError(
          'Vault screen closed. Reopen and review the action again.');
    }
    if (NetworkSettings.network.value != KaspaNetwork.mainnet) {
      throw StateError(
          'Covenant vault tests require Kaspa Mainnet. Switch back before continuing.');
    }
  }

  Future<Object?> get(String path, {bool allowMissing = false}) async {
    final response = await client
        .get(Uri.parse('$node$path'))
        .timeout(const Duration(seconds: 20));
    if (allowMissing && response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw StateError(
          'The Kaspire node is unavailable (${response.statusCode}). Saved vaults remain safe.');
    }
    if (response.bodyBytes.length > 8 * 1024 * 1024) {
      throw StateError('Node response too large.');
    }
    return jsonDecode(response.body);
  }

  Future<int> daa() async {
    guard();
    final data = vaultMap(await get('/info/blockdag'));
    if (data['networkName'] != 'kaspa-mainnet' ||
        vaultInt(data['virtualDaaScore']) <= 0) {
      throw StateError(
          'The local node did not report a valid Mainnet DAA score.');
    }
    return vaultInt(data['virtualDaaScore']);
  }

  Future<List<Map<String, Object?>>> saved() => security.loadCovenantVaults();
  Future<void> put(Map<String, Object?> item) async {
    final record = vaultMap(item['record']);
    await security.validateVaultRecord(record);
    final list = await saved();
    final index = list.indexWhere(
        (e) => vaultMap(e['record'])['covenantId'] == record['covenantId']);
    if (index < 0) {
      list.add(item);
    } else {
      list[index] = item;
    }
    await security.saveCovenantVaults(list);
  }

  Future<void> importRecord(Map<String, Object?> record) async {
    final validated = await security.validateVaultRecord(record);
    final list = await saved();
    // An old recovery file never overwrites a newer signed transaction journal.
    if (!list.any((e) =>
        vaultMap(e['record'])['covenantId'] == validated['covenantId'])) {
      await put({'record': validated});
    }
  }

  Map<String, Object?> terms(
          {required String owner,
          required String kind,
          required String name,
          required int limitDaa,
          String beneficiary = ''}) =>
      {
        'kind': kind,
        'owner': owner,
        'beneficiary': beneficiary,
        'name': name.trim(),
        'limitDaa': limitDaa,
        'instance': List.generate(
            32,
            (_) => Random.secure()
                .nextInt(256)
                .toRadixString(16)
                .padLeft(2, '0')).join(),
      };

  Future<Map<String, Object?>?> cell(Map<String, Object?> record) async {
    guard();
    await security.validateVaultRecord(record);
    final rows = await get(
            '/addresses/${Uri.encodeComponent(record['vaultAddress'].toString())}/utxos')
        as List;
    final matches = <Map<String, Object?>>[];
    for (final row in rows.whereType<Map>()) {
      final point = vaultMap(row['outpoint']),
          entry = vaultMap(row['utxoEntry']);
      final spk = vaultMap(entry['scriptPublicKey']);
      if (spk['scriptPublicKey'] != record['scriptPublicKey'] ||
          entry['isCoinbase'] != false ||
          vaultInt(entry['amount']) != vaultInt(record['amountSompi']) ||
          vaultInt(entry['blockDaaScore']) <= 0) {
        continue;
      }
      final id = point['transactionId'].toString();
      final tx = vaultMap(await get('/transactions/$id'));
      if (tx['is_accepted'] != true || tx['transaction_id'] != id) continue;
      final outputs = (tx['outputs'] as List? ?? []).whereType<Map>();
      if (!outputs.any((o) =>
          vaultInt(o['index']) == vaultInt(point['index']) &&
          o['covenant_id'] == record['covenantId'] &&
          o['script_public_key'] == record['scriptPublicKey'] &&
          vaultInt(o['amount']) == vaultInt(record['amountSompi']))) {
        continue;
      }
      matches.add({
        'covenantId': record['covenantId'],
        'transactionId': id,
        'index': vaultInt(point['index']),
        'valueSompi': vaultInt(entry['amount']),
        'blockDaaScore': vaultInt(entry['blockDaaScore']),
        'scriptPublicKey': record['scriptPublicKey']
      });
    }
    if (matches.length > 1) {
      throw StateError(
          'Ambiguous vault outputs. No transaction will be signed.');
    }
    return matches.isEmpty ? null : matches.single;
  }

  Future<Map<String, Object?>> prepare(
      String sender, Map<String, Object?> terms, int amount, String action,
      {Map<String, Object?>? record}) async {
    guard();
    final current = await daa();
    final live = record == null ? null : await cell(record);
    if (action != 'create' && live == null) {
      throw StateError(
          'No confirmed spendable vault output was found. It may still be pending. Refresh before trying again.');
    }
    final funding = action == 'create' || action == 'heartbeat'
        ? await get('/addresses/${Uri.encodeComponent(sender)}/utxos') as List
        : const [];
    final request = <String, Object?>{
      'action': action,
      'sender': sender,
      'terms': terms,
      'amountSompi': amount,
      'currentDaa': current,
      'feeRate': 100.0,
      'fundingUtxosJson': jsonEncode(funding),
      'cell': live
    };
    final review = await security.prepareCovenantVault(request);
    return {'request': request, 'review': review};
  }

  Future<String> commit(Map<String, Object?> prepared,
      {Map<String, Object?>? previous}) async {
    guard();
    final request = vaultMap(prepared['request']),
        review = vaultMap(prepared['review']);
    // Validate current outpoints again AFTER password export / user review.
    await verifyInputs(request);
    final signed = await security.signCovenantVault(
        request, review['reviewHash'].toString());
    guard();
    final record = Map<String, Object?>.from(vaultMap(signed['record']));
    record['genesisTransactionId'] = previous?['genesisTransactionId'] ??
        previous?['transactionId'] ??
        signed['transactionId'];
    if (request['cell'] != null) record['lastConfirmedCell'] = request['cell'];
    // Spending terminates the covenant; keep its last real cell, not a P2PK payout.
    if (request['action'] == 'release' || request['action'] == 'claim') {
      record['transactionId'] = previous!['transactionId'];
    }
    final item = <String, Object?>{
      'record': record,
      'pending': {
        'transactionId': signed['transactionId'],
        'wrpcJson': signed['wrpcJson'],
        'submitJson': signed['submitJson'],
        'action': request['action'],
      }
    };
    // Mandatory durable write before ANY network submit. No secrets in this data.
    await put(item);
    return resume(item);
  }

  Future<void> verifyInputs(Map<String, Object?> request) async {
    guard();
    final currentDaa = await daa();
    if (request['action'] == 'create' &&
        vaultMap(request['terms'])['kind'] == 'timeLock' &&
        vaultInt(vaultMap(request['terms'])['limitDaa']) <= currentDaa) {
      throw StateError(
          'The prepared unlock DAA has already passed. Choose a future DAA score and prepare again. Nothing was broadcast.');
    }
    final funding = jsonDecode(request['fundingUtxosJson'].toString()) as List;
    if (funding.isNotEmpty) {
      final current = await get(
              '/addresses/${Uri.encodeComponent(request['sender'].toString())}/utxos')
          as List;
      for (final row in funding) {
        if (!current.any((e) =>
            jsonEncode(e['outpoint']) == jsonEncode(row['outpoint']) &&
            jsonEncode(e['utxoEntry']) == jsonEncode(row['utxoEntry']))) {
          throw StateError(
              'Wallet outputs changed during review. Refresh and prepare again. Nothing was broadcast.');
        }
      }
    }
    if (request['cell'] != null) {
      final expected = vaultMap(request['cell']);
      final descriptor =
          vaultMap((await security.prepareCovenantVault(request))['record']);
      final current = await cell(descriptor);
      if (current == null || jsonEncode(current) != jsonEncode(expected)) {
        throw StateError(
            'The vault output changed during review. Refresh and review again.');
      }
    }
  }

  Future<String> resume(Map<String, Object?> item) async {
    guard();
    // A stale detail view must never resubmit an already confirmed transaction
    // or replace a newer transaction journal for the same covenant.
    final cid = vaultMap(item['record'])['covenantId'];
    final current = (await saved()).firstWhere(
        (e) => vaultMap(e['record'])['covenantId'] == cid,
        orElse: () =>
            throw StateError('The saved vault record was not found.'));
    final expected = vaultMap(item['pending'])['transactionId'].toString();
    if (current['pending'] == null) return expected;
    final pending = Map<String, Object?>.from(vaultMap(current['pending']));
    if (pending['transactionId'] != expected) {
      throw StateError('The saved vault transaction changed. Refresh first.');
    }
    final reconciled = await refresh(current);
    if (reconciled['pending'] == null) return expected;
    guard();
    // Same signed bytes and transaction ID only; never creates a duplicate deposit.
    final id = await api.broadcastKcc20(pending['wrpcJson'].toString(),
        expectedTransactionId: pending['transactionId'].toString());
    final record = Map<String, Object?>.from(vaultMap(current['record']));
    record['status'] =
        pending['action'] == 'release' || pending['action'] == 'claim'
            ? 'opening'
            : 'pending';
    pending['submitted'] = true;
    final submitted = <String, Object?>{'record': record, 'pending': pending};
    await put(submitted);
    // Broadcast acknowledgement is not consensus confirmation. Keep the bytes
    // until our node proves acceptance, but remove them immediately once it does.
    try {
      await refresh(submitted);
    } catch (_) {
      /* Broadcast succeeded; retain the durable confirmation journal. */
    }
    return id;
  }

  Future<Map<String, Object?>> refresh(Map<String, Object?> item) async {
    final record = Map<String, Object?>.from(vaultMap(item['record']));
    final live = await cell(record);
    final pending = item['pending'] == null ? null : vaultMap(item['pending']);
    if (live != null &&
        (pending == null ||
            live['transactionId'] == pending['transactionId'])) {
      record['transactionId'] = live['transactionId'];
      record['lastConfirmedCell'] = live;
      record['status'] = 'locked';
      final updated = <String, Object?>{'record': record};
      await put(updated);
      return updated;
    }
    if (pending != null) {
      final raw = await get('/transactions/${pending['transactionId']}',
          allowMissing: true);
      final tx = raw == null ? <String, Object?>{} : vaultMap(raw);
      if (tx['transaction_id'] == pending['transactionId'] &&
          tx['is_accepted'] == true &&
          (pending['action'] == 'create' || pending['action'] == 'heartbeat') &&
          (tx['outputs'] as List? ?? []).whereType<Map>().any((o) =>
              vaultInt(o['index']) == vaultInt(record['index']) &&
              o['covenant_id'] == record['covenantId'] &&
              o['script_public_key'] == record['scriptPublicKey'] &&
              vaultInt(o['amount']) == vaultInt(record['amountSompi']))) {
        // The output can already be spent (e.g. on a second phone). Accepted
        // genesis/pulse proof still completes this submission, even without UTXOs.
        record['status'] = live != null ? 'locked' : 'pending';
        final updated = <String, Object?>{'record': record};
        await put(updated);
        return updated;
      }
      if (tx['transaction_id'] == pending['transactionId'] &&
          tx['is_accepted'] == true &&
          (pending['action'] == 'release' || pending['action'] == 'claim')) {
        record['status'] = 'opened';
        final updated = <String, Object?>{'record': record};
        await put(updated);
        return updated;
      }
    }
    if (live == null &&
        record['status'] != 'opened' &&
        await confirmedOpening(record)) {
      record['status'] = 'opened';
      final updated = <String, Object?>{'record': record};
      await put(updated);
      return updated;
    }
    // Empty UTXOs alone cannot establish a payout, especially after importing.
    return item;
  }

  Future<bool> confirmedOpening(Map<String, Object?> record) async {
    // Import / second phone: absence is not proof. Trace an accepted payout's
    // real previous output and covenant ID on our node before marking opened.
    final terms = vaultMap(record['terms']);
    final recipient =
        terms['kind'] == 'timeLock' ? terms['owner'] : terms['beneficiary'];
    for (var offset = 0; offset < 1000; offset += 100) {
      final rows = await get(
              '/addresses/${Uri.encodeComponent(record['vaultAddress'].toString())}/full-transactions?limit=100&offset=$offset&resolve_previous_outpoints=light')
          as List;
      for (final tx in rows.whereType<Map>()) {
        if (tx['is_accepted'] != true ||
            (tx['inputs'] as List? ?? []).length != 1 ||
            (tx['outputs'] as List? ?? []).length != 1) {
          continue;
        }
        final input = (tx['inputs'] as List).single as Map;
        final output = (tx['outputs'] as List).single as Map;
        if (output['script_public_key_address'] != recipient ||
            output['covenant_id'] != null ||
            vaultInt(output['amount']) <= 0 ||
            vaultInt(output['amount']) > vaultInt(record['amountSompi'])) {
          continue;
        }
        final parentId = input['previous_outpoint_hash']?.toString() ?? '';
        if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(parentId) ||
            vaultInt(input['previous_outpoint_index']) != 0) {
          continue;
        }
        final parent = vaultMap(await get('/transactions/$parentId'));
        if (parent['is_accepted'] == true &&
            parent['transaction_id'] == parentId &&
            (parent['outputs'] as List? ?? []).whereType<Map>().any((o) =>
                vaultInt(o['index']) == 0 &&
                o['covenant_id'] == record['covenantId'] &&
                o['script_public_key'] == record['scriptPublicKey'] &&
                vaultInt(o['amount']) == vaultInt(record['amountSompi']))) {
          return true;
        }
      }
      if (rows.length < 100) return false;
    }
    return false;
  }

  Future<int> discover(String address) async {
    guard();
    var count = 0;
    final known =
        (await saved()).map((e) => vaultMap(e['record'])['covenantId']).toSet();
    for (var offset = 0; offset < 10000; offset += 100) {
      final rows = await get(
              '/addresses/${Uri.encodeComponent(address)}/full-transactions?limit=100&offset=$offset&resolve_previous_outpoints=light')
          as List;
      for (final row in rows.whereType<Map>()) {
        if (row['is_accepted'] != true) continue;
        try {
          final hex = row['payload']?.toString() ?? '';
          if (hex.length > 32768 || hex.length.isOdd) continue;
          final bytes = [
            for (var i = 0; i < hex.length; i += 2)
              int.parse(hex.substring(i, i + 2), radix: 16)
          ];
          final payload = vaultMap(jsonDecode(utf8.decode(bytes)));
          if (payload['p'] != protocol || payload['action'] != 'create') {
            continue;
          }
          final terms = vaultMap(payload['terms']);
          if (terms['owner'] != address && terms['beneficiary'] != address) {
            continue;
          }
          final output = (row['outputs'] as List)
              .whereType<Map>()
              .firstWhere((o) => vaultInt(o['index']) == 0);
          final cid = output['covenant_id'];
          if (known.contains(cid)) continue;
          // Rebuild the descriptor independently of untrusted chain metadata.
          final script = output['script_public_key'].toString();
          final descriptor =
              await descriptorForDiscovered(terms, payload, row, script);
          await importRecord(descriptor);
          known.add(cid);
          count++;
        } on FormatException {/* Unrelated payload. */} on StateError {
          rethrow;
        } catch (_) {/* Not a locally valid vault genesis. */}
      }
      if (rows.length < 100) return count;
    }
    throw StateError(
        'Scanned the first 10,000 transactions. Import a recovery file for older vaults. Existing records were preserved.');
  }

  Future<Map<String, Object?>> descriptorForDiscovered(
      Map<String, Object?> terms,
      Map<String, Object?> payload,
      Map row,
      String script) async {
    // Native describe has no funding or time-maturity assumptions.
    final described = await security.describeCovenantVault(terms);
    final output = (row['outputs'] as List)
        .whereType<Map>()
        .firstWhere((o) => vaultInt(o['index']) == 0);
    if (described['scriptPublicKey'] != script ||
        described['vaultAddress'] != payload['vaultAddress'] ||
        vaultInt(output['amount']) != vaultInt(payload['amountSompi'])) {
      throw const FormatException('Invalid genesis');
    }
    return {
      ...described,
      'covenantId': output['covenant_id'],
      'transactionId': row['transaction_id'],
      'genesisTransactionId': row['transaction_id'],
      'index': 0,
      'amountSompi': vaultInt(output['amount']),
      'status': 'pending'
    };
  }
}
