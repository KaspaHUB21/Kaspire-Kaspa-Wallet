import 'dart:convert';

import 'package:http/http.dart' as http;

import 'network_settings.dart';

class EvmNetworkConfig {
  const EvmNetworkConfig({
    required this.name,
    required this.chainId,
    required this.rpcUrl,
    required this.explorerUrl,
    required this.explorerApiUrl,
    required this.nativeSymbol,
    required this.wrappedNative,
  });
  final String name;
  final int chainId;
  final String rpcUrl;
  final String explorerUrl;
  final String explorerApiUrl;
  final String nativeSymbol;
  final String wrappedNative;

  static EvmNetworkConfig get current =>
      NetworkSettings.network.value == KaspaNetwork.kasplex ? kasplex : igra;
  static const kasplex = EvmNetworkConfig(
    name: 'Kasplex zkEVM Mainnet',
    chainId: 202555,
    rpcUrl: 'https://evmrpc.kasplex.org',
    explorerUrl: 'https://explorer.kasplex.org',
    explorerApiUrl: 'https://api-explorer2.kasplex.org/api/v2',
    nativeSymbol: 'KAS',
    wrappedNative: '0x2c2Ae87Ba178F48637acAe54B87c3924F544a83e',
  );
  static const igra = EvmNetworkConfig(
    name: 'Igra Network',
    chainId: 38833,
    rpcUrl: 'https://rpc.igralabs.com:8545',
    explorerUrl: 'https://explorer.igralabs.com',
    explorerApiUrl: 'https://explorer.igralabs.com/api/v2',
    nativeSymbol: 'iKAS',
    wrappedNative: '0x17Ec7E1768c813E2a3a9b0f94A35605CA520C242',
  );
}

class EvmToken {
  const EvmToken(
      {required this.contract,
      required this.symbol,
      required this.name,
      required this.decimals,
      required this.rawBalance,
      required this.trusted,
      this.iconUrl});
  final String contract;
  final String symbol;
  final String name;
  final int decimals;
  final BigInt rawBalance;
  final bool trusted;
  final String? iconUrl;
}

class EvmSnapshot {
  const EvmSnapshot(
      {required this.address,
      required this.nativeBalance,
      required this.tokens});
  final String address;
  final BigInt nativeBalance;
  final List<EvmToken> tokens;
}

class EvmActivity {
  const EvmActivity(
      {required this.hash,
      required this.from,
      required this.to,
      required this.value,
      required this.fee,
      required this.timestamp,
      required this.success,
      this.method,
      this.assetSymbol,
      this.decimals = 18});
  final String hash;
  final String from;
  final String to;
  final BigInt value;
  final BigInt fee;
  final DateTime? timestamp;
  final bool success;
  final String? method;
  final String? assetSymbol;
  final int decimals;
}

class EvmApi {
  EvmApi({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  int _rpcId = 0;

  Future<Object?> rpc(String method, List<Object?> params) async {
    final config = EvmNetworkConfig.current;
    final response = await _client
        .post(Uri.parse(config.rpcUrl),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({
              'jsonrpc': '2.0',
              'id': ++_rpcId,
              'method': method,
              'params': params
            }))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw StateError(
          '${config.name} RPC returned HTTP ${response.statusCode}.');
    }
    final decoded = jsonDecode(response.body) as Map;
    if (decoded['error'] != null) {
      throw StateError('RPC: ${(decoded['error'] as Map)['message']}');
    }
    return decoded['result'];
  }

  Future<EvmSnapshot> loadWallet(String address) async {
    final results = await Future.wait([
      rpc('eth_getBalance', [address, 'latest']),
      _loadTokenBalances(address),
      _trustedContracts(),
    ]);
    final trusted = results[2] as Set<String>;
    final tokens = (results[1] as List<Map<String, Object?>>)
        .map((row) {
          final token =
              (row['token'] as Map? ?? const {}).cast<String, Object?>();
          final contract =
              (token['address_hash'] ?? token['address'] ?? '').toString();
          return EvmToken(
            contract: contract,
            symbol: (token['symbol'] ?? 'TOKEN').toString().toUpperCase(),
            name: (token['name'] ?? 'Unknown token').toString(),
            decimals: int.tryParse('${token['decimals'] ?? 18}') ?? 18,
            rawBalance: BigInt.tryParse('${row['value'] ?? 0}') ?? BigInt.zero,
            trusted: trusted.contains(contract.toLowerCase()),
            iconUrl: token['icon_url']?.toString(),
          );
        })
        .where((token) =>
            token.rawBalance > BigInt.zero && token.contract.isNotEmpty)
        .toList()
      ..sort((a, b) => a.symbol.compareTo(b.symbol));
    return EvmSnapshot(
      address: address,
      nativeBalance: _hexInt(results[0]),
      tokens: tokens,
    );
  }

  Future<List<Map<String, Object?>>> _loadTokenBalances(String address) async {
    final url =
        '${EvmNetworkConfig.current.explorerApiUrl}/addresses/$address/token-balances';
    final response =
        await _client.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw StateError('L2 explorer returned HTTP ${response.statusCode}.');
    }
    return (jsonDecode(response.body) as List)
        .whereType<Map>()
        .map((item) => item.cast<String, Object?>())
        .toList();
  }

