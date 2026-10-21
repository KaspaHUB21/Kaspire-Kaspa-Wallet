import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../kaspa_address.dart';
import '../models/wallet_snapshot.dart';
import '../number_format.dart';
import 'kcc20_compound.dart';

// Shared by discovery and send preparations, including service instances created
// by KaspaApi getters. Only read requests are queued; signing is never retried.
class _KasvioReadQueue {
  Future<void> tail = Future<void>.value();
  DateTime next = DateTime.fromMillisecondsSinceEpoch(0);

  Future<http.Response> read(
      http.Client client, Uri uri, bool Function()? isCancelled) {
    final task = tail.then((_) async {
      for (var attempt = 0;; attempt++) {
        final wait = next.difference(DateTime.now());
        if (wait.isNegative == false) await Future<void>.delayed(wait);
        if (isCancelled?.call() == true) {
          throw StateError('KCC20 preparation cancelled.');
        }
        next = DateTime.now().add(const Duration(milliseconds: 300));
        final response =
            await client.get(uri).timeout(const Duration(seconds: 8));
        if (response.statusCode != 429 || attempt >= 2) return response;
        final retry = response.headers['retry-after'];
        final seconds = int.tryParse(retry ?? '');
        final date = DateTime.tryParse(retry ?? '');
        final retryMs = seconds != null
            ? seconds * 1000
            : date?.difference(DateTime.now()).inMilliseconds ?? 0;
        next = DateTime.now().add(Duration(
            milliseconds:
                math.max(1500 * (1 << attempt), retryMs).clamp(0, 30000)));
      }
    });
    tail = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return task;
  }
}

class StandardKcc20Wallet {
  const StandardKcc20Wallet(this.assets, this.transactions, this.warning);
  final List<WalletAsset> assets;
  final List<WalletTransaction> transactions;
  final String warning;
}

/// Read-only discovery. Indexer metadata never supplies executable programs.
/// Spending cells are checked on the own node and the native core rebuilds
/// every script/transfer using the same pinned KCC20 reference template.
class Kcc20StandardService {
  Kcc20StandardService(this.client,
      {this.base = 'https://kasvio.network/api/kcc20/v1',
      this.node = 'https://kaspire.kaslab.space/api/local-node'});
  final http.Client client;
  final String base, node;
  static const standard = 'kcc20';
  static bool isStandard(String? value) =>
      value == standard || value == 'kcc20-last-call';
  static const templateId = 'argent-kcc20-c8a0871';
  static const reference = 'c8a087117735a1f87c5c6d115fcddeaf2562c784';
  static const templateHash =
      '9703112ee6e3555107cd168858992b77d3b74f655205b2b463b1f9ec2ec73cf7';
  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');
  static final _queues = Expando<_KasvioReadQueue>();
  static Map<String, dynamic> map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : {};
  Future<Map<String, dynamic>> get(String url,
      {bool Function()? isCancelled}) async {
    final uri = Uri.parse(url);
    final r = url.startsWith('$base/')
        ? await (_queues[client] ??= _KasvioReadQueue())
            .read(client, uri, isCancelled)
        : await client.get(uri).timeout(const Duration(seconds: 8));
    if (isCancelled?.call() == true) {
      throw StateError('KCC20 preparation cancelled.');
    }
    if (r.statusCode != 200) {
      throw StateError('KCC20 data unavailable (${r.statusCode}).');
    }
    final value = map(jsonDecode(r.body));
    if (url.startsWith(base)) {
      final meta = map(value['meta']);
      if (meta['network'] != 'mainnet' ||
          meta['reference_commit'] != reference) {
        throw StateError('Kasvio KCC20 network or reference revision differs.');
      }
    }
    return value;
  }

