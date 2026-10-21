import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kasvault_wallet/src/models/asset_send_intent.dart';
import 'package:kasvault_wallet/src/models/wallet_snapshot.dart';
import 'package:kasvault_wallet/src/screens/asset_send_screen.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';
import 'package:kasvault_wallet/src/services/kcc20_compound.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';

const address = 'kaspa:test';
final cid = 'c' * 64;
final token = WalletAsset(
    symbol: 'TEST.K',
    balance: 100,
    rawBalance: '100',
    decimals: 0,
    kind: 'KCC20',
    covenantId: cid,
    standard: 'kcc20',
    templateHash: 'argent-kcc20-c8a0871');
final snapshot = WalletSnapshot(
    balanceSompi: 100000000,
    kasUsd: null,
    transactions: [],
    krc20Tokens: [],
    krc721Collections: [],
    knsDomains: [],
    kcc20Tokens: [token]);

class SendApi extends KaspaApi {
  SendApi(this.count);
  final int count;
  int walletLoads = 0, waits = 0, proofs = 0;
  bool accepted = true;
  final broadcasts = <String>[];
  @override
  Future<bool> isKcc20TransactionAccepted(String transactionId) async =>
      accepted;
  @override
  Future<String> broadcastKcc20(String wrpcJson,
      {String? expectedTransactionId}) async {
    broadcasts.add(wrpcJson);
    return expectedTransactionId!;
  }

  @override
  Future<WalletSnapshot> loadWallet(String address,
      {int transactionLimit = 20,
      bool includeNativeTransactions = true,
      bool includeAssetHistory = true,
      bool includeMarketData = true,
      void Function(WalletSnapshot)? onProgress}) async {
    walletLoads++;
    return snapshot;
  }

  @override
  Future<String> resolveWalletInput(String input) async => input;
  @override
  Future<String> loadUtxos(String address) async => '[]';
  @override
  Future<void> verifyKcc20CellsOnOwnNode(
      List<Kcc20CellRecord> cells, String covenantId) async {
    throw StateError('Standard proofs must not be repeated.');
  }

  @override
  Future<Kcc20Step> loadStandardKcc20SigningBatch(
      String address, String covenantId, int amount,
      {bool Function()? isCancelled, void Function(String)? onProgress}) async {
    proofs++;
    onProgress?.call('Verifying selected token only…');
    final cells = List.generate(
        3,
        (i) => Kcc20CellRecord(
            covenantId: cid,
            transactionId: 'a' * 64,
            index: i,
            valueSompi: 100000000,
            blockDaaScore: 1,
            scriptPublicKey: 'aa',
            tokenAmount: i == 0 ? 90 : 1,
            redeemScript: 'bb'));
    return Kcc20Step(cells, count > 1 ? 30 : amount, count > 1,
        requiredCells: count > 1 ? 10 : 1, transactionCount: count);
  }

  @override
  Future<void> waitForStandardKcc20Cell(
      String address, String covenantId, String transactionId,
      {bool Function()? isCancelled, void Function(String)? onProgress}) async {
    waits++;
    expect(covenantId, cid);
  }
}

