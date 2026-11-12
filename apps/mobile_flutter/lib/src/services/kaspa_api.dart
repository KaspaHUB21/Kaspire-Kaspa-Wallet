import 'dart:async';
import 'dart:convert';
import 'kns_holdings_loader.dart';
import 'dotk_service.dart';
import 'kasparocket_service.dart';
import 'kasseal_service.dart';
import 'dex_display_price.dart';
import 'kasforge_service.dart';
import 'kforge_service.dart';
import 'krc721_reads.dart';
import 'kron_holdings.dart';
import 'kcc20_standard_service.dart';
import 'kcc20_compound.dart';
import 'activity_store.dart';

import 'package:http/http.dart' as http;

import '../models/wallet_snapshot.dart';
import '../models/network_diagnostics.dart';
import '../number_format.dart';
import 'network_settings.dart';
import 'app_settings.dart';

class KaspaApiException implements Exception {
  KaspaApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class KaspaApi {
  KaspaApi({
    http.Client? client,
    String? baseUrl,
    this.tokenExplorerBaseUrl = 'https://kaspatoken.kaslab.space/api',
    this.kasplexBaseUrl = 'https://api.kasplex.org/v1',
    this.kccKrc20BaseUrl = 'https://kaspire.kaslab.space/api/krc20-fallback',
    this.knsIndexerBaseUrl = 'https://api.knsdomains.org/mainnet',
    this.krc721IndexerBaseUrl =
        'https://krc721-indexer.kaspa.com/api/v1/krc721/mainnet',
    this.krc721ReadBaseUrl = 'https://kaspire.kaslab.space/krc721-read-v1',
    this.krc721CacheBaseUrl =
        'https://krc721-cache.kaspa.com/krc721/mainnet/optimized',
    this.kaspaComBaseUrl = 'https://api.kaspa.com',
    this.nftMetadataBaseUrl = 'https://api.kaspa.com',
    this.kascovBaseUrl = 'https://kascov.io/data/mainnet',
    this.kronIndexerBaseUrl = 'https://idx.kron.technology/v1/kcc20',
    this.kasvioBaseUrl = 'https://kasvio.network',
    this.toccataBroadcastUrl =
        'https://gothdag.kaslab.space/api/covenant-broadcast',
  })  : _baseUrlOverride = baseUrl,
        _client = client ?? http.Client();

  final http.Client _client;
  final String? _baseUrlOverride;
  String get baseUrl => _baseUrlOverride ?? NetworkSettings.kaspaRestUrl;
  final String tokenExplorerBaseUrl;
  final String kasplexBaseUrl;
  final String kccKrc20BaseUrl;
  final String knsIndexerBaseUrl;
  final String krc721IndexerBaseUrl;
  final String krc721ReadBaseUrl;
  Krc721Reads get nftReads => Krc721Reads(_client,
      localBase: krc721ReadBaseUrl,
      officialBase: krc721IndexerBaseUrl,
      metadataBase: nftMetadataBaseUrl);
  final String krc721CacheBaseUrl;
  final String kaspaComBaseUrl;
  final String nftMetadataBaseUrl;
  final String kascovBaseUrl;
  final String kronIndexerBaseUrl;
  final String kasvioBaseUrl;
  KronHoldings get kronHoldings =>
      KronHoldings(_client, indexer: kronIndexerBaseUrl, kasvio: kasvioBaseUrl);
  Kcc20StandardService get standardKcc20 => Kcc20StandardService(_client,
      base: '$kasvioBaseUrl/api/kcc20/v4',
      node: '$baseUrl/local-node',
      kascovBase: kascovBaseUrl);
  Future<Kcc20CellRecord?> loadKcc20BorrowedReceive(String recipient,
          String cid, int amount, Kcc20CellRecord first, String templateId,
          {bool Function()? isCancelled}) =>
      standardKcc20.borrowedReceive(recipient, cid, amount, first, templateId,
          isCancelled: isCancelled);
  Future<List<Kcc20CellRecord>> loadStandardKcc20SigningCells(
          String address, String covenantId, int amount,
          {bool allowCompound = false}) =>
      standardKcc20.signingCells(address, covenantId, amount,
          allowCompound: allowCompound);
  Future<Kcc20Step> loadStandardKcc20SigningBatch(
          String address, String covenantId, int amount,
          {bool Function()? isCancelled,
          void Function(String)? onProgress,
          String? sourceStandard,
          bool fullPlan = false}) =>
      sourceStandard == 'kasparocket-kcc20'
          ? KaspaRocketService(client: _client, mainnet: true).signingBatch(
              address, covenantId, amount,
              isCancelled: isCancelled,
              onProgress: onProgress,
              fullPlan: fullPlan)
          : standardKcc20.signingBatch(address, covenantId, amount,
              isCancelled: isCancelled,
              onProgress: onProgress,
              kassealOwnerOnly: sourceStandard == 'kasseal-kcc20',
              fullPlan: fullPlan);
  Future<void> waitForStandardKcc20Cell(
          String address, String covenantId, String transactionId,
          {bool Function()? isCancelled,
          void Function(String)? onProgress,
          String? sourceStandard}) =>
      sourceStandard == 'kasparocket-kcc20'
          ? KaspaRocketService(client: _client, mainnet: true).waitForCell(
              address, covenantId, transactionId,
              isCancelled: isCancelled, onProgress: onProgress)
          : standardKcc20.waitForCell(address, covenantId, transactionId,
              isCancelled: isCancelled, onProgress: onProgress);
  final String toccataBroadcastUrl;
  Future<Map<String, double>>? _floorPrices;

  DotkService get dotk => DotkService(client: _client, nodeBaseUrl: baseUrl);

  List<WalletAsset> _alphabeticalAssets(Iterable<WalletAsset> assets) =>
      alphabeticalWalletAssets(assets);

  static String _normalizeScriptPublicKey(Object? value) {
    final script = value?.toString().trim().toLowerCase() ?? '';
    // KCC20 indexers serialize Kaspa ScriptPublicKey as version (u16) +
    // script, while the node endpoints expose the raw script bytes.
    return script.startsWith('0000') ? script.substring(4) : script;
  }

  Future<WalletSnapshot> loadWallet(
    String address, {
    int transactionLimit = 20,
    bool includeNativeTransactions = true,
    bool includeAssetHistory = true,
    bool includeMarketData = true,
    void Function(WalletSnapshot)? onProgress,
  }) async {
    final testnet = NetworkSettings.isTestnet;
    Object? progressiveTokens;
    _Kcc20Wallet? progressiveCovenants;
    var progressiveUtxos = 0;
    var progressiveDotk = <DotkName>[];
    String? dotkWarning;
    var dotkLoaded = false;
    Set<String> loadedCategories(Object? tokens) {
      final data = _map(_map(tokens)['data']);
      return {
        if (data['krc20_read_succeeded'] == true) 'krc20',
        if (data['krc721_read_succeeded'] == true) 'krc721',
        if (data['kns_read_succeeded'] == true) 'kns',
        if (dotkLoaded) 'dotk',
        if (progressiveCovenants?.coverageComplete == true) 'kcc20',
      };
    }

    void publish() {
      if (onProgress == null) return;
      final parsed = _parseAssets(progressiveTokens);
      List<WalletTransaction> tokenHistory = const [];
      try {
        tokenHistory = _parseTokenTransactions(progressiveTokens, address);
      } on KaspaApiException {
        // The final snapshot reports integrity errors. Never block another
        // protocol's already validated history on a malformed token response.
      }
      onProgress(WalletSnapshot(
        balanceSompi: 0,
        kasUsd: null,
        fiatCode: AppSettings.fiatCurrency.value.code,
        fiatSymbol: AppSettings.fiatCurrency.value.symbol,
        usdToFiat: double.nan,
        transactions: mergeWalletActivity(
            tokenHistory, progressiveCovenants?.transactions ?? const []),
        krc20Tokens: parsed.krc20.toList()
          ..sort((a, b) => a.symbol.compareTo(b.symbol)),
        krc721Collections: parsed.krc721,
        knsDomains: parsed.domains,
        dotkNames: progressiveDotk,
        kcc20Tokens:
            _alphabeticalAssets(progressiveCovenants?.assets ?? const []),
        assetWarning: [
          ...parsed.warnings,
          if (progressiveCovenants?.warning.isNotEmpty == true)
            progressiveCovenants!.warning,
        ].where((warning) => warning.isNotEmpty).join(' '),
        assetDiscoveryComplete: progressiveCovenants?.coverageComplete ?? false,
        utxoCount: progressiveUtxos,
        loadedAssetCategories: loadedCategories(progressiveTokens),
      ));
    }

    final results = await Future.wait([
      _getReadOnlyWithFallback(
        '/addresses/${Uri.encodeComponent(address)}/balance',
      ),
      testnet || !includeMarketData
          ? Future<Object?>.value(null)
          : _getReadOnlyWithFallback('/info/price'),
      includeNativeTransactions
          ? _getReadOnlyWithFallback(
              '/addresses/${Uri.encodeComponent(address)}/full-transactions?limit=$transactionLimit&offset=0&resolve_previous_outpoints=light',
            )
          : Future<Object?>.value(const <Object?>[]),
      testnet
          ? Future<Object?>.value(null)
          : _loadTokenWallet(address, includeHistory: includeAssetHistory,
              onProgress: (value) {
              progressiveTokens = value;
              publish();
            }).catchError((_) => null),
      testnet
          ? _loadTestnetDexWallet(address, onProgress: (value) {
              progressiveCovenants = value;
              publish();
            }).then<Object?>((value) => value)
          : _loadMainnetKcc20Wallet(address,
              historyLimit: includeAssetHistory ? transactionLimit : 0,
              onProgress: (value) {
              progressiveCovenants = value;
              publish();
            }).then<Object?>((value) => value).catchError((_) => null),
      testnet || !includeAssetHistory
          ? Future<Object?>.value(const <WalletTransaction>[])
          : loadKronTransactions(address, limit: transactionLimit)
              .timeout(const Duration(seconds: 20))
              .catchError((_) => const <WalletTransaction>[]),
      loadUtxos(address).then((value) {
        progressiveUtxos = (jsonDecode(value) as List).length;
        publish();
        return value;
      }).catchError((_) => '[]'),
      (includeMarketData
              ? _loadUsdExchangeRate(AppSettings.fiatCurrency.value)
              : Future<double>.value(double.nan))
          .catchError(
        (_) => double.nan,
      ),
      testnet
          ? Future<Object?>.value(null)
          : dotk.namesOf(address).then<Object?>((names) {
              dotkLoaded = true;
              progressiveDotk = names;
              publish();
              return names;
            }).catchError((_) {
              dotkWarning =
                  'dot.k names are temporarily unavailable. Pull to refresh to retry.';
              return null;
            }),
    ]);
    final balanceJson = results[0];
    final priceJson = results[1];
    final transactionJson = results[2];
    final tokenWallet = results[3];
    final kcc20Wallet = results[4] as _Kcc20Wallet?;
    final kronTransactions = results[5] as List<WalletTransaction>;
    final utxoCount = (jsonDecode(results[6] as String) as List).length;
    final currency = AppSettings.fiatCurrency.value;
    final usdToFiat = results[7] as double;
    final balanceSompi = _asInt(_map(balanceJson)['balance']);
    final kasUsd = _asDouble(_map(priceJson)['price']);
    if (balanceSompi < 0) {
      throw KaspaApiException(
        'The Kaspa endpoint returned an impossible negative balance.',
      );
    }
    if (kasUsd != null && (!kasUsd.isFinite || kasUsd < 0)) {
      throw KaspaApiException(
        'The Kaspa endpoint returned an invalid market price.',
      );
    }
    var assets = const _WalletAssets(
      krc20: [],
      krc721: [],
      domains: [],
      warnings: [],
    );
    final tokenIntegrityWarnings = <String>[];
    try {
      assets = _parseAssets(tokenWallet);
      tokenIntegrityWarnings.addAll(assets.warnings);
    } on KaspaApiException catch (error) {
      tokenIntegrityWarnings.add(
        'KRC/KNS indexer response was rejected: ${error.message}',
      );
    }
    final nativeTransactions = parseTransactions(transactionJson, address);
    var tokenTransactions = <WalletTransaction>[];
    try {
      tokenTransactions = _parseTokenTransactions(tokenWallet, address);
    } on KaspaApiException catch (error) {
      tokenIntegrityWarnings.add(
        'KRC/KNS activity was rejected: ${error.message}',
      );
    }
    final krc20 = includeMarketData
        ? await Future.wait(
            assets.krc20.map((asset) => _withTokenMarket(asset, kasUsd)))
        : assets.krc20.toList();
    krc20.sort((a, b) => a.symbol.compareTo(b.symbol));
    final assetWarnings = <String>[
      if (dotkWarning != null) dotkWarning!,
      if (!testnet && tokenWallet == null)
        'KRC-20, KRC-721 and KNS data is temporarily unavailable.',
      ...tokenIntegrityWarnings,
      if (kcc20Wallet == null)
        'KCC20 covenant data is temporarily unavailable.',
      if (kcc20Wallet != null && kcc20Wallet.warning.isNotEmpty)
        kcc20Wallet.warning,
    ];
    return WalletSnapshot(
      balanceSompi: balanceSompi,
      kasUsd: kasUsd,
      usdToFiat: usdToFiat,
      fiatCode: currency.code,
      fiatSymbol: currency.symbol,
      transactions: [
        ...nativeTransactions,
        ...tokenTransactions,
        ...?kcc20Wallet?.transactions,
        ...kronTransactions,
      ]..sort((a, b) => b.timestamp.compareTo(a.timestamp)),
      krc20Tokens: krc20,
      kcc20Tokens: _alphabeticalAssets(kcc20Wallet?.assets ?? const []),
      krc721Collections: assets.krc721,
      knsDomains: assets.domains,
      dotkNames: progressiveDotk,
      assetWarning: assetWarnings.isEmpty ? null : assetWarnings.join(' '),
      assetDiscoveryComplete: kcc20Wallet?.coverageComplete ?? false,
      hasMoreTransactions: includeNativeTransactions &&
          nativeTransactions.length >= transactionLimit,
      utxoCount: utxoCount,
      loadedAssetCategories: loadedCategories(tokenWallet),
    );
  }

  Future<_Kcc20Wallet> _loadTestnetDexWallet(String walletAddress,
      {required void Function(_Kcc20Wallet) onProgress}) async {
    final address = NetworkSettings.addressForNetwork(walletAddress);
    final groups = <String, List<WalletAsset>>{};
    final warnings = <String, String>{};
    _Kcc20Wallet snapshot() => _Kcc20Wallet(
          assets: groups.values.expand((rows) => rows).toList(),
          transactions: const [],
          warning: [
            ...warnings.values,
            if (groups.values
                .expand((rows) => rows)
                .any((a) => !a.discoveryComplete))
              'TN10 DEX balances are indexer-reported. Generic transfers require independently verified signing cells.',
          ].join(' '),
        );
    Future<void> load(String source, Future<List<WalletAsset>> task) async {
      try {
        groups[source] = await task;
      } catch (_) {
        warnings[source] =
            '$source token balances are temporarily unavailable; this does not mean zero.';
      }
      onProgress(snapshot());
    }

    await Future.wait([
      load('Kasseal', KassealService(client: _client).walletAssets(address)),
      load('KaspaRocket',
          KaspaRocketService(client: _client).walletAssets(address)),
      if (KasForgeService.enabled)
        load(
            'KasForge', KasForgeService(client: _client).walletAssets(address)),
      if (KForgeService.enabled)
        load(
            'KForge',
            KForgeService(client: _client).walletAssets(address,
                onProgress: (assets) {
              groups['KForge'] = assets;
              onProgress(snapshot());
            }, onWarning: (warning) {
              warnings['KForge metadata'] = warning;
              onProgress(snapshot());
            })),
    ]);
    return snapshot();
  }

  /// Loads only the information required by the balance card. This deliberately
  /// does not wait for asset indexers, UTXOs or transaction history.
  Future<WalletSnapshot> loadWalletBalance(
    String address, {
    Future<int>? balanceSompi,
  }) async {
    final testnet = NetworkSettings.isTestnet;
    final results = await Future.wait([
      balanceSompi ?? loadBalanceSompi(address),
      testnet
          ? Future<Object?>.value(null)
          : _getReadOnlyWithFallback('/info/price'),
      _loadUsdExchangeRate(AppSettings.fiatCurrency.value).catchError(
        (_) => double.nan,
      ),
    ]);
    final loadedBalanceSompi = results[0] as int;
    final kasUsd = _asDouble(_map(results[1])['price']);
    if (kasUsd != null && (!kasUsd.isFinite || kasUsd < 0)) {
      throw KaspaApiException(
        'The Kaspa endpoint returned an invalid market price.',
      );
    }
    final currency = AppSettings.fiatCurrency.value;
    return WalletSnapshot(
      balanceSompi: loadedBalanceSompi,
      kasUsd: kasUsd,
      usdToFiat: results[2] as double,
      fiatCode: currency.code,
      fiatSymbol: currency.symbol,
      transactions: const [],
      krc20Tokens: const [],
      kcc20Tokens: const [],
      krc721Collections: const [],
      knsDomains: const [],
    );
  }

  /// Fast path for the native KAS amount. Market data and every indexer are
  /// intentionally excluded so the primary balance cannot be held back by an
  /// unrelated service.
  Future<int> loadBalanceSompi(String address) async {
    final json = await _getReadOnlyWithFallback(
      '/addresses/${Uri.encodeComponent(address)}/balance',
    );
    final balance = _asInt(_map(json)['balance']);
    if (balance < 0) {
      throw KaspaApiException(
        'The Kaspa endpoint returned an impossible negative balance.',
      );
    }
    return balance;
  }

  Future<int> loadBalanceSompiForAddresses(
    Iterable<String> addresses,
  ) async {
    final unique = addresses.map((item) => item.toLowerCase()).toSet();
    final balances = await Future.wait(unique.map(loadBalanceSompi));
    var total = 0;
    for (final balance in balances) {
      total = total + balance;
      if (total < 0) {
        throw KaspaApiException("The aggregated Kaspa balance overflowed.");
      }
    }
    return total;
  }

  Future<String> loadUtxosForAddresses(Iterable<String> addresses) async {
    final unique = addresses.map((item) => item.toLowerCase()).toSet();
    final responses = await Future.wait(unique.map(loadUtxos));
    final merged = <String, Map<String, Object?>>{};
    for (final response in responses) {
      for (final raw in (jsonDecode(response) as List).whereType<Map>()) {
        final item = raw.cast<String, Object?>();
        final outpoint = _map(item["outpoint"]);
        final key = "${outpoint["transactionId"]}:${outpoint["index"]}";
        if (key != "null:null") merged[key] = item;
      }
    }
    return jsonEncode(merged.values.toList());
  }

  Future<List<WalletTransaction>> loadNativeTransactionsForAddresses(
    Iterable<String> addresses, {
    int limit = 20,
    void Function(List<WalletTransaction>)? onProgress,
    void Function(String)? onWarning,
  }) async {
    final unique = addresses.map((item) => item.toLowerCase()).toSet();
    final merged = <String, Map<String, Object?>>{};
    final failed = <String>{};
    List<WalletTransaction> result() => (parseTransactionsForAddresses(
          merged.values.toList(),
          unique,
        )..sort((left, right) => right.timestamp.compareTo(left.timestamp)))
            .take(limit)
            .toList();
    // Bound address fan-out; do not discard a healthy address because a
    // different rotated address is unavailable or rate-limited.
    final pending = unique.iterator;
    Future<void> worker() async {
      while (pending.moveNext()) {
        final address = pending.current;
        try {
          for (var offset = 0; offset < limit;) {
            final size = (limit - offset).clamp(1, 100);
            final response = await _getReadOnlyWithFallback(
              "/addresses/${Uri.encodeComponent(address)}/full-transactions?limit=$size&offset=$offset&resolve_previous_outpoints=light",
              validate: (raw) => parseTransactionsForAddresses(
                  _nativeHistoryRows(raw), unique),
            );
            final rows = _nativeHistoryRows(response);
            for (final raw in rows.cast<Map>()) {
              final item = raw.cast<String, Object?>();
              final id =
                  (item['transaction_id'] ?? item['id'] ?? '').toString();
              if (id.isNotEmpty) merged[id] = item;
            }
            onProgress?.call(result());
            offset += rows.length;
            if (rows.length < size) break;
          }
        } catch (_) {
          failed.add(address);
        }
      }
    }

    await Future.wait(
        List.generate(unique.length.clamp(0, 4), (_) => worker()));
    if (failed.isNotEmpty) {
      final message = failed.length == unique.length
          ? 'KAS history is temporarily unavailable. Please retry.'
          : 'KAS history is incomplete: ${failed.length} account address lookup(s) failed. Please retry.';
      if (failed.length == unique.length || onWarning == null) {
        throw KaspaApiException(message);
      }
      onWarning(message);
    }
    return result();
  }

  static List _nativeHistoryRows(Object? response) {
    final rows = response is List ? response : _map(response)['transactions'];
    if (rows is! List || rows.any((row) => row is! Map)) {
      throw KaspaApiException('Invalid KAS history response.');
    }
    return rows;
  }

  Future<List<WalletTransaction>> loadNativeTransactions(
    String address, {
    int limit = 20,
  }) async {
    final json = await _getReadOnlyWithFallback(
      '/addresses/${Uri.encodeComponent(address)}/full-transactions?limit=$limit&offset=0&resolve_previous_outpoints=light',
    );
    return parseTransactions(json, address);
  }

  Future<double> _loadUsdExchangeRate(FiatCurrency currency) async {
    if (currency == FiatCurrency.usd) return 1;
    final response = await _client
        .get(Uri.parse('https://open.er-api.com/v6/latest/USD'))
        .timeout(const Duration(seconds: 8));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KaspaApiException('Currency rates are temporarily unavailable.');
    }
    final envelope = _map(jsonDecode(response.body));
    final rates = _map(envelope['rates']);
    final rate = _asDouble(rates[currency.code]);
    if (rate == null || !rate.isFinite || rate <= 0) {
      throw KaspaApiException('The selected currency rate is unavailable.');
    }
    return rate;
  }

