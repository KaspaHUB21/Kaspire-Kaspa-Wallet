import 'dart:convert';
import 'dart:io' show HttpDate;
import 'package:flutter/services.dart' show PlatformException;
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
      {NativeSecurity? security,
      http.Client? client,
      KaspaApi? api,
      DateTime Function()? clock,
      Future<void> Function(Duration)? sleep})
      : security = security ?? NativeSecurity(),
        client = client ?? http.Client(),
        api = api ?? KaspaApi(),
        _clock = clock ?? DateTime.now,
        _sleep = sleep ?? ((duration) => Future<void>.delayed(duration));
  final String owner;
  final NativeSecurity security;
  final http.Client client;
  final KaspaApi api;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _sleep;
  Future<void> _readQueue = Future<void>.value();
  DateTime? _nextRead, _cooldown;
  Future<void>? _pendingRun;
  void Function(String?)? onPaymentProgress;
  static const _readInterval = Duration(milliseconds: 100);
  static const _rateLimited =
      'Account data is temporarily rate-limited. Please wait a moment and refresh. Saved addresses and signed payments remain preserved.';
  static const node = 'https://kaspire.kaslab.space/api/local-node';
  static const history = 'https://kaspire.kaslab.space/api';
  static const descriptor = 'kip22-p2sh-v1';
  bool _closed = false;
  void close() {
    _closed = true;
    onPaymentProgress = null;
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

  // Queue request STARTS, not entire responses. At most ten reads/second,
  // shared by discovery, UTXO rechecks and activity, including retry cooldowns.
  Future<void> _readSlot() {
    final slot = _readQueue.then((_) async {
      await guard();
      while (true) {
        final now = _clock();
        var ready = _nextRead ?? now;
        if (_cooldown != null && _cooldown!.isAfter(ready)) ready = _cooldown!;
        final wait = ready.difference(now);
        if (wait <= Duration.zero) break;
        if (wait > const Duration(seconds: 30)) throw StateError(_rateLimited);
        await _sleep(wait);
        await guard();
      }
      _nextRead = _clock().add(_readInterval);
    });
    _readQueue = slot.then<void>((_) {}, onError: (Object _) {});
    return slot;
  }

  Duration _retryDelay(http.Response response, int attempt) {
    final header = response.headers['retry-after'];
    final seconds = int.tryParse(header ?? '');
    if (seconds != null && seconds >= 0) return Duration(seconds: seconds);
    if (header != null) {
      try {
        final wait = HttpDate.parse(header).difference(_clock());
        if (wait > Duration.zero) return wait;
      } catch (_) {}
    }
    return Duration(seconds: 1 << attempt);
  }

  Future<Object?> get(String url) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      await _readSlot();
      final response =
          await client.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
      await guard();
      if (response.statusCode == 429) {
        final delay = _retryDelay(response, attempt);
        final until = _clock().add(delay);
        if (_cooldown == null || until.isAfter(_cooldown!)) _cooldown = until;
        if (attempt == 2 || delay > const Duration(seconds: 30)) {
          throw StateError(_rateLimited);
        }
        continue; // Only retry a GET, never sign or recreate a payment.
      }
      if (response.statusCode != 200 ||
          response.bodyBytes.length > 4 * 1024 * 1024) {
        throw StateError(
            'Account lookup unavailable (${response.statusCode}). Previously saved addresses and transactions are preserved.');
      }
      return jsonDecode(response.body);
    }
    throw StateError(_rateLimited);
  }

  Future<Map<String, Object?>> scan({void Function(int)? progress}) async {
    await guard();
    final state = await security.hiddenKasState();
    if (state['descriptor'] != descriptor) {
      throw StateError(
          'This is not a KIP-22 account. Addresses from the retired P2SH experiment must not be used here.');
    }
    final addresses = <Map<String, Object?>>[],
        used = <Map<String, Object?>>[],
        utxos = <Map<String, Object?>>[];
    // Retirement is monotonic native metadata. A known used/retired address
    // cannot become unused again; its UTXOs are nevertheless ALWAYS re-read.
    final retired = (state['exposed'] as List).map((e) => '$e').toSet();
    var checked = 0;
    for (var branch = 0; branch < 2; branch++) {
      final issued =
          hiddenInt(state[branch == 0 ? 'receiveCount' : 'changeCount']);
      var start = 0, lastUsed = -1;
      while (true) {
        final target = issued > lastUsed + 21 ? issued : lastUsed + 21;
        if (start >= target) break;
        if (target > 10000) {
          throw StateError(
              'Discovery reached the experimental scan limit. Keep the encrypted backup; no address will be reused.');
        }
        await guard();
        // Cover exactly the issued range and 20-address discovery gap. One
        // used address at index 0 needs 21 lookups, not a second block of 20.
        final remaining = target - start;
        final batch = await security.deriveHiddenKas(
            branch, start, remaining > 20 ? 20 : remaining);
        for (var offset = 0; offset < batch.length; offset += 5) {
          final group = batch.skip(offset).take(5).toList();
          final responses = await Future.wait(group.map((a) async {
            final encoded = Uri.encodeComponent(a['address'].toString());
            final both = await Future.wait([
              get('$node/addresses/$encoded/utxos'),
              retired.contains('${a['branch']}:${a['index']}')
                  ? Future<Object?>.value(const [true])
                  : get(
                      '$history/addresses/$encoded/full-transactions?limit=1&offset=0&resolve_previous_outpoints=light'),
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

  Future<Map<String, Object?>> prepare(String recipient, int amount,
      {bool sendAll = false}) async {
    if (recipient.trim().isEmpty) {
      throw StateError(
          'Enter a Kaspa Mainnet recipient address before reviewing the payment.');
    }
    final snapshot =
        await scan(); // Fresh complete account snapshot, not cached balances.
    await guard();
    if (hiddenMap(snapshot['state'])['pending'] != null) {
      throw StateError('Resume the saved payment first.');
    }
    final rows = (snapshot['utxos'] as List).map(hiddenMap).toList();
    if (rows.isEmpty) {
      throw StateError('No spendable KAS is available in this P2SH account.');
    }
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
      if (sendAll) 'sendAll': true,
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

  Future<void> resume() {
    final running = _pendingRun;
    if (running != null) return running;
    final run = _resumeSaved();
    _pendingRun = run;
    run.then<void>((_) {
      _pendingRun = null;
    }, onError: (Object _, StackTrace __) {
      _pendingRun = null;
    });
    return run;
  }

  Future<bool> _confirmed(String id) async {
    await guard();
    try {
      await security.confirmHiddenKas(id);
      await guard();
      return true;
    } on PlatformException catch (error) {
      // Only the native node-lookup pending result is transient. A changed
      // wallet/journal or storage/security error must stop this operation.
      if (error.code != 'CONFIRMATION_PENDING') rethrow;
      await guard();
      return false;
    }
  }

  Future<void> _resumeSaved() async {
    try {
      await _submitAndConfirm();
    } finally {
      onPaymentProgress?.call(null);
    }
  }

  Future<void> _submitAndConfirm() async {
    await guard();
    final state = await security.hiddenKasState();
    final pending = state['pending'];
    if (pending == null) return;
    final saved = hiddenMap(pending), id = saved['transactionId'].toString();
    onPaymentProgress?.call('Checking the saved payment…');
    if (await _confirmed(id)) return;
    onPaymentProgress?.call('Submitting the signed payment…');
    // One POST of the exact journaled bytes. Even a transport failure or an
    // "already known" response can mean that the transaction reached the node.
    // Never construct/re-sign another payment; only poll native acceptance.
    try {
      await client
          .post(Uri.parse('$history/transactions'),
              headers: const {'content-type': 'application/json'},
              body: saved['submitJson'].toString())
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      await guard();
    }
    onPaymentProgress?.call('Waiting for confirmation from the Kaspire node…');
    final deadline = _clock().add(const Duration(seconds: 30));
    while (_clock().isBefore(deadline)) {
      if (await _confirmed(id)) return;
      final remaining = deadline.difference(_clock());
      if (remaining <= Duration.zero) break;
      await _sleep(remaining < const Duration(seconds: 2)
          ? remaining
          : const Duration(seconds: 2));
      await guard();
    }
    throw StateError(
        'The Kaspire node has not confirmed this payment yet. It may already be on the network. The same signed transaction remains safely saved. Check its status later; do not create another payment.');
  }

  Future<List<WalletTransaction>> activity(
      Map<String, Object?> snapshot) async {
    await guard();
    final state = hiddenMap(snapshot['state']);
    final addresses = (snapshot['addresses'] as List)
        .map(hiddenMap)
        .where((a) =>
            hiddenInt(a['index']) <
            hiddenInt(state[a['branch'] == 0 ? 'receiveCount' : 'changeCount']))
        .map((a) => a['address'].toString())
        .toSet();
    if (addresses.isEmpty) return [];
    final merged = <String, Map<String, Object?>>{};
    final all = addresses.toList();
    for (var offset = 0; offset < all.length; offset += 5) {
      final responses = await Future.wait(all.skip(offset).take(5).map((a) => get(
          '$history/addresses/${Uri.encodeComponent(a)}/full-transactions?limit=20&offset=0&resolve_previous_outpoints=light')));
      for (final response in responses) {
        if (response is! List) {
          throw StateError('Incomplete account activity response.');
        }
        for (final raw in response) {
          final row = hiddenMap(raw);
          final id = (row['transaction_id'] ?? row['id'] ?? '').toString();
          if (id.isNotEmpty) merged[id] = row;
        }
      }
    }
    final result = KaspaApi.parseTransactionsForAddresses(
        merged.values.toList(), addresses)
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return result.take(20).toList();
  }
}