void main() {
  final requests = <Map>[];
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    requests.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('space.kasvault/security'), (call) async {
      if (call.method == 'hasNativeWallet') return true;
      if (call.method == 'prepareKronTransfer') {
        requests.add(
            jsonDecode((call.arguments as Map)['request'] as String) as Map);
        return jsonEncode({
          'psktRequest': {'fixture': true},
          'feeSompi': 1000,
          'feeMass': 100,
          'computeMass': 100,
          'transientMass': 100,
          'computeBudget': 100,
          'covenantInputCount': 3,
          'covenantOutputCount': 2,
          'lockedKasSompi': 300000000,
          'lockedKasOutputSompi': 200000000,
          'lockedKasTopUpSompi': 0,
          'lockedKasReleasedSompi': 100000000,
          'templateHash': 'argent-kcc20-c8a0871'
        });
      }
      if (call.method == 'preparePskt') {
        return jsonEncode({'reviewHash': 'fixture-review'});
      }
      throw StateError(
          'Unexpected native operation ${call.method}; tests never sign or broadcast.');
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('space.kasvault/security'), null));

  Future<void> open(WidgetTester tester, SendApi api) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AssetSendScreen(
                address: address,
                onDone: () {},
                api: api,
                initialAsset:
                    AssetSendIntent.kcc20('TEST.K', cid, wallet: snapshot)))));
    await tester.pumpAndSettle();
  }

  Future<void> prepare(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField).at(0), 'kaspa:recipient');
    await tester.enterText(find.byType(TextField).at(1), '80');
    await tester.scrollUntilVisible(
        find.text(buttonLabel('REVIEW ASSET TRANSFER')), 400,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text(buttonLabel('REVIEW ASSET TRANSFER')));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'ordinary payment passes all three selected cells without changing recipient amount',
      (tester) async {
    final api = SendApi(1);
    await open(tester, api);
    await prepare(tester);
    expect(requests, hasLength(1));
    expect(requests.single['cells'], hasLength(3));
    expect(requests.single['amount'], 80);
    expect(requests.single['recipient'], 'kaspa:recipient');
    expect(api.walletLoads, 1);
    expect(api.proofs, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('many consolidation steps require upfront acknowledgement',
      (tester) async {
    await open(tester, SendApi(5));
    await prepare(tester);
    expect(requests.single['recipient'], address);
    expect(requests.single['amount'], 30);
    await tester.scrollUntilVisible(
        find.text(buttonLabel('SEND ON-CHAIN')), 400,
        scrollable: find.byType(Scrollable).first);
    FilledButton send() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, buttonLabel('SEND ON-CHAIN')));
    expect(send().onPressed, isNull);
    await tester.scrollUntilVisible(find.byType(CheckboxListTile), -400,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.text(buttonLabel('SEND ON-CHAIN')), 400,
        scrollable: find.byType(Scrollable).first);
    expect(send().onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'saved standard continuation waits for balance then prepares once, no wallet rescan',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'kaspire_pending_kcc20_compound_$address': jsonEncode({
        'transactionId': 'a' * 64,
        'operation': {
          'covenantId': cid,
          'standard': 'kcc20',
          'intendedRecipient': 'kaspa:recipient',
          'intendedAmount': '80',
          'intendedDisplayAmount': '80',
          'completedSteps': 0
        }
      })
    });
    final api = SendApi(1);
    await open(tester, api);
    await tester.tap(find.text('Continue KCC20 transfer'));
    await tester.pumpAndSettle();
    expect(api.waits, 1);
    expect(api.proofs, 1);
    expect(api.walletLoads, 1);
    expect(requests.single['recipient'], 'kaspa:recipient');
    expect(requests.single['amount'], 80);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'saved final payments are checked or identically replayed, never duplicated',
      (tester) async {
    // Exercise both recoveries in one FakeAsync zone: ActivityStore serializes
    // writes with a static Future chain, which must not outlive a test's clock.
    for (final alreadyAccepted in [true, false]) {
      final operation = {
        'kind': 'kcc20',
        'ticker': 'TEST.K',
        'amount': '80',
        'displayAmount': '80',
        'recipient': 'kaspa:recipient',
        'covenantId': cid
      };
      final key = 'kaspire_pending_kcc20_compound_$address';
      SharedPreferences.setMockInitialValues({
        key: jsonEncode({
          'transactionId': 'a' * 64,
          'operation': operation,
          'finalPayment': {
            'transactionId': 'b' * 64,
            'signedTxJson': 'identical-signed-bytes',
            'operation': operation,
            'feeSompi': 1000
          }
        })
      });
      final api = SendApi(1)..accepted = alreadyAccepted;
      await open(tester, api);
      await tester.tap(find.text('Continue KCC20 transfer'));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      expect(api.proofs, 0);
      expect(api.waits, 0);
      expect(api.broadcasts,
          alreadyAccepted ? isEmpty : ['identical-signed-bytes']);
      expect((await SharedPreferences.getInstance()).getString(key), isNull);
      expect(find.text(displayLabel('ASSET SENT')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });
}
