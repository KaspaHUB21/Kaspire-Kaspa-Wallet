import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../kaspa_address.dart';
import '../models/wallet_snapshot.dart';
import '../number_format.dart';
import 'kcc20_compound.dart';
import 'kcc20_kascov_source.dart';

// Shared by discovery and send preparations, including service instances created
// by KaspaApi getters. Only read requests are queued; signing is never retried.
class _KasvioReadQueue {
  final urgent = <Future<void> Function()>[];
  final ordinary = <Future<void> Function()>[];
  bool running = false;
  DateTime next = DateTime.fromMillisecondsSinceEpoch(0);

  Future<http.Response> read(
      http.Client client, Uri uri, bool Function()? isCancelled,
      {bool priority = false}) {
    final result = Completer<http.Response>();
    Future<http.Response> execute() async {
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
    }

    (priority ? urgent : ordinary).add(() async {
      try {
        result.complete(await execute());
      } catch (e, stack) {
        result.completeError(e, stack);
      }
    });
    if (!running) unawaited(drain());
    return result.future;
  }

  Future<void> drain() async {
    running = true;
    while (urgent.isNotEmpty || ordinary.isNotEmpty) {
      await (urgent.isNotEmpty ? urgent : ordinary).removeAt(0)();
    }
    running = false;
  }
}

class StandardKcc20Wallet {
  const StandardKcc20Wallet(this.assets, this.transactions, this.warning,
      {this.coverageComplete = true});
  final List<WalletAsset> assets;
  final List<WalletTransaction> transactions;
  final String warning;
  final bool coverageComplete;
}

class Kcc20ReadError extends StateError {
  Kcc20ReadError(this.status, {String source = 'KCC20'})
      : super('$source data unavailable ($status).');
  final int status;
}

/// Read-only discovery. Indexer metadata never supplies executable programs.
/// Spending cells are checked on the own node and the native core rebuilds
/// every script/transfer using the same pinned KCC20 reference template.
class Kcc20StandardService {
  Kcc20StandardService(this.client,
      {this.base = 'https://kasvio.network/api/kcc20/v4',
      this.kascovBase = 'https://kascov.io/data/mainnet',
      this.node = 'https://kaspire.kaslab.space/api/local-node'});
  final http.Client client;
  final String base, node, kascovBase;
  static final _fallbacks = Expando<Map<String, Kcc20KascovSource>>();
  static final _unavailableUntil = Expando<Map<String, DateTime>>();
  Kcc20KascovSource get _fallback => (_fallbacks[client] ??= {}).putIfAbsent(
      kascovBase, () => Kcc20KascovSource(client, kascovBase, reference));
  static const standard = 'kcc20';
  static bool isStandard(String? value) =>
      value == standard ||
      value == 'kcc20-last-call' ||
      value == 'kasparocket-kcc20' ||
      value == 'kasseal-kcc20';
  static bool supportsBorrowedReceive(String? value) =>
      isStandard(value) && value != 'kasseal-kcc20';
  static const templateId = 'argent-kcc20-c8a0871';
  // Separate native mode: pinned reference bytes, owner signatures only,
  // whole tokens, borrow=0 and Kasseal's 5 KAS output reserve.
  static const kassealOwnerTemplateId = 'kasseal-kcc20-owner-v1';
  static const reference = 'c8a087117735a1f87c5c6d115fcddeaf2562c784';
  static const templateHash =
      '9703112ee6e3555107cd168858992b77d3b74f655205b2b463b1f9ec2ec73cf7';
  static const tenTemplateId = 'argent-kcc20-c8a0871-10x10';
  static const tenTemplateHash =
      'ff3ae732e3a2819bf9181f5aed6b1e9d0f7abea70a1dd655b8e777cbcbd2422b';
  // Pre-final KCC20 experiments are not supported signing programs. Only
  // these two identifiers of the same legacy template are exempt from warnings
  // (Kascov KCC1 identifier and canonical SilverScript hash, respectively).
  static const obsoleteTemplateHashes = {
    '9bf2df2cd4a05b8124082c868e79c52eb4d719362af2e1a75c025cfb50a2844e',
    '36205a78ae657a7f1db798f6c52925ca82aca7361df71ef6a8202ce05aa7ec5f',
  };

