import 'dart:convert';
import 'package:http/http.dart' as http;
import '../kaspa_address.dart';
import '../models/wallet_snapshot.dart';
import 'network_settings.dart';

typedef KForgeSnapshot = ({List<KForgeToken> tokens, List<WalletAsset> assets});

/// KForge v6 is a separate launchpad, not KasForge. Indexed balances alone
/// never authorize signing; the native trading profile verifies every program.
class KForgeService {
  KForgeService({http.Client? client, bool? mainnet})
      : client = client ?? http.Client(),
        mainnet = mainnet ?? !NetworkSettings.isTestnet;
  final http.Client client;
  final bool mainnet;
  String get network => mainnet ? 'mainnet' : 'testnet-10';
  String get label => mainnet ? 'Kaspa Mainnet' : 'Testnet 10';
  String get prefix => mainnet ? 'kaspa' : 'kaspatest';
  String get origin =>
      mainnet ? 'https://api.kforge.xyz' : 'https://api-test.kforge.xyz';
  static const enabled =
      bool.fromEnvironment('KASPIRE_KFORGE_TN10', defaultValue: true);
  static const tradingEnabled = true;
  void guard([String? address]) {
    if (!NetworkSettings.isKaspa ||
        mainnet == NetworkSettings.isTestnet ||
        (address != null &&
            (!address.startsWith('$prefix:') ||
                kaspaOwnerIdFromAddress(address).isEmpty))) {
      throw StateError('KForge wallet/network changed. Reopen the DEX.');
    }
  }

