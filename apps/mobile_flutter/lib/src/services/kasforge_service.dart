import 'dart:convert';

import 'package:http/http.dart' as http;

import '../kaspa_address.dart';
import '../models/wallet_snapshot.dart';
import 'network_settings.dart';

/// Read-only, explicitly opt-in TN10 integration. The token list is metadata,
/// not authority to sign an order or accept an arbitrary contract program.
class KasForgeService {
  KasForgeService({http.Client? client}) : client = client ?? http.Client();

  static const enabled =
      bool.fromEnvironment('KASPIRE_KASFORGE_TN10', defaultValue: true);
  static const tradingEnabled = true;
  static const origin = 'https://kaspa.pumpforge.tech';
  final http.Client client;

  void guard([String? address]) {
    if (!NetworkSettings.isTestnet ||
        (address != null &&
            (!address.startsWith('kaspatest:') ||
                kaspaOwnerIdFromAddress(address).isEmpty))) {
      throw StateError('KasForge is available only on Kaspa Testnet 10.');
    }
  }

  Future<Map<String, dynamic>> _read(String path,
      {Map<String, String>? query}) async {
    guard();
    final uri = Uri.parse('$origin$path').replace(queryParameters: query);
    final response = await client.get(uri).timeout(const Duration(seconds: 12));
    guard();
    if (response.statusCode == 429) {
      throw StateError('KasForge is temporarily rate-limited. Please retry.');
    }
    if (response.statusCode != 200) {
      throw StateError(
          'KasForge data is temporarily unavailable (${response.statusCode}).');
    }
    if (response.bodyBytes.length > 4 * 1024 * 1024) {
      throw StateError('KasForge response exceeds the safe size limit.');
    }
    final data = jsonDecode(response.body);
    if (data is! Map || data['ok'] == false) {
      throw StateError('KasForge returned incomplete or invalid data.');
    }
    return Map<String, dynamic>.from(data);
  }

  Future<List<KasForgeToken>> tokens() async {
    final data = await _read('/api/kaspa-tn/forge/tokenlist');
    if (data['network'] != 'testnet-10' || data['tokens'] is! List) {
      throw StateError('KasForge token list has the wrong network or shape.');
    }
    final seen = <String>{};
    final rows = <KasForgeToken>[];
    for (final item in data['tokens'] as List) {
      if (item is! Map) throw StateError('Invalid KasForge token entry.');
      final token = KasForgeToken.fromJson(item);
      if (!seen.add(token.id)) {
        throw StateError('KasForge token list repeats a covenant ID.');
      }
      rows.add(token);
    }
    return rows;
  }

  Future<List<KasForgeToken>> catalogue() async {
    final results = await Future.wait([tokens(), _read('/api/v1/markets')]);
    final rows = results[0] as List<KasForgeToken>;
    final data = results[1] as Map<String, dynamic>;
    if (data['markets'] is! List) {
      throw StateError('KasForge market catalogue is incomplete.');
    }
    final markets = <String, Map>{};
    for (final market in (data['markets'] as List).whereType<Map>()) {
      final id = market['covenantId'];
      if (id is String) {
        // More than one record for a coin is not permission to guess which
        // market is live, especially around graduation.
        if (markets.containsKey(id)) {
          throw StateError(
              'KasForge reports conflicting markets for one token.');
        }
        markets[id] = market;
      }
    }
    return rows.map((token) {
      final market = markets[token.id];
      return market == null ? token : token.withMarket(market);
    }).toList()
      ..sort((a, b) {
        final cap = (b.marketCapKas ?? -1).compareTo(a.marketCapKas ?? -1);
        if (cap != 0) return cap;
        final volume = (b.volume24hKas ?? -1).compareTo(a.volume24hKas ?? -1);
        return volume != 0 ? volume : a.id.compareTo(b.id);
      });
  }

  Future<Map<String, dynamic>> portfolio(String address) async {
    guard(address);
    final pub = kaspaOwnerIdFromAddress(address);
    final data = await _read('/api/v1/portfolio/$pub');
    guard(address);
    if (data['ok'] != true ||
        data['address'] != address ||
        data['positions'] is! List ||
        data['orders'] is! List ||
        data['activity'] is! List) {
      throw StateError(
          'KasForge wallet data is incomplete or belongs to another wallet.');
    }
    return data;
  }

  Future<List<WalletAsset>> walletAssets(String address) async {
    guard(address);
    final results = await Future.wait([tokens(), portfolio(address)]);
    final metadata = {
      for (final token in results[0] as List<KasForgeToken>) token.id: token
    };
    final rows = (results[1] as Map)['positions'] as List;
    final seen = <String>{};
    final assets = <WalletAsset>[];
    for (final row in rows) {
      if (row is! Map || !seen.add('${row['token']}')) {
        throw StateError(
            'KasForge wallet contains invalid or duplicate balances.');
      }
      final token = metadata[row['token']];
      if (token == null) {
        throw StateError(
            'KasForge wallet token is missing from its token list.');
      }
      final balance = exactUnsigned(row['tokens']);
      if (balance == BigInt.zero) continue;
      assets.add(WalletAsset(
        symbol: token.symbol,
        balance: balance.toDouble(),
        rawBalance: balance.toString(),
        kind: 'KCC20',
        id: token.id,
        covenantId: token.id,
        decimals: token.decimals,
        imageUrl: token.logo,
        priceKas: nonnegativeNumber(row['priceKas']),
        standard: 'kasforge-kcc20',
        discoveryComplete: false,
        validationStatus: 'kasforge-indexed',
      ));
    }
    guard(address);
    return assets;
  }

