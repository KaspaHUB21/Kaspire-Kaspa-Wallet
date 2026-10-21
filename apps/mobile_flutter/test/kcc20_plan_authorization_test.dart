import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/native_security.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('space.kasvault/security');
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));
  test(
      'one native authorization is bound to the entire plan hash, never per-step signatures',
      () async {
    final calls = <MethodCall>[];
    final source = <String, Object?>{
      'sender': 'wallet-A',
      'recipient': 'wallet-B',
      'amount': 69
    };
    final hash = 'a' * 64;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final args = call.arguments as Map;
      if (call.method == 'authorizeOperation') {
        expect(args['operation'], 'signKcc20Plan');
        expect(args['binding'], hash);
        return 'single-use-plan-authorization';
      }
      expect(call.method, 'signKcc20Plan');
      expect(args['authorizationToken'], 'single-use-plan-authorization');
      expect(args['reviewHash'], hash);
      expect(jsonDecode(args['request'] as String), source);
      return jsonEncode({
        'reviewHash': hash,
        'transactions': [{}, {}, {}]
      });
    });
    final signed = await NativeSecurity().signKcc20Plan(source, hash);
    expect(signed['transactions'], hasLength(3));
    expect(calls.map((c) => c.method), ['authorizeOperation', 'signKcc20Plan']);
  });
  test('cancelled whole-plan authorization never invokes the signer', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    await expectLater(
        NativeSecurity().signKcc20Plan({'sender': 'wallet-A'}, 'a' * 64),
        throwsStateError);
    expect(calls, ['authorizeOperation']);
  });
}
