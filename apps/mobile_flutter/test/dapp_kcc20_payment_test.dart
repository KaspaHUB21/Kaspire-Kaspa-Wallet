import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reown_walletkit/reown_walletkit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kasvault_wallet/src/app.dart';
import 'package:kasvault_wallet/src/models/wallet_snapshot.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/services/dapp_kcc20_payment.dart';
import 'package:kasvault_wallet/src/services/dapp_session_service.dart';
import 'package:kasvault_wallet/src/services/kcc20_compound.dart';
import 'package:kasvault_wallet/src/services/kcc20_standard_service.dart';
import 'package:kasvault_wallet/src/services/native_security.dart';
import 'dapp_request_recovery_test.dart' as fixture;

const cid = '82f033aed87d6eb39f509b51b1c817a49e0b07c4789b619cab08d4c8fb82d18e';
const pool =
    'kaspa:qqre4wt08dp0rvmxwqgwdkz4zu4m36g9uvmfledd27mx939uxe2yjpmmd37zq';
Kcc20CellRecord cell([int units = 10000000000]) => Kcc20CellRecord(
    covenantId: cid,
    transactionId: 'a' * 64,
    index: 0,
    valueSompi: 100000000,
    blockDaaScore: 123,
    scriptPublicKey: 'aa20${'b' * 64}87',
    tokenAmount: units,
    redeemScript: '51');

class SelectedApi extends fixture.HoldingsOnlyApi {
  Completer<void>? gate;
  bool badUnits = false, borrowFailed = false;
  int batches = 0, borrows = 0, broadcasts = 0;
  @override
  Kcc20StandardService get standardKcc20 =>
      Kcc20StandardService(MockClient((r) async {
        expect(r.url.path.endsWith('/tokens/$cid'), true);
        return http.Response(
            jsonEncode({
              'meta': {
                'network': 'mainnet',
                'reference_commit': Kcc20StandardService.reference
              },
              'data': {
                'covenant_id': cid,
                'recognition': 'hash_proven_reference_actor_family',
                'template_hash': Kcc20StandardService.templateHash,
                'metadata': {
                  'binding_verified': !badUnits,
                  'ticker': 'KASPIRE',
                  'decimals': 8,
                  'covenant_id': cid
                }
              }
            }),
            200);
      }));
  @override
  Future<Kcc20Step> loadStandardKcc20SigningBatch(
      String address, String covenantId, int amount,
      {bool Function()? isCancelled,
      void Function(String)? onProgress,
      String? sourceStandard,
      bool fullPlan = false}) async {
    expect(fullPlan, true);
    expect(amount, 2100000000);
    batches++;
    await gate?.future;
    return Kcc20Step([cell()], amount, false,
        templateId: Kcc20StandardService.templateId);
  }

  @override
  Future<Kcc20CellRecord?> loadKcc20BorrowedReceive(String recipient,
      String covenant, int amount, Kcc20CellRecord first, String templateId,
      {bool Function()? isCancelled}) async {
    borrows++;
    if (borrowFailed) throw StateError('Recipient lookup unavailable');
    return cell(50000000000);
  }

  @override
  Future<bool> kcc20PlanTransactionAccepted(String id) async => broadcasts > 0;
  @override
  Future<String> broadcastKcc20(String bytes,
      {String? expectedTransactionId}) async {
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('kaspire_pending_kcc20_compound_${fixture.wallet}'),
        isNotNull,
        reason: 'persist exact signed bytes before broadcasting');
    broadcasts++;
    return expectedTransactionId!;
  }
}