  Future<Map<String, dynamic>> quote(
      KasForgeToken token, String side, String amount) async {
    guard();
    if (!['buy', 'sell'].contains(side) ||
        !RegExp(side == 'buy'
                ? r'^(?:0|[1-9][0-9]{0,10})(?:\.[0-9]{1,8})?$'
                : r'^[1-9][0-9]{0,15}$')
            .hasMatch(amount) ||
        double.tryParse(amount) == null ||
        double.parse(amount) <= 0) {
      throw StateError('Enter a positive amount (whole tokens for a sale).');
    }
    final data = await _read('/api/v1/market/${token.id}');
    if (data['market'] is! Map) {
      throw StateError('KasForge live market is unavailable.');
    }
    final current = token.withMarket(data['market'] as Map);
    if (current.activeMarket != token.activeMarket) {
      throw StateError(
          'This token changed market during graduation. Reload the token before quoting.');
    }
    final result = await _read('/api/v1/quote/${current.activeMarket}', query: {
      'side': side,
      side == 'buy' ? 'kas' : 'tokens': amount,
    });
    if (result['ok'] != true || result['side'] != side) {
      throw StateError(
          'KasForge quote does not match the requested direction.');
    }
    if (side == 'buy') {
      exactUnsigned(result['receiveTokens']);
      if (nonnegativeNumber(result['payKas']) != double.parse(amount)) {
        throw StateError('KasForge quote changed the requested amount.');
      }
    } else if (nonnegativeNumber(result['receiveKas']) == null) {
      throw StateError('KasForge sale quote is incomplete.');
    }
    return {
      ...result,
      'marketId': current.activeMarket,
      'tokenId': token.id,
      'localAmount': amount,
      'localAt': DateTime.now().millisecondsSinceEpoch
    };
  }

  static BigInt exactUnsigned(Object? value) {
    final text = '$value';
    if (!RegExp(r'^(0|[1-9][0-9]{0,18})$').hasMatch(text)) {
      throw StateError('KasForge returned an invalid token quantity.');
    }
    return BigInt.parse(text);
  }

  static double? nonnegativeNumber(Object? value) {
    final parsed = double.tryParse('$value');
    return parsed != null && parsed.isFinite && parsed >= 0 ? parsed : null;
  }
}

class KasForgeToken {
  const KasForgeToken({
    required this.id,
    required this.symbol,
    required this.name,
    required this.decimals,
    required this.genesis,
    required this.curve,
    required this.pool,
    required this.graduated,
    this.logo,
    this.priceKas,
    this.marketCapKas,
    this.volume24hKas,
  });

  final String id, symbol, name, genesis, curve;
  final String? pool, logo;
  final int decimals;
  final bool graduated;
  final double? priceKas, marketCapKas, volume24hKas;
  String get activeMarket => graduated ? pool! : curve;

  factory KasForgeToken.fromJson(Map row) {
    final extensions = row['extensions'];
    final hex = RegExp(r'^[a-f0-9]{64}$');
    if (row['network'] != 'testnet-10' ||
        extensions is! Map ||
        extensions['launchpad'] != 'kasforge' ||
        !hex.hasMatch('${row['covenantId']}') ||
        !hex.hasMatch('${extensions['curveCovenantId']}') ||
        !hex.hasMatch('${extensions['genesisTxid']}') ||
        row['decimals'] != 0 ||
        row['symbol'] is! String ||
        (row['symbol'] as String).trim().isEmpty ||
        (row['symbol'] as String).length > 80 ||
        row['name'] is! String ||
        (row['name'] as String).length > 256 ||
        extensions['graduated'] is! bool) {
      throw StateError('Invalid or unsupported KasForge token metadata.');
    }
    final graduated = extensions['graduated'] as bool;
    final pool = extensions['poolCovenantId'];
    if ((pool != null && !hex.hasMatch('$pool')) ||
        (graduated && pool == null)) {
      throw StateError('KasForge graduated token has no valid pool.');
    }
    final logo = Uri.tryParse('${row['logoURI']}');
    return KasForgeToken(
      id: row['covenantId'] as String,
      symbol: row['symbol'] as String,
      name: row['name'] as String,
      decimals: 0,
      genesis: extensions['genesisTxid'] as String,
      curve: extensions['curveCovenantId'] as String,
      pool: pool as String?,
      graduated: graduated,
      logo: logo != null &&
              logo.scheme == 'https' &&
              logo.host.isNotEmpty &&
              logo.userInfo.isEmpty
          ? logo.toString()
          : null,
    );
  }

  KasForgeToken withMarket(Map market) {
    if (market['network'] != 'testnet-10' ||
        market['covenantId'] != id ||
        market['genesisTxid'] != genesis ||
        market['id'] != curve ||
        market['graduated'] != graduated ||
        market['kind'] != (graduated ? 'pool' : 'curve') ||
        market['market'] != activeMarket) {
      throw StateError(
          'KasForge token list and live market disagree. Reload before continuing.');
    }
    return KasForgeToken(
      id: id,
      symbol: symbol,
      name: name,
      decimals: decimals,
      genesis: genesis,
      curve: curve,
      pool: pool,
      graduated: graduated,
      logo: logo,
      priceKas: KasForgeService.nonnegativeNumber(market['priceKas']),
      marketCapKas: KasForgeService.nonnegativeNumber(market['mcapKas']),
      volume24hKas: KasForgeService.nonnegativeNumber(market['volume24h']),
    );
  }
}