  Future<String> resolveWalletInput(String input) async {
    final normalized = input.trim().toLowerCase();
    final prefix = NetworkSettings.isTestnet ? 'kaspatest' : 'kaspa';
    if (RegExp('^$prefix:[a-z0-9]{61,63}\$').hasMatch(normalized)) {
      return normalized;
    }
    if (NetworkSettings.isTestnet) {
      throw KaspaApiException('Enter a valid TN10 kaspatest: address.');
    }
    if (normalized.endsWith('.k')) {
      if (NetworkSettings.isEvm) {
        throw KaspaApiException(
            'dot.k payments are available on Kaspa Layer 1 only.');
      }
      final network = NetworkSettings.network.value;
      final resolved = await dotk.resolve(normalized);
      if (NetworkSettings.network.value != network) {
        throw KaspaApiException('Network changed. Review the recipient again.');
      }
      return resolved.address;
    }
    if (!_isKnsName(normalized)) {
      throw KaspaApiException('Enter a Kaspa address, name.kas or name.k.');
    }
    final response = _map(await _loadTokenWallet(normalized));
    final data = _map(response['data']);
    final address = (data['address'] ?? '').toString().toLowerCase();
    if (!RegExp(r'^kaspa:[a-z0-9]{61,63}$').hasMatch(address)) {
      throw KaspaApiException('KNS domain not found or it has no Kaspa owner.');
    }
    return address;
  }

