import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kasvault_wallet/src/services/update_service.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('accepts a verified newer Kaspire release', () async {
    final service = UpdateService(
      client: MockClient((_) async => http.Response(_envelope(build: 70), 200)),
      verifier: (_, signature) async => signature == 'valid',
      packageInfo: () async => _packageInfo(build: 69),
    );

    final update = await service.checkNow();

    expect(update?.version, '0.11.12');
    expect(update?.build, 70);
    expect(service.state.value.error, isNull);
  });

  test('does not advertise the installed build', () async {
    final service = UpdateService(
      client: MockClient((_) async => http.Response(_envelope(build: 69), 200)),
      verifier: (_, __) async => true,
      packageInfo: () async => _packageInfo(build: 69),
    );

    expect(await service.checkNow(), isNull);
    expect(service.state.value.update, isNull);
  });

  test('rejects an invalid signature and hostile download host', () async {
    final invalidSignature = UpdateService(
      client: MockClient((_) async => http.Response(_envelope(build: 70), 200)),
      verifier: (_, __) async => false,
      packageInfo: () async => _packageInfo(build: 69),
    );
    expect(await invalidSignature.checkNow(), isNull);
    expect(
        invalidSignature.state.value.error, contains('signature is invalid'));

    final hostileHost = UpdateService(
      client: MockClient(
        (_) async => http.Response(
          _envelope(build: 70, apkHost: 'attacker.example'),
          200,
        ),
      ),
      verifier: (_, __) async => true,
      packageInfo: () async => _packageInfo(build: 69),
    );
    expect(await hostileHost.checkNow(), isNull);
    expect(hostileHost.state.value.error, contains('invalid fields'));
  });

  test('remind later suppresses the current build for one day', () async {
    final service = UpdateService(
      client: MockClient((_) async => http.Response(_envelope(build: 70), 200)),
      verifier: (_, __) async => true,
      packageInfo: () async => _packageInfo(build: 69),
    );
    final update = await service.checkNow();
    expect(update, isNotNull);

    await service.remindLater(update!);
    expect(await service.checkNow(), isNull);
  });

  test('automatic check fetches on every cold start despite a recent check',
      () async {
    var requests = 0;
    SharedPreferences.setMockInitialValues({
      'updates_last_checked_v1': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
    final service = UpdateService(
      client: MockClient((request) async {
        requests++;
        expect(request.url.queryParameters['check'], isNotEmpty);
        expect(request.headers['Cache-Control'], contains('no-store'));
        return http.Response(_envelope(build: 70), 200);
      }),
      verifier: (_, __) async => true,
      packageInfo: () async => _packageInfo(build: 69),
    );

    await service.checkIfDue();

    expect(requests, 1);
    expect(service.state.value.update?.build, 70);
  });

  test('automatic check remains disabled when the user turned it off',
      () async {
    var requests = 0;
    SharedPreferences.setMockInitialValues({'updates_automatic_v1': false});
    final service = UpdateService(
      client: MockClient((_) async {
        requests++;
        return http.Response(_envelope(build: 70), 200);
      }),
      verifier: (_, __) async => true,
      packageInfo: () async => _packageInfo(build: 69),
    );

    await service.checkIfDue();

    expect(requests, 0);
    expect(service.state.value.update, isNull);
  });
}

PackageInfo _packageInfo({required int build}) => PackageInfo(
      appName: 'Kaspire',
      packageName: 'space.kaspire.wallet',
      version: '0.11.11',
      buildNumber: '$build',
    );

String _envelope(
    {required int build, String apkHost = 'kaspire.kaslab.space'}) {
  final payload = jsonEncode({
    'version': '0.11.12',
    'build': build,
    'minimumBuild': 69,
    'critical': false,
    'publishedAt': '2026-08-02T12:00:00Z',
    'apkUrl': 'https://$apkHost/downloads/Kaspire-Android-mainnet-v0.11.12.apk',
    'sha256': 'a' * 64,
    'releaseNotesUrl':
        'https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/tag/v0.11.12',
  });
  return jsonEncode({
    'payload': base64Encode(utf8.encode(payload)),
    'signature': 'valid',
  });
}
