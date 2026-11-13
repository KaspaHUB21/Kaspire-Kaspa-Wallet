import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:reown_walletkit/reown_walletkit.dart';
import 'package:kasvault_wallet/src/app.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/services/dapp_session_service.dart';
import 'dapp_request_recovery_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('space.kasvault/security');
  for (final theme in KaspireTheme.values)
    for (final approve in [false, true]) {
      testWidgets(
          'PSKT 56,899-byte review explicit approve=$approve ${theme.name} at 320px',
          (tester) async {
        tester.view.physicalSize = const Size(320, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues(
            {'watch_address_v1': fixture.wallet});
        FlutterSecureStorage.setMockInitialValues({});
        AppSettings.lockMinutes.value = 0;
        AppSettings.theme.value = theme;
        addTearDown(() {
          AppSettings.lockMinutes.value = 15;
          AppSettings.theme.value = KaspireTheme.midnight;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });
        final methods = <String>[],
            kit = fixture.FakeKit(),
            service = DappSessionService.forTesting(() async => kit);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
          methods.add(call.method);
          switch (call.method) {
            case 'initializeVault':
            case 'setInternalNexusUnlocked':
              return null;
            case 'hasNativeWallet':
              return true;
            case 'preparePskt':
              final request =
                  jsonDecode((call.arguments as Map)['request'] as String)
                      as Map;
              expect((request['scripts'] as List).single['scriptHex'].length,
                  56899 * 2);
              return jsonEncode({
                'reviewHash': 'e' * 64,
                'transactionId': 'f' * 64,
                'walletNetSompi': -1000000,
                'feeSompi': 1000000,
                'finalFeeKnown': true,
                'selectedInputCount': 1,
                'inputCount': 1,
                'outputCount': 1,
                'inputs': [],
                'outputs': [],
                'warnings': [
                  'Unknown covenant business rules: verify independently.'
                ],
                'payloadHex': ''
              });
            case 'authorizeOperation':
              return 'fixture-authorization';
            case 'signPskt':
              return jsonEncode({
                'signedTxJson': 'signed-fixture-only',
                'transactionId': 'f' * 64
              });
            default:
              throw StateError('Unexpected operation ${call.method}');
          }
        });
        for (final name in [
          'com.llfbandit.app_links/messages',
          'com.llfbandit.app_links/events'
        ])
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
        await tester.pumpWidget(KasVaultApp(
            dappSessions: service,
            dappApiFactory: () => fixture.HoldingsOnlyApi()));
        await tester.pumpAndSettle();
        final request = SessionRequest(
            id: 901,
            topic: fixture.topic,
            chainId: 'kaspa:mainnet',
            method: 'kaspa_signPskt',
            params: {
              'psktTransactionJson': '{"version":1}',
              'options': {
                'signInputs': [
                  {'index': 0}
                ]
              },
              'scripts': [
                {'inputIndex': 0, 'scriptHex': '00' * 56899}
              ],
              'submitTransaction': false
            },
            verifyContext: fixture.verification);
        kit.requests['901'] = request;
        kit.onSessionRequest
            .broadcast(SessionRequestEvent.fromSessionRequest(request));
        await tester.pumpAndSettle();
        expect(find.text('GothDAG requests PSKT signing'), findsOneWidget);
        expect(find.text('Important Warnings'), findsOneWidget);
        expect(methods.contains('signPskt'), false);
        await tester.tap(approve
            ? find.byType(FilledButton).last
            : find.widgetWithText(TextButton, 'Reject'));
        await tester.pumpAndSettle();
        expect(kit.responses, hasLength(1));
        if (approve) {
          expect(kit.responses.single.result,
              {'psktTransactionJson': 'signed-fixture-only'});
          expect(methods.where((v) => v == 'signPskt'), hasLength(1));
        } else {
          expect(kit.responses.single.error?.code, 4001);
          expect(methods.contains('authorizeOperation'), false);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }
}