  Future<Object?> _loadTokenWallet(
    String addressOrDomain, {
    void Function(Object?)? onProgress,
    bool includeHistory = true,
  }) async {
    // Query the protocol indexers directly. KaspaToken remains an independent
    // compatibility source for metadata and activity that an upstream does
    // not expose, but wallet discovery no longer depends on that aggregator.
    final results = await Future.wait<Object?>([
      _loadTokenWalletFromUpstreams(addressOrDomain,
              includeHistory: includeHistory, onProgress: onProgress)
          .then<Object?>((value) => value)
          .catchError((_) => null),
      // The aggregator supplies optional history/metadata. A holdings-only
      // send form does not need to wait for that extra request.
      (includeHistory
              ? _loadTokenWalletFromKaspaToken(addressOrDomain)
              : Future<Object?>.value(null))
          .then<Object?>((value) => value)
          .timeout(const Duration(seconds: 8))
          .catchError((_) => null),
    ]);
    final direct = results[0];
    final explorer = results[1];
    if (direct == null && explorer == null) {
      throw KaspaApiException(
        'KRC-20, KRC-721 and KNS indexers are temporarily unavailable.',
      );
    }
    final merged = _mergeTokenWalletSources(direct, explorer, addressOrDomain);
    onProgress?.call(merged);
    return merged;
  }

  Future<Object?> _loadTokenWalletFromKaspaToken(
    String addressOrDomain,
  ) async {
    final response = await _client
        .get(
          Uri.parse(
            '$tokenExplorerBaseUrl/wallet/krc20/${Uri.encodeComponent(addressOrDomain)}',
          ),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KaspaApiException('KaspaToken returned ${response.statusCode}');
    }
    return jsonDecode(response.body);
  }

