import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/hidden_kas_service.dart';
import 'package:kasvault_wallet/src/services/native_security.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/screens/hidden_kas_screen.dart';
import 'package:kasvault_wallet/src/theme.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';

const owner =
    'kaspa:qqd6e65yefepe9wk0m9vuxdufxd80sphy67gwwd0vdaumzdt4tc9s3qt0lqeh';
const p2sh =
    'kaspa:prguvhxfnrx520s8u7jm77hvw7wqy394urnymj32cp783ek0y8ftxxtznwft6';
const signedId =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class HiddenSecurity extends NativeSecurity {
  String kind = 'mnemonic';
  int derivations = 0;
  String active = owner;
  Map<String, Object?> state = {
    'descriptor': HiddenKasService.descriptor,
    'receiveCount': 0,
    'changeCount': 0,
    'exposed': <String>[]
  };
  int observed = 0, signatures = 0, confirmations = 0, issues = 0;
  bool confirm = false;
  Map<String, Object?> clone(Map<String, Object?> data) =>
      hiddenMap(jsonDecode(jsonEncode(data)));
  @override
  Future<String?> getNativeAddress() async => active;
  @override
  Future<List<NativeWalletInfo>> listWallets() async => [
        NativeWalletInfo(
            id: 'test',
            address: active,
            name: 'Test wallet',
            kind: kind,
            active: true,
            addresses: [])
      ];
  @override
  Future<Map<String, Object?>> hiddenKasState() async => clone(state);
  @override
  Future<List<Map<String, Object?>>> deriveHiddenKas(
      int branch, int start, int count) async {
    derivations++;
    return List.generate(
        count,
        (i) => {
              'branch': branch,
              'index': start + i,
              'address': branch == 0 && start + i == 0
                  ? p2sh
                  : 'kaspa:p-test-$branch-${start + i}',
              'keyHash': '00' * 32
            });
  }

  @override
  Future<Map<String, Object?>> observeHiddenKas(
      List<Map<String, Object?>> used) async {
    observed++;
    for (final a in used) {
      final key = a['branch'] == 0 ? 'receiveCount' : 'changeCount';
      if (hiddenInt(state[key]) <= hiddenInt(a['index'])) {
        state[key] = hiddenInt(a['index']) + 1;
      }
      final coordinate = '${a['branch']}:${a['index']}';
      final retired = (state['exposed'] as List);
      if (!retired.contains(coordinate)) retired.add(coordinate);
    }
    return clone(state);
  }

  @override
  Future<Map<String, Object?>> issueHiddenKas(int branch) async {
    issues++;
    final key = branch == 0 ? 'receiveCount' : 'changeCount';
    final index = hiddenInt(state[key]);
    state[key] = index + 1;
    return (await deriveHiddenKas(branch, index, 1)).single;
  }

  @override
  Future<void> confirmHiddenKas(String transactionId) async {
    confirmations++;
    if (!confirm) throw StateError('Awaiting node');
    expect(transactionId, signedId);
    state.remove('pending');
  }

  @override
  Future<Map<String, Object?>> signHiddenKas(
      Map<String, Object?> request, String reviewHash) async {
    signatures++;
    state['pending'] = {
      'transactionId': signedId,
      'submitJson': 'EXACT SAVED SIGNED BYTES'
    };
    return hiddenMap(state['pending']);
  }
}