  Future<Object?> read(String path) async {
    guard();
    final r = await client
        .get(Uri.parse('$origin$path'))
        .timeout(const Duration(seconds: 12));
    guard();
    if (r.statusCode != 200 || r.bodyBytes.length > 4 * 1024 * 1024) {
      throw StateError(
          'KForge data is temporarily unavailable (${r.statusCode}); this does not mean zero.');
    }
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  Future<void> _verifyRegistry() async {
    final registry = await read('/v6/registry');
    if (registry is! Map ||
        registry['network'] != network ||
        registry['version'] != 'v6' ||
        registry['parameters'] is! Map ||
        registry['parameters']['totalSupply'] != 1000000000 ||
        registry['parameters']['tokensPerStep'] != 1000000 ||
        registry['parameters']['base'] != (mainnet ? 6249997720 : 624999772) ||
        registry['parameters']['slope'] != (mainnet ? 15644550 : 1564455) ||
        registry['parameters']['feeBps'] != 100) {
      throw StateError(
          'KForge catalogue network, version or token units are unsupported.');
    }
  }

  Future<List<KForgeToken>> catalogue() async {
    final data =
        await Future.wait<Object?>([_verifyRegistry(), read('/v6/tokens')]);
    return _parseCatalogue(data[1]);
  }

  List<KForgeToken> _parseCatalogue(Object? raw) {
    if (raw is! List || raw.length > 1000)
      throw StateError('Invalid KForge token catalogue.');
    final ids = <String>{}, curves = <String>{};
    final rows = raw.map((row) {
      if (row is! Map) throw StateError('Invalid KForge token metadata.');
      final token = KForgeToken.fromJson(row, mainnet: mainnet);
      if (!ids.add(token.id) || !curves.add(token.curve)) {
        throw StateError('KForge repeats a token or market covenant.');
      }
      return token;
    }).toList();
    rows.sort((a, b) {
      final cap = b.marketCapKas.compareTo(a.marketCapKas);
      return cap != 0 ? cap : b.volume24hKas.compareTo(a.volume24hKas);
    });
    return rows;
  }

  Future<KForgeSnapshot> load(String address) async {
    guard(address);
    final data = await Future.wait(
        [catalogue(), read('/v6/holdings/${Uri.encodeComponent(address)}')]);
    guard(address);
    final tokens = data[0] as List<KForgeToken>, body = data[1];
    if (body is! Map ||
        body['wallet'] != address ||
        body['holdings'] is! List ||
        (body['holdings'] as List).length > 1000) {
      throw StateError(
          'KForge holdings are incomplete or belong to another wallet.');
    }
    final metadata = {for (final t in tokens) t.id: t}, seen = <String>{};
    final assets = <WalletAsset>[];
    for (final row in body['holdings'] as List) {
      if (row is! Map ||
          row['tokenCovId'] is! String ||
          !seen.add(row['tokenCovId'])) {
        throw StateError('Invalid or duplicate KForge holdings.');
      }
      final token = metadata[row['tokenCovId']];
      if (token == null || row['rungCovId'] != token.curve) {
        throw StateError('KForge holding does not match the token catalogue.');
      }
      final raw = '${row['amount']}';
      if (!RegExp(r'^(0|[1-9][0-9]{0,9})$').hasMatch(raw) ||
          BigInt.parse(raw) > BigInt.from(1000000000)) {
        throw StateError('KForge returned an invalid whole-token balance.');
      }
      final amount = BigInt.parse(raw);
      if (amount == BigInt.zero) continue;
      assets.add(WalletAsset(
          symbol: token.symbol,
          balance: amount.toDouble(),
          rawBalance: raw,
          kind: 'KCC20',
          id: token.id,
          covenantId: token.id,
          decimals: 0,
          imageUrl: token.logo,
          priceKas: token.priceKas,
          standard: 'kforge-kcc20',
          discoveryComplete: false,
          validationStatus: 'kforge-indexed'));
    }
    return (tokens: tokens, assets: assets);
  }

  /// Positive holdings do not depend on the full catalogue being available.
  /// These remain indexed, non-signable assets; no transfer policy is relaxed.
  Future<List<WalletAsset>> walletAssets(
    String address, {
    void Function(List<WalletAsset>)? onProgress,
    void Function(String)? onWarning,
  }) async {
    guard(address);
    final metadataTask = read('/v6/tokens')
        .then<List<KForgeToken>?>((raw) => _parseCatalogue(raw))
        .catchError((Object _) {
      onWarning?.call(
          'KForge metadata is temporarily unavailable; indexed holdings are retained.');
      return null;
    });
    // Only unrelated catalogue metadata may fail independently, not the
    // protocol/network proof that fixes these quantities to whole tokens.
    final data = await Future.wait<Object?>([
      _verifyRegistry(),
      read('/v6/holdings/${Uri.encodeComponent(address)}')
    ]);
    final body = data[1];
    guard(address);
    if (body is! Map ||
        body['wallet'] != address ||
        body['holdings'] is! List ||
        (body['holdings'] as List).length > 1000) {
      throw StateError(
          'KForge holdings are incomplete or belong to another wallet.');
    }
    final records = <Map>[];
    final seen = <String>{};
    for (final item in body['holdings'] as List) {
      if (item is! Map) throw StateError('Invalid KForge holding.');
      final id = KForgeToken.cid(item['tokenCovId']);
      KForgeToken.cid(item['rungCovId']);
      final raw = '${item['amount']}';
      if (!seen.add(id) ||
          !RegExp(r'^(0|[1-9][0-9]{0,9})$').hasMatch(raw) ||
          BigInt.parse(raw) > BigInt.from(1000000000)) {
        throw StateError('Invalid or duplicate whole-token KForge holding.');
      }
      if (BigInt.parse(raw) > BigInt.zero) records.add(item);
    }
    List<WalletAsset> assets(List<KForgeToken>? tokens) {
      final metadata = {
        for (final token in tokens ?? <KForgeToken>[]) token.id: token
      };
      return records.map((row) {
        final id = '${row['tokenCovId']}', token = metadata[id];
        if (token != null && row['rungCovId'] != token.curve) {
          throw StateError('KForge holding differs from the indexed market.');
        }
        String symbol;
        try {
          symbol = token?.symbol ?? KForgeToken.label(row['ticker'], 32);
        } catch (_) {
          symbol = 'KCC20 ${id.substring(0, 8)}';
        }
        final raw = '${row['amount']}';
        return WalletAsset(
            symbol: symbol,
            balance: BigInt.parse(raw).toDouble(),
            rawBalance: raw,
            kind: 'KCC20',
            id: id,
            covenantId: id,
            decimals: 0,
            imageUrl: token?.logo ??
                KForgeToken.image(row['image'], mainnet: mainnet),
            priceKas: token?.priceKas,
            standard: 'kforge-kcc20',
            discoveryComplete: false,
            validationStatus: 'kforge-indexed');
      }).toList();
    }

    final known = assets(null);
    onProgress?.call(known);
    final tokens = await metadataTask;
    guard(address);
    final complete = assets(tokens);
    onProgress?.call(complete);
    if (tokens != null &&
        records.any((row) => !tokens.any((t) => t.id == row['tokenCovId']))) {
      onWarning?.call(
          'Some KForge token metadata is not indexed yet; known balances are retained.');
    }
    return complete;
  }
}

class KForgeToken {
  KForgeToken.fromJson(Map row, {bool? mainnet})
      : market = Map<String, dynamic>.from(jsonDecode(jsonEncode(row)) as Map),
        id = cid(row['tokenCovId']),
        curve = cid(row['rungCovId']),
        name = label(row['name'], 120),
        symbol = label(row['ticker'], 32),
        graduated = row['phase'] == 'pool',
        pool = row['phase'] == 'pool' && row['pool'] is Map
            ? cid(row['pool']['poolCovId'])
            : null,
        logo = image(row['image'], mainnet: mainnet),
        priceKas = number(row['pricePerLot']) / 100000000000000,
        marketCapKas = number(row['marketCap']) / 100000000,
        volume24hKas = number(row['volume24h']) / 100000000 {
    if (!['curve', 'pool'].contains(row['phase']) ||
        (graduated && pool == null) ||
        (!graduated && row['pool'] != null)) {
      throw StateError('KForge market phase is incomplete.');
    }
  }
  final String id, curve, name, symbol;
  final Map<String, dynamic> market;
  final String? pool, logo;
  final bool graduated;
  final double priceKas, marketCapKas, volume24hKas;
  static String cid(Object? value) {
    if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
      throw StateError('Invalid KForge covenant ID.');
    }
    return value;
  }