  Future<List<Map<String, dynamic>>> directory() async {
    final tokens = <String, Map<String, dynamic>>{};
    String? cursor;
    for (var page = 0; page < 20; page++) {
      final value = await get('$base/tokens?${Uri(queryParameters: {
            'limit': '50',
            if (cursor != null) 'cursor': cursor
          }).query}');
      for (final item in (value['data'] as List? ?? []).whereType<Map>()) {
        final row = map(item), cid = rowId(item);
        if (_hex64.hasMatch(cid)) tokens[cid] = row;
      }
      final pagination = map(value['pagination']);
      final next = pagination['next_cursor']?.toString();
      if (pagination['has_more'] != true || next == null) {
        return tokens.values.toList();
      }
      if (next == cursor) throw StateError('KCC20 catalogue cursor repeated.');
      cursor = next;
    }
    throw StateError(
        'KCC20 catalogue discovery limit reached; balance discovery is incomplete.');
  }

  static String rowId(Map row) => row['covenant_id']?.toString() ?? '';
  Future<Map<String, dynamic>> balance(String cid, String owner,
      {bool Function()? isCancelled}) async {
    final result = await get('$base/tokens/$cid/balance?owner=$owner&scheme=00',
        isCancelled: isCancelled);
    final data = map(result['data']);
    if (data['covenant_id'] != cid ||
        data['owner_value'] != owner ||
        data['owner_scheme'] != 0 ||
        data['available'] != true) {
      throw StateError('KCC20 owner balance is unavailable or mismatched.');
    }
    return data;
  }

  Future<StandardKcc20Wallet> load(String address,
      {int historyLimit = 20,
      void Function(StandardKcc20Wallet)? onProgress}) async {
    final owner = kaspaOwnerIdFromAddress(address);
    if (!address.startsWith('kaspa:') || owner.isEmpty) {
      return const StandardKcc20Wallet([], [], '');
    }
    final status = await get('$base/status');
    if (map(status['data'])['status'] != 'ready') {
      throw StateError('Kasvio KCC20 indexer is not ready.');
    }
    final tokens = await directory();
    final assets = <WalletAsset>[], transactions = <WalletTransaction>[];
    var failures = 0;
    final details = <String, Future<Map<String, dynamic>>>{};
    Future<Map<String, dynamic>> detail(String cid, String txid) =>
        details.putIfAbsent('$cid/$txid', () async {
          final value =
              map((await get('$base/tokens/$cid/transactions/$txid'))['data']);
          if (value['txid'] != txid ||
              map(value['token'])['covenant_id'] != cid ||
              value['components_complete'] != true) {
            throw StateError('Incomplete KCC20 transaction details.');
          }
          return value;
        });
    for (var offset = 0; offset < tokens.length; offset += 6) {
      await Future.wait(tokens.skip(offset).take(6).map((token) async {
        final cid = rowId(token), metadata = map(token['metadata']);
        if (token['profile_id'] != 'KCC20PublicMint@c8a0871' ||
            token['recognition'] != 'hash_proven_reference_actor_family') {
          return;
        }
        final decimals = metadata['binding_verified'] == true
            ? int.tryParse(metadata['decimals'].toString())
            : 0;
        if (decimals == null || decimals < 0 || decimals > 18) {
          failures++;
          return;
        }
        final ticker = (metadata['binding_verified'] == true
                ? metadata['ticker'] ?? metadata['symbol'] ?? 'KCC20_RAW'
                : 'KCC20_RAW')
            .toString()
            .toUpperCase();
        if (!RegExp(r'^[A-Z0-9_.-]{1,32}$').hasMatch(ticker)) {
          failures++;
          return;
        }
        try {
          final b = await balance(cid, owner),
              raw = BigInt.tryParse(b['balance_raw'].toString());
          if (raw == null || raw < BigInt.zero) {
            throw StateError('Invalid KCC20 balance.');
          }
          if (raw > BigInt.zero) {
            final hash = metadata['image_hash']?.toString() ?? '';
            assets.add(WalletAsset(
                symbol: ticker,
                balance: raw.toDouble() / math.pow(10, decimals),
                kind: 'KCC20',
                decimals: decimals,
                rawBalance: raw.toString(),
                id: cid,
                covenantId: cid,
                standard: standard,
                templateHash: templateId,
                validationStatus: 'observed',
                discoveryComplete: false,
                imageUrl: metadata['image_bytes_verified'] == true &&
                        _hex64.hasMatch(hash)
                    ? '$base/images/$hash'
                    : null));
            onProgress?.call(StandardKcc20Wallet(
                alphabeticalWalletAssets(assets), List.of(transactions), ''));
          }
        } catch (_) {
          failures++;
        }
        // History is independent of current holdings, including fully sold tokens.
        // Send forms request holdings only; never scan the global token history
        // before allowing an already selected asset to be displayed.
        if (historyLimit <= 0) return;
        try {
          String? cursor;
          final pageSize = historyLimit.clamp(1, 50);
          for (var page = 0; page < 5; page++) {
            final value = await get(
                '$base/tokens/$cid/transactions?${Uri(queryParameters: {
                  'limit': '$pageSize',
                  if (cursor != null) 'cursor': cursor
                }).query}');
            final rows =
                (value['data'] as List? ?? []).whereType<Map>().toList();
            for (var offset = 0; offset < rows.length; offset += 6) {
              await Future.wait(rows.skip(offset).take(6).map((row) async {
                final id = row['txid']?.toString() ?? '';
                if (!_hex64.hasMatch(id)) return;
                try {
                  final tx = await detail(cid, id);
                  final activity =
                      transaction(tx, cid, owner, ticker, decimals);
                  if (activity != null) transactions.add(activity);
                } catch (_) {
                  /* A missing history item does not hide balances. */
                }
              }));
            }
            final next = map(value['pagination'])['next_cursor']?.toString();
            if (rows.isEmpty ||
                next == null ||
                next == cursor ||
                page * pageSize + rows.length >= historyLimit) {
              break;
            }
            cursor = next;
          }
        } catch (_) {/* Optional historical coverage, never spend authority. */}
      }));
    }
    return StandardKcc20Wallet(
        alphabeticalWalletAssets(assets),
        transactions..sort((a, b) => b.timestamp.compareTo(a.timestamp)),
        failures > 0
            ? 'Some standard KCC20 balances could not be loaded. Refresh to retry.'
            : map(status['meta'])['stale'] == true
                ? 'Standard KCC20 indexer data is stale; live outputs are rechecked before sending.'
                : '');
  }

  static WalletTransaction? transaction(
      Map tx, String cid, String owner, String ticker, int decimals) {
    BigInt total(String direction) => (tx[direction] as List? ?? [])
        .whereType<Map>()
        .where((r) =>
            r['actor'] == 'KCC20' &&
            r['covenant_id'] == cid &&
            r['owner_scheme'] == 0 &&
            r['owner_value'] == owner &&
            r['state_hash_verified'] == true)
        .fold(
            BigInt.zero,
            (sum, r) =>
                sum +
                (BigInt.tryParse(r['token_amount'].toString()) ?? BigInt.zero));
    final delta = total('outputs') - total('inputs');
    final time = int.tryParse(tx['time_ms'].toString());
    if (delta == BigInt.zero ||
        time == null ||
        time < 1577836800000 ||
        time > DateTime.now().millisecondsSinceEpoch + 300000) {
      return null;
    }
    return WalletTransaction(
        id: tx['txid'].toString(),
        timestamp: DateTime.fromMillisecondsSinceEpoch(time),
        amountSompi: 0,
        incoming: delta > BigInt.zero,
        assetKind: 'KCC20',
        assetSymbol: ticker,
        tokenId: cid,
        displayAmount: formatRawTokenAmount(delta.abs(), decimals),
        status: TransactionStatus.confirmed);
  }

  Future<List<Kcc20CellRecord>> signingCells(
      String address, String cid, int amount,
      {bool allowCompound = false}) async {
    final step = await signingBatch(address, cid, amount);
    if (step.compound && !allowCompound) {
      throw StateError(
          'KCC20 cells need to be compounded before this transfer.');
    }
    return step.cells;
  }

  /// Only poll the balance for indexing readiness. The next preparation checks
  /// fresh origin/live proofs once, rather than repeating them on every poll.
  Future<void> waitForCell(String address, String cid, String transactionId,
      {bool Function()? isCancelled,
      void Function(String)? onProgress,
      Duration timeout = const Duration(seconds: 90)}) async {
    final owner = kaspaOwnerIdFromAddress(address);
    if (!_hex64.hasMatch(cid) ||
        !_hex64.hasMatch(transactionId) ||
        owner.isEmpty) {
      throw StateError('Invalid KCC20 consolidation identity.');
    }
    final watch = Stopwatch()..start();
    while (watch.elapsed < timeout) {
      if (isCancelled?.call() == true) {
        throw StateError('KCC20 preparation cancelled.');
      }
      onProgress?.call(
          'Consolidation submitted. Waiting for indexed output; recipient NOT paid…');
      try {
        final b = await balance(cid, owner, isCancelled: isCancelled);
        if ((b['outputs'] as List? ?? []).whereType<Map>().any((r) =>
            r['txid'] == transactionId &&
            (BigInt.tryParse(r['balance_raw'].toString()) ?? BigInt.zero) >
                BigInt.zero)) {
          return;
        }
      } catch (_) {
        if (isCancelled?.call() == true) rethrow;
        // Temporary indexer failures never authorize another transaction.
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    throw StateError(
        'Consolidation $transactionId is saved but not indexed yet. Recipient NOT paid. Continue the saved transfer later.');
  }

  Future<Kcc20Step> signingBatch(String address, String cid, int amount,
      {bool Function()? isCancelled, void Function(String)? onProgress}) async {
    final watch = Stopwatch()..start();
    bool cancelled() =>
        isCancelled?.call() == true ||
        watch.elapsed > const Duration(minutes: 5);
    void check() {
      if (cancelled()) {
        throw StateError(
            'KCC20 preparation cancelled or timed out. Please retry.');
      }
    }

    check();
    final owner = kaspaOwnerIdFromAddress(address);
    if (!_hex64.hasMatch(cid) || !_hex64.hasMatch(owner) || amount <= 0) {
      throw StateError('Invalid KCC20 request.');
    }
    onProgress?.call('Loading the selected KCC20 token’s current cells…');
    final b = await balance(cid, owner, isCancelled: cancelled);
    if ((BigInt.tryParse(b['balance_raw'].toString()) ?? BigInt.zero) <
        BigInt.from(amount)) {
      throw StateError('Insufficient spendable KCC20 token balance.');
    }
    final template = map(jsonDecode(
        await rootBundle.loadString('assets/kcc20_standard_template.json')));
    if (template['referenceCommit'] != reference) {
      throw StateError('Incorrect local KCC20 template.');
    }
    final seen = <String>{};
    final outputs = (b['outputs'] as List? ?? []).whereType<Map>().toList();
    for (final raw in outputs) {
      final id = raw['txid']?.toString() ?? '',
          index = int.tryParse(raw['output_index'].toString()),
          units = BigInt.tryParse(raw['balance_raw'].toString());
      if (!_hex64.hasMatch(id) ||
          index == null ||
          index < 0 ||
          index > 0xffffffff ||
          units == null ||
          units <= BigInt.zero ||
          units > BigInt.from(0x7fffffffffffffff) ||
          !seen.add('$id:$index')) {
        throw StateError('Invalid or duplicate KCC20 output.');
      }
    }
    outputs.sort((a, b) {
      final units = BigInt.parse(b['balance_raw'].toString())
          .compareTo(BigInt.parse(a['balance_raw'].toString()));
      if (units != 0) return units;
      final id = a['txid'].toString().compareTo(b['txid'].toString());
      return id != 0
          ? id
          : int.parse(a['output_index'].toString())
              .compareTo(int.parse(b['output_index'].toString()));
    });
    var covered = BigInt.zero, requiredCells = 0;
    for (final raw in outputs) {
      covered += BigInt.parse(raw['balance_raw'].toString());
      requiredCells++;
      if (covered >= BigInt.from(amount)) break;
    }
    if (covered < BigInt.from(amount)) {
      throw StateError('KCC20 cell discovery is incomplete.');
    }
    final mandatory = math.min(3, requiredCells);
    final candidates = outputs.take(mandatory).toList();
    // An ordinary payment already has room for three own inputs. Fill spare
    // slots with the smallest compatible cells, without increasing the payment.
    for (final raw in outputs.reversed) {
      if (candidates.length >= 3) break;
      if (!candidates.contains(raw)) candidates.add(raw);
    }
    final reads = <String, Future<Map<String, dynamic>>>{};
    final liveReads = <String, Future<List<dynamic>>>{};
    Future<Map<String, dynamic>> once(String url) {
      check();
      return reads.putIfAbsent(url, () => get(url, isCancelled: cancelled));
    }

    Future<(Kcc20CellRecord, String)?> verify(Map raw, int position) async {
      try {
        check();
        onProgress?.call(
            'Verifying KCC20 cell ${position + 1} of ${candidates.length} with the local node…');
        final id = raw['txid'].toString(),
            index = int.parse(raw['output_index'].toString());
        final detail =
            map((await once('$base/tokens/$cid/transactions/$id'))['data']);
        final rows = (detail['outputs'] as List? ?? [])
            .whereType<Map>()
            .where((r) =>
                r['io_index'] == index &&
                r['covenant_id'] == cid &&
                r['actor'] == 'KCC20')
            .toList();
        if (detail['txid'] != id || rows.length != 1) {
          throw StateError('Missing KCC20 state reconstruction.');
        }
        final state = rows.single,
            units = BigInt.tryParse(state['token_amount'].toString());
        if (state['state_hash_verified'] != true ||
            state['template_hash'] != templateHash ||
            state['owner_value'] != owner ||
            state['owner_scheme'] != 0 ||
            units == null ||
            units <= BigInt.zero ||
            units > BigInt.from(0x7fffffffffffffff) ||
            state['token_amount'].toString() != raw['balance_raw'].toString()) {
          throw StateError(
              'KCC20 ownership or token amount differs from the reconstructed state.');
        }
        if (state['borrow_scheme'] != 0 || state['borrow_guard'] != '0' * 64) {
          throw StateError(
              'This KCC20 output has a borrowing policy; direct transfers are not supported yet.');
        }
        final extension = state['extension_commitment']?.toString() ?? '';
        if (!_hex64.hasMatch(extension)) {
          throw StateError('KCC20 extension commitment is missing.');
        }
        final bytes = <int>[
          8,
          ...List.generate(8, (i) => (units >> (8 * i)).toInt() & 255),
          32
        ];
        String hex(List<int> b) =>
            b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
        final redeem =
            '${template['prefix']}${hex(bytes)}${owner}0100010020${'0' * 64}20$extension${template['suffix']}';
        final origin = await once('$node/transactions/$id');
        final outputs = (origin['outputs'] as List? ?? [])
            .whereType<Map>()
            .where((r) => r['index'] == index)
            .toList();
        if (origin['transaction_id'] != id ||
            origin['is_accepted'] != true ||
            outputs.length != 1 ||
            outputs.single['covenant_id'] != cid ||
            outputs.single['amount'].toString() !=
                raw['amount_sompi'].toString()) {
          throw StateError('The own node does not confirm this KCC20 output.');
        }
        final output = outputs.single,
            outputAddress = output['script_public_key_address']?.toString();
        if (outputAddress == null ||
            !RegExp(r'^kaspa:[a-z0-9]{61,63}$').hasMatch(outputAddress)) {
          throw StateError('KCC20 output address is unavailable.');
        }
        final url = '$node/addresses/$outputAddress/utxos';
        final entries = await liveReads.putIfAbsent(url, () async {
          check();
          final response = await client
              .get(Uri.parse(url))
              .timeout(const Duration(seconds: 8));
          if (response.statusCode != 200) {
            throw StateError('Live KCC20 output verification failed.');
          }
          return jsonDecode(response.body) as List;
        });
        check();
        final live = entries
            .whereType<Map>()
            .where((r) =>
                map(r['outpoint'])['transactionId'] == id &&
                map(r['outpoint'])['index'] == index)
            .toList();
        if (live.length != 1) {
          throw StateError(
              'This KCC20 output was already spent. Refresh the token balance.');
        }
        final entry = map(live.single['utxoEntry']),
            script = map(entry['scriptPublicKey'])['scriptPublicKey'];
        if (script != output['script_public_key'] ||
            entry['amount'].toString() != output['amount'].toString() ||
            entry['isCoinbase'] != false) {
          throw StateError(
              'Live KCC20 script or deposit differs from its confirmed origin.');
        }
        return (
          Kcc20CellRecord(
              covenantId: cid,
              transactionId: id,
              index: index,
              valueSompi: int.parse(entry['amount'].toString()),
              blockDaaScore: int.parse(entry['blockDaaScore'].toString()),
              scriptPublicKey: script.toString(),
              tokenAmount: units.toInt(),
              redeemScript: redeem),
          extension
        );
      } catch (_) {
        if (position < mandatory || cancelled()) rethrow;
        // Optional dust must not break an otherwise valid payment.
        return null;
      }
    }

    final verified = await Future.wait(
        [for (var i = 0; i < candidates.length; i++) verify(candidates[i], i)]);
    check();
    final cells = <Kcc20CellRecord>[];
    var total = BigInt.zero;
    for (var i = 0; i < verified.length; i++) {
      final row = verified[i];
      if (row == null) continue;
      if (row.$2 != verified.first!.$2) {
        if (i < mandatory) {
          throw StateError(
              'Different extended token identities cannot be combined.');
        }
        continue;
      }
      // Do not let optional dust overflow a valid mandatory batch.
      final next = total + BigInt.from(row.$1.tokenAmount);
      if (next > BigInt.from(0x7fffffffffffffff)) {
        if (i < mandatory) throw StateError('KCC20 amount overflow.');
        continue;
      }
      cells.add(row.$1);
      total = next;
    }
    return Kcc20Step(
        cells,
        total < BigInt.from(amount) ? total.toInt() : amount,
        total < BigInt.from(amount),
        requiredCells: requiredCells,
        transactionCount: kcc20TransactionCount(requiredCells));
  }
}