  static Object? _templateHash(Map row) =>
      row['template_hash'] ??
      map(row['program'])['template_hash'] ??
      map(row['configuration'])['template_hash'];

  static String? tokenTemplate(Map row) {
    final hash = _templateHash(row);
    if (hash != null) {
      if (hash == templateHash) return templateId;
      if (hash == tenTemplateHash) return tenTemplateId;
      return null;
    }
    return row['profile_id'] == 'KCC20PublicMint@c8a0871' ? templateId : null;
  }

  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');
  static final _queues = Expando<_KasvioReadQueue>();
  static final _historyCaches =
      Expando<Map<String, Future<Map<String, dynamic>>>>();
  Future<Map<String, dynamic>> _historyGet(String path) {
    final cache = _historyCaches[client] ??= {};
    final key = '$base/$path';
    if (cache.length > 1024) cache.clear();
    return cache.putIfAbsent(key, () async {
      try {
        final value = map((await get(key, priority: true))['data']);
        if (path.contains('/transactions/') &&
            value['components_complete'] != true) {
          throw StateError('Incomplete KCC20 transaction details.');
        }
        return value;
      } catch (_) {
        cache.remove(key);
        rethrow;
      }
    });
  }

  static Map<String, dynamic> map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : {};
  Future<Map<String, dynamic>> get(String url,
      {bool Function()? isCancelled, bool priority = false}) async {
    final uri = Uri.parse(url);
    final primary = url.startsWith('$base/');
    final path = primary
        ? uri.pathSegments.skip(Uri.parse(base).pathSegments.length).toList()
        : <String>[];
    if (path.length == 3 && path.first == 'tokens' && path.last == 'balance') {
      _fallback.rememberOwner(path[1], uri.queryParameters['owner'] ?? '');
    }
    final supported = primary &&
        (path.firstOrNull == 'addresses' || path.firstOrNull == 'tokens') &&
        path.length >= 2;
    try {
      final until = (_unavailableUntil[client] ?? {})[base];
      if (supported && until != null && until.isAfter(DateTime.now())) {
        throw Kcc20ReadError(503, source: 'Kasvio KCC20');
      }
      final r = primary
          ? await (_queues[client] ??= _KasvioReadQueue())
              .read(client, uri, isCancelled, priority: priority)
          : await client.get(uri).timeout(const Duration(seconds: 8));
      if (isCancelled?.call() == true) {
        throw StateError('KCC20 preparation cancelled.');
      }
      if (r.statusCode != 200) {
        throw Kcc20ReadError(r.statusCode,
            source: primary ? 'Kasvio KCC20' : 'Own-node KCC20');
      }
      final value = map(jsonDecode(r.body));
      if (primary) {
        final meta = map(value['meta']);
        // V4 covers multiple contract families and no longer claims one global
        // reference revision. This is read provenance only: individual token
        // templates, reconstructed states and own-node proofs remain pinned.
        final v4Envelope = Uri.parse(base).path.endsWith('/kcc20/v4') &&
            meta['reference_commit'] == null &&
            meta['adapter'] == 'kcc20' &&
            meta['source_run'] is String &&
            (meta['source_run'] as String).startsWith('v4:') &&
            _hex64.hasMatch('${meta['source_fingerprint']}') &&
            _hex64.hasMatch('${meta['decoder_fingerprint']}');
        if (meta['network'] != 'mainnet' ||
            (meta['reference_commit'] != reference && !v4Envelope)) {
          throw StateError(
              'Kasvio KCC20 network or reference revision differs.');
        }
        // An unassigned V4 family has no signing identity. Ask the secondary
        // source for its independently pinned identity, including known retired
        // profiles that must be excluded rather than shown as wallet errors.
        if (v4Envelope && path.length == 2 && path.first == 'tokens') {
          final token = map(value['data']);
          if (rowId(token) == path[1] &&
              tokenTemplate(token) == null &&
              token['profile_id'] == null &&
              _templateHash(token) == null) {
            return await _fallback.read(path, uri.queryParameters);
          }
          if (rowId(token) == path[1] &&
              tokenTemplate(token) == templateId &&
              map(token['market'])['venue'] == 'kasseal' &&
              verifiedDecimals(token) == 0) {
            value['data'] = {...token, 'wallet_standard': 'kasseal-kcc20'};
          }
        }
      }
      return value;
    } catch (error) {
      if (isCancelled?.call() == true) rethrow;
      final unavailable = error is TimeoutException ||
          error is http.ClientException ||
          error is FormatException ||
          (error is Kcc20ReadError &&
              (error.status == 404 ||
                  error.status == 405 ||
                  error.status == 408 ||
                  error.status == 429 ||
                  error.status >= 500));
      if (!supported || !unavailable) rethrow;
      if (error is! Kcc20ReadError ||
          (error.status != 404 && error.status != 405)) {
        (_unavailableUntil[client] ??= {})[base] =
            DateTime.now().add(const Duration(seconds: 15));
      }
      try {
        final value = await _fallback.read(path, uri.queryParameters);
        if (isCancelled?.call() == true)
          throw StateError('KCC20 preparation cancelled.');
        return value;
      } catch (fallbackError) {
        // Preserve the original 404/405 compatibility path only if neither
        // source exposes it. Never reinterpret an unavailable lookup as zero.
        if (error is Kcc20ReadError &&
            (error.status == 404 || error.status == 405)) throw error;
        throw StateError(
            'Kasvio and Kascov could not provide this KCC20 read. $fallbackError');
      }
    }
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
  static int? verifiedDecimals(Map token) {
    final units = map(token['token_units']), metadata = map(token['metadata']);
    final value = units['status'] == 'verified'
        ? units['decimals']
        : metadata['binding_verified'] == true
            ? metadata['decimals']
            : null;
    final decimals = int.tryParse(value?.toString() ?? '');
    return decimals != null && decimals >= 0 && decimals <= 18
        ? decimals
        : null;
  }

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
    try {
      return await _loadAddress(address, owner, historyLimit, onProgress);
    } on Kcc20ReadError catch (e) {
      // Compatibility with deployments that do not expose the address route.
      // An outage/rate limit is not evidence that the wallet owns no tokens,
      // and must not trigger hundreds of additional catalogue requests.
      if (e.status != 404 && e.status != 405) rethrow;
      return _loadCatalogue(address,
          historyLimit: historyLimit, onProgress: onProgress);
    }
  }

