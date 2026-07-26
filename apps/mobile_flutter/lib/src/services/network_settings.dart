import 'package:shared_preferences/shared_preferences.dart';

class NetworkSettings {
  static const publicKaspaRestUrl = 'https://kaspire.kaslab.space/api';
  static const _legacyPublicKaspaRestUrl = 'https://api.kaspa.org';
  static const _key = 'kaspa_rest_endpoint_v1';
  static String kaspaRestUrl = publicKaspaRestUrl;

  static Future<void> initialize() async {
    final preferences = await SharedPreferences.getInstance();
    final stored = preferences.getString(_key);
    if (stored == _legacyPublicKaspaRestUrl) {
      await preferences.remove(_key);
      kaspaRestUrl = publicKaspaRestUrl;
    } else if (stored != null && isValidEndpoint(stored)) {
      kaspaRestUrl = stored;
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
    kaspaRestUrl = normalized;
    await (await SharedPreferences.getInstance()).setString(_key, normalized);
  }

  static Future<void> reset() async {
    kaspaRestUrl = publicKaspaRestUrl;
    await (await SharedPreferences.getInstance()).remove(_key);
  }
}