  Future<Object?> _loadTokenWalletFromUpstreams(
    String addressOrDomain, {
    void Function(Object?)? onProgress,
    bool includeHistory = true,
  }) async {
    var address = addressOrDomain.trim().toLowerCase();
    if (_isKnsName(address)) {
      final result = _map(await _externalGet(
        knsIndexerBaseUrl,
        '/api/v1/assets',
        query: {
          'asset': address,
          'page': '1',
          'pageSize': '10',
          'type': 'domain',
        },
      ));
      final data = _map(result['data']);
      final exact = (data['assets'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => item.cast<String, Object?>())
          .where((item) =>
              (item['asset'] ?? item['name'])?.toString().toLowerCase() ==
              address)
          .firstOrNull;
      final owner = exact?['owner']?.toString().toLowerCase();
      if (owner == null ||
          !RegExp(r'^kaspa:[a-z0-9]{61,63}$').hasMatch(owner)) {
        throw KaspaApiException('KNS domain not found or has no owner.');
      }
      address = owner;
    }
    if (!RegExp(r'^kaspa:[a-z0-9]{61,63}$').hasMatch(address)) {
      throw KaspaApiException('Invalid Kaspa wallet address.');
    }

    final progress = <String, Object?>{'address': address};
    final warnings = <String>[];
    var knsComplete = true;
    void emit() => onProgress?.call({
          'data': Map<String, Object?>.of(progress),
          'warnings': List<String>.of(warnings),
        });
    Future<List<Map<String, Object?>>> track(
        String key, Future<List<Map<String, Object?>>> future) async {
      final rows = await future;
      progress[key] = rows;
      emit();
      return rows;
    }

    // Kasplex is authoritative while it is healthy. The authenticated mirror
    // is deliberately cold: do not contact it unless the primary request
    // fails or returns an unusable response.
    final tokenList = _loadKrc20HoldingsRows(address);
    final transactionList = !includeHistory
        ? Future<List<Map<String, Object?>>>.value([])
        : _loadKrc20WalletTransactions(kasplexBaseUrl, address)
            .timeout(const Duration(seconds: 8))
            .catchError(
              (_) => _loadKrc20WalletTransactions(kccKrc20BaseUrl, address)
                  .timeout(const Duration(seconds: 8)),
            );
    final results = await Future.wait<List<Map<String, Object?>>>([
      track(
          'tokens',
          tokenList.then((rows) {
            progress['krc20_read_succeeded'] = true;
            return rows;
          }).catchError((_) {
            warnings.add(
                'KRC20 balances are temporarily unavailable. Previously loaded balances are retained.');
            return <Map<String, Object?>>[];
          })),
      track(
          'domains',
          _loadKnsWalletDomains(address, onProgress: (rows) {
            progress['domains'] = rows;
            emit();
          }, onWarning: (warning) {
            knsComplete = false;
            warnings.add(warning);
            emit();
          }).then((rows) {
            progress['kns_read_succeeded'] = knsComplete;
            return rows;
          })),
      track(
          'krc721_tokens',
          _loadKrc721WalletHoldings(address)
              .timeout(const Duration(seconds: 12))
              .then((rows) {
            progress['krc721_read_succeeded'] = true;
            return rows;
          }).catchError((_) => <Map<String, Object?>>[])),
      transactionList.catchError((_) => <Map<String, Object?>>[]),
    ]);
    return {
      'data': {
        'address': address,
        'tokens': results[0],
        'domains': results[1],
        'krc721_tokens': results[2],
        'krc721_read_succeeded': progress['krc721_read_succeeded'] == true,
        'krc20_read_succeeded': progress['krc20_read_succeeded'] == true,
        'kns_read_succeeded': progress['kns_read_succeeded'] == true,
        'transactions': results[3],
      },
      'source_mode': 'DIRECT_REDUNDANT',
      'warnings': warnings,
    };
  }

  Object _mergeTokenWalletSources(
    Object? direct,
    Object? explorer,
    String requestedAddress,
  ) {
    final directEnvelope = _map(direct);
    final explorerEnvelope = _map(explorer);
    final directData = _map(directEnvelope['data']);
    final explorerData = _map(explorerEnvelope['data']);

    List<Map<String, Object?>> rows(
      Map<String, Object?> data,
      String key,
    ) =>
        (data[key] as List? ?? const [])
            .whereType<Map>()
            .map((item) => item.cast<String, Object?>())
            .toList();

    final tokens = _mergeRows(
      [rows(explorerData, 'tokens'), rows(directData, 'tokens')],
      (item) => (item['token_id'] ?? item['symbol'] ?? item['ticker'] ?? '')
          .toString()
          .toLowerCase(),
    );
    final domains = _mergeRows(
      [rows(explorerData, 'domains'), rows(directData, 'domains')],
      (item) => (item['asset_id'] ?? item['name'] ?? item['asset'] ?? '')
          .toString()
          .toLowerCase(),
    );
    final krc721 = _mergeRows(
      [
        if (directData['krc721_read_succeeded'] != true)
          rows(explorerData, 'krc721_tokens'),
        rows(directData, 'krc721_tokens'),
      ],
      (item) => (item['token_id'] ?? item['symbol'] ?? item['ticker'] ?? '')
          .toString()
          .toLowerCase(),
    );
    final transactions = _mergeRows(
      [
        rows(explorerData, 'transactions'),
        rows(directData, 'transactions'),
      ],
      (item) => item['id']?.toString() ?? '',
    );
    final resolvedAddress =
        (directData['address'] ?? explorerData['address'] ?? requestedAddress)
            .toString()
            .toLowerCase();
    return {
      'data': {
        'address': resolvedAddress,
        'tokens': tokens,
        'domains': domains,
        'krc721_tokens': krc721,
        'transactions': transactions,
        'krc20_read_succeeded': directData['krc20_read_succeeded'] == true,
        'krc721_read_succeeded': directData['krc721_read_succeeded'] == true,
        'kns_read_succeeded': directData['kns_read_succeeded'] == true,
      },
      'source_mode': direct == null ? 'EXPLORER_FALLBACK' : 'DIRECT_REDUNDANT',
      'warnings': <Object?>[
        ...(directEnvelope['warnings'] as List? ?? const []),
        ...(explorerEnvelope['warnings'] as List? ?? const []),
      ],
    };
  }

  List<Map<String, Object?>> _mergeRows(
    List<List<Map<String, Object?>>> sources,
    String Function(Map<String, Object?> item) keyOf,
  ) {
    final merged = <String, Map<String, Object?>>{};
    for (final source in sources) {
      for (final item in source) {
        final key = keyOf(item);
        if (key.isNotEmpty) merged[key] = item;
      }
    }
    return merged.values.toList();
  }

  /// Holdings-only reads for marketplaces. Never wait for unrelated protocols,
  /// transaction history, native balance or market metadata.
  Future<List<WalletAsset>> loadKrc20Holdings(String address) async {
    address = _holdingsAddress(address);
    final rows = await _loadKrc20HoldingsRows(address);
    return _parseAssets({
      'data': {'tokens': rows}
    }).krc20;
  }

  Future<List<Map<String, Object?>>> _loadKrc20HoldingsRows(String address) =>
      _loadKrc20WalletTokens(kasplexBaseUrl, address)
          .timeout(const Duration(seconds: 8))
          .catchError((_) => _loadKrc20WalletTokens(kccKrc20BaseUrl, address)
              .timeout(const Duration(seconds: 8)));

  Future<List<KnsDomain>> loadKnsHoldings(String address,
      {void Function(List<KnsDomain>)? onProgress,
      void Function(String)? onWarning}) async {
    address = _holdingsAddress(address);
    List<KnsDomain> parse(List<Map<String, Object?>> rows) => _parseAssets({
          'data': {'domains': rows}
        }).domains;
    String? warning;
    final rows = await _loadKnsWalletDomains(address,
        onProgress: (rows) => onProgress?.call(parse(rows)),
        onWarning: (value) {
          warning = value;
          onWarning?.call(value);
        });
    // A failed first page is not evidence of an empty wallet.
    if (rows.isEmpty && warning != null) throw KaspaApiException(warning!);
    return parse(rows);
  }

  String _holdingsAddress(String value) {
    final address = value.trim().toLowerCase();
    if (!RegExp(r'^kaspa:[a-z0-9]{61,63}$').hasMatch(address)) {
      throw KaspaApiException('Invalid Kaspa holdings address.');
    }
    return address;
  }

  Future<List<Map<String, Object?>>> _loadKrc20WalletTokens(
    String sourceBaseUrl,
    String address,
  ) async {
    final tokens = <String, Map<String, Object?>>{};
    String? cursor;
    for (var page = 0; page < 20; page++) {
      final raw = _map(await _externalGet(
        sourceBaseUrl,
        sourceBaseUrl == kasplexBaseUrl
            ? '/krc20/address/${Uri.encodeComponent(address)}/tokenlist'
            : '/address/${Uri.encodeComponent(address)}/tokenlist',
        query: {if (cursor != null) 'next': cursor},
      ));
      if (raw['result'] is! List && raw['data'] is! List) {
        throw KaspaApiException('Invalid KRC20 token-list response.');
      }
      final items = _externalItems(raw);
      for (final item in items) {
        final symbol = (item['tick'] ?? item['ticker'] ?? item['symbol'] ?? '')
            .toString()
            .toUpperCase();
        final decimals = _asInt(item['dec'] ?? item['decimals'] ?? 8);
        final rawBalance = (item['balance'] ?? item['amount'])?.toString();
        final integer = BigInt.tryParse(rawBalance ?? '');
        final reportedLocked = item['locked']?.toString();
        final rawLocked = reportedLocked != null &&
                RegExp(r'^[0-9]{1,128}$').hasMatch(reportedLocked)
            ? reportedLocked
            : null;
        final locked = BigInt.tryParse(rawLocked ?? '') ?? BigInt.zero;
        if (symbol.isEmpty ||
            integer == null ||
            integer < BigInt.zero ||
            (integer == BigInt.zero && locked == BigInt.zero) ||
            decimals < 0 ||
            decimals > 18) {
          continue;
        }
        tokens[symbol] = {
          'token_id': 'krc20-${symbol.toLowerCase()}',
          'symbol': symbol,
          'balance': integer.toDouble() / _pow10(decimals),
          'decimals': decimals,
          'raw_balance': rawBalance,
          if (rawLocked != null) 'raw_locked_balance': rawLocked,
        };
      }
      cursor = _externalCursor(raw);
      if (cursor == null || items.isEmpty) break;
    }
    return tokens.values.toList()
      ..sort((left, right) =>
          left['symbol'].toString().compareTo(right['symbol'].toString()));
  }

  Future<List<Map<String, Object?>>> _loadKnsWalletDomains(
    String address, {
    void Function(List<Map<String, Object?>>)? onProgress,
    void Function(String)? onWarning,
  }) async {
    List<Map<String, Object?>> normalize(List<Map<String, Object?>> items) {
      final domains = <String, Map<String, Object?>>{};
      for (final item in items) {
        final name = (item['asset'] ?? item['domain'] ?? item['name'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
        if (!_isKnsName(name)) continue;
        final assetId = (item['assetId'] ?? item['asset_id'])
            ?.toString()
            .trim()
            .toLowerCase();
        domains[assetId != null && assetId.isNotEmpty ? assetId : name] = {
          'name': name,
          'status': item['status'],
          'asset_id': assetId,
        };
      }
      return domains.values.toList()
        ..sort((a, b) => a['name'].toString().compareTo(b['name'].toString()));
    }

    final result = await loadKnsHoldingsPages(
      fetchPage: (page) async => _map(await _externalGet(
        knsIndexerBaseUrl,
        '/api/v1/assets',
        query: {
          'owner': address,
          'page': '$page',
          'pageSize': '100',
          'type': 'domain',
        },
      )),
      onProgress: (rows) => onProgress?.call(normalize(rows)),
    );
    if (result.warning != null) onWarning?.call(result.warning!);
    return normalize(result.records);
  }

  Future<List<Map<String, Object?>>> _loadKrc721WalletHoldings(
    String address,
  ) async {
    final grouped = <String, List<String>>{};
    String? cursor;
    for (var page = 0; page < 100; page++) {
      final raw =
          await nftReads.walletPage(address, cursor: cursor, limit: 500);
      final items = _externalItems(raw);
      for (final item in items) {
        final symbol = (item['tick'] ?? item['ticker'] ?? item['symbol'] ?? '')
            .toString()
            .toUpperCase();
        final tokenId =
            (item['tokenId'] ?? item['id'] ?? item['nftId'])?.toString();
        if (symbol.isNotEmpty && tokenId != null && tokenId.isNotEmpty) {
          grouped.putIfAbsent(symbol, () => []).add(tokenId);
        }
      }
      cursor = _externalCursor(raw);
      if (cursor == null || items.isEmpty) break;
    }
    return grouped.entries
        .map((entry) => <String, Object?>{
              'token_id': 'krc721-${entry.key.toLowerCase()}',
              'symbol': entry.key,
              'balance': entry.value.length,
              'decimals': 0,
              'image_url': entry.value.isEmpty
                  ? null
                  : Krc721Reads.image(entry.key, entry.value.first),
            })
        .toList();
  }

  /// Fresh activity, independent of the cached asset/balance snapshot.
  Future<List<WalletTransaction>> loadSupplementalAssetTransactions(
      String address,
      {int limit = 51}) async {
    if (NetworkSettings.isTestnet || NetworkSettings.isEvm) return [];
    final raw = await _loadTokenWalletFromKaspaToken(address)
        .timeout(const Duration(seconds: 8));
    final data = _map(_map(raw)['data']);
    final rows =
        (data['transactions'] as List? ?? []).whereType<Map>().where((row) {
      final kind = (row['asset_kind'] ?? row['kind'] ?? row['type'] ?? '')
          .toString()
          .toLowerCase();
      return kind.contains('721') || kind.contains('kns');
    }).toList();
    return _parseTokenTransactions({
      'data': {'transactions': rows}
    }, address)
        .take(limit)
        .toList();
  }

  Future<List<WalletTransaction>> loadKrc20Transactions(String address,
      {int limit = 50}) async {
    if (NetworkSettings.isTestnet || NetworkSettings.isEvm) return [];
    final rows = await _loadKrc20WalletTransactions(kasplexBaseUrl, address,
            limit: limit)
        .timeout(const Duration(seconds: 8))
        .catchError((_) =>
            _loadKrc20WalletTransactions(kccKrc20BaseUrl, address, limit: limit)
                .timeout(const Duration(seconds: 8)));
    return _parseTokenTransactions({
      'data': {'transactions': rows}
    }, address);
  }

  Future<List<Map<String, Object?>>> _loadKrc20WalletTransactions(
      String sourceBaseUrl, String address,
      {int limit = 50}) async {
    final transactions = <Map<String, Object?>>[];
    String? cursor;
    for (var page = 0; page < 100 && transactions.length < limit; page++) {
      final raw = _map(await _externalGet(
        sourceBaseUrl,
        sourceBaseUrl == kasplexBaseUrl ? '/krc20/oplist' : '/oplist',
        query: {
          'address': address,
          if (cursor != null) 'next': cursor,
        },
      ));
      final items = _externalItems(raw);
      for (final item in items) {
        final from =
            (item['from'] ?? item['fromAddress'] ?? item['sender'])?.toString();
        final to =
            (item['to'] ?? item['toAddress'] ?? item['receiver'])?.toString();
        final timestamp = _externalTimestamp(item);
        final rawAmount =
            (item['amt'] ?? item['amount'] ?? item['value'])?.toString();
        final decimals = _asInt(item['dec'] ?? item['decimals'] ?? 8);
        final amountInteger = BigInt.tryParse(rawAmount ?? '');
        if (timestamp == null ||
            amountInteger == null ||
            amountInteger < BigInt.zero) {
          continue;
        }
        final symbol = (item['tick'] ?? item['ticker'] ?? item['symbol'] ?? '')
            .toString()
            .toUpperCase();
        transactions.add({
          'id': (item['txid'] ??
                  item['hashRev'] ??
                  item['operationId'] ??
                  item['opScore'] ??
                  '${timestamp.microsecondsSinceEpoch}')
              .toString(),
          'type': 'transfer',
          'token_id': 'krc20-${symbol.toLowerCase()}',
          'token_symbol': symbol,
          'amount': rawTokenDecimal(amountInteger, decimals),
          'from_wallet': from,
          'to_wallet': to,
          'timestamp': timestamp.toUtc().toIso8601String(),
        });
      }
      cursor = _externalCursor(raw);
      if (cursor == null || items.isEmpty) break;
    }
    return transactions.take(limit).toList();
  }

  Future<List<WalletTransaction>> loadKronTransactions(String address,
      {int limit = 200}) async {
    if (NetworkSettings.isTestnet) return [];
    final raw = _map(await _externalGet(
      kronIndexerBaseUrl,
      '/address/${Uri.encodeComponent(address)}/trades',
      query: {'offset': '0', 'limit': limit.toString()},
    ));
    // KRON's address feed supplies KAS volume, NOT the number of tokens.
    // Join exact raw token quantities from Kasvio by covenant, txid and wallet.
    // Never divide KAS volume by a floating point spot price to invent units.
    final exact = <String, WalletTransaction>{};
    final tickers = _externalItems(raw)
        .map((e) => (e['tick'] ?? e['ticker'] ?? '').toString())
        .where((t) => RegExp(r'^[a-zA-Z0-9_-]{1,32}$').hasMatch(t))
        .toSet();
    await Future.wait(tickers.map((ticker) async {
      try {
        final metadata = _externalItems(_map(await _externalGet(
            kronIndexerBaseUrl, '/token/${Uri.encodeComponent(ticker)}')));
        for (final token in metadata) {
          final covenant = token['covenantId']?.toString() ?? '';
          final decimals = int.tryParse(token['dec'].toString());
          if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(covenant) ||
              decimals == null ||
              decimals < 0 ||
              decimals > 18) {
            continue;
          }
          String? cursor;
          var read = 0;
          for (var page = 0; page < 5 && read < limit; page++) {
            final data = _map(await _externalGet(
                kasvioBaseUrl, '/api/kron/v2/tokens/$covenant/trades',
                query: {'limit': '100', if (cursor != null) 'cursor': cursor}));
            final rows = _externalItems(data);
            for (final row in rows) {
              final wallets = row['wallet_addresses'];
              final id = row['txid']?.toString() ?? '';
              final amount =
                  BigInt.tryParse(row['token_amount_raw'].toString());
              final time = int.tryParse(row['time_ms'].toString());
              final side = row['side'];
              if (wallets is! List ||
                  !wallets.contains(address) ||
                  row['token_id'] != covenant ||
                  !RegExp(r'^[0-9a-f]{64}$').hasMatch(id) ||
                  amount == null ||
                  amount <= BigInt.zero ||
                  time == null ||
                  time < 1577836800000 ||
                  time > DateTime.now().millisecondsSinceEpoch + 300000 ||
                  !const ['buy', 'sell'].contains(side)) {
                continue;
              }
              final tx = WalletTransaction(
                  id: id,
                  timestamp: DateTime.fromMillisecondsSinceEpoch(time),
                  amountSompi: 0,
                  incoming: side == 'buy',
                  assetKind: 'KCC20',
                  assetSymbol: ticker.toUpperCase(),
                  tokenId: covenant,
                  displayAmount: formatRawTokenAmount(amount, decimals),
                  operationLabel: side == 'buy' ? 'KRON Buy' : 'KRON Sell',
                  status: TransactionStatus.confirmed);
              exact['$id|$covenant|$side'] = tx;
            }
            read += rows.length;
            final next = _map(data['pagination'])['next_cursor']?.toString();
            if (next == null || next == cursor || rows.isEmpty) break;
            cursor = next;
          }
        }
      } catch (_) {
        /* One unavailable token source must not hide other activity. */
      }
    }));
    final now = DateTime.now();
    final trades = <WalletTransaction>[...exact.values];
    for (final item in _externalItems(raw)) {
      final ticker =
          (item['tick'] ?? item['ticker'] ?? '').toString().toUpperCase();
      final txid = (item['txid'] ?? item['transactionId'] ?? '')
          .toString()
          .toLowerCase();
      final side = item['side']?.toString().toLowerCase();
      if (exact.values.any((tx) =>
          tx.id == txid &&
          tx.assetSymbol == ticker &&
          tx.incoming == (side == 'buy'))) {
        continue;
      }
      final market = item['kind']?.toString().toLowerCase();
      final volume = _asDouble(item['volume']);
      final price = _asDouble(item['price']);
      final timestamp = _externalTimestamp({
        'timestamp': item['ts'] ?? item['timestamp'],
      });
      if (!RegExp(r'^[A-Z0-9_-]{1,32}$').hasMatch(ticker) ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(txid) ||
          !const {'buy', 'sell'}.contains(side) ||
          !const {'curve', 'pool'}.contains(market) ||
          volume == null ||
          !volume.isFinite ||
          volume <= 0 ||
          price == null ||
          !price.isFinite ||
          price <= 0 ||
          timestamp == null ||
          timestamp.isBefore(DateTime.utc(2020)) ||
          timestamp.isAfter(now.add(const Duration(minutes: 5)))) {
        continue;
      }
      trades.add(
        WalletTransaction(
          id: txid,
          timestamp: timestamp,
          amountSompi: 0,
          incoming: side == 'buy',
          assetKind: 'KRON SWAP',
          assetSymbol: ticker,
          tokenId: ticker,
          operationLabel: side == 'buy' ? 'KRON Buy' : 'KRON Sell',
          amountLabelOverride:
              '${formatEnglishDecimal(item['volume'].toString())} KAS volume',
          status: TransactionStatus.confirmed,
        ),
      );
    }
    return trades;
  }

  Future<Object?> _externalGet(
    String base,
    String path, {
    Map<String, String>? query,
  }) async {
    final uri = Uri.parse('$base$path').replace(queryParameters: query);
    final response = await _client.get(uri, headers: const {
      'cache-control': 'no-cache',
      'pragma': 'no-cache',
    }).timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KaspaApiException(
        '${uri.host} returned ${response.statusCode}',
      );
    }
    return jsonDecode(response.body);
  }

  List<Map<String, Object?>> _externalItems(Map<String, Object?> raw) {
    for (final key in const ['result', 'data', 'items', 'list']) {
      final value = raw[key];
      if (value is List) {
        return value
            .whereType<Map>()
            .map((item) => item.cast<String, Object?>())
            .toList();
      }
      if (value is Map) {
        final nested = _externalItems(value.cast<String, Object?>());
        if (nested.isNotEmpty) return nested;
      }
    }
    return const [];
  }

  String? _externalCursor(Map<String, Object?> raw) {
    for (final key in const ['next', 'next_cursor', 'nextCursor', 'offset']) {
      final value = raw[key]?.toString();
      if (value != null && value.isNotEmpty && value != 'null') return value;
    }
    final data = raw['data'];
    return data is Map ? _externalCursor(data.cast<String, Object?>()) : null;
  }

  DateTime? _externalTimestamp(Map<String, Object?> item) {
    final raw = item['timestamp'] ??
        item['blockTime'] ??
        item['mtsAdd'] ??
        item['opScore'];
    if (raw == null) return null;
    final text = raw.toString();
    final number = int.tryParse(text);
    if (number != null) {
      final milliseconds = number > 1000000000000 ? number : number * 1000;
      return DateTime.fromMillisecondsSinceEpoch(milliseconds);
    }
    return DateTime.tryParse(text);
  }

  Future<_Kcc20Wallet> _loadMainnetKcc20Wallet(String address,
      {required int historyLimit,
      void Function(_Kcc20Wallet)? onProgress}) async {
    _Kcc20Wallet? ordinary;
    List<WalletAsset> rocket = const [],
        seal = const [],
        forge = const [],
        kasforge = const [];
    var rocketUnavailable = false;
    var sealUnavailable = false;
    var forgeUnavailable = false;
    var kasforgeUnavailable = false;
    String forgeWarning = '';
    _Kcc20Wallet merged() {
      String key(WalletAsset asset) =>
          (asset.covenantId ?? asset.id ?? asset.symbol).toLowerCase();
      final assets = {
        for (final asset in ordinary?.assets ?? <WalletAsset>[])
          key(asset): asset
      };
      for (final asset in [...rocket, ...seal, ...forge, ...kasforge]) {
        final current = assets[key(asset)];
        if (current == null ||
            !current.discoveryComplete ||
            asset.standard == 'kforge-kcc20' ||
            asset.standard == 'kasforge-kcc20') {
          assets[key(asset)] = asset;
        } else {
          // Preserve independently discovered signing cells while retaining
          // the venue identity and market data needed by the token detail UI.
          assets[key(asset)] = WalletAsset(
            symbol: asset.symbol,
            balance: current.balance,
            kind: current.kind,
            imageUrl: asset.imageUrl ?? current.imageUrl,
            id: current.id,
            decimals: current.decimals,
            rawBalance: current.rawBalance,
            priceKas: asset.priceKas ?? current.priceKas,
            priceUsd: current.priceUsd,
            covenantId: current.covenantId,
            templateHash: current.templateHash,
            validationStatus: current.validationStatus,
            kcc20Cells: current.kcc20Cells,
            discoveryComplete: current.discoveryComplete,
            standard: asset.standard,
            activityOrigins: current.activityOrigins,
          );
        }
      }
      return _Kcc20Wallet(
          assets: _alphabeticalAssets(assets.values.toList()),
          transactions: ordinary?.transactions ?? const [],
          coverageComplete: ordinary?.coverageComplete == true &&
              !rocketUnavailable &&
              !sealUnavailable &&
              !forgeUnavailable &&
              !kasforgeUnavailable,
          signingIssues: {
            ...?ordinary?.signingIssues
          }..removeAll([...rocket, ...seal, ...forge].map((a) => a.covenantId)),
          warning: [
            if (ordinary?.warning.isNotEmpty == true) ordinary!.warning,
            if (rocketUnavailable)
              'KaspaRocket token balances are temporarily unavailable. Pull to refresh.',
            if (sealUnavailable)
              'Kasseal token balances are temporarily unavailable. Pull to refresh.',
            if (forgeUnavailable)
              'KForge token balances are temporarily unavailable. Previously loaded balances are retained.',
            if (kasforgeUnavailable)
              'KasForge token balances are temporarily unavailable. Previously loaded balances are retained.',
            if (forgeWarning.isNotEmpty) forgeWarning,
          ].join(' '));
    }

    void publish() => onProgress?.call(merged());
    await Future.wait([
      if (KasForgeService.enabled)
        KasForgeService(client: _client, mainnet: true)
            .walletAssets(address)
            .then((assets) {
          kasforge = assets;
          publish();
        }).catchError((_) {
          kasforgeUnavailable = true;
          publish();
        }),
      if (KForgeService.enabled)
        KForgeService(client: _client, mainnet: true).walletAssets(address,
            onProgress: (assets) {
          forge = assets;
          publish();
        }, onWarning: (warning) {
          forgeWarning = warning;
          publish();
        }).then((assets) {
          forge = assets;
          publish();
        }).catchError((_) {
          forgeUnavailable = true;
          publish();
        }),
      KassealService(client: _client).walletAssets(address).then((assets) {
        seal = assets;
        publish();
      }).catchError((_) {
        sealUnavailable = true;
        publish();
      }),
      KaspaRocketService(client: _client, mainnet: true)
          .walletAssets(address)
          .then((assets) {
        rocket = assets;
        publish();
      }).catchError((_) {
        rocketUnavailable = true;
        publish();
      }),
      _loadKcc20Wallet(address, historyLimit: historyLimit,
          onProgress: (value) {
        ordinary = value;
        publish();
      }).then((value) {
        ordinary = value;
        publish();
      }).catchError((_) {
        ordinary = const _Kcc20Wallet(
            assets: [],
            transactions: [],
            warning: 'Other KCC20 balances are temporarily unavailable.');
        publish();
      }),
    ]);
    return merged();
  }

  Future<_Kcc20Wallet> _loadKcc20Wallet(
    String address, {
    int historyLimit = 20,
    void Function(_Kcc20Wallet)? onProgress,
  }) async {
    _Kcc20Wallet? kron, standard;
    void publish() {
      final value =
          standard == null ? kron : _withStandardHoldings(kron, standard!);
      if (value != null) onProgress?.call(value);
    }

    await Future.wait<void>([
      kronHoldings.load(address, onProgress: (assets) {
        kron =
            _Kcc20Wallet(assets: assets, transactions: const [], warning: '');
        publish();
      }).then<void>((assets) {
        kron =
            _Kcc20Wallet(assets: assets, transactions: const [], warning: '');
        publish();
      }).catchError((_) {}),
      () async {
        void accept(StandardKcc20Wallet result) {
          standard = _Kcc20Wallet(
              assets: result.assets,
              transactions: result.transactions,
              coverageComplete: result.coverageComplete,
              warning: result.warning);
          publish();
        }

        try {
          // The same reader now falls back per read, including send-time cell
          // and policy proofs. No obsolete legacy decoder or API participates.
          accept(await standardKcc20.load(address,
              historyLimit: historyLimit, onProgress: accept));
        } catch (_) {
          standard = _Kcc20Wallet(
              assets: standard?.assets ?? const [],
              transactions: standard?.transactions ?? const [],
              coverageComplete: false,
              warning:
                  'KCC20 account data is temporarily unavailable from Kasvio and Kascov. Loaded balances are retained; refresh to retry.');
          publish();
        }
      }(),
    ]);
    return _withStandardHoldings(kron, standard!);
  }

  _Kcc20Wallet _withStandardHoldings(
      _Kcc20Wallet? existing, _Kcc20Wallet standard) {
    final ids = standard.assets.map((asset) => asset.covenantId).toSet();
    return _Kcc20Wallet(
      coverageComplete: standard.coverageComplete,
      signingIssues: {...?existing?.signingIssues}..removeAll(ids),
      assets: _alphabeticalAssets([
        ...?existing?.assets.where((asset) => !ids.contains(asset.covenantId)),
        ...standard.assets,
      ]),
      transactions: mergeWalletActivity(
          existing?.transactions ?? const [], standard.transactions),
      warning: [
        if (existing?.warning.isNotEmpty == true) existing!.warning,
        if (standard.warning.isNotEmpty) standard.warning
      ].join(' '),
    );
  }

  /// Token quantities from KRON must not be confused with native UTXO value.
  Future<List<Kcc20CellRecord>> loadKronSigningCells(
      String address, String covenantId, int amount) async {
    final rows = await kronHoldings.transferRows(address, covenantId, amount);
    final cells = <Kcc20CellRecord>[];
    for (final row in rows) {
      final txid = row['outpoint']['transactionId'].toString();
      final index = row['outpoint']['index'] as int;
      final transaction = _map(await _get('/local-node/transactions/$txid'));
      final outputs = transaction['outputs'] as List? ?? const [];
      final output = outputs.whereType<Map>().firstWhere(
          (item) => _nullableInt(item['index']) == index,
          orElse: () => throw KaspaApiException(
              'The local node could not find this KRON output.'));
      final outputAddress =
          (output['script_public_key_address'] ?? output['address'])
              ?.toString();
      if (outputAddress == null) {
        throw KaspaApiException(
            'KRON output address is missing on the local node.');
      }
      final live = await _get(
          '/local-node/addresses/${Uri.encodeComponent(outputAddress)}/utxos');
      final entry =
          (live is List ? live : const []).whereType<Map>().firstWhere(
                (item) =>
                    item['outpoint']?['transactionId'] == txid &&
                    item['outpoint']?['index'] == index,
                orElse: () => throw KaspaApiException(
                    'This KRON output is already spent or pending. Refresh and try again.'),
              )['utxoEntry'] as Map;
      cells.add(Kcc20CellRecord(
        covenantId: covenantId,
        transactionId: txid,
        index: index,
        valueSompi: _asInt(output['amount']),
        blockDaaScore: _asInt(entry['blockDaaScore']),
        scriptPublicKey: _normalizeScriptPublicKey(row['scriptPublicKey']),
        tokenAmount: int.parse(row['amount'].toString()),
        redeemScript: row['redeemScriptHex'].toString(),
      ));
    }
    await verifyKcc20CellsOnOwnNode(cells, covenantId);
    return cells;
  }

  Future<Map<String, Object?>> preflightKcc20(String transactionJson) async {
    final response = await _client
        .post(
          Uri.parse('$kascovBaseUrl/preflight'),
          headers: const {'content-type': 'application/json'},
          body: transactionJson,
        )
        .timeout(const Duration(seconds: 25));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KaspaApiException(
        'Kascov preflight failed (${response.statusCode}): ${response.body}',
      );
    }
    return _map(jsonDecode(response.body));
  }