  Future<Set<String>> _trustedContracts() async {
    final trusted = <String>{
      EvmNetworkConfig.current.wrappedNative.toLowerCase(),
      if (NetworkSettings.network.value == KaspaNetwork.igra) ...{
        '0x093d77d397f8accbaee0820345e9e700b1233cd1',
        '0x434591c88ec6fdbc6ca1b9155a4dad375232ed8e',
        '0x16d92794f5b81d2cded0f0958779a410401e6435',
      },
    };
    try {
      final response = await _client
          .get(Uri.parse('https://api.katbridge.com/token-pair'))
          .timeout(const Duration(seconds: 8));
      final decoded = jsonDecode(response.body);
      final rows = decoded is List
          ? decoded
          : ((decoded as Map)['result'] as List? ??
              decoded['data'] as List? ??
              const []);
      for (final raw in rows.whereType<Map>()) {
        if (raw['is_active'] == false) continue;
        final chain = int.tryParse(
            '${raw['chainId'] ?? raw['chain_id'] ?? raw['l2_chain_id'] ?? 0}');
        final address = (raw['l2Contract'] ??
                raw['l2_contract'] ??
                raw['contractAddress'] ??
                raw['l2_address'] ??
                '')
            .toString();
        if (chain == EvmNetworkConfig.current.chainId &&
            RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(address)) {
          trusted.add(address.toLowerCase());
        }
      }
    } catch (_) {}
    return trusted;
  }

  Future<BigInt> nonce(String address) async =>
      _hexInt(await rpc('eth_getTransactionCount', [address, 'pending']));
  Future<BigInt> gasPrice() async =>
      _hexInt(await rpc('eth_gasPrice', const []));
  Future<BigInt> tokenBalance(String contract, String address) async {
    final data = '0x70a08231${address.substring(2).padLeft(64, '0')}';
    return _hexInt(await rpc('eth_call', [
      {'to': contract, 'data': data},
      'latest'
    ]));
  }

  Future<BigInt> estimateGas(
          String from, String to, String valueWei, String data) async =>
      _hexInt(await rpc('eth_estimateGas', [
        {
          'from': from,
          'to': to,
          'value': _toHex(BigInt.parse(valueWei)),
          if (data.isNotEmpty) 'data': data
        }
      ]));
  Future<String> broadcast(String raw) async =>
      (await rpc('eth_sendRawTransaction', [raw])).toString();