  Future<StandardKcc20Wallet> _loadAddress(String address, String owner,
      int historyLimit, void Function(StandardKcc20Wallet)? onProgress) async {
    final assets = <String, WalletAsset>{};
    final references = <String, Set<String>>{};
    final warnings = <String>{};
    final seen = <String>{};
    final cursors = <String>{};
    var coverageComplete = true;
    String? cursor, snapshot;
    StandardKcc20Wallet result([List<WalletTransaction> history = const []]) =>
        StandardKcc20Wallet(alphabeticalWalletAssets(assets.values), history,
            warnings.join(' '),
            coverageComplete: coverageComplete);
    void publish() => onProgress?.call(result());
    for (var page = 0; page < 20; page++) {
      Map<String, dynamic> response;
      try {
        response = await get(
            '$base/addresses/${Uri.encodeComponent(address)}/tokens?${Uri(queryParameters: {
                  'limit': '100',
                  if (cursor != null) 'cursor': cursor
                }).query}',
            priority: true);
        final context = map(response['address_context']);
        if (context['address'] != address ||
            context['network'] != 'mainnet' ||
            context['owner_scheme'] != 0 ||
            context['owner_value'] != owner ||
            response['data'] is! List ||
            (response['data'] as List).length > 100) {
          throw StateError(
              'KCC20 address response is unavailable or mismatched.');
        }
        final meta = map(response['meta']);
        final currentSnapshot = meta['snapshot_id']?.toString();
        if (snapshot != null && currentSnapshot != snapshot) {
          throw StateError('KCC20 address pagination snapshot changed.');
        }
        snapshot ??= currentSnapshot;
        if (context['balances_complete'] != true) {
          coverageComplete = false;
          // Global unrecognized contracts are not a failed holding of this
          // wallet. Retain partial-state semantics separately, even if empty.
          if (context['unknown_tokens_attributable_to_address'] != false) {
            warnings.add(
                'Standard KCC20 discovery is incomplete; additional holdings may not yet be indexed.');
          }
        }
        if (meta['stale'] == true || meta['retained_snapshot'] == true) {
          warnings.add(
              'Standard KCC20 indexer data is stale; live outputs are rechecked before sending.');
        }
      } catch (_) {
        if (page == 0) rethrow;
        coverageComplete = false;
        warnings.add(
            'Some standard KCC20 holdings could not be loaded. Previously discovered holdings are retained.');
        break;
      }
      final rows = response['data'] as List;
      for (var offset = 0; offset < rows.length; offset += 6) {
        await Future.wait(rows.skip(offset).take(6).map((item) async {
          try {
            if (item is! Map) throw StateError('Invalid KCC20 holding.');
            final row = map(item), cid = rowId(row);
            final rawText = row['balance_raw']?.toString() ?? '';
            if (!_hex64.hasMatch(cid) ||
                !seen.add(cid) ||
                row['owner_scheme'] != 0 ||
                row['owner_value'] != owner ||
                !RegExp(r'^\d+$').hasMatch(rawText)) {
              throw StateError('Invalid or duplicate KCC20 holding.');
            }
            final raw = BigInt.parse(rawText);
            if (raw == BigInt.zero) return;
            // The address route is balance evidence, not a signing template.
            // Resolve only held tokens through the pinned public token API.
            final token =
                map((await get('$base/tokens/$cid', priority: true))['data']);
            final program = tokenTemplate(token);
            if (rowId(token) == cid &&
                obsoleteTemplateHashes.contains(_templateHash(token))) {
              return;
            }
            final venue = map(token['market'])['venue'];
            if (rowId(token) == cid &&
                token['recognition'] ==
                    'hash_proven_parameterized_actor_family' &&
                ((token['profile_id'] == 'KCC20Parameterized@v1-i10-o10' &&
                        venue == 'kasparocket') ||
                    (token['profile_id'] == 'KCC20Parameterized@v1-i6-o6' &&
                        venue == 'kforge'))) {
              // Discovered and verified by the dedicated venue path;
              // this is not a failed reference-actor holding or a signing pin.
              return;
            }
            if (rowId(token) != cid ||
                program == null ||
                !const [
                  'hash_proven_reference_actor_family',
                  'hash_proven_program_artifact'
                ].contains(token['recognition'])) {
              throw StateError('Unsupported KCC20 program.');
            }
            final detailMetadata = map(token['metadata']);
            final rowMetadata = map(row['metadata']);
            for (final metadata in [detailMetadata, rowMetadata]) {
              if (metadata['binding_verified'] == true &&
                  metadata['covenant_id'] != null &&
                  metadata['covenant_id'] != cid) {
                throw StateError('KCC20 metadata covenant differs.');
              }
            }
            final metadata = detailMetadata['binding_verified'] == true
                ? detailMetadata
                : rowMetadata;
            final detailDecimals = verifiedDecimals(token);
            final rowDecimals = verifiedDecimals(row);
            if (detailDecimals != null &&
                rowDecimals != null &&
                detailDecimals != rowDecimals) {
              throw StateError('KCC20 token units differ.');
            }
            final decimals = detailDecimals ?? rowDecimals;
            if (decimals == null) throw StateError('Unverified KCC20 units.');
            final ticker = (metadata['binding_verified'] == true
                    ? metadata['ticker'] ?? metadata['symbol'] ?? 'KCC20_RAW'
                    : 'KCC20_RAW')
                .toString()
                .toUpperCase();
            if (!RegExp(r'^[A-Z0-9_.-]{1,32}$').hasMatch(ticker)) {
              throw StateError('Invalid KCC20 ticker.');
            }
            if (row['balance_complete'] != true) {
              coverageComplete = false;
              warnings.add(
                  'Some standard KCC20 balances have incomplete coverage.');
            }
            final hash = metadata['image_hash']?.toString() ?? '';
            assets[cid] = WalletAsset(
                symbol: ticker,
                balance: raw.toDouble() / math.pow(10, decimals),
                kind: 'KCC20',
                decimals: decimals,
                rawBalance: rawText,
                id: cid,
                covenantId: cid,
                standard: token['wallet_standard'] == 'kasseal-kcc20'
                    ? 'kasseal-kcc20'
                    : standard,
                templateHash: program,
                validationStatus: 'observed',
                discoveryComplete: false,
                imageUrl: metadata['image_bytes_verified'] == true &&
                        _hex64.hasMatch(hash)
                    ? '$base/images/$hash'
                    : metadata['binding_verified'] == true &&
                            Uri.tryParse('${metadata['image_uri']}')?.scheme ==
                                'https'
                        ? metadata['image_uri'].toString()
                        : null);
            publish();
          } catch (_) {
            coverageComplete = false;
            warnings.add(
                'Some standard KCC20 holdings could not be verified. Refresh to retry.');
          }
        }));
      }
      final pagination = map(response['pagination']);
      if (pagination['has_more'] == false) break;
      final next = pagination['next_cursor'];
      if (pagination['has_more'] != true ||
          next is! String ||
          next.isEmpty ||
          next.length > 4096 ||
          !cursors.add(next) ||
          page == 19) {
        coverageComplete = false;
        warnings.add(
            'Standard KCC20 address pagination is incomplete. Refresh to retry.');
        break;
      }
      cursor = next;
    }
    // Publish balances before optional origin/history reads. Origin IDs keep
    // existing Activity discovery working without scanning unrelated tokens.
    publish();
    for (final cid in assets.keys.toList()) {
      try {
        final b = await balance(cid, owner);
        final origins = ((b['outputs'] as List? ?? []).whereType<Map>().toList()
              ..sort((a, b) =>
                  (BigInt.tryParse(b['acceptance_id'].toString()) ??
                          BigInt.zero)
                      .compareTo(
                          BigInt.tryParse(a['acceptance_id'].toString()) ??
                              BigInt.zero)))
            .map((row) => row['txid']?.toString() ?? '')
            .where(_hex64.hasMatch)
            .take(512)
            .toSet();
        references[cid] = origins;
        final asset = assets[cid]!;
        assets[cid] = WalletAsset(
            symbol: asset.symbol,
            balance: asset.balance,
            kind: asset.kind,
            imageUrl: asset.imageUrl,
            id: asset.id,
            decimals: asset.decimals,
            rawBalance: asset.rawBalance,
            covenantId: cid,
            standard: asset.standard,
            templateHash: asset.templateHash,
            validationStatus: asset.validationStatus,
            discoveryComplete: false,
            activityOrigins: origins.toList());
        publish();
      } catch (_) {
        warnings.add(
            'Some KCC20 activity origins are temporarily unavailable; loaded balances are retained.');
      }
    }
    final history = historyLimit > 0
        ? await historyForTransactions(address, references,
            limit: historyLimit, onWarning: warnings.add)
        : <WalletTransaction>[];
    return result(history);
  }

  Future<StandardKcc20Wallet> _loadCatalogue(String address,
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
        final tokenProgram = tokenTemplate(token);
        if (tokenProgram == null ||
            ![
              'hash_proven_reference_actor_family',
              'hash_proven_program_artifact'
            ].contains(token['recognition'])) {
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
                templateHash: tokenProgram,
                validationStatus: 'observed',
                discoveryComplete: false,
                activityOrigins:
                    ((b['outputs'] as List? ?? []).whereType<Map>().toList()
                          ..sort((a, b) =>
                              (BigInt.tryParse(b['acceptance_id'].toString()) ??
                                      BigInt.zero)
                                  .compareTo(BigInt.tryParse(
                                          a['acceptance_id'].toString()) ??
                                      BigInt.zero)))
                        .map((row) => row['txid']?.toString() ?? '')
                        .where(_hex64.hasMatch)
                        .take(512)
                        .toList(),
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
        unitSource: 'verified-kcc20',
        assetSymbol: ticker,
        tokenId: cid,
        displayAmount: formatRawTokenAmount(delta.abs(), decimals),
        status: TransactionStatus.confirmed);
  }

  /// Resolve only transactions already associated with this wallet. Never
  /// walk the global token catalogue or every token's public trading history.
  Future<List<WalletTransaction>> historyForTransactions(
      String address, Map<String, Set<String>> references,
      {int limit = 51,
      void Function(List<WalletTransaction>)? onProgress,
      void Function(String)? onWarning}) async {
    final owner = kaspaOwnerIdFromAddress(address);
    if (owner.isEmpty) return [];
    final result = <WalletTransaction>[];
    var failures = 0;
    final candidates =
        references.entries.where((e) => _hex64.hasMatch(e.key)).toList();
    for (var offset = 0; offset < candidates.length; offset += 4) {
      await Future.wait(candidates.skip(offset).take(4).map((entry) async {
        try {
          final token = await _historyGet('tokens/${entry.key}');
          if (rowId(token) != entry.key ||
              ![
                'hash_proven_reference_actor_family',
                'hash_proven_program_artifact',
                'hash_proven_parameterized_actor_family'
              ].contains(token['recognition'])) {
            return;
          }
          final metadata = map(token['metadata']);
          final decimals = verifiedDecimals(token);
          final ticker = (metadata['binding_verified'] == true
                  ? metadata['ticker'] ?? metadata['symbol'] ?? 'KCC20_RAW'
                  : 'KCC20_RAW')
              .toString()
              .toUpperCase();
          if (decimals == null ||
              decimals < 0 ||
              decimals > 18 ||
              !RegExp(r'^[A-Z0-9_.-]{1,32}$').hasMatch(ticker)) {
            throw StateError('Invalid KCC20 history units.');
          }
          for (final id in entry.value.where(_hex64.hasMatch).take(limit * 2)) {
            try {
              final tx =
                  await _historyGet('tokens/${entry.key}/transactions/$id');
              if (tx['txid'] != id ||
                  map(tx['token'])['covenant_id'] != entry.key ||
                  tx['components_complete'] != true) {
                throw StateError('Incomplete KCC20 history.');
              }
              final item = transaction(tx, entry.key, owner, ticker, decimals);
              if (item != null) {
                result.add(item);
                result.sort((a, b) => b.timestamp.compareTo(a.timestamp));
                onProgress?.call(result.take(limit).toList());
              }
            } on Kcc20ReadError {
              failures++;
            } catch (_) {
              failures++;
            }
          }
        } on Kcc20ReadError catch (e) {
          // Pool, NFT and legacy covenants are not standard KCC20 tokens.
          if (e.status != 404) failures++;
        } catch (_) {
          failures++;
        }
      }));
    }
    if (failures > 0) {
      if (onWarning == null && result.isEmpty) {
        throw StateError('KCC20 history is incomplete.');
      }
      onWarning?.call(
          'Some KCC20 transaction details are temporarily unavailable. Retry to complete the history.');
    }
    return result.take(limit).toList();
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

  /// Reuse only an explicitly enabled amount-threshold recipient cell. A
  /// disabled/signature/hash-chain cell is never spent without its authority.
  Future<Kcc20CellRecord?> borrowedReceive(String recipient, String cid,
      int amount, Kcc20CellRecord first, String programId,
      {bool Function()? isCancelled}) async {
    final owner = kaspaOwnerIdFromAddress(recipient);
    if (!_hex64.hasMatch(owner) || amount <= 0)
      throw StateError('Invalid borrowed receive request.');
    final ten = programId == tenTemplateId;
    if (!ten && programId != templateId)
      throw StateError('Unsupported borrowed receive program.');
    final template = map(jsonDecode(await rootBundle.loadString(ten
        ? 'assets/kcc20_reference_10_template.json'
        : 'assets/kcc20_standard_template.json')));
    final prefix = template['prefix'].toString(),
        suffix = template['suffix'].toString();
    final senderScript = first.redeemScript ?? '';
    if (!senderScript.startsWith(prefix) ||
        senderScript.length < prefix.length + 224)
      throw StateError('Missing sender token identity.');
    final extension =
        senderScript.substring(prefix.length + 160, prefix.length + 224);
    final b = await balance(cid, owner, isCancelled: isCancelled);
    for (final raw in (b['outputs'] as List? ?? []).whereType<Map>().take(32)) {
      if (isCancelled?.call() == true)
        throw StateError('KCC20 preparation cancelled.');
      final id = raw['txid']?.toString() ?? '',
          index = int.tryParse(raw['output_index'].toString());
      if (!_hex64.hasMatch(id) || index == null || index < 0) continue;
      final tx = map((await get('$base/tokens/$cid/transactions/$id',
          isCancelled: isCancelled, priority: true))['data']);
      final rows = (tx['outputs'] as List? ?? [])
          .whereType<Map>()
          .where((s) =>
              s['io_index'] == index &&
              s['covenant_id'] == cid &&
              s['actor'] == 'KCC20')
          .toList();
      if (tx['txid'] != id || rows.length != 1) continue;
      final s = rows.single,
          units = BigInt.tryParse(s['token_amount'].toString()),
          guard = s['borrow_guard']?.toString() ?? '';
      if (s['state_hash_verified'] != true ||
          s['template_hash'] != (ten ? tenTemplateHash : templateHash) ||
          s['owner_scheme'] != 0 ||
          s['owner_value'] != owner ||
          s['borrow_scheme'] != 1 ||
          !_hex64.hasMatch(guard) ||
          s['extension_commitment'] != extension ||
          units == null ||
          units < BigInt.zero ||
          units + BigInt.from(amount) > BigInt.from(0x7fffffffffffffff) ||
          s['token_amount'].toString() != raw['balance_raw'].toString())
        continue;
      final encoded = BigInt.parse(
          List.generate(8, (i) => guard.substring(i * 2, i * 2 + 2))
              .reversed
              .join(),
          radix: 16);
      final threshold = encoded >> 63 != BigInt.zero ? BigInt.zero : encoded;
      if (BigInt.from(amount) <= threshold) continue;
      final origin =
          await get('$node/transactions/$id', isCancelled: isCancelled);
      final outputs = (origin['outputs'] as List? ?? [])
          .whereType<Map>()
          .where((o) => o['index'] == index)
          .toList();
      if (origin['transaction_id'] != id ||
          origin['is_accepted'] != true ||
          outputs.length != 1) continue;
      final o = outputs.single,
          outputAddress = o['script_public_key_address']?.toString() ?? '';
      if (o['covenant_id'] != cid ||
          o['amount'].toString() != raw['amount_sompi'].toString() ||
          !RegExp(r'^kaspa:[a-z0-9]{61,63}$').hasMatch(outputAddress)) continue;
      final response = await client
          .get(Uri.parse('$node/addresses/$outputAddress/utxos'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200)
        throw StateError('Recipient cell verification unavailable.');
      final live = (jsonDecode(response.body) as List)
          .whereType<Map>()
          .where((r) =>
              map(r['outpoint'])['transactionId'] == id &&
              map(r['outpoint'])['index'] == index)
          .toList();
      if (live.length != 1) continue;
      final e = map(live.single['utxoEntry']);
      if (e['isCoinbase'] != false ||
          map(e['scriptPublicKey'])['scriptPublicKey'] !=
              o['script_public_key'] ||
          e['amount'].toString() != o['amount'].toString()) continue;
      final little = List.generate(
          8,
          (i) => ((units >> (8 * i)).toInt() & 255)
              .toRadixString(16)
              .padLeft(2, '0')).join();
      return Kcc20CellRecord(
          covenantId: cid,
          transactionId: id,
          index: index,
          valueSompi: int.parse(e['amount'].toString()),
          blockDaaScore: int.parse(e['blockDaaScore'].toString()),
          scriptPublicKey: o['script_public_key'].toString(),
          tokenAmount: units.toInt(),
          redeemScript:
              '${prefix}08${little}20${owner}0100010120${guard}20$extension$suffix');
    }
    return null;
  }

  Future<Kcc20Step> signingBatch(String address, String cid, int amount,
      {bool Function()? isCancelled,
      void Function(String)? onProgress,
      bool kassealOwnerOnly = false,
      bool fullPlan = false}) async {
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
    final seen = <String>{};
    final outputs = (b['outputs'] as List? ?? [])
        .whereType<Map>()
        .where((r) => r['balance_raw'].toString() != '0')
        .toList();
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
    if (fullPlan && requiredCells > 65) {
      throw StateError(
          'This payment needs more than 65 token cells. Split the amount into smaller payments.');
    }
    if (outputs.isEmpty) throw StateError('No standard KCC20 token outputs.');
    final first = outputs.first;
    final firstPath = '$base/tokens/$cid/transactions/${first['txid']}';
    final firstResponse = await get(firstPath, isCancelled: cancelled);
    final firstDetail = map(firstResponse['data']);
    final firstStates = (firstDetail['outputs'] as List? ?? [])
        .whereType<Map>()
        .where((r) =>
            r['io_index'] == first['output_index'] &&
            r['covenant_id'] == cid &&
            r['actor'] == 'KCC20')
        .toList();
    if (firstDetail['txid'] != first['txid'] ||
        firstStates.length != 1 ||
        firstStates.single['state_hash_verified'] != true) {
      throw StateError('Missing KCC20 program proof.');
    }
    final programHash = firstStates.single['template_hash'];
    final ten = programHash == tenTemplateHash;
    if (!ten && programHash != templateHash) {
      throw StateError('Unsupported KCC20 program configuration.');
    }
    if (kassealOwnerOnly && ten) {
      throw StateError('Unsupported Kasseal token program.');
    }
    final programId = kassealOwnerOnly
        ? kassealOwnerTemplateId
        : ten
            ? tenTemplateId
            : templateId;
    final limit = ten ? 10 : 3;
    final template = map(jsonDecode(await rootBundle.loadString(ten
        ? 'assets/kcc20_reference_10_template.json'
        : 'assets/kcc20_standard_template.json')));
    if (template['referenceCommit'] != reference) {
      throw StateError('Incorrect local KCC20 template.');
    }
    final mandatory = fullPlan ? requiredCells : math.min(limit, requiredCells);
    final candidates = outputs.take(mandatory).toList();
    // An ordinary payment has room up to its verified contract limit. Fill spare
    // slots with the smallest compatible cells, without increasing the payment.
    for (final raw in outputs.reversed) {
      if (candidates.length >= limit) break;
      if (!candidates.contains(raw)) candidates.add(raw);
    }
    final reads = <String, Future<Map<String, dynamic>>>{};
    reads[firstPath] = Future.value(firstResponse);
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
            state['template_hash'] != programHash ||
            state['owner_value'] != owner ||
            state['owner_scheme'] != 0 ||
            units == null ||
            units <= BigInt.zero ||
            units > BigInt.from(0x7fffffffffffffff) ||
            state['token_amount'].toString() != raw['balance_raw'].toString()) {
          throw StateError(
              'KCC20 ownership or token amount differs from the reconstructed state.');
        }
        final borrowScheme = state['borrow_scheme'],
            guard = state['borrow_guard']?.toString() ?? '';
        if (borrowScheme is! int ||
            borrowScheme < 0 ||
            borrowScheme > 3 ||
            !_hex64.hasMatch(guard))
          throw StateError('Invalid KCC20 borrowing policy.');
        final extension = state['extension_commitment']?.toString() ?? '';
        if (!_hex64.hasMatch(extension)) {
          throw StateError('KCC20 extension commitment is missing.');
        }
        if (kassealOwnerOnly &&
            (borrowScheme != 0 ||
                guard != '0' * 64 ||
                extension != '0' * 64 ||
                units > BigInt.from(1200000000))) {
          throw StateError('Unsupported Kasseal token policy.');
        }
        final bytes = <int>[
          8,
          ...List.generate(8, (i) => (units >> (8 * i)).toInt() & 255),
          32
        ];
        String hex(List<int> b) =>
            b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
        final redeem =
            '${template['prefix']}${hex(bytes)}${owner}010001${borrowScheme.toRadixString(16).padLeft(2, '0')}20${guard}20$extension${template['suffix']}';
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

    final verified = <(Kcc20CellRecord, String)?>[];
    for (var offset = 0; offset < candidates.length; offset += 3) {
      verified.addAll(await Future.wait([
        for (var i = offset; i < math.min(offset + 3, candidates.length); i++)
          verify(candidates[i], i)
      ]));
    }
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
        transactionCount: kcc20TransactionCount(requiredCells, limit),
        inputLimit: limit,
        templateId: programId);
  }
}