Map<String, Object?> plan() => {
      'reviewHash': 'e' * 64,
      'totalFeeSompi': 1000,
      'transactionCount': 1,
      'steps': [
        {
          'feeSompi': 1000,
          'feeMass': 2000,
          'lockedKasOutputSompi': 200000000,
          'psktRequest': {
            'tradeSummary': {'amount': 2100000000}
          }
        }
      ]
    };
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('space.kasvault/security');
  final methods = <String>[];
  setUp(() {
    methods.clear();
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(
        {'watch_address_v1': fixture.wallet});
    AppSettings.lockMinutes.value = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      switch (call.method) {
        case 'initializeVault':
        case 'setInternalNexusUnlocked':
          return null;
        case 'hasNativeWallet':
          return true;
        case 'prepareKcc20Plan':
          final req =
              jsonDecode((call.arguments as Map)['request'] as String) as Map;
          expect(req['amount'], 2100000000);
          expect(req['recipient'], pool);
          expect((req['borrowedReceive'] as Map)['tokenAmount'], 50000000000);
          expect((req['cells'] as List).single.containsKey('isMinter'), false);
          return jsonEncode(plan());
        case 'authorizeOperation':
          return 'fixture-authorization';
        case 'signKcc20Plan':
          return jsonEncode({
            'reviewHash': 'e' * 64,
            'totalFeeSompi': 1000,
            'transactions': [
              {
                'transactionId': 'f' * 64,
                'signedTxJson': 'saved-public-fixture-bytes'
              }
            ]
          });
        case 'getEncryptedData':
        case 'readEncrypted':
          return null;
        case 'setEncryptedData':
        case 'writeEncrypted':
          return true;
        default:
          throw StateError('Unexpected native method ${call.method}');
      }
    });
    for (final name in [
      'com.llfbandit.app_links/messages',
      'com.llfbandit.app_links/events'
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });
  tearDown(() {
    AppSettings.lockMinutes.value = 15;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  Future<DappKcc20Payment> prepare(SelectedApi api) => prepareDappKcc20Payment(
      api: api,
      security: NativeSecurity(),
      sender: fixture.wallet,
      recipient: pool,
      covenantId: cid,
      amount: 2100000000,
      isCancelled: () => false);
  test(
      'fresh selected-token proof, borrowed receive and complete native plan; no wallet scan',
      () async {
    final api = SelectedApi(), p = await prepare(api);
    expect(p.ticker, 'KASPIRE');
    expect(p.recipientCellStatus, 'reused');
    expect(api.scans, 0);
    expect(api.batches, 1);
    expect(api.borrows, 1);
    expect(methods, ['prepareKcc20Plan']);
  });
  test('unverified units fail before preparing or signing', () async {
    final api = SelectedApi()..badUnits = true;
    await expectLater(prepare(api), throwsStateError);
    expect(api.batches, 0);
    expect(methods, isEmpty);
  });
  test('recipient lookup failure cannot silently fund a fresh cell', () async {
    final api = SelectedApi()..borrowFailed = true;
    await expectLater(prepare(api), throwsStateError);
    expect(methods, isEmpty);
  });
  for (final approve in [false, true]) {
    testWidgets(
        'real app KCC20 request reaches review without wallet scan; approve=$approve',
        (tester) async {
      final kit = fixture.FakeKit(),
          api = SelectedApi(),
          service = DappSessionService.forTesting(() async => kit);
      await tester.pumpWidget(
          KasVaultApp(dappSessions: service, dappApiFactory: () => api));
      await tester.pumpAndSettle();
      api.gate = Completer<void>();
      final request = SessionRequest(
          id: 701,
          topic: fixture.topic,
          chainId: 'kaspa:mainnet',
          method: 'kaspa_sendKcc20',
          params: {
            'from': fixture.wallet,
            'to': pool,
            'covenantId': cid,
            'amount': '2100000000'
          },
          verifyContext: fixture.verification);
      kit.requests['701'] = request;
      kit.onSessionRequest
          .broadcast(SessionRequestEvent.fromSessionRequest(request));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Preparing KCC20 payment'), findsOneWidget);
      api.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('GothDAG requests KCC20'), findsOneWidget);
      expect(find.text('21 KASPIRE'), findsOneWidget);
      expect(api.scans, 0);
      expect(api.batches, 1);
      await tester.tap(approve
          ? find.byType(FilledButton).last
          : find.widgetWithText(TextButton, 'Reject'));
      await tester.pumpAndSettle();
      if (approve) {
        for (var attempt = 0;
            attempt < 50 && kit.responses.isEmpty;
            attempt++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(kit.responses, hasLength(1),
            reason: 'native calls: $methods; broadcasts: ${api.broadcasts}');
        expect(kit.responses.single.result, isA<Map>());
        expect((kit.responses.single.result as Map)['transactionId'], 'f' * 64);
        expect(api.broadcasts, 1);
      } else {
        expect(kit.responses.single.error?.code, 4001);
        expect(api.broadcasts, 0);
        expect(methods.contains('authorizeOperation'), false);
      }
      expect(
          (await SharedPreferences.getInstance())
              .getString('kaspire_pending_kcc20_compound_${fixture.wallet}'),
          isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}