  static String label(Object? value, int max) {
    if (value is! String ||
        value.trim().isEmpty ||
        value.length > max ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      throw StateError('Invalid KForge token name.');
    }
    return value;
  }

  static double number(Object? value) {
    final n = double.tryParse('$value');
    if (n == null || !n.isFinite || n < 0) {
      throw StateError('KForge market data is incomplete.');
    }
    return n;
  }

  static String? image(Object? value, {bool? mainnet}) {
    if (value is! String ||
        value.length > 2048 ||
        value.contains(RegExp(r'[\x00-\x20\x7f]'))) return null;
    if (RegExp(r'^[a-zA-Z0-9_-]{1,120}\.(png|jpg|jpeg|webp|gif)$')
        .hasMatch(value)) {
      final origin = (mainnet ?? !NetworkSettings.isTestnet)
          ? 'https://api.kforge.xyz'
          : 'https://api-test.kforge.xyz';
      return '$origin/img/$value';
    }
    if (value.startsWith('ipfs://')) {
      final path = value.substring(7);
      if (!RegExp(r'^[A-Za-z0-9]{32,120}(?:/[A-Za-z0-9._-]+)*$')
              .hasMatch(path) ||
          path.split('/').contains('..')) return null;
      return 'https://ipfs.io/ipfs/$path';
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.host == 'localhost' ||
        uri.host.endsWith('.local') ||
        RegExp(r'^[0-9.:]+$').hasMatch(uri.host)) return null;
    return uri.toString();
  }
}