  Future<WalletAsset> loadTokenMarket(WalletAsset asset) async {
    double? price;
    try {
      price = _asDouble(
          _map(await _getReadOnlyWithFallback('/info/price'))['price']);
    } catch (_) {}
    if (asset.kind == 'KCC20') {
      var tokenPrice = asset.priceKas;
      if (asset.standard == 'kasseal-kcc20' && asset.covenantId != null) {
        try {
          final catalogue = await KassealService(client: _client)
              .searchTokens(asset.covenantId!);
          final row = (catalogue['tokens'] as List? ?? const [])
              .whereType<Map>()
              .where((r) => _map(r['meta'])['covenantId'] == asset.covenantId)
              .singleOrNull;
          if (row != null) tokenPrice = DexDisplayPrice.kassealPriceKas(row);
        } catch (_) {
          /* Display data never changes the asset or signing identity. */
        }
      }
      return WalletAsset(
          symbol: asset.symbol,
          balance: asset.balance,
          kind: asset.kind,
          imageUrl: asset.imageUrl,
          id: asset.id,
          decimals: asset.decimals,
          rawBalance: asset.rawBalance,
          rawLockedBalance: asset.rawLockedBalance,
          priceKas: tokenPrice,
          priceUsd: tokenPrice == null || price == null
              ? asset.priceUsd
              : tokenPrice * price,
          covenantId: asset.covenantId,
          templateHash: asset.templateHash,
          validationStatus: asset.validationStatus,
          kcc20Cells: asset.kcc20Cells,
          activityOrigins: asset.activityOrigins,
          discoveryComplete: asset.discoveryComplete,
          standard: asset.standard);
    }
    return _withTokenMarket(asset, price);
  }

  Future<double> loadSelectedFiatRate() =>
      _loadUsdExchangeRate(AppSettings.fiatCurrency.value);