  Future<Map<String, Object?>> waitForReceipt(String hash) async {
    for (var attempt = 0; attempt < 30; attempt++) {
      final raw = await rpc('eth_getTransactionReceipt', [hash]);
      if (raw is Map) {
        final receipt = raw.cast<String, Object?>();
        if (_hexInt(receipt['status']) != BigInt.one) {
          throw StateError('The network rejected the transaction on-chain.');
        }
        return receipt;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw StateError(
        'Transaction broadcast, but confirmation is still pending.');
  }

  Future<List<EvmActivity>> loadActivity(String address,
      {int limit = 20}) async {
    final base = EvmNetworkConfig.current.explorerApiUrl;
    final responses = await Future.wait([
      _client.get(Uri.parse('$base/addresses/$address/transactions')),
      _client.get(Uri.parse('$base/addresses/$address/token-transfers')),
    ]).timeout(const Duration(seconds: 12));
    if (responses.first.statusCode != 200) {
      throw StateError(
          'L2 activity service returned HTTP ${responses.first.statusCode}.');
    }
    final decoded = jsonDecode(responses.first.body);
    final rows =
        decoded is Map ? (decoded['items'] as List? ?? const []) : const [];
    final activity = rows
        .whereType<Map>()
        .take(limit)
        .map((row) {
          final gasUsed =
              BigInt.tryParse('${row['gas_used'] ?? 0}') ?? BigInt.zero;
          final gasPrice =
              BigInt.tryParse('${row['gas_price'] ?? 0}') ?? BigInt.zero;
          final status = '${row['status'] ?? row['result'] ?? ''}'.toLowerCase();
          return EvmActivity(
            hash: '${row['hash'] ?? ''}',
            from: '${(row['from'] as Map?)?['hash'] ?? row['from'] ?? ''}',
            to: '${(row['to'] as Map?)?['hash'] ?? row['to'] ?? ''}',
            value: BigInt.tryParse('${row['value'] ?? 0}') ?? BigInt.zero,
            fee: gasUsed * gasPrice,
            timestamp: DateTime.tryParse('${row['timestamp'] ?? ''}'),
            success: status == 'ok' || status == 'success',
            method: row['method']?.toString(),
          );
        })
        .where((tx) => tx.hash.isNotEmpty)
        .toList();
    if (responses[1].statusCode == 200) {
      final tokenDecoded = jsonDecode(responses[1].body);
      final tokenRows = tokenDecoded is Map
          ? (tokenDecoded['items'] as List? ?? const [])
          : const [];
      for (final row in tokenRows.whereType<Map>()) {
        final token = row['token'] is Map ? row['token'] as Map : const {};
        final total = row['total'] is Map ? row['total'] as Map : const {};
        activity.add(EvmActivity(
          hash: '${row['transaction_hash'] ?? row['tx_hash'] ?? ''}',
          from: '${(row['from'] as Map?)?['hash'] ?? row['from'] ?? ''}',
          to: '${(row['to'] as Map?)?['hash'] ?? row['to'] ?? ''}',
          value: BigInt.tryParse('${total['value'] ?? row['value'] ?? 0}') ??
              BigInt.zero,
          fee: BigInt.zero,
          timestamp: DateTime.tryParse('${row['timestamp'] ?? ''}'),
          success: true,
          method: 'Token transfer',
          assetSymbol: '${token['symbol'] ?? 'TOKEN'}'.toUpperCase(),
          decimals:
              int.tryParse('${token['decimals'] ?? total['decimals'] ?? 18}') ??
                  18,
        ));
      }
    }
    activity.sort((a, b) =>
        (b.timestamp ?? DateTime.fromMillisecondsSinceEpoch(0))
            .compareTo(a.timestamp ?? DateTime.fromMillisecondsSinceEpoch(0)));
    return activity.take(limit).toList();
  }

  static String erc20TransferData(String recipient, BigInt amount) =>
      '0xa9059cbb${recipient.substring(2).padLeft(64, '0')}${amount.toRadixString(16).padLeft(64, '0')}';
  static BigInt _hexInt(Object? value) =>
      BigInt.parse(value?.toString().replaceFirst('0x', '') ?? '0', radix: 16);
  static String _toHex(BigInt value) => '0x${value.toRadixString(16)}';
}

BigInt parseUnits(String value, int decimals) {
  final normalized = value.trim().replaceAll(',', '.');
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(normalized)) {
    throw const FormatException('Invalid amount.');
  }
  final parts = normalized.split('.');
  if (parts.length > 1 && parts[1].length > decimals) {
    throw FormatException('Use no more than $decimals decimal places.');
  }
  final fraction = parts.length == 1 ? '' : parts[1];
  final paddedFraction = fraction.padRight(decimals, '0');
  return BigInt.parse(parts[0]) * BigInt.from(10).pow(decimals) +
      BigInt.parse(paddedFraction.isEmpty ? '0' : paddedFraction);
}

String formatUnits(BigInt value, int decimals, {int visible = 6}) {
  final raw = value.toString().padLeft(decimals + 1, '0');
  final whole = raw.substring(0, raw.length - decimals);
  final fraction = raw
      .substring(raw.length - decimals)
      .substring(0, visible.clamp(0, decimals))
      .replaceFirst(RegExp(r'0+$'), '');
  return fraction.isEmpty ? whole : '$whole.$fraction';
}
