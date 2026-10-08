import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kasvault_wallet/src/services/nexus_service.dart';
import 'package:kasvault_wallet/src/services/native_security.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class SessionService extends NexusService {
  SessionService(super.address);
  @override
  Future<void> guard() async {}
}

class LoginService extends NexusService {
  LoginService(super.address, {required super.client});
  @override
  Future<void> guard() async {
    if (!NativeSecurity.internalNexusUnlocked) throw StateError('Locked');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'internal offers authenticate on unlock without a second PIN or signing approval',
      () async {
    NexusService.disconnect();
    FlutterSecureStorage.setMockInitialValues({});
    final methods = <String>[];
    const channel = MethodChannel('space.kasvault/security');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'signInternalNexusChallenge') {
        return jsonEncode({'signature': 'test-signature'});
      }
      if (call.method == 'publicKey') {
        return jsonEncode({'publicKey': 'test-public-key'});
      }
      throw StateError('Unexpected authentication: ${call.method}');
    });
    const address = 'kaspa:test';
    final nonce = 'a' * 43,
        issued = DateTime.now().toUtc().toIso8601String(),
        expires = DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 5))
            .toIso8601String();
    final service = LoginService(address, client: MockClient((request) async {
      if (request.url.path.endsWith('internal-challenge')) {
        return http.Response(
            jsonEncode({
              'nonce': nonce,
              'expiresAt': expires,
              'message':
                  'Kaspire Internal NFT Offers\n\nDomain: kaspire.kaslab.space\nPurpose: internal-private-offers-v1\nWallet: $address\nNonce: $nonce\nIssued at: $issued\nExpires at: $expires\n\nAuthenticate this wallet for private offers and notifications inside Kaspire only.\nThis signature does not create a transaction or spend funds.'
            }),
            200);
      }
      return http.Response(
          jsonEncode({'walletAddress': address, 'token': 'test-only-bearer'}),
          200);
    }));
    try {
      NativeSecurity.internalNexusUnlocked = false;
      expect(await service.connect(), false);
      expect(methods, isEmpty);
      NativeSecurity.internalNexusUnlocked = true;
      expect(await service.connect(), true);
      expect(methods, ['signInternalNexusChallenge', 'publicKey']);
      expect(await service.connect(), true);
      expect(methods.length, 2);
    } finally {
      NativeSecurity.internalNexusUnlocked = false;
      NexusService.disconnect();
      service.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });
  test(
      'encrypted notification bearer restores without requesting a signature, only for its wallet',
      () async {
    NexusService.disconnect();
    FlutterSecureStorage.setMockInitialValues({
      'kaspire-private-nft-notifications-v1:kaspa:test': jsonEncode({
        'address': 'kaspa:test',
        'token': 'test-only-bearer',
        'expires': DateTime.now().add(const Duration(days: 1)).toIso8601String()
      })
    });
    final other = SessionService('kaspa:other'),
        own = SessionService('kaspa:test');
    expect(await other.restoreSession(), false);
    expect(await own.restoreSession(), true);
    expect(own.connected, true);
    NexusService.disconnect();
    own.close();
    other.close();
  });
}