  Future<WalletAsset> _withTokenMarket(
    WalletAsset asset,
    double? kasUsd,
  ) async {
    if (asset.id == null) return asset;
    String? imageUrl = asset.imageUrl;
    double? priceKas;
    double? priceUsd;
    try {
      priceKas = (await (_floorPrices ??= _loadFloorPrices()))[asset.symbol];
      if (priceKas != null && kasUsd != null) {
        priceUsd = priceKas * kasUsd;
      }
    } catch (_) {}
    try {
      final response = await _client
          .get(Uri.parse('$tokenExplorerBaseUrl/token/${asset.id}'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = _map(_map(jsonDecode(response.body))['data']);
        imageUrl ??= _absoluteImageUrl(data['image_url']?.toString());
        priceKas ??= _validPrice(data['price_kas']);
        priceUsd ??= _validPrice(data['price_usd']);
      }
    } catch (_) {}
    return WalletAsset(
      symbol: asset.symbol,
      balance: asset.balance,
      kind: asset.kind,
      imageUrl: imageUrl,
      id: asset.id,
      decimals: asset.decimals,
      rawBalance: asset.rawBalance,
      rawLockedBalance: asset.rawLockedBalance,
      priceKas: priceKas,
      priceUsd: priceUsd,
    );
  }

  Future<Map<String, double>> _loadFloorPrices() async {
    final raw = await _externalGet(kaspaComBaseUrl, '/api/floor-price');
    final map = _map(raw);
    final items = raw is List
        ? raw.whereType<Map>()
        : (map['data'] as List? ??
                map['items'] as List? ??
                map['result'] as List? ??
                const [])
            .whereType<Map>();
    return {
      for (final item in items)
        if ((item['ticker'] ?? item['tick'] ?? item['symbol'])
                ?.toString()
                .isNotEmpty ==
            true)
          (item['ticker'] ?? item['tick'] ?? item['symbol']).toString().toUpperCase():
              _validPrice(
                    item['floor_price'] ?? item['price'],
                  ) ??
                  0,
    }..removeWhere((_, value) => value <= 0);
  }

  double? _validPrice(Object? raw) {
    final value = _asDouble(raw);
    return value != null && value.isFinite && value >= 0 ? value : null;
  }

  Future<NftCollectionPage> loadNftCollection(
    String address,
    String ticker, {
    int offset = 0,
  }) async {
    return _loadNftCollectionFromIndexer(address, ticker, offset: offset);
  }

  Future<NftCollectionPage> _loadNftCollectionFromIndexer(
    String address,
    String ticker, {
    required int offset,
  }) async {
    final normalizedTicker = ticker.toUpperCase();
    final tokenIds = <String>[];
    final listedTokenIds = <String>{};
    String? cursor;
    for (var page = 0; page < 100; page++) {
      final raw =
          await nftReads.walletPage(address, cursor: cursor, limit: 500);
      final items = _externalItems(raw);
      for (final item in items) {
        final itemTicker =
            (item['tick'] ?? item['ticker'] ?? item['symbol'] ?? '')
                .toString()
                .toUpperCase();
        final tokenId =
            (item['tokenId'] ?? item['id'] ?? item['nftId'])?.toString();
        if (itemTicker == normalizedTicker &&
            tokenId != null &&
            tokenId.isNotEmpty) {
          tokenIds.add(tokenId);
          if (_map(item['status'])['state'] == 'listed') {
            listedTokenIds.add(tokenId);
          }
        }
      }
      cursor = _externalCursor(raw);
      if (cursor == null || items.isEmpty) break;
    }
    final unique = tokenIds.toSet().toList()
      ..sort((left, right) {
        final a = int.tryParse(left);
        final b = int.tryParse(right);
        return a != null && b != null ? a.compareTo(b) : left.compareTo(right);
      });
    final pageIds = unique.skip(offset).take(48).toList();
    final ranks = await _loadNftRanks(normalizedTicker, pageIds);
    return NftCollectionPage(
      ticker: normalizedTicker,
      total: unique.length,
      nfts: pageIds
          .map(
            (tokenId) => WalletNft(
              ticker: normalizedTicker,
              tokenId: tokenId,
              isListed: listedTokenIds.contains(tokenId),
              imageUrl: Krc721Reads.image(normalizedTicker, tokenId),
              rarityRank: ranks[tokenId],
              nexusUrl: 'https://kaspanftnexus.com/nft/'
                  '${normalizedTicker.toLowerCase()}/'
                  '${Uri.encodeComponent(tokenId)}',
            ),
          )
          .toList(),
      nextOffset: offset + pageIds.length < unique.length
          ? offset + pageIds.length
          : null,
    );
  }

  Future<Map<String, int>> _loadNftRanks(
    String ticker,
    List<String> tokenIds,
  ) async {
    if (tokenIds.isEmpty) return const {};
    try {
      final items = await nftReads.metadata(ticker, tokenIds);
      return Map.fromEntries(
        items.map((item) {
          final id = (item['tokenId'] ?? '').toString();
          final rank = _nullableInt(item['rarityRank']);
          return rank == null || id.isEmpty ? null : MapEntry(id, rank);
        }).whereType<MapEntry<String, int>>(),
      );
    } catch (_) {
      return const {};
    }
  }

  _WalletAssets _parseAssets(Object? raw) {
    final envelope = _map(raw);
    final data = _map(envelope['data']);
    final warnings = <String>[
      ...(envelope['warnings'] as List? ?? const [])
          .map((item) => item.toString())
          .where((item) => item.isNotEmpty),
    ];

    List<WalletAsset> assets(String key, String kind) {
      final valid = <WalletAsset>[];
      var rejected = 0;
      for (final item in (data[key] as List? ?? const [])) {
        if (item is! Map) {
          rejected++;
          continue;
        }
        final map = item.cast<String, Object?>();
        final symbol =
            (map['symbol'] ?? map['ticker'] ?? '').toString().toUpperCase();
        final balance = _asDouble(map['balance']);
        final decimals = _asInt(map['decimals']);
        final rawBalance = map['raw_balance']?.toString();
        final reportedLocked = map['raw_locked_balance']?.toString();
        final rawLocked = kind == 'KRC-20' &&
                reportedLocked != null &&
                RegExp(r'^[0-9]{1,128}$').hasMatch(reportedLocked)
            ? reportedLocked
            : null;
        final locked = BigInt.tryParse(rawLocked ?? '') ?? BigInt.zero;
        if (!RegExp(r'^[A-Z0-9_-]{1,32}$').hasMatch(symbol) ||
            balance == null ||
            !balance.isFinite ||
            balance < 0 ||
            decimals < 0 ||
            decimals > 18 ||
            (rawBalance != null &&
                !RegExp(r'^[0-9]{1,128}$').hasMatch(rawBalance))) {
          rejected++;
          continue;
        }
        if (balance > 0 || locked > BigInt.zero) {
          valid.add(
            WalletAsset(
              symbol: symbol,
              balance: balance,
              kind: kind,
              id: (map['token_id'] ??
                      (kind == 'KRC-20'
                          ? 'krc20-${(map['symbol'] ?? map['ticker'] ?? '').toString().toLowerCase()}'
                          : null))
                  ?.toString(),
              decimals: decimals,
              rawBalance: rawBalance,
              rawLockedBalance: rawLocked,
              // A stable, own-hosted image URL works in progressive holdings
              // before market enrichment finishes, including cached outages.
              imageUrl: kind == 'KRC-20'
                  ? '${NetworkSettings.publicKaspaRestUrl}/token-logos/krc20/${symbol.toLowerCase()}'
                  : _absoluteImageUrl(map['image_url']?.toString()),
            ),
          );
        }
      }
      if (rejected > 0) {
        warnings.add(
          'The indexer returned $rejected unusable ${kind.toUpperCase()} '
          '${rejected == 1 ? 'record' : 'records'}; the remaining holdings '
          'are still shown.',
        );
      }
      return _alphabeticalAssets(valid);
    }

    final domains = <KnsDomain>[];
    var rejectedDomains = 0;
    for (final item in (data['domains'] as List? ?? const [])) {
      if (item is! Map) {
        rejectedDomains++;
        continue;
      }
      final name = (item['name'] ?? '').toString().toLowerCase();
      final rawStatus = item['status']?.toString().toLowerCase();
      final rawAssetId = item['asset_id']?.toString();
      if (!_isKnsName(name)) {
        rejectedDomains++;
        continue;
      }
      final status =
          rawStatus != null && RegExp(r'^[a-z0-9_-]{1,32}$').hasMatch(rawStatus)
              ? rawStatus
              : null;
      final assetId = rawAssetId != null &&
              RegExp(r'^[0-9a-fA-F]{64}i0$').hasMatch(rawAssetId)
          ? rawAssetId
          : null;
      domains.add(KnsDomain(name: name, status: status, assetId: assetId));
    }
    if (rejectedDomains > 0) {
      warnings.add(
        'The indexer returned $rejectedDomains unusable KNS '
        '${rejectedDomains == 1 ? 'record' : 'records'}; the remaining '
        'holdings are still shown.',
      );
    }
    return _WalletAssets(
      krc20: assets('tokens', 'KRC-20'),
      krc721: assets('krc721_tokens', 'KRC-721'),
      domains: {
        for (final domain in domains) domain.assetId ?? domain.name: domain
      }.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name)),
      warnings: warnings,
    );
  }

  List<WalletTransaction> _parseTokenTransactions(
    Object? raw,
    String address,
  ) {
    final data = _map(_map(raw)['data']);
    return (data['transactions'] as List? ?? const [])
        .whereType<Map>()
        .map((item) {
      final map = item.cast<String, Object?>();
      final from = map['from_wallet']?.toString();
      final to = map['to_wallet']?.toString();
      final timestamp = DateTime.tryParse(map['timestamp']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final symbol = map['token_symbol']?.toString().toUpperCase() ??
          map['token_id']?.toString().replaceFirst('krc20-', '').toUpperCase();
      final rawKind = (map['asset_kind'] ?? map['kind'] ?? map['type'] ?? '')
          .toString()
          .toLowerCase();
      final assetKind = rawKind.contains('721')
          ? 'KRC-721'
          : rawKind.contains('kns')
              ? 'KNS'
              : 'KRC-20';
      final displayAmount = map['amount']?.toString();
      final now = DateTime.now();
      if ((from != null &&
              from.isNotEmpty &&
              !RegExp(r'^(kaspa|kaspatest):[a-z0-9]{61,63}$').hasMatch(from)) ||
          (to != null &&
              to.isNotEmpty &&
              !RegExp(r'^(kaspa|kaspatest):[a-z0-9]{61,63}$').hasMatch(to)) ||
          timestamp.isBefore(DateTime.utc(2020)) ||
          timestamp.isAfter(now.add(const Duration(minutes: 5))) ||
          displayAmount == null ||
          !RegExp(r'^[0-9]+(\.[0-9]{1,18})?$').hasMatch(displayAmount)) {
        throw KaspaApiException('invalid token transaction metadata');
      }
      return WalletTransaction(
        id: map['id']?.toString() ??
            'krc20-${timestamp.microsecondsSinceEpoch}',
        timestamp: timestamp,
        amountSompi: 0,
        incoming: to == address && from != address,
        assetKind: assetKind,
        assetSymbol: symbol,
        displayAmount: displayAmount,
        tokenId: map['token_id']?.toString(),
        counterparty: to == address ? from : to,
        from: [
          if (from != null && from.isNotEmpty) TransactionParty(address: from),
        ],
        to: [
          if (to != null && to.isNotEmpty) TransactionParty(address: to),
        ],
        status: TransactionStatus.confirmed,
      );
    }).toList();
  }

  Future<String> loadUtxos(String address) async {
    final response = await _client
        .get(
          Uri.parse('$baseUrl/addresses/${Uri.encodeComponent(address)}/utxos'),
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KaspaApiException('Kaspa API returned ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! List) throw KaspaApiException('Invalid UTXO response');
    validateUtxos(decoded, address);
    return jsonEncode(decoded);
  }

  Future<void> verifyKcc20CellsOnOwnNode(
    List<Kcc20CellRecord> cells,
    String covenantId,
  ) async {
    final expectedCovenant = covenantId.toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedCovenant) ||
        cells.isEmpty ||
        cells.length > 1000) {
      throw KaspaApiException('Invalid KCC20 verification request.');
    }
    final outpoints = cells
        .map((cell) => '${cell.transactionId.toLowerCase()}:${cell.index}')
        .toSet();
    if (outpoints.length != cells.length) {
      throw KaspaApiException(
        'The KCC20 verification request contains a duplicate outpoint.',
      );
    }
    for (final cell in cells) {
      final transaction = _map(await _get(
        '/local-node/transactions/${Uri.encodeComponent(cell.transactionId)}',
      ));
      if (transaction['transaction_id']?.toString().toLowerCase() !=
              cell.transactionId.toLowerCase() ||
          transaction['is_accepted'] != true) {
        throw KaspaApiException(
          'The local Kaspa node did not confirm the KCC20 cell transaction.',
        );
      }
      final outputs = (transaction['outputs'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => item.cast<String, Object?>());
      Map<String, Object?>? output;
      for (final candidate in outputs) {
        if (_nullableInt(candidate['index']) == cell.index) {
          output = candidate;
          break;
        }
      }
      final outputScript = _normalizeScriptPublicKey(
        output?['script_public_key'] ?? output?['scriptPublicKey'],
      );
      final outputAddress =
          (output?['script_public_key_address'] ?? output?['address'])
              ?.toString();
      if (output == null ||
          output['covenant_id']?.toString().toLowerCase() != expectedCovenant ||
          cell.covenantId.toLowerCase() != expectedCovenant ||
          _nullableInt(output['amount']) != cell.valueSompi ||
          outputScript != _normalizeScriptPublicKey(cell.scriptPublicKey) ||
          outputAddress == null ||
          outputAddress.isEmpty) {
        throw KaspaApiException(
          'The KCC20 indexer data conflicts with the local Kaspa node.',
        );
      }
      final live = await _get(
        '/local-node/addresses/${Uri.encodeComponent(outputAddress)}/utxos',
      );
      if (live is! List ||
          !live.whereType<Map>().any((raw) {
            final item = raw.cast<Object?, Object?>();
            final outpoint = item['outpoint'];
            final entry = item['utxoEntry'];
            if (outpoint is! Map || entry is! Map) return false;
            final script = entry['scriptPublicKey'];
            final liveScript = _normalizeScriptPublicKey(script is Map
                ? (script['scriptPublicKey'] ?? script['script_public_key'])
                : script);
            return (outpoint['transactionId'] ?? outpoint['transaction_id'])
                        ?.toString()
                        .toLowerCase() ==
                    cell.transactionId.toLowerCase() &&
                _nullableInt(outpoint['index']) == cell.index &&
                _nullableInt(entry['amount']) == cell.valueSompi &&
                liveScript == _normalizeScriptPublicKey(cell.scriptPublicKey) &&
                entry['isCoinbase'] != true;
          })) {
        throw KaspaApiException(
          'The local Kaspa node reports that this KCC20 cell is no longer spendable.',
        );
      }
    }
  }

  Future<void> verifyWyrmCell(Map<String, Object?> cell) async {
    final transactionId = cell["transactionId"]?.toString().toLowerCase() ?? "";
    final covenantId = cell["covenantId"]?.toString().toLowerCase() ?? "";
    final outputAddress = cell["outputAddress"]?.toString() ?? "";
    final index = _nullableInt(cell["index"]);
    final valueSompi = _nullableInt(cell["valueSompi"]);
    final expectedScript = _normalizeScriptPublicKey(cell["scriptPublicKey"]);
    if (!RegExp(r"^[0-9a-f]{64}$").hasMatch(transactionId) ||
        !RegExp(r"^[0-9a-f]{64}$").hasMatch(covenantId) ||
        !RegExp(r"^kaspa:[a-z0-9]{61,63}$").hasMatch(outputAddress) ||
        index == null ||
        index < 0 ||
        valueSompi == null ||
        valueSompi <= 0 ||
        expectedScript.isEmpty) {
      throw KaspaApiException("Invalid Covenant Wyrm cell descriptor.");
    }
    final transaction = _map(await _get(
      "/local-node/transactions/${Uri.encodeComponent(transactionId)}",
    ));
    if (transaction["transaction_id"]?.toString().toLowerCase() !=
            transactionId ||
        transaction["is_accepted"] != true) {
      throw KaspaApiException(
          "The local Kaspa node did not confirm the Covenant Wyrm transaction.");
    }
    final outputs =
        (transaction["outputs"] as List? ?? const []).whereType<Map>();
    Map<Object?, Object?>? output;
    for (final candidate in outputs) {
      if (_nullableInt(candidate["index"]) == index) {
        output = candidate;
        break;
      }
    }
    final nodeScript = _normalizeScriptPublicKey(
        output?["script_public_key"] ?? output?["scriptPublicKey"]);
    final nodeAddress =
        (output?["script_public_key_address"] ?? output?["address"])
            ?.toString();
    if (output == null ||
        output["covenant_id"]?.toString().toLowerCase() != covenantId ||
        _nullableInt(output["amount"]) != valueSompi ||
        nodeScript != expectedScript ||
        nodeAddress != outputAddress) {
      throw KaspaApiException(
          "Covenant Wyrm data conflicts with the local Kaspa node.");
    }
    final live = await _get(
      "/local-node/addresses/${Uri.encodeComponent(outputAddress)}/utxos",
    );
    if (live is! List ||
        !live.whereType<Map>().any((raw) {
          final outpoint = raw["outpoint"];
          final entry = raw["utxoEntry"];
          if (outpoint is! Map || entry is! Map) return false;
          final script = entry["scriptPublicKey"];
          return (outpoint["transactionId"] ?? outpoint["transaction_id"])
                      ?.toString()
                      .toLowerCase() ==
                  transactionId &&
              _nullableInt(outpoint["index"]) == index &&
              _nullableInt(entry["amount"]) == valueSompi &&
              _normalizeScriptPublicKey(script is Map
                      ? (script["scriptPublicKey"] ??
                          script["script_public_key"])
                      : script) ==
                  expectedScript &&
              entry["isCoinbase"] != true;
        })) {
      throw KaspaApiException(
          "The local Kaspa node reports that this Covenant Wyrm cell is no longer spendable.");
    }
  }

  Future<String> waitForTransactionUtxos(
      String address, String transactionId) async {
    for (var attempt = 0; attempt < 45; attempt += 1) {
      final selected = await transactionUtxos(address, transactionId);
      if (selected != null) return selected;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw KaspaApiException(
        "The Wyrm action commit was not confirmed in time.");
  }

  Future<String?> transactionUtxos(String address, String transactionId) async {
    final raw = await loadUtxos(address);
    final decoded = jsonDecode(raw);
    final selected = decoded is List
        ? decoded
            .where((item) =>
                item is Map &&
                item["outpoint"] is Map &&
                (item["outpoint"]["transactionId"] ??
                            item["outpoint"]["transaction_id"])
                        ?.toString()
                        .toLowerCase() ==
                    transactionId.toLowerCase())
            .toList()
        : const [];
    return selected.isEmpty ? null : jsonEncode(selected);
  }

  static void validateUtxos(List<Object?> decoded, String address) {
    final seen = <String>{};
    for (final raw in decoded) {
      if (raw is! Map) {
        throw KaspaApiException(
            'The Kaspa endpoint returned a malformed UTXO.');
      }
      final item = raw.cast<Object?, Object?>();
      final itemAddress = item['address']?.toString();
      if (itemAddress != null &&
          itemAddress.isNotEmpty &&
          itemAddress.toLowerCase() != address.toLowerCase()) {
        throw KaspaApiException(
          'The Kaspa endpoint returned a UTXO belonging to another address.',
        );
      }
      final outpoint = item['outpoint'];
      final entry = item['utxoEntry'];
      if (outpoint is! Map || entry is! Map) {
        throw KaspaApiException(
            'The Kaspa endpoint returned a malformed UTXO.');
      }
      final transactionId =
          (outpoint['transactionId'] ?? outpoint['transaction_id'])
              ?.toString()
              .toLowerCase();
      final index = _nullableInt(outpoint['index']);
      final amount = _nullableInt(entry['amount']);
      if (transactionId == null ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(transactionId) ||
          index == null ||
          index < 0 ||
          amount == null ||
          amount <= 0) {
        throw KaspaApiException(
            'The Kaspa endpoint returned a malformed UTXO.');
      }
      if (!seen.add('$transactionId:$index')) {
        throw KaspaApiException(
          'The Kaspa endpoint returned a duplicate UTXO.',
        );
      }
    }
  }

  Future<bool> addressHasActivity(String address) async {
    final balance = _map(
      await _get('/addresses/${Uri.encodeComponent(address)}/balance'),
    );
    if (_asInt(balance['balance']) > 0) return true;
    final history = await _get(
      '/addresses/${Uri.encodeComponent(address)}/full-transactions?limit=1&offset=0&resolve_previous_outpoints=no',
    );
    return history is List
        ? history.isNotEmpty
        : (_map(history)['transactions'] as List? ?? const []).isNotEmpty;
  }

  Future<double> loadFeeRate() async {
    final value = _map(await _get('/info/fee-estimate'));
    final priority = value['priorityBucket'];
    final rate = priority is Map ? _asDouble(priority['feerate']) : null;
    if (rate == null || !rate.isFinite || rate < 0 || rate > 100000000) {
      throw KaspaApiException(
        'The Kaspa endpoint returned an invalid fee estimate.',
      );
    }
    return rate < 100 ? 100.0 : rate;
  }

  Future<List<DiagnosticCheck>> runDiagnostics(String address) async {
    final checks = <DiagnosticCheck>[];
    await _diagnosticProbe(
      checks,
      'Kaspa node · fee estimate',
      baseUrl,
      () => loadFeeRate().then((rate) => '${rate.toStringAsFixed(2)} sompi/g'),
    );
    await _diagnosticProbe(
      checks,
      'Kaspa node · UTXO integrity',
      baseUrl,
      () => loadUtxos(address).then(
        (raw) => '${(jsonDecode(raw) as List).length} validated UTXOs',
      ),
    );
    await _diagnosticProbe(
      checks,
      'KRC / KNS indexer',
      tokenExplorerBaseUrl,
      () => _loadTokenWallet(address).then((_) => 'Response decoded'),
    );
    await _diagnosticProbe(
      checks,
      'KCC20 primary · Kasvio',
      '$kasvioBaseUrl/api/kcc20/v4',
      () =>
          standardKcc20.get('$kasvioBaseUrl/api/kcc20/v4/status').then((value) {
        if (_map(value['data'])['status'] != 'ready')
          throw KaspaApiException('Kasvio is not ready');
        return 'KCC20 API available';
      }),
    );
    await _diagnosticProbe(checks, 'KCC20 fallback · Kascov', kascovBaseUrl,
        () async {
      final response = await _client
          .get(Uri.parse(
              '$kascovBaseUrl/addr/${Uri.encodeComponent(address)}.json'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200 ||
          _map(jsonDecode(response.body))['network'] != 'mainnet') {
        throw KaspaApiException(
            'Kascov account API unavailable (${response.statusCode})');
      }
      return 'KCC20 fallback API available';
    });
    return checks;
  }

  Future<void> _diagnosticProbe(
    List<DiagnosticCheck> checks,
    String name,
    String endpoint,
    Future<String> Function() operation,
  ) async {
    final watch = Stopwatch()..start();
    try {
      final detail = await operation();
      checks.add(DiagnosticCheck(
        name: name,
        endpoint: endpoint,
        ok: true,
        detail: detail,
        elapsedMs: watch.elapsedMilliseconds,
      ));
    } catch (error) {
      checks.add(DiagnosticCheck(
        name: name,
        endpoint: endpoint,
        ok: false,
        detail: error.toString(),
        elapsedMs: watch.elapsedMilliseconds,
      ));
    }
  }

  Future<String> broadcast(
    String submitJson, {
    String? expectedTransactionId,
  }) async {
    Object? broadcastError;
    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/transactions'),
            headers: const {'content-type': 'application/json'},
            body: submitJson,
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        broadcastError = KaspaApiException(
          'Broadcast rejected (${response.statusCode}): ${response.body}',
        );
      } else {
        final decoded = _map(jsonDecode(response.body));
        final transactionId =
            (decoded['transactionId'] ?? decoded['transaction_id'] ?? '')
                .toString()
                .toLowerCase();
        if (RegExp(r'^[0-9a-f]{64}$').hasMatch(transactionId)) {
          return transactionId;
        }
        broadcastError = KaspaApiException(
            'The Kaspa broadcaster returned no valid transaction ID.');
      }
    } on TimeoutException catch (error) {
      broadcastError = error;
    } on http.ClientException catch (error) {
      broadcastError = error;
    } on FormatException catch (error) {
      broadcastError = error;
    }

    final expected = expectedTransactionId?.toLowerCase();
    if (expected != null && await _waitForAcceptedTransaction(expected)) {
      return expected;
    }
    if (broadcastError is KaspaApiException) throw broadcastError;
    throw KaspaApiException(
      'Kaspa broadcast could not be confirmed: $broadcastError',
    );
  }

  Future<String> broadcastKcc20(
    String signedTxJson, {
    required String expectedTransactionId,
  }) async {
    final expected = expectedTransactionId.toLowerCase();
    Object? broadcastError;
    try {
      final response = await _client
          .post(
            Uri.parse(toccataBroadcastUrl),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({'signedTxJson': signedTxJson}),
          )
          .timeout(const Duration(seconds: 30));
      Map<String, Object?> decoded = const {};
      try {
        decoded = _map(jsonDecode(response.body));
      } catch (_) {}
      if (response.statusCode < 200 || response.statusCode >= 300) {
        broadcastError = KaspaApiException(
          'Toccata wRPC broadcast rejected (${response.statusCode}): '
          '${decoded['error'] ?? response.body}',
        );
      } else {
        final transactionId =
            (decoded['txId'] ?? decoded['transactionId'] ?? '')
                .toString()
                .toLowerCase();
        if (transactionId == expected) return transactionId;
        broadcastError = KaspaApiException(transactionId.isEmpty
            ? 'Toccata wRPC broadcast returned no transaction ID.'
            : 'Toccata wRPC returned a mismatching transaction ID.');
      }
    } on TimeoutException catch (error) {
      broadcastError = error;
    } on http.ClientException catch (error) {
      broadcastError = error;
    } on FormatException catch (error) {
      broadcastError = error;
    }

    // A broadcaster can lose its HTTP response after the node has already
    // accepted the exact transaction. Verify that state before surfacing an
    // error, otherwise a user retry can create a duplicate covenant asset.
    if (await _waitForAcceptedTransaction(expected)) return expected;
    if (broadcastError is KaspaApiException) throw broadcastError;
    throw KaspaApiException(
      'Covenant broadcast could not be confirmed: $broadcastError',
    );
  }

  Future<bool> isKcc20TransactionAccepted(String transactionId) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(transactionId)) {
      throw StateError('Invalid KCC20 transaction ID.');
    }
    return _waitForAcceptedTransaction(transactionId);
  }

  Future<bool> kcc20PlanTransactionAccepted(String transactionId) async {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(transactionId)) {
      throw StateError('Invalid KCC20 transaction ID.');
    }
    final response = await _client
        .get(Uri.parse('$baseUrl/local-node/transactions/$transactionId'))
        .timeout(const Duration(seconds: 5));
    if (response.statusCode == 404) return false;
    if (response.statusCode != 200) {
      throw StateError('KCC20 confirmation temporarily unavailable.');
    }
    final tx = _map(jsonDecode(response.body));
    return tx['transaction_id'] == transactionId && tx['is_accepted'] == true;
  }

  Future<bool> _waitForAcceptedTransaction(String transactionId) async {
    for (var attempt = 0; attempt < 12; attempt += 1) {
      try {
        final response = await _client
            .get(Uri.parse(
                '$baseUrl/local-node/transactions/${Uri.encodeComponent(transactionId)}'))
            .timeout(const Duration(seconds: 5));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final transaction = _map(jsonDecode(response.body));
          if (transaction['is_accepted'] == true &&
              transaction['transaction_id']?.toString().toLowerCase() ==
                  transactionId) {
            return true;
          }
        }
      } catch (_) {}
      if (attempt < 11) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    return false;
  }

  Future<Object?> _get(String path) async {
    final response = await _client
        .get(Uri.parse('$baseUrl$path'))
        .timeout(const Duration(seconds: 12));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KaspaApiException('Kaspa API returned ${response.statusCode}');
    }
    return jsonDecode(response.body);
  }

  Future<Object?> _getReadOnlyWithFallback(String path,
      {void Function(Object?)? validate}) async {
    try {
      final result = await _get(path);
      validate?.call(result);
      return result;
    } on TimeoutException {
      /* Retry the independent read-only source. */
    } on http.ClientException {
      /* Retry the independent read-only source. */
    } on KaspaApiException {
      /* Retry the independent read-only source. */
    } on FormatException {/* Malformed JSON is not an empty account. */}
    final result = await _getFromPublicFallback(path);
    validate?.call(result);
    return result;
  }

  Future<Object?> _getFromPublicFallback(String path) async {
    if (baseUrl == NetworkSettings.publicKaspaFallbackRestUrl) {
      return _get(path);
    }
    final response = await _client
        .get(Uri.parse('${NetworkSettings.publicKaspaFallbackRestUrl}$path'))
        .timeout(const Duration(seconds: 12));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KaspaApiException(
        'Kaspa read fallback returned ${response.statusCode}',
      );
    }
    return jsonDecode(response.body);
  }

  static List<WalletTransaction> parseTransactions(
    Object? raw,
    String address,
  ) =>
      parseTransactionsForAddresses(raw, [address]);

  static List<WalletTransaction> parseTransactionsForAddresses(
    Object? raw,
    Iterable<String> addresses,
  ) {
    final controlled = addresses.map((item) => item.toLowerCase()).toSet();
    final list =
        raw is List ? raw : (_map(raw)["transactions"] as List? ?? const []);
    return list.whereType<Map>().map((item) {
      final map = item.cast<String, Object?>();
      final outputs = (map["outputs"] as List? ?? const []).whereType<Map>();
      final inputs = (map["inputs"] as List? ?? const []).whereType<Map>();
      var received = 0;
      var spent = 0;
      var totalInput = 0;
      var totalOutput = 0;
      final from = <TransactionParty>[];
      final to = <TransactionParty>[];
      final covenantTransactions = <String, Set<String>>{};
      final transactionId =
          (map['transaction_id'] ?? map['id'] ?? '').toString();
      void rememberCovenant(Map row, {String? origin}) {
        final cid = row['covenant_id']?.toString().toLowerCase() ?? '';
        if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(cid)) return;
        final ids = covenantTransactions.putIfAbsent(cid, () => <String>{});
        if (RegExp(r'^[0-9a-f]{64}$').hasMatch(transactionId)) {
          ids.add(transactionId);
        }
        if (origin != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(origin)) {
          ids.add(origin);
        }
      }

      for (final output in outputs) {
        rememberCovenant(output);
        final amount = _asInt(output["amount"]);
        if (amount < 0) {
          throw KaspaApiException(
            "Transaction history contains a negative output.",
          );
        }
        totalOutput += amount;
        final outputAddress = output["script_public_key_address"]?.toString();
        if (outputAddress != null && outputAddress.isNotEmpty) {
          to.add(TransactionParty(
            address: outputAddress,
            amountSompi: amount,
          ));
          if (controlled.contains(outputAddress.toLowerCase())) {
            received += amount;
          }
        }
      }
      for (final input in inputs) {
        rememberCovenant(input,
            origin: input['previous_outpoint_hash']?.toString());
        final previous =
            input["previous_outpoint_resolved"] ?? input["previous_outpoint"];
        String? inputAddress;
        var inputAmount = 0;
        if (previous is Map) {
          inputAddress = previous["script_public_key_address"]?.toString();
          inputAmount = _asInt(previous["amount"]);
        } else {
          inputAddress = input["previous_outpoint_address"]?.toString();
          inputAmount = _asInt(input["previous_outpoint_amount"]);
        }
        totalInput += inputAmount;
        if (inputAmount < 0) {
          throw KaspaApiException(
            "Transaction history contains a negative input.",
          );
        }
        if (inputAddress != null && inputAddress.isNotEmpty) {
          from.add(TransactionParty(
            address: inputAddress,
            amountSompi: inputAmount,
          ));
          if (controlled.contains(inputAddress.toLowerCase())) {
            spent += inputAmount;
          }
        }
      }
      final net = received - spent;
      final timestamp = _asInt(
        map["block_time"] ?? map["accepting_block_time"],
      );
      return WalletTransaction(
        id: (map["transaction_id"] ?? map["id"] ?? "unknown").toString(),
        timestamp: timestamp > 0
            ? DateTime.fromMillisecondsSinceEpoch(timestamp)
            : DateTime.now(),
        amountSompi: net.abs(),
        incoming: net >= 0,
        from: from,
        to: to,
        totalInputSompi: totalInput > 0 ? totalInput : null,
        totalOutputSompi: totalOutput,
        feeSompi: totalInput >= totalOutput && totalInput > 0
            ? totalInput - totalOutput
            : null,
        inputCount: inputs.length,
        outputCount: outputs.length,
        blockDaaScore: _nullableInt(
          map["accepting_block_daa_score"] ?? map["block_daa_score"],
        ),
        mass: _nullableInt(map["mass"]),
        isCoinbase: map["is_coinbase"] == true,
        status: TransactionStatus.confirmed,
        covenantTransactions: covenantTransactions,
      );
    }).toList();
  }

  static Map<String, Object?> _map(Object? value) =>
      value is Map ? value.cast<String, Object?>() : const {};
  static int _asInt(Object? value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;
  static int? _nullableInt(Object? value) => value == null
      ? null
      : value is num
          ? value.toInt()
          : int.tryParse('$value');
  static double? _asDouble(Object? value) =>
      value is num ? value.toDouble() : double.tryParse('$value');
  static double _pow10(int exponent) {
    var result = 1.0;
    for (var index = 0; index < exponent; index++) {
      result *= 10;
    }
    return result;
  }

  String? _absoluteImageUrl(String? value) {
    if (value == null || value.isEmpty || value.endsWith('.svg')) return null;
    if (value.startsWith('https://') || value.startsWith('http://')) {
      return value;
    }
    if (value.startsWith('/')) {
      final base = Uri.parse(tokenExplorerBaseUrl);
      return '${base.scheme}://${base.authority}$value';
    }
    return null;
  }

  static bool _isKnsName(String value) {
    if (value.length > 253) return false;
    final labels = value.split('.');
    if (labels.length < 2 || labels.last != 'kas') return false;
    return labels
        .take(labels.length - 1)
        .every((label) => RegExp(r'^[a-z0-9-]{1,63}$').hasMatch(label));
  }
}

class _WalletAssets {
  const _WalletAssets({
    required this.krc20,
    required this.krc721,
    required this.domains,
    required this.warnings,
  });
  final List<WalletAsset> krc20;
  final List<WalletAsset> krc721;
  final List<KnsDomain> domains;
  final List<String> warnings;
}

class _Kcc20Wallet {
  const _Kcc20Wallet({
    required this.assets,
    required this.transactions,
    required String warning,
    this.signingIssues = const {},
    this.coverageComplete = true,
  }) : _warning = warning;
  final List<WalletAsset> assets;
  final List<WalletTransaction> transactions;
  final Set<String> signingIssues;
  final bool coverageComplete;
  final String _warning;
  // A resolved source cannot leave a frozen generic failure message behind.
  static const signingWarning =
      'Some KCC20 balances could not be mapped to complete signing cells.';
  String get warning => [
        if (signingIssues.isNotEmpty) signingWarning,
        _warning.replaceAll(signingWarning, '').trim(),
      ].where((s) => s.isNotEmpty).join(' ');
}
