import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'native_security.dart';
import 'network_settings.dart';
import 'preferences_service.dart';

Map<String, Object?> nexusMap(Object? value) =>
    value is Map ? value.cast<String, Object?>() : {};
List<Map<String, Object?>> nexusRows(Object? value) =>
    (value is List ? value : []).map(nexusMap).toList();

/// Offer relay only: no transaction building or custody. Private access is
/// scoped to the unlocked wallet; stored bearers are encrypted on Android.
class NexusService {
  NexusService(this.address, {http.Client? client})
      : client = client ?? http.Client();
  static const base = 'https://kaspire.kaslab.space/nexus-test-v1';
  static String? _sessionAddress, _token;
  static DateTime? _expires;
  static Future<bool>? _connecting;
  static const _secureStorage = FlutterSecureStorage();
  String get _storageKey => 'kaspire-private-nft-notifications-v1:$address';
  Future<bool> restoreSession() async {
    await guard();
    if (connected) return true;
    try {
      final value = await _secureStorage.read(key: _storageKey);
      if (value == null) return false;
      final saved = nexusMap(jsonDecode(value));
      final expires = DateTime.tryParse(saved['expires']?.toString() ?? '');
      if (saved['address'] != address ||
          saved['token'] is! String ||
          expires == null ||
          !expires.isAfter(DateTime.now())) {
        return false;
      }
      await guard();
      _sessionAddress = address;
      _token = saved['token'] as String;
      _expires = expires;
      return true;
    } catch (_) {
      return false;
    }
  }

  final String address;
  final http.Client client;
  bool closed = false;
  bool get connected =>
      _sessionAddress == address &&
      _token != null &&
      _expires != null &&
      _expires!.isAfter(DateTime.now());
  static void disconnect() {
    _token = null;
    _sessionAddress = null;
    _expires = null;
  }

  void close() {
    closed = true;
    client.close();
  }

  Future<void> guard() async {
    if (closed ||
        !NativeSecurity.internalNexusUnlocked ||
        NetworkSettings.network.value != KaspaNetwork.mainnet ||
        await PreferencesService().getAddress() != address) {
      disconnect();
      throw StateError('Account or network changed. Reopen Nexus Offers.');
    }
  }

  Future<Object?> request(String path,
      {Map<String, String> query = const {},
      Map<String, Object?>? body,
      bool private = false}) async {
    await guard();
    if (private && !connected) {
      throw StateError('Unlock your wallet to access private offers.');
    }
    final uri = Uri.parse('$base/$path')
        .replace(queryParameters: query.isEmpty ? null : query);
    final headers = <String, String>{
      'content-type': 'application/json',
      if (private) 'authorization': 'Bearer $_token'
    };
    final response = await (body == null
            ? client.get(uri, headers: headers)
            : client.post(uri, headers: headers, body: jsonEncode(body)))
        .timeout(const Duration(seconds: 45));
    await guard();
    final data = jsonDecode(response.body);
    if (response.statusCode == 401) {
      try {
        await _secureStorage.delete(key: _storageKey);
      } catch (_) {}
      disconnect();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(nexusMap(data)['error']?.toString() ??
          'Nexus unavailable (${response.statusCode}).');
    }
    return data;
  }

  Future<bool> connect([BuildContext? context]) async {
    if (!NativeSecurity.internalNexusUnlocked) return false;
    if (_connecting != null) {
      await _connecting;
      return connected;
    }
    final pending = _connect();
    _connecting = pending;
    try {
      return await pending;
    } finally {
      _connecting = null;
    }
  }

  Future<bool> _connect() async {
    if (connected || await restoreSession()) return true;
    await guard();
    final challenge = nexusMap(await request('auth/internal-challenge',
        body: {'walletAddress': address}));
    final message = challenge['message']?.toString() ?? '',
        nonce = challenge['nonce']?.toString() ?? '';
    final expiry = DateTime.tryParse(challenge['expiresAt']?.toString() ?? '');
    final issuedAt =
        RegExp(r'\nIssued at: ([^\n]+)\n').firstMatch(message)?.group(1) ?? '';
    final issued = DateTime.tryParse(issuedAt);
    final expected =
        'Kaspire Internal NFT Offers\n\nDomain: kaspire.kaslab.space\nPurpose: internal-private-offers-v1\nWallet: $address\nNonce: $nonce\nIssued at: $issuedAt\nExpires at: ${challenge['expiresAt']}\n\nAuthenticate this wallet for private offers and notifications inside Kaspire only.\nThis signature does not create a transaction or spend funds.';
    // Never automatically authorize website login or arbitrary signing text.
    if (message != expected ||
        issued == null ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(nonce) ||
        expiry == null ||
        expiry.difference(issued) <= Duration.zero ||
        expiry.difference(issued) > const Duration(minutes: 6)) {
      throw StateError(
          'Invalid internal NFT authentication. Nothing was signed.');
    }
    final security = NativeSecurity();
    await guard();
    final signature =
        await security.signInternalNexusChallenge(address, message);
    await guard();
    final publicKey = await security.publicKey(address);
    final result = nexusMap(await request('auth/internal-verify', body: {
      'walletAddress': address,
      'nonce': nonce,
      'signature': signature,
      'publicKey': publicKey
    }));
    if (result['walletAddress'] != address || result['token'] is! String) {
      throw StateError('Nexus returned an invalid wallet session.');
    }
    _sessionAddress = address;
    _token = result['token'] as String;
    _expires = DateTime.now().add(const Duration(days: 7));
    try {
      await _secureStorage.write(
          key: _storageKey,
          value: jsonEncode({
            'address': address,
            'token': _token,
            'expires': _expires!.toIso8601String()
          }));
    } catch (_) {/* In-memory access remains usable if secure storage fails. */}
    return true;
  }
}
