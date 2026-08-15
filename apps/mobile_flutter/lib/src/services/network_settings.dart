import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

import '../kaspa_address.dart';

enum KaspaNetwork { mainnet, tn10, kasplex, igra }

class NetworkSettings {
  static const publicKaspaRestUrl = 'https://kaspire.kaslab.space/api';
  static const mainnetFallbackRestUrl = 'https://api.kaspa.org';
  static const tn10RestUrl = 'https://api-tn10.kaspa.org';
  static const _key = 'kaspa_rest_endpoint_v1';
  static const _networkKey = 'kaspa_network_v1';
  static String _mainnetRestUrl = publicKaspaRestUrl;
  static final ValueNotifier<KaspaNetwork> network =
      ValueNotifier(KaspaNetwork.mainnet);

  static bool get isTestnet => network.value == KaspaNetwork.tn10;
  static bool get isEvm =>
      network.value == KaspaNetwork.kasplex ||
      network.value == KaspaNetwork.igra;
  static bool get isKaspa => !isEvm;
  static String get kaspaRestUrl => isTestnet ? tn10RestUrl : _mainnetRestUrl;
  static String get publicKaspaFallbackRestUrl =>
      isTestnet ? tn10RestUrl : mainnetFallbackRestUrl;
  static String get label => switch (network.value) {
        KaspaNetwork.mainnet => 'MAINNET',
        KaspaNetwork.tn10 => 'TN10',
        KaspaNetwork.kasplex => 'KASPLEX',
        KaspaNetwork.igra => 'IGRA',
      };
  static String get displayName => switch (network.value) {
        KaspaNetwork.mainnet => 'Kaspa Mainnet',
        KaspaNetwork.tn10 => 'Kaspa Testnet 10',
        KaspaNetwork.kasplex => 'Kasplex zkEVM Mainnet',
        KaspaNetwork.igra => 'Igra Network',
      };
  static String get addressPrefix => isTestnet ? 'kaspatest' : 'kaspa';

  static Future<void> initialize() async {
    final preferences = await SharedPreferences.getInstance();
    network.value = KaspaNetwork.values.firstWhere(
      (value) => value.name == preferences.getString(_networkKey),
      orElse: () => KaspaNetwork.mainnet,
    );
    final stored = preferences.getString(_key);
    if (stored == mainnetFallbackRestUrl) {
      await preferences.remove(_key);
      _mainnetRestUrl = publicKaspaRestUrl;
    } else if (stored != null && isValidEndpoint(stored)) {
      _mainnetRestUrl = stored;
    }
  }

  static bool isValidEndpoint(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment;
  }

  static Future<void> save(String value) async {
    final normalized = value.trim().replaceFirst(RegExp(r'/+$'), '');
    if (!isValidEndpoint(normalized)) {
      throw const FormatException(
        'Enter an HTTPS Kaspa REST endpoint without credentials or query parameters.',
      );
    }
    _mainnetRestUrl = normalized;
    await (await SharedPreferences.getInstance()).setString(_key, normalized);
  }

  static Future<void> reset() async {
    _mainnetRestUrl = publicKaspaRestUrl;
    await (await SharedPreferences.getInstance()).remove(_key);
  }

  static Future<void> setNetwork(KaspaNetwork value) async {
    if (network.value == value) return;
    network.value = value;
    await (await SharedPreferences.getInstance())
        .setString(_networkKey, value.name);
  }

  static String addressForNetwork(String storedAddress) {
    final converted = kaspaAddressWithPrefix(storedAddress, addressPrefix);
    return converted.isEmpty ? storedAddress : converted;
  }

  static String storageAddress(String networkAddress) {
    final converted = kaspaAddressWithPrefix(networkAddress, 'kaspa');
    return converted.isEmpty ? networkAddress : converted;
  }
}
