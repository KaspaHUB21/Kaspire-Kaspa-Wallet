import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/screens/covenant_vault_screen.dart';
import 'package:kasvault_wallet/src/services/covenant_vault_service.dart';
import 'package:kasvault_wallet/src/services/native_security.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';

const owner =
    'kaspa:qp0mtdvzscrkfft702j85s8yzdl8a87n5d6pgtm8vrxg6hqu0wywzvwkevdk3';
final cid = 'aa' * 32, txid = 'bb' * 32;
Map<String, Object?> record({String status = 'locked'}) => {
      'protocol': CovenantVaultService.protocol,
      'covenantId': cid,
      'transactionId': txid,
      'index': 0,
      'amountSompi': 100000000,
      'vaultAddress': 'kaspa:vault',
      'scriptPublicKey': 'script',
      'compiler': 'silverscript-v1.0.0',
      'status': status,
      'terms': {
        'kind': 'timeLock',
        'owner': owner,
        'beneficiary': '',
        'name': 'Test vault',
        'limitDaa': 5000,
        'instance': '01' * 32
      },
    };
Map<String, Object?> prepared() => {
      'request': {
        'action': 'create',
        'sender': owner,
        'terms': record()['terms'],
        'fundingUtxosJson': '[]',
        'cell': null
      },
      'review': {'reviewHash': 'hash', 'record': record(status: 'pending')},
    };

class VaultSecurity extends NativeSecurity {
  List<Map<String, Object?>> catalog = [];
  final List<String> log;
  bool failWrite = false;
  int signatures = 0;
  VaultSecurity(this.log);
  @override
  Future<List<Map<String, Object?>>> loadCovenantVaults() async =>
      (jsonDecode(jsonEncode(catalog)) as List).map(vaultMap).toList();
  @override
  Future<void> saveCovenantVaults(List<Map<String, Object?>> list) async {
    log.add('persist');
    if (failWrite) throw StateError('Storage failed');
    catalog = list;
  }

  @override
  Future<Map<String, Object?>> validateVaultRecord(
          Map<String, Object?> value) async =>
      value;
  @override
  Future<Map<String, Object?>> signCovenantVault(
      Map<String, Object?> request, String hash) async {
    log.add('sign');
    signatures++;
    return {
      'transactionId': txid,
      'wrpcJson': 'EXACT SIGNED BYTES',
      'submitJson': '{}',
      'record': record(status: 'pending')
    };
  }
}

class VaultApi extends KaspaApi {
  final List<String> log;
  String? bytes;
  bool failNetwork = false;
  VaultApi(this.log);
  @override
  Future<String> broadcastKcc20(String signedTxJson,
      {required String expectedTransactionId}) async {
    log.add('broadcast');
    bytes = signedTxJson;
    if (failNetwork) throw StateError('Network unavailable');
    return expectedTransactionId;
  }
}

http.Response response(Object body) => http.Response(jsonEncode(body), 200);
MockClient node(
        {Object utxos = const [],
        String? proofCovenant,
        bool accepted = true}) =>
    MockClient((req) async {
      if (req.url.path.endsWith('/info/blockdag')) {
        return response(
            {'networkName': 'kaspa-mainnet', 'virtualDaaScore': '2100'});
      }
      if (req.url.path.endsWith('/utxos')) return response(utxos);
      if (req.url.path.contains('/transactions/')) {
        return response({
          'is_accepted': accepted,
          'transaction_id': txid,
          'outputs': [
            {
              'index': 0,
              'covenant_id': proofCovenant ?? cid,
              'amount': '100000000',
              'script_public_key': 'script'
            }
          ]
        });
      }
      if (req.url.path.endsWith('/full-transactions')) return response([]);
      throw StateError('Unexpected request ${req.url}');
    });
final cellRow = {
  'outpoint': {'transactionId': txid, 'index': 0},
  'utxoEntry': {
    'amount': '100000000',
    'blockDaaScore': '2001',
    'isCoinbase': false,
    'scriptPublicKey': {'scriptPublicKey': 'script'}
  }
};

