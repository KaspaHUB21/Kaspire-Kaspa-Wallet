import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../kaspa_address.dart';
import '../models/wallet_snapshot.dart';
import '../number_format.dart';

class StandardKcc20Wallet {
  const StandardKcc20Wallet(this.assets, this.transactions, this.warning);
  final List<WalletAsset> assets;
  final List<WalletTransaction> transactions;
  final String warning;
}

/// Read-only discovery. Indexer metadata never supplies executable programs.
/// Spending cells are checked on the own node and the native core rebuilds
/// every script/transfer using the same pinned Last Call reference template.
class Kcc20StandardService {
  Kcc20StandardService(this.client,
      {this.base = 'https://kasvio.network/api/kcc20/v1',
      this.node = 'https://kaspire.kaslab.space/api/local-node'});
  final http.Client client;
  final String base, node;
  static const standard = 'kcc20-last-call';
  static const templateId = 'argent-kcc20-c8a0871';
  static const reference = 'c8a087117735a1f87c5c6d115fcddeaf2562c784';
  static const templateHash =
      '9703112ee6e3555107cd168858992b77d3b74f655205b2b463b1f9ec2ec73cf7';
  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');
  static Map<String, dynamic> map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : {};
  Future<Map<String, dynamic>> get(String url) async {
    final r =
        await client.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
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
  Future<Map<String, dynamic>> balance(String cid, String owner) async {
    final result =
        await get('$base/tokens/$cid/balance?owner=$owner&scheme=00');
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
        if (!RegExp(r'^[A-Z0-9_-]{1,32}$').hasMatch(ticker)) {
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
      String address, String cid, int amount) async {
    final owner = kaspaOwnerIdFromAddress(address),
        b = await balance(cid, kaspaOwnerIdFromAddress(address));
    final template = map(jsonDecode(
        await rootBundle.loadString('assets/kcc20_standard_template.json')));
    if (template['referenceCommit'] != reference) {
      throw StateError('Incorrect local KCC20 template.');
    }
    final cells = <Kcc20CellRecord>[];
    var total = BigInt.zero;
    final seen = <String>{};
    for (final raw in (b['outputs'] as List? ?? []).whereType<Map>()) {
      final id = raw['txid']?.toString() ?? '',
          index = int.tryParse(raw['output_index'].toString());
      if (!_hex64.hasMatch(id) ||
          index == null ||
          index < 0 ||
          !seen.add('$id:$index')) {
        throw StateError('Invalid or duplicate KCC20 output.');
      }
      final detail =
          map((await get('$base/tokens/$cid/transactions/$id'))['data']);
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
      final origin = await get('$node/transactions/$id');
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
      if (outputAddress == null) {
        throw StateError('KCC20 output address is unavailable.');
      }
      final response = await client
          .get(Uri.parse('$node/addresses/$outputAddress/utxos'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        throw StateError('Live KCC20 output verification failed.');
      }
      final live = (jsonDecode(response.body) as List)
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
      cells.add(Kcc20CellRecord(
          covenantId: cid,
          transactionId: id,
          index: index,
          valueSompi: int.parse(entry['amount'].toString()),
          blockDaaScore: int.parse(entry['blockDaaScore'].toString()),
          scriptPublicKey: script.toString(),
          tokenAmount: units.toInt(),
          redeemScript: redeem));
      total += units;
      if (total >= BigInt.from(amount)) break;
      if (cells.length >= 3) {
        throw StateError(
            'This transfer needs more than three KCC20 inputs. Send a smaller amount first.');
      }
    }
    if (total < BigInt.from(amount)) {
      throw StateError('Insufficient spendable KCC20 token balance.');
    }
    return cells;
  }
}
