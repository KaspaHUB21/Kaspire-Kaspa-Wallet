import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/digests/blake2b.dart';
import '../kaspa_address.dart';
import 'kcc20_metadata.dart';

/// Public read adapter, not a signing authority. Programs must byte-match a
/// bundled template and their committed P2SH hash. The ordinary send path still
/// verifies every origin/live UTXO on our node and rebuilds it in native Rust.
class Kcc20KascovSource {
  Kcc20KascovSource(this.client, this.base, this.reference);
  final http.Client client;
  final String base, reference;
  static const templates = {
    '9703112ee6e3555107cd168858992b77d3b74f655205b2b463b1f9ec2ec73cf7':
        'assets/kcc20_standard_template.json',
    'ff3ae732e3a2819bf9181f5aed6b1e9d0f7abea70a1dd655b8e777cbcbd2422b':
        'assets/kcc20_reference_10_template.json',
  };
  static const obsolete = {
    '9bf2df2cd4a05b8124082c868e79c52eb4d719362af2e1a75c025cfb50a2844e',
    '36205a78ae657a7f1db798f6c52925ca82aca7361df71ef6a8202ce05aa7ec5f',
  };
  static final hex64 = RegExp(r'^[0-9a-f]{64}$');
  final _reads = <String, (DateTime, Future<Map<String, dynamic>>)>{};
  final _states = <String, Map<String, Map<String, dynamic>>>{};
  final _owners = <String, Set<String>>{};
  void rememberOwner(String cid, String owner) {
    if (hex64.hasMatch(cid) && hex64.hasMatch(owner)) {
      if (_owners.length > 128) _owners.clear();
      (_owners[cid] ??= {}).add(owner);
    }
  }

