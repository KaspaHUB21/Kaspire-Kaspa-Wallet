import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/wallet_snapshot.dart';
import 'native_security.dart';
import 'network_settings.dart';
import 'kaspa_api.dart';

Map<String, Object?> hiddenMap(Object? value) =>
    (value as Map).cast<String, Object?>();
int hiddenInt(Object? value) => int.parse('$value');

/// Separate experimental KAS account. Node UTXOs are the spending source;
/// historical discovery is read-only. Never substitutes an error with zero.
class HiddenKasService {
  HiddenKasService(this.owner,
      {NativeSecurity? security, http.Client? client, KaspaApi? api})
      : security = security ?? NativeSecurity(),
        client = client ?? http.Client(),
        api = api ?? KaspaApi();
  final String owner;
  final NativeSecurity security;
  final http.Client client;
  final KaspaApi api;
  static const node = 'https://kaspire.kaslab.space/api/local-node';
  static const history = 'https://kaspire.kaslab.space/api';
  static const descriptor = 'kaspire-hidden-kas-v1';
  bool _closed = false;
  void close() {
    _closed = true;
    client.close();
  }

  Future<void> guard() async {
    if (_closed ||
        NetworkSettings.network.value != KaspaNetwork.mainnet ||
        NetworkSettings.storageAddress(
                (await security.getNativeAddress()) ?? '') !=
            NetworkSettings.storageAddress(owner)) {
      throw StateError(
          'Wallet or network changed. Reopen the hidden KAS account; no new payment was submitted.');
    }
  }

  Future<bool> supportsHdWallet() async {
    await guard();
    final wallets = await security.listWallets();
    for (final wallet in wallets) {
      if (wallet.active) return wallet.kind != 'private-key';
    }
    throw StateError(
        'No active signing wallet. Create or restore a seed-based HD wallet to use P2SH.');
  }