class ScreenVaultService extends CovenantVaultService {
  ScreenVaultService({this.offline = false})
      : super(client: node(), security: VaultSecurity([]));
  final bool offline;
  bool confirmPending = false;
  String confirmedStatus = 'locked';
  List<Map<String, Object?>> catalog = [
    {'record': record()}
  ];
  @override
  Future<int> daa() async {
    if (offline) throw StateError('Node offline');
    return 2100;
  }

  @override
  Future<List<Map<String, Object?>>> saved() async => catalog;
  @override
  Future<Map<String, Object?>> refresh(Map<String, Object?> item) async {
    if (offline) throw StateError('Node offline');
    if (confirmPending) {
      catalog = [
        {'record': record(status: confirmedStatus)}
      ];
      return catalog.single;
    }
    return item;
  }
}

void main() {
  setUp(() {
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    AppSettings.theme.value = KaspireTheme.midnight;
  });
  test('decimal KAS parsing is exact and rejects invalid or tiny deposits', () {
    expect(parseVaultKas('1.00000001'), 100000001);
    expect(parseVaultKas('21.5'), 2150000000);
    for (final amount in ['0.9', '-1', '1,5', '1.000000001', 'NaN']) {
      expect(() => parseVaultKas(amount), throwsStateError);
    }
  });
  test(
      'durable journal precedes broadcast and storage failure never broadcasts',
      () async {
    final log = <String>[], security = VaultSecurity([]);
    final api = VaultApi(log),
        service =
            CovenantVaultService(client: node(), security: security, api: api);
    security.log.clear();
    security.failWrite = true;
    await expectLater(service.commit(prepared()), throwsStateError);
    expect(log, isEmpty);
    expect(security.signatures, 1);
    service.close();
  });
  test(
      'network error preserves signed data and resume never signs a second deposit',
      () async {
    final log = <String>[],
        security = VaultSecurity(log),
        api = VaultApi(log)..failNetwork = true;
    final service = CovenantVaultService(
        client: node(accepted: false), security: security, api: api);
    await expectLater(service.commit(prepared()), throwsStateError);
    expect(log, ['sign', 'persist', 'broadcast']);
    expect(security.catalog.single['pending'], isNotNull);
    api.failNetwork = false;
    await service.resume(security.catalog.single);
    expect(api.bytes, 'EXACT SIGNED BYTES');
    expect(security.signatures, 1);
    service.close();
  });
  test('already confirmed creation completes without a duplicate broadcast',
      () async {
    final log = <String>[], security = VaultSecurity(log), api = VaultApi(log);
    final service = CovenantVaultService(
        client: node(utxos: [cellRow]), security: security, api: api);
    expect(await service.commit(prepared()), txid);
    expect(log.where((e) => e == 'broadcast'), isEmpty);
    expect(security.catalog.single['pending'], isNull);
    expect(vaultMap(security.catalog.single['record'])['status'], 'locked');
    service.close();
  });
  test('successful broadcast immediately reconciles node confirmation',
      () async {
    final log = <String>[], security = VaultSecurity(log), api = VaultApi(log);
    final before = node(accepted: false), after = node(utxos: [cellRow]);
    final service = CovenantVaultService(
        client: MockClient((request) async =>
            (log.contains('broadcast') ? after : before).get(request.url)),
        security: security,
        api: api);
    await service.commit(prepared());
    expect(log.where((e) => e == 'broadcast'), hasLength(1));
    expect(security.catalog.single['pending'], isNull);
    expect(vaultMap(security.catalog.single['record'])['status'], 'locked');
    service.close();
    before.close();
    after.close();
  });
  test('missing transaction proof retains the journal without a false success',
      () async {
    final log = <String>[], security = VaultSecurity(log), api = VaultApi(log);
    final fallback = node(accepted: false);
    final service = CovenantVaultService(
        client: MockClient((request) async =>
            request.url.path.contains('/transactions/')
                ? http.Response('not indexed yet', 404)
                : fallback.get(request.url)),
        security: security,
        api: api);
    await service.commit(prepared());
    final journal = vaultMap(security.catalog.single['pending']);
    expect(journal['submitted'], true);
    expect(journal['wrpcJson'], 'EXACT SIGNED BYTES');
    expect(security.signatures, 1);
    service.close();
    fallback.close();
  });
  test('stale resume after confirmation cannot broadcast or resurrect journal',
      () async {
    final log = <String>[], security = VaultSecurity(log), api = VaultApi(log);
    final old = {
      'record': record(),
      'pending': {
        'transactionId': txid,
        'wrpcJson': 'SIGNED',
        'action': 'create'
      }
    };
    security.catalog = [
      {'record': record()}
    ];
    final service =
        CovenantVaultService(client: node(), security: security, api: api);
    expect(await service.resume(old), txid);
    expect(log, isEmpty);
    expect(security.catalog.single['pending'], isNull);
    service.close();
  });
  test('accepted transaction with wrong covenant does not clear the journal',
      () async {
    final security = VaultSecurity([])
      ..catalog = [
        {
          'record': record(status: 'pending'),
          'pending': {'transactionId': txid, 'action': 'create'}
        }
      ];
    final service = CovenantVaultService(
        client: node(proofCovenant: 'cc' * 32), security: security);
    final result = await service.refresh(security.catalog.single);
    expect(result['pending'], isNotNull);
    service.close();
  });
  test('old recovery import never overwrites a newer pending transaction',
      () async {
    final security = VaultSecurity([])
      ..catalog = [
        {
          'record': record(),
          'pending': {'transactionId': txid, 'wrpcJson': 'SIGNED'}
        }
      ];
    final service = CovenantVaultService(client: node(), security: security);
    await service.importRecord(record(status: 'pending'));
    expect(vaultMap(security.catalog.single['pending'])['wrpcJson'], 'SIGNED');
    service.close();
  });
  test('empty UTXO response is not evidence that funds were paid out',
      () async {
    final security = VaultSecurity([])
      ..catalog = [
        {'record': record()}
      ];
    final service = CovenantVaultService(client: node(), security: security);
    final updated = await service.refresh(security.catalog.single);
    expect(vaultMap(updated['record'])['status'], 'locked');
    expect(security.log, isEmpty);
    service.close();
  });
  test('matching script and amount alone do not authorize a vault cell',
      () async {
    final wrong = CovenantVaultService(
        client: node(utxos: [cellRow], proofCovenant: 'cc' * 32),
        security: VaultSecurity([]));
    expect(await wrong.cell(record()), isNull);
    wrong.close();
    final unaccepted = CovenantVaultService(
        client: node(utxos: [cellRow], accepted: false),
        security: VaultSecurity([]));
    expect(await unaccepted.cell(record()), isNull);
    unaccepted.close();
    final valid = CovenantVaultService(
        client: node(utxos: [cellRow]), security: VaultSecurity([]));
    expect((await valid.cell(record()))?['covenantId'], cid);
    valid.close();
  });
  test('refresh confirms a deposit before removing the pending journal',
      () async {
    final security = VaultSecurity([])
      ..catalog = [
        {
          'record': record(status: 'pending'),
          'pending': {'transactionId': txid, 'action': 'create'}
        }
      ];
    final service = CovenantVaultService(
        client: node(utxos: [cellRow]), security: security);
    final updated = await service.refresh(security.catalog.single);
    expect(updated['pending'], isNull);
    expect(vaultMap(updated['record'])['status'], 'locked');
    service.close();
  });
  test('node outage never deletes encrypted records', () async {
    final security = VaultSecurity([])
      ..catalog = [
        {'record': record()}
      ];
    final service = CovenantVaultService(
        client: MockClient((_) async => http.Response('offline', 503)),
        security: security);
    await expectLater(
        service.refresh(security.catalog.single), throwsStateError);
    expect(security.catalog.length, 1);
    expect(security.log, isEmpty);
    service.close();
  });
  for (final theme in [
    KaspireTheme.midnight,
    KaspireTheme.hub21,
    KaspireTheme.glacier,
    KaspireTheme.neptune
  ]) {
    testWidgets('vault forms scroll without clipping in ${theme.name} at 320px',
        (tester) async {
      AppSettings.theme.value = theme;
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = ScreenVaultService();
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: CovenantVaultScreen(address: owner, service: service)));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('start-timeLock')), 280,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('start-timeLock')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Vault name'), 220,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Vault name'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Prepare vault'), 280,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      service.close();
    });
  }
  testWidgets('offline startup still shows local vault records',
      (tester) async {
    final service = ScreenVaultService(offline: true);
    await tester.pumpWidget(MaterialApp(
        home: CovenantVaultScreen(address: owner, service: service)));
    await tester.pumpAndSettle();
    expect(find.text('Test vault'), findsOneWidget);
    expect(find.text('Node offline'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    service.close();
  });
  testWidgets(
      'pending warning is prominent and vanishes after automatic confirmation',
      (tester) async {
    final service = ScreenVaultService()
      ..catalog = [
        {
          'record': record(status: 'pending'),
          'pending': {
            'transactionId': txid,
            'action': 'create',
            'submitted': true
          }
        }
      ];
    await tester.pumpWidget(MaterialApp(
        home: CovenantVaultScreen(address: owner, service: service)));
    await tester.pumpAndSettle();
    expect(find.text('Awaiting node confirmation'), findsOneWidget);
    expect(find.text('Resume saved transaction'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Awaiting node confirmation')).dy,
        lessThan(tester.getTopLeft(find.text('Your money. Your rules.')).dy));
    service.confirmPending = true;
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Resume saved transaction'), findsNothing);
    expect(find.text('Awaiting node confirmation'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    service.close();
  });
  testWidgets('confirmed opening automatically removes vault from overview',
      (tester) async {
    final service = ScreenVaultService()
      ..confirmedStatus = 'opened'
      ..catalog = [
        {
          'record': record(),
          'pending': {
            'action': 'release',
            'transactionId': txid,
            'submitted': true
          },
        }
      ];
    await tester.pumpWidget(MaterialApp(
        home: CovenantVaultScreen(address: owner, service: service)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('My Vaults'), 220,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Test vault'), findsOneWidget);
    service.confirmPending = true;
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Test vault'), findsNothing);
    expect(find.text('Resume saved transaction'), findsNothing);
    expect(service.catalog.length, 1);
    expect(vaultMap(service.catalog.single['record'])['status'], 'opened');
    await tester.pumpWidget(const SizedBox.shrink());
    service.close();
  });
  testWidgets('overview hides opened vaults without deleting recovery records',
      (tester) async {
    final opened = record(status: 'opened')
      ..['covenantId'] = 'cc' * 32
      ..['terms'] = {...vaultMap(record()['terms']), 'name': 'Completed vault'};
    final service = ScreenVaultService()
      ..catalog = [
        {'record': opened},
        {'record': record()}
      ];
    await tester.pumpWidget(MaterialApp(
        home: CovenantVaultScreen(address: owner, service: service)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('My Vaults'), 220,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Completed vault'), findsNothing);
    expect(find.text('Test vault'), findsOneWidget);
    expect(service.catalog.length, 2);
    expect(vaultMap(service.catalog.first['record'])['status'], 'opened');
    await tester.pumpWidget(const SizedBox.shrink());
    service.close();
  });
  testWidgets('overview with only opened vaults has a useful empty state',
      (tester) async {
    final service = ScreenVaultService()
      ..catalog = [
        {'record': record(status: 'opened')}
      ];
    await tester.pumpWidget(MaterialApp(
        home: CovenantVaultScreen(address: owner, service: service)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('My Vaults'), 220,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Test vault'), findsNothing);
    expect(
        find.text(
            'No active vaults. Opened vaults are hidden from this overview.'),
        findsOneWidget);
    expect(service.catalog.length, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    service.close();
  });
  testWidgets('home returns from vault details to the vault overview',
      (tester) async {
    final service = ScreenVaultService();
    await tester.pumpWidget(MaterialApp(
        home: CovenantVaultScreen(address: owner, service: service)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Test vault'), 220,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Test vault'));
    await tester.pumpAndSettle();
    expect(find.text('Technical details'), findsOneWidget);
    await tester.tap(find.byTooltip('Vault overview'));
    await tester.pumpAndSettle();
    expect(find.text('My Vaults'), findsOneWidget);
    expect(find.text('Technical details'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    service.close();
  });
}