  static Map<String, dynamic> map(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : {};
  static List<Map<String, dynamic>> rows(Object? v) =>
      v is List ? v.whereType<Map>().map(map).toList() : [];
  static String hex(List<int> bytes) =>
      bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  static Uint8List bytes(String value) {
    if (value.isEmpty ||
        value.length.isOdd ||
        !RegExp(r'^[0-9a-f]+$').hasMatch(value)) {
      throw StateError('Invalid Kascov program encoding.');
    }
    return Uint8List.fromList([
      for (var i = 0; i < value.length; i += 2)
        int.parse(value.substring(i, i + 2), radix: 16)
    ]);
  }

  Map<String, dynamic> envelope(Object data,
          {Map<String, Object?> extra = const {}}) =>
      {
        'data': data,
        'meta': <String, dynamic>{
          'network': 'mainnet',
          'reference_commit': reference,
          'read_source': 'kascov'
        },
        ...extra,
      };
  Future<Map<String, dynamic>> fetch(String path, {bool cache = true}) async {
    final previous = _reads[path];
    if (cache &&
        previous != null &&
        DateTime.now().difference(previous.$1) < const Duration(seconds: 10))
      return previous.$2;
    if (_reads.length > 128) _reads.clear();
    final pending = () async {
      final response = await client
          .get(Uri.parse('$base$path'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200)
        throw StateError(
            'Kascov KCC20 data unavailable (${response.statusCode}).');
      final value = map(jsonDecode(response.body));
      if (value['network'] != 'mainnet')
        throw StateError('Kascov returned a different network.');
      return value;
    }();
    _reads[path] = (DateTime.now(), pending);
    try {
      return await pending;
    } catch (_) {
      _reads.remove(path);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> token(String cid) async {
    final detail = await fetch('/token/$cid'), t = map(detail['token']);
    if (t['covenant_id'] != cid || t['status'] != 'verified')
      throw StateError('Kascov token is not verified.');
    final hash = t['layout'] == 'kcc20-46'
        ? obsolete.first
        : map(t['standard'])['template_hash'] ?? t['template_hash'];
    final declaration = verifiedKascovDeclaration(cid, t);
    // Units must come from a bound declaration, not an arbitrary ticker or a
    // guessed default. Venue-specific discovery remains a separate path.
    final decimals = declaration?['decimals'];
    return {
      'covenant_id': cid,
      'template_hash': hash,
      if (map(map(detail['market'])['program'])['token_covenant_id'] == cid &&
          '${map(map(detail['market'])['program'])['skeleton']}'
              .toLowerCase()
              .startsWith('kasseal '))
        'wallet_standard': 'kasseal-kcc20',
      'recognition': templates.containsKey(hash)
          ? 'hash_proven_program_artifact'
          : 'unsupported',
      'metadata': declaration == null
          ? {}
          : {
              ...declaration,
              'covenant_id': cid,
              'binding_verified': true,
              'image_uri': declaration['image'],
            },
      if (decimals is int)
        'token_units': {'status': 'verified', 'decimals': decimals},
    };
  }

  Future<Map<String, dynamic>> balance(String cid, String owner) async {
    if (!hex64.hasMatch(cid) || !hex64.hasMatch(owner))
      throw StateError('Invalid Kascov token owner.');
    final t = await token(cid),
        hash = t['template_hash'],
        asset = templates[hash];
    if (asset == null) throw StateError('Unsupported Kascov KCC20 program.');
    final template = map(jsonDecode(await rootBundle.loadString(asset)));
    if (template['referenceCommit'] != reference)
      throw StateError('Incorrect local KCC20 reference.');
    final prefix = '${template['prefix']}', suffix = '${template['suffix']}';
    final data = await fetch('/token/$cid/cells?owner=00$owner&limit=1000');
    if (data['token_id'] != cid ||
        data['owner'] != '00$owner' ||
        data['cells'] is! List ||
        (data['cells'] as List).any((cell) => cell is! Map) ||
        ['omitted_over_limit', 'omitted_unproven', 'omitted_unvalued']
            .any((k) => data[k] != 0)) {
      throw StateError(
          'Kascov cell discovery is incomplete; no zero balance is assumed.');
    }
    final outputs = <Map<String, dynamic>>[], seen = <String>{};
    var total = BigInt.zero;
    final states = _states.putIfAbsent(cid, () => {});
    if (_states.length > 128) _states.remove(_states.keys.first);
    for (final cell in rows(data['cells'])) {
      final outpoint = '${cell['outpoint']}', parts = outpoint.split(':');
      final index = parts.length == 2 ? int.tryParse(parts[1]) : null;
      final program = '${cell['program_hex']}';
      if (parts.length != 2 ||
          !hex64.hasMatch(parts[0]) ||
          index == null ||
          index < 0 ||
          index > 0xffffffff ||
          !seen.add(outpoint) ||
          cell['is_minter'] != false ||
          !program.startsWith(prefix) ||
          !program.endsWith(suffix) ||
          program.length != prefix.length + 224 + suffix.length) {
        throw StateError('Invalid, duplicate or unsupported Kascov cell.');
      }
      final s = program.substring(prefix.length, prefix.length + 224);
      if (s.substring(0, 2) != '08' ||
          s.substring(18, 20) != '20' ||
          s.substring(20, 84) != owner ||
          s.substring(84, 90) != '010001' ||
          s.substring(92, 94) != '20' ||
          s.substring(158, 160) != '20') {
        throw StateError('Kascov cell ownership or state layout differs.');
      }
      final amount = BigInt.parse(
          [for (var i = 16; i >= 2; i -= 2) s.substring(i, i + 2)].join(),
          radix: 16);
      final borrow = int.parse(s.substring(90, 92), radix: 16),
          guard = s.substring(94, 158),
          extension = s.substring(160, 224);
      final deposit = BigInt.tryParse('${cell['value_sompi']}');
      final commitment =
          'aa20${hex(Blake2bDigest(digestSize: 32).process(bytes(program)))}87';
      if (amount > BigInt.from(0x7fffffffffffffff) ||
          borrow > 3 ||
          !hex64.hasMatch(guard) ||
          !hex64.hasMatch(extension) ||
          cell['amount_str'] != amount.toString() ||
          cell['owner'] != '00$owner' ||
          cell['borrow_scheme'] != borrow.toRadixString(16).padLeft(2, '0') ||
          cell['borrow_guard'] != guard ||
          cell['extension_commitment'] != extension ||
          deposit == null ||
          deposit <= BigInt.zero ||
          deposit > BigInt.from(0x7fffffffffffffff) ||
          cell['script_hex'] != commitment) {
        throw StateError(
            'Kascov program, policy, amount or P2SH commitment differs.');
      }
      total += amount;
      if (total > BigInt.from(0x7fffffffffffffff))
        throw StateError('KCC20 balance overflow.');
      outputs.add({
        'txid': parts[0],
        'output_index': index,
        'balance_raw': amount.toString(),
        'amount_sompi': deposit.toString()
      });
      states[outpoint] = {
        'io_index': index,
        'covenant_id': cid,
        'actor': 'KCC20',
        'token_amount': amount.toString(),
        'owner_scheme': 0,
        'owner_value': owner,
        'state_hash_verified': true,
        'template_hash': hash,
        'borrow_scheme': borrow,
        'borrow_guard': guard,
        'extension_commitment': extension,
      };
    }
    return envelope({
      'covenant_id': cid,
      'owner_scheme': 0,
      'owner_value': owner,
      'available': true,
      'balance_raw': total.toString(),
      'outputs': outputs
    });
  }

  Future<Map<String, dynamic>> read(
      List<String> path, Map<String, String> query) async {
    if (path.length == 3 &&
        path.first == 'addresses' &&
        path.last == 'tokens') {
      final address = path[1], owner = kaspaOwnerIdFromAddress(path[1]);
      if (!address.startsWith('kaspa:') || !hex64.hasMatch(owner))
        throw StateError('Invalid KCC20 address.');
      final page = await fetch(
          '/addr/${Uri.encodeComponent(address)}.json?${Uri(queryParameters: {
            'limit': '100',
            if (query['cursor'] != null) 'before_token': query['cursor']!,
          }).query}');
      if (page['address'] != address ||
          page['pubkey'] != owner ||
          page['token_holdings'] is! List)
        throw StateError('Kascov account identity differs.');
      if ((page['token_holdings'] as List).any((row) => row is! Map)) {
        throw StateError('Malformed Kascov account holdings.');
      }
      final amounts = <String, BigInt>{}, seen = <String>{};
      var unverified = false;
      for (final row in rows(page['token_holdings'])) {
        final cid = '${row['token_id'] ?? row['covenant_id']}',
            amount = BigInt.tryParse('${row['balance_str'] ?? row['balance']}');
        if (!hex64.hasMatch(cid) ||
            amount == null ||
            amount < BigInt.zero ||
            !seen.add('$cid:${row['class'] ?? ''}')) {
          throw StateError('Invalid or duplicate Kascov account holding.');
        }
        if (amount == BigInt.zero) continue;
        if (row['status'] != 'verified') {
          unverified = true;
          continue;
        }
        amounts[cid] = (amounts[cid] ?? BigInt.zero) + amount;
      }
      final data = [
        for (final entry in amounts.entries)
          {
            'covenant_id': entry.key,
            'owner_scheme': 0,
            'owner_value': owner,
            'balance_raw': entry.value.toString(),
            'balance_complete': true,
          }
      ];
      final cursor = page['next_before_token'];
      final tipAt = int.tryParse('${page['tip_at_ms']}');
      final stale = tipAt == null ||
          (DateTime.now().millisecondsSinceEpoch - tipAt).abs() >
              const Duration(minutes: 5).inMilliseconds;
      final result = envelope(data, extra: {
        'address_context': {
          'address': address,
          'network': 'mainnet',
          'owner_scheme': 0,
          'owner_value': owner,
          'balances_complete':
              page.containsKey('next_before_token') && !unverified && !stale,
          'unknown_tokens_attributable_to_address':
              unverified || !page.containsKey('next_before_token'),
        },
        'pagination': {'has_more': cursor != null, 'next_cursor': cursor},
      });
      (result['meta'] as Map)['snapshot_id'] = 'kascov:${page['tip_daa']}';
      (result['meta'] as Map)['stale'] = stale;
      return result;
    }
    if (path.length >= 2 && path.first == 'tokens' && hex64.hasMatch(path[1])) {
      final cid = path[1];
      if (path.length == 2) return envelope(await token(cid));
      if (path.length == 3 && path.last == 'balance' && query['scheme'] == '00')
        return balance(cid, query['owner'] ?? '');
      if (path.length == 4 &&
          path[2] == 'transactions' &&
          hex64.hasMatch(path[3])) {
        if (!(_states[cid] ?? {})
            .keys
            .any((key) => key.startsWith('${path[3]}:'))) {
          for (final owner in (_owners[cid] ?? <String>{}).take(32)) {
            await balance(cid, owner);
          }
        }
        final outputs = (_states[cid] ?? {})
            .entries
            .where((e) => e.key.startsWith('${path[3]}:'))
            .map((e) => e.value)
            .toList();
        if (outputs.isEmpty)
          throw StateError(
              'Kascov has no verified current state for this transaction.');
        // Current output evidence is sufficient for sends, NOT a complete
        // historical transaction. Activity must retain its unavailable status.
        return envelope({
          'txid': path[3],
          'outputs': outputs,
          'components_complete': false
        });
      }
    }
    throw StateError('This KCC20 read is unavailable from Kascov.');
  }
}
