/// A missing transaction or a missing UTXO never proves that a swap failed.
/// Only an independently accepted spender of an exact saved input is proof.
class SwapConflictUnknown extends StateError {
  SwapConflictUnknown()
      : super(
            'Unable to determine whether the saved swap is obsolete within the history lookup limit. Its signed transaction remains saved; no replacement was created.');
}

Future<String?> findConfirmedSwapConflict({
  required Map tx,
  required Set<String> savedIds,
  required String node,
  required String prefix,
  required Future<Object?> Function(String) read,
}) async {
  final inputs = (tx['inputs'] as List).whereType<Map>().toList();
  if (inputs.length > 64) throw SwapConflictUnknown();
  final groups = <String, Set<String>>{}, points = <String>{};
  final origins = <String, Object?>{};
  var incomplete = false, totalPages = 0;
  for (final input in inputs) {
    final point = input['previousOutpoint'] as Map? ?? input;
    final id = '${point['transactionId']}',
        index = int.tryParse('${point['index']}');
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
        index == null ||
        index < 0 ||
        index > 0xffffffff) {
      throw StateError(
          'Invalid saved swap input. The signed transaction remains saved.');
    }
    final key = '$id:$index';
    points.add(key);
    var address = (input['utxo'] as Map?)?['address'];
    if (address is! String || !address.startsWith(prefix)) {
      if (!origins.containsKey(id))
        origins[id] = await read('$node/transactions/$id');
      final origin = origins[id];
      if (origin is! Map ||
          origin['transaction_id'] != id ||
          origin['is_accepted'] != true) {
        incomplete = true;
        continue;
      }
      final outputs = (origin['outputs'] as List)
          .whereType<Map>()
          .where((o) => '${o['index']}' == '$index')
          .toList();
      address = outputs.length == 1
          ? outputs.single['script_public_key_address']
          : null;
    }
    if (address is! String || !address.startsWith(prefix)) {
      incomplete = true;
      continue;
    }
    groups.putIfAbsent(address, () => <String>{}).add(key);
  }
  bool spends(Map candidate) => (candidate['inputs'] as List? ?? const [])
      .whereType<Map>()
      .any((i) => points.contains(
          '${i['previous_outpoint_hash']}:${i['previous_outpoint_index']}'));
  final checked = <String>{};
  for (final address in groups.keys) {
    final pages = <String>{};
    var complete = false;
    for (var page = 0; page < 20; page++) {
      if (++totalPages > 100) {
        incomplete = true;
        break;
      }
      final rows = await read(
          '$node/addresses/${Uri.encodeComponent(address)}/full-transactions?limit=50&offset=${page * 50}');
      if (rows is! List || rows.length > 50)
        throw StateError(
            'Invalid swap history. The signed transaction remains saved.');
      final signature =
          rows.whereType<Map>().map((r) => r['transaction_id']).join(',');
      if (rows.isNotEmpty && !pages.add(signature)) {
        incomplete = true;
        break;
      }
      for (final row in rows.whereType<Map>()) {
        final id = row['transaction_id'];
        if (id is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
            savedIds.contains(id) ||
            !spends(row) ||
            !checked.add(id)) continue;
        final confirmed = await read('$node/transactions/$id');
        if (confirmed is Map &&
            confirmed['transaction_id'] == id &&
            confirmed['is_accepted'] == true &&
            spends(confirmed)) return id;
      }
      if (rows.length < 50) {
        complete = true;
        break;
      }
    }
    if (!complete) incomplete = true;
  }
  if (incomplete) throw SwapConflictUnknown();
  return null;
}
