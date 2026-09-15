import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'native_security.dart';

class DotkException implements Exception {
  const DotkException(this.message);
  final String message;
  @override
  String toString() => message;
}

class DotkName {
  const DotkName(
      {required this.name,
      required this.address,
      this.deedAddress,
      this.outpoint});
  final String name;
  final String address;
  final String? deedAddress;
  final String? outpoint;
  bool get verified => outpoint != null;
}

/// Directory responses are discovery hints, never payment authorization.
/// A fresh native-derived deed + live node UTXO is required for each resolution.
class DotkService {
  DotkService({
    required this.client,
    required this.nodeBaseUrl,
    this.directories = const ['https://api.dotk.name/v1'],
    Future<Map<String, Object?>> Function(Map<String, Object?>)? derive,
  }) : derive = derive ?? NativeSecurity().deriveDotkDeed;

  static const registry =
      'ee2128c03dfac7f6d74734bb3c879bd999434c47a55945b8a6daae2a1e4a21de';
  final http.Client client;
  final String nodeBaseUrl;
  final List<String> directories;
  final Future<Map<String, Object?>> Function(Map<String, Object?>) derive;

  static String bareName(String input) {
    final normalized = input.trim().toLowerCase();
    if (!normalized.endsWith('.k')) {
      throw const DotkException(
          'Enter a complete dot.k name, for example name.k.');
    }
    final bare = normalized.substring(0, normalized.length - 2);
    if (!RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$').hasMatch(bare)) {
      throw const DotkException(
          'Invalid dot.k name. Use 1–32 letters, digits or internal hyphens.');
    }
    return bare;
  }

  Future<Object?> _get(String url) async {
    final response =
        await client.get(Uri.parse(url)).timeout(const Duration(seconds: 6));
    if (response.statusCode != 200 ||
        response.bodyBytes.length > 2 * 1024 * 1024) {
      throw const DotkException(
          'dot.k data is unavailable or the name has no active registration.');
    }
    return jsonDecode(response.body);
  }

  Map<String, Object?> _map(Object? value) {
    if (value is! Map) throw const DotkException('Invalid dot.k response.');
    return value.cast<String, Object?>();
  }

  void _identity(Map<String, Object?> row) {
    if (row['registryCovenantId'] != registry) {
      throw const DotkException(
          'dot.k registry identity does not match the pinned deployment.');
    }
  }

  // A failed/stale mirror cannot win. In particular, a successful HTTP response
  // with a false claim must pass the node proof before it can resolve a payment.
  Future<T> _directory<T>(Future<T> Function(String) load) {
    final result = Completer<T>();
    if (directories.isEmpty) {
      return Future.error(
          const DotkException('No dot.k directory configured.'));
    }
    var remaining = directories.length;
    for (var i = 0; i < directories.length; i++) {
      Future<void>(() async {
        if (i > 0) await Future<void>.delayed(Duration(milliseconds: 300 * i));
        if (result.isCompleted) return;
        try {
          final value = await load(directories[i]);
          if (!result.isCompleted) result.complete(value);
        } catch (error, stack) {
          if (--remaining == 0 && !result.isCompleted) {
            result.completeError(error, stack);
          }
        }
      });
    }
    return result.future;
  }

  /// The address endpoint returns the complete set (no pagination). These are
  /// labelled directory listings; opening a name verifies its current deed.
  Future<List<DotkName>> namesOf(String address) => _directory((base) async {
        final row =
            _map(await _get('$base/addresses/${Uri.encodeComponent(address)}'));
        _identity(row);
        if (row['address'] != address || row['names'] is! List) {
          throw const DotkException(
              'dot.k directory returned a different owner.');
        }
        final names = (row['names'] as List)
            .map((value) {
              if (value is! String) {
                throw const DotkException('Invalid dot.k name list.');
              }
              final bare = bareName('$value.k');
              if (bare != value) {
                throw const DotkException('Non-canonical dot.k name.');
              }
              return bare;
            })
            .toSet()
            .toList()
          ..sort();
        return names
            .map((name) => DotkName(name: '$name.k', address: address))
            .toList();
      });

  Future<DotkName> resolve(String input) {
    final name = bareName(input);
    return _directory((base) async {
      final row = _map(await _get('$base/names/$name'));
      _identity(row);
      if (row['name'] != name) {
        throw const DotkException('dot.k returned a different name.');
      }
      final derived = await derive(
          {'name': name, 'ownerType': row['ownerType'], 'owner': row['owner']});
      _identity(derived);
      final address = derived['address'];
      final deed = derived['deedAddress'];
      final script = derived['scriptPublicKey'];
      if (address is! String || !address.startsWith('kaspa:')) {
        throw const DotkException(
            'This dot.k name is covenant-owned and has no payment address.');
      }
      if (row['address'] != address ||
          row['deedAddress'] != deed ||
          deed is! String ||
          script is! String) {
        throw const DotkException(
            'dot.k owner or deed address conflicts with native derivation.');
      }
      final path =
          '$nodeBaseUrl/local-node/addresses/${Uri.encodeComponent(deed)}/utxos';
      final live = await _get(path);
      if (live is! List) {
        throw const DotkException('Invalid node proof for dot.k.');
      }
      for (final raw in live.take(64)) {
        final utxo = _map(raw);
        final entry = _map(utxo['utxoEntry']);
        final point = _map(utxo['outpoint']);
        final txid = point['transactionId'];
        final index = point['index'];
        final spk = _map(entry['scriptPublicKey']);
        if (entry['amount'].toString() != derived['bond'].toString() ||
            entry['isCoinbase'] != false ||
            spk['scriptPublicKey'] != script ||
            txid is! String ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(txid) ||
            index is! int ||
            index < 0 ||
            (utxo['address'] != null && utxo['address'] != deed)) {
          continue;
        }
        // The current REST bridge omits covenant IDs from UTXOs. Read the
        // output on the same trusted node, then recheck that it is still live.
        final tx =
            _map(await _get('$nodeBaseUrl/local-node/transactions/$txid'));
        if (tx['transaction_id'] != txid ||
            tx['is_accepted'] != true ||
            tx['outputs'] is! List) {
          continue;
        }
        final matches = (tx['outputs'] as List).whereType<Map>().where((out) =>
            out['index'] == index &&
            out['covenant_id'] == registry &&
            out['amount'].toString() == derived['bond'].toString() &&
            out['script_public_key_address'] == deed &&
            out['script_public_key'] == script);
        if (matches.isEmpty) continue;
        final fresh = await _get(path);
        if (fresh is! List ||
            !fresh.whereType<Map>().any((u) =>
                u['outpoint'] is Map &&
                u['utxoEntry'] is Map &&
                u['outpoint']['transactionId'] == txid &&
                u['outpoint']['index'] == index &&
                u['utxoEntry']['amount'].toString() ==
                    derived['bond'].toString())) {
          continue;
        }
        return DotkName(
            name: '$name.k',
            address: address,
            deedAddress: deed,
            outpoint: '$txid:$index');
      }
      throw const DotkException(
          'dot.k ownership could not be confirmed by the node. No recipient was selected; retry after refresh.');
    }).timeout(const Duration(seconds: 12), onTimeout: () {
      throw const DotkException(
          'dot.k verification timed out. No recipient was selected; please retry.');
    });
  }
}