  Future<Object?> get(String url) async {
    final response =
        await client.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200 ||
        response.bodyBytes.length > 4 * 1024 * 1024) {
      throw StateError(
          'Account lookup unavailable (${response.statusCode}). Previously saved addresses and transactions are preserved.');
    }
    return jsonDecode(response.body);
  }

  Future<Map<String, Object?>> scan({void Function(int)? progress}) async {
    await guard();
    final state = await security.hiddenKasState();
    final addresses = <Map<String, Object?>>[],
        used = <Map<String, Object?>>[],
        utxos = <Map<String, Object?>>[];
    var checked = 0;
    for (var branch = 0; branch < 2; branch++) {
      final issued =
          hiddenInt(state[branch == 0 ? 'receiveCount' : 'changeCount']);
      var start = 0, lastUsed = -1;
      while (true) {
        if (start + 20 > 10000) {
          throw StateError(
              'Discovery reached the experimental scan limit. Keep the encrypted backup; no address will be reused.');
        }
        await guard();
        final batch = await security.deriveHiddenKas(branch, start, 20);
        for (var offset = 0; offset < batch.length; offset += 5) {
          final group = batch.skip(offset).take(5).toList();
          final responses = await Future.wait(group.map((a) async {
            final encoded = Uri.encodeComponent(a['address'].toString());
            final both = await Future.wait([
              get('$node/addresses/$encoded/utxos'),
              get('$history/addresses/$encoded/full-transactions?limit=1&offset=0&resolve_previous_outpoints=light'),
            ]);
            if (both[0] is! List || both[1] is! List) {
              throw StateError(
                  'Incomplete account discovery response; receiving and signing remain disabled.');
            }
            return both;
          }));
          for (var i = 0; i < group.length; i++) {
            final a = group[i];
            final rows = (responses[i][0] as List).map(hiddenMap).toList();
            KaspaApi.validateUtxos(rows, a['address'].toString());
            if (rows.isNotEmpty || (responses[i][1] as List).isNotEmpty) {
              used.add(a);
              lastUsed = hiddenInt(a['index']);
            }
            addresses.add(a);
            utxos.addAll(rows);
          }
          checked += group.length;
          progress?.call(checked);
        }
        start += batch.length;
        if (start >= issued && start > lastUsed + 20) break;
      }
    }
    await guard();
    final updated = await security.observeHiddenKas(used);
    return {
      'state': updated,
      'addresses': addresses,
      'utxos': utxos,
      'balanceSompi': utxos.fold<int>(0,
          (sum, row) => sum + hiddenInt(hiddenMap(row['utxoEntry'])['amount']))
    };
  }

  Future<Map<String, Object?>> receive(Map<String, Object?> snapshot) async {
    await guard();
    final state = hiddenMap(snapshot['state']);
    if (state['pending'] != null) {
      throw StateError('Finish the saved transaction before receiving again.');
    }
    final retired = (state['exposed'] as List).map((e) => '$e').toSet();
    final issued = hiddenInt(state['receiveCount']);
    final available = (snapshot['addresses'] as List)
        .map(hiddenMap)
        .where((a) =>
            a['branch'] == 0 &&
            hiddenInt(a['index']) < issued &&
            !retired.contains('0:${a['index']}'))
        .toList();
    return available.isEmpty ? security.issueHiddenKas(0) : available.last;
  }

  Future<Map<String, Object?>> prepare(String recipient, int amount) async {
    final snapshot =
        await scan(); // Fresh complete account snapshot, not cached balances.
    await guard();
    if (hiddenMap(snapshot['state'])['pending'] != null) {
      throw StateError('Resume the saved payment first.');
    }
    final rows = (snapshot['utxos'] as List).map(hiddenMap).toList();
    final usedAddresses = rows.map((e) => e['address']).toSet();
    final signers = (snapshot['addresses'] as List)
        .map(hiddenMap)
        .where((a) => usedAddresses.contains(a['address']))
        .toList();
    final change = await security.issueHiddenKas(1);
    final fee = await api.loadFeeRate();
    if (fee > 1000) {
      throw StateError(
          'Network fee exceeds the experimental safety limit. Try again later.');
    }
    await guard();
    final request = <String, Object?>{
      'descriptor': descriptor,
      'recipient': recipient.trim(),
      'amountSompi': amount,
      'feeRate': fee,
      'signers': signers,
      'change': change,
      'utxosJson': jsonEncode(rows)
    };
    final review = await security.prepareHiddenKas(request);
    return {'request': request, 'review': review};
  }

  Future<void> signAndSubmit(Map<String, Object?> prepared) async {
    await guard();
    final request = hiddenMap(prepared['request']);
    final live = <Map<String, Object?>>[];
    for (final a in (request['signers'] as List).map(hiddenMap)) {
      live.addAll((await get(
                  '$node/addresses/${Uri.encodeComponent(a['address'].toString())}/utxos')
              as List)
          .map(hiddenMap));
    }
    String points(List<Map<String, Object?>> rows) {
      final result = rows.map((e) => jsonEncode(e)).toList()..sort();
      return result.join('\n');
    }

    if (points(live) !=
        points((jsonDecode(request['utxosJson'].toString()) as List)
            .map(hiddenMap)
            .toList())) {
      throw StateError(
          'Wallet outputs changed during review. Refresh and review again; nothing was signed.');
    }
    await guard();
    await security.signHiddenKas(
        request, hiddenMap(prepared['review'])['reviewHash'].toString());
    await resume();
  }

  Future<void> resume() async {
    await guard();
    final state = await security.hiddenKasState();
    final pending = state['pending'];
    if (pending == null) return;
    final saved = hiddenMap(pending), id = saved['transactionId'].toString();
    // Replays exactly native-journaled bytes, never creates another payment.
    try {
      await security.confirmHiddenKas(id);
      return;
    } catch (_) {
      await guard();
    }
    final response = await client
        .post(Uri.parse('$history/transactions'),
            headers: const {'content-type': 'application/json'},
            body: saved['submitJson'].toString())
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw StateError(
          'Node did not accept the payment (${response.statusCode}). Signed bytes remain saved; do not create another payment.');
    }
    await guard();
    await security.confirmHiddenKas(id);
  }

  Future<List<WalletTransaction>> activity(
      Map<String, Object?> snapshot) async {
    final state = hiddenMap(snapshot['state']);
    final addresses = (snapshot['addresses'] as List)
        .map(hiddenMap)
        .where((a) =>
            hiddenInt(a['index']) <
            hiddenInt(state[a['branch'] == 0 ? 'receiveCount' : 'changeCount']))
        .map((a) => a['address'].toString());
    if (addresses.isEmpty) return [];
    return api.loadNativeTransactionsForAddresses(addresses);
  }
}