void main() {
  setUp(() {
    NetworkSettings.network.value = KaspaNetwork.mainnet;
  });
  testWidgets(
      'private key wallets get an informational HD requirement before discovery',
      (tester) async {
    final native = HiddenSecurity()..kind = 'private-key';
    await tester.pumpWidget(MaterialApp(
        home: HiddenKasScreen(
            address: owner,
            service: HiddenKasService(owner, security: native))));
    await tester.pumpAndSettle();
    expect(find.text('Seed-based HD wallet required'), findsOneWidget);
    expect(find.text(hiddenKasHdRequired), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.text('Review payment'), findsNothing);
    expect(find.textContaining('PlatformException'), findsNothing);
    expect(native.derivations, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  test('native errors keep the useful cause without Java/platform wrappers',
      () {
    expect(
        hiddenKasUserMessage(PlatformException(
            code: 'SECURITY_ERROR',
            message:
                'IllegalStateException: invalid transaction request: Hidden KAS requires a root mnemonic wallet')),
        hiddenKasHdRequired);
    expect(
        hiddenKasUserMessage(PlatformException(
            code: 'SECURITY_ERROR',
            message:
                'IllegalStateException: invalid transaction request: Insufficient KAS including network fee')),
        'Insufficient KAS including network fee');
  });
  test(
      'scan covers both branches and does not publish keys or create addresses',
      () async {
    final native = HiddenSecurity();
    var calls = 0;
    final service =
        HiddenKasService(owner, security: native, client: MockClient((r) async {
      calls++;
      return http.Response('[]', 200);
    }));
    final snapshot = await service.scan();
    expect(snapshot['balanceSompi'], 0);
    expect((snapshot['addresses'] as List).length, 40);
    expect(calls, 80);
    expect(native.observed, 1);
    expect(native.issues, 0);
    expect(native.signatures, 0);
    service.close();
  });
  test('an indexer/node error is not zero, not unused and not an issuance',
      () async {
    final native = HiddenSecurity();
    final service = HiddenKasService(owner,
        security: native,
        client: MockClient((r) async => http.Response('down', 503)));
    await expectLater(service.scan(), throwsStateError);
    expect(native.observed, 0);
    expect(native.issues, 0);
    expect(native.signatures, 0);
    service.close();
  });
  test('restore scans issued ranges past ordinary gap', () async {
    final native = HiddenSecurity()..state['receiveCount'] = 45;
    final service = HiddenKasService(owner,
        security: native,
        client: MockClient((r) async => http.Response('[]', 200)));
    final snapshot = await service.scan();
    expect((snapshot['addresses'] as List).length, 80);
    service.close();
  });
  test('already retired receive address is not offered again', () async {
    final native = HiddenSecurity()
      ..state['receiveCount'] = 1
      ..state['exposed'] = <String>['0:0'];
    final service = HiddenKasService(owner, security: native);
    final address = await service.receive({
      'state': await native.hiddenKasState(),
      'addresses': await native.deriveHiddenKas(0, 0, 20)
    });
    expect(address['index'], 1);
    expect(native.issues, 1);
    service.close();
  });
  test(
      'pending transaction blocks receiving; failed resume keeps exactly original bytes',
      () async {
    final native = HiddenSecurity()
      ..state['pending'] = {
        'transactionId': signedId,
        'submitJson': 'EXACT SAVED SIGNED BYTES'
      };
    final bodies = <String>[];
    final service =
        HiddenKasService(owner, security: native, client: MockClient((r) async {
      expect(r.url.toString(), 'https://kaspire.kaslab.space/api/transactions');
      bodies.add(r.body);
      return http.Response('rejected', 503);
    }));
    await expectLater(service.receive({'state': await native.hiddenKasState()}),
        throwsStateError);
    await expectLater(service.resume(), throwsStateError);
    await expectLater(service.resume(), throwsStateError);
    expect(bodies, ['EXACT SAVED SIGNED BYTES', 'EXACT SAVED SIGNED BYTES']);
    expect(native.signatures, 0);
    expect(native.state['pending'], isNotNull);
    service.close();
  });
  test('already confirmed transaction is cleared without rebroadcast',
      () async {
    final native = HiddenSecurity()
      ..confirm = true
      ..state['pending'] = {
        'transactionId': signedId,
        'submitJson': 'EXACT SAVED SIGNED BYTES'
      };
    final service = HiddenKasService(owner,
        security: native,
        client:
            MockClient((r) async => throw StateError('No broadcast allowed')));
    await service.resume();
    expect(native.state['pending'], isNull);
    expect(native.confirmations, 1);
    service.close();
  });
  test('wallet switch, network switch and closing stop further actions',
      () async {
    final native = HiddenSecurity();
    final service = HiddenKasService(owner, security: native);
    native.active = 'different';
    await expectLater(service.guard(), throwsStateError);
    native.active = owner;
    NetworkSettings.network.value = KaspaNetwork.tn10;
    await expectLater(service.guard(), throwsStateError);
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    service.close();
    await expectLater(service.guard(), throwsStateError);
  });
  test('exact fixed-point amount parsing never rounds through a double', () {
    expect(parseHiddenKasAmount('1.00000001'), 100000001);
    for (final text in ['-1', '0', '1,5', 'NaN', '1.000000001', '1e8']) {
      expect(() => parseHiddenKasAmount(text), throwsStateError);
    }
  });
  for (final theme in [
    KaspireTheme.midnight,
    KaspireTheme.hub21,
    KaspireTheme.glacier,
    KaspireTheme.neptune
  ]) {
    testWidgets(
        'experimental warning fits and is scrollable at 320px in $theme',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      AppSettings.theme.value = theme;
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: HiddenKasScreen(
              address: owner,
              service: HiddenKasService(owner, security: HiddenSecurity()))));
      await tester.pumpAndSettle();
      expect(find.text('Experimental P2SH account'), findsOneWidget);
      expect(find.textContaining('NOT a post-quantum'), findsOneWidget);
      expect(find.text('Copy address'), findsNothing);
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pump();
      expect(tester.takeException(), isNull);
      AppSettings.theme.value = KaspireTheme.midnight;
    });
  }
}
