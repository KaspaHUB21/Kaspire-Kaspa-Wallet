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
import 'package:kasvault_wallet/src/models/wallet_snapshot.dart';
import 'package:kasvault_wallet/src/widgets/hub21_material.dart';
import 'package:kasvault_wallet/src/widgets/kas_receive_request.dart';
import 'package:qr_flutter/qr_flutter.dart';

class ReadClock {
  DateTime time = DateTime.utc(2026, 10, 19);
  final waits = <Duration>[];
  DateTime now() => time;
  Future<void> sleep(Duration duration) async {
    waits.add(duration);
    time = time.add(duration);
  }
}

class ReadStartClient extends http.BaseClient {
  ReadStartClient(this.clock);
  final ReadClock clock;
  final starts = <DateTime>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    // Measure send initiation, not MockClient's later body-reading callback.
    starts.add(clock.now());
    return Future.value(
        http.StreamedResponse(Stream.value(utf8.encode('[]')), 200));
  }
}

HiddenKasService hiddenService(String owner,
    {NativeSecurity? security, http.Client? client}) {
  final clock = ReadClock();
  return HiddenKasService(owner,
      security: security, client: client, clock: clock.now, sleep: clock.sleep);
}

const owner =
    'kaspa:qqd6e65yefepe9wk0m9vuxdufxd80sphy67gwwd0vdaumzdt4tc9s3qt0lqeh';
const p2sh =
    'kaspa:pq02dzckvs0g6hhl9s9c484fv0wsd93sltwct9symfad4yw062w5y4v4mtlxa';
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
  int? confirmOnAttempt;
  String? confirmationErrorCode;
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
    if (confirmationErrorCode != null) {
      throw PlatformException(
          code: confirmationErrorCode!, message: 'Journal changed');
    }
    if (!confirm &&
        (confirmOnAttempt == null || confirmations < confirmOnAttempt!)) {
      throw PlatformException(
          code: 'CONFIRMATION_PENDING', message: 'Awaiting node');
    }
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

class ConfirmedPaymentService extends HiddenKasService {
  ConfirmedPaymentService(this.native) : super(native.active, security: native);
  final HiddenSecurity native;
  int scans = 0, submits = 0;
  bool confirmed = false, rejectSubmit = false;
  List<WalletTransaction> activities = [];
  @override
  Future<bool> supportsHdWallet() async => true;
  @override
  Future<Map<String, Object?>> scan({void Function(int)? progress}) async {
    scans++;
    if (confirmed) throw StateError('Account lookup unavailable (429).');
    return {
      'state': await native.hiddenKasState(),
      'addresses': <Object?>[],
      'utxos': <Object?>[],
      'balanceSompi': 100000000
    };
  }

  @override
  Future<List<WalletTransaction>> activity(Map<String, Object?> snapshot,
          {bool more = false}) async =>
      activities;
  @override
  Future<void> resume() async {
    submits++;
    if (rejectSubmit) throw StateError('Original node submission error');
    await native.confirmHiddenKas(signedId);
    confirmed = true;
  }
}

class MaxPreviewService extends ConfirmedPaymentService {
  MaxPreviewService(super.native);
  int preparations = 0;
  bool? requestedMax;
  int? requestedAmount;
  @override
  Future<Map<String, Object?>> prepare(String recipient, int amount,
      {bool sendAll = false}) async {
    preparations++;
    requestedMax = sendAll;
    requestedAmount = amount;
    return {
      'request': {'amountSompi': amount, 'sendAll': sendAll},
      'review': {
        'recipient': recipient,
        'sendAll': sendAll,
        'amountSompi': 99990000,
        'feeSompi': 10000,
        'changeSompi': 0,
        'inputCount': 1,
        'reviewHash': 'test-only-review'
      }
    };
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
            address: owner, service: hiddenService(owner, security: native))));
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
        hiddenService(owner, security: native, client: MockClient((r) async {
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
  test('KIP-22 does not reinterpret the retired experimental account',
      () async {
    final native = HiddenSecurity();
    native.state['descriptor'] = 'kaspire-hidden-kas-v1';
    final service = hiddenService(owner, security: native);
    await expectLater(service.scan(), throwsStateError);
    expect(native.derivations, 0);
    expect(native.observed, 0);
    expect(native.issues, 0);
    service.close();
  });
  test('an indexer/node error is not zero, not unused and not an issuance',
      () async {
    final native = HiddenSecurity();
    final service = hiddenService(owner,
        security: native,
        client: MockClient((r) async => http.Response('down', 503)));
    await expectLater(service.scan(), throwsStateError);
    expect(native.observed, 0);
    expect(native.issues, 0);
    expect(native.signatures, 0);
    service.close();
  });
  test('GET starts are paced across parallel own-node reads', () async {
    final clock = ReadClock();
    final client = ReadStartClient(clock);
    final starts = client.starts;
    final service = HiddenKasService(owner,
        security: HiddenSecurity(),
        clock: clock.now,
        sleep: clock.sleep,
        client: client);
    await Future.wait(List.generate(
        15, (i) => service.get('${HiddenKasService.node}/read/$i')));
    expect(starts.length, 15);
    for (var i = 1; i < starts.length; i++) {
      expect(starts[i].difference(starts[i - 1]),
          greaterThanOrEqualTo(const Duration(milliseconds: 100)));
    }
    service.close();
  });
  test('429 Retry-After is retried automatically, without signing', () async {
    final clock = ReadClock();
    final native = HiddenSecurity();
    final starts = <DateTime>[];
    final service = HiddenKasService(owner,
        security: native,
        clock: clock.now,
        sleep: clock.sleep, client: MockClient((r) async {
      starts.add(clock.now());
      return starts.length == 1
          ? http.Response('limited', 429, headers: {'retry-after': '2'})
          : http.Response('[]', 200);
    }));
    expect(await service.get('${HiddenKasService.history}/read'), isEmpty);
    expect(starts.length, 2);
    expect(starts[1].difference(starts[0]),
        greaterThanOrEqualTo(const Duration(seconds: 2)));
    expect(native.signatures, 0);
    expect(native.issues, 0);
    service.close();
  });
  test('public history cooldown never blocks the own node', () async {
    final clock = ReadClock();
    final native = HiddenSecurity();
    var nodeReads = 0;
    final service = HiddenKasService(owner,
        security: native,
        clock: clock.now,
        sleep: clock.sleep, client: MockClient((request) async {
      if (request.url.toString().startsWith(HiddenKasService.node)) {
        nodeReads++;
        return http.Response('[]', 200);
      }
      return http.Response('limited', 429, headers: {'retry-after': '120'});
    }));
    await expectLater(
        service.get('${HiddenKasService.history}/read'), throwsStateError);
    expect(await service.get('${HiddenKasService.node}/read'), isEmpty);
    expect(nodeReads, 1);
    expect(clock.waits, isEmpty);
    expect(native.signatures, 0);
    service.close();
  });
  test(
      'P2SH history loads older pages and deduplicates across receive/change addresses',
      () async {
    final native = HiddenSecurity();
    final offsets = <int>[];
    final service =
        hiddenService(owner, security: native, client: MockClient((r) async {
      final offset = int.parse(r.url.queryParameters['offset']!);
      offsets.add(offset);
      final rows = offset == 0
          ? List.generate(
              50,
              (i) => {
                    'transaction_id':
                        (i + 1).toRadixString(16).padLeft(64, '0'),
                    'is_accepted': true,
                    'block_time': 1792000000000 - i * 1000,
                    'inputs': [],
                    'outputs': [
                      {'amount': 10000, 'script_public_key_address': p2sh}
                    ]
                  })
          : [
              {
                'transaction_id': 'f' * 64,
                'is_accepted': true,
                'block_time': 1791000000000,
                'inputs': [],
                'outputs': [
                  {'amount': 10000, 'script_public_key_address': p2sh}
                ]
              }
            ];
      return http.Response(jsonEncode(rows), 200);
    }));
    final snapshot = <String, Object?>{
      'state': {'receiveCount': 1, 'changeCount': 1},
      'addresses': [
        {'address': p2sh, 'branch': 0, 'index': 0},
        {'address': 'kaspa:pother', 'branch': 1, 'index': 0}
      ]
    };
    expect((await service.activity(snapshot)).length, 50);
    expect(service.activityHasMore, true);
    expect((await service.activity(snapshot, more: true)).length, 51);
    expect(service.activityHasMore, false);
    expect(offsets, [0, 0, 50, 50]);
    service.close();
  });
  test('discovery and activity never depend on the public history fallback',
      () async {
    final native = HiddenSecurity()..state['receiveCount'] = 1;
    var public = 0, local = 0;
    final service = hiddenService(owner, security: native,
        client: MockClient((request) async {
      if (!request.url.toString().startsWith(HiddenKasService.node)) {
        public++;
        return http.Response('limited', 429);
      }
      local++;
      return http.Response('[]', 200);
    }));
    for (var i = 0; i < 3; i++) {
      final snapshot = await service.scan();
      expect(snapshot['balanceSompi'], 0);
      expect(await service.activity(snapshot), isEmpty);
    }
    expect(public, 0);
    expect(local, greaterThan(0));
    expect(native.signatures, 0);
    service.close();
  });
  test('exhausted 429 retries never become zero balance or unused addresses',
      () async {
    final native = HiddenSecurity();
    var calls = 0;
    final service =
        hiddenService(owner, security: native, client: MockClient((r) async {
      calls++;
      return http.Response('limited', 429);
    }));
    await expectLater(
        service.get('${HiddenKasService.history}/read'),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('rate-limited'))));
    expect(calls, 3);
    expect(native.observed, 0);
    expect(native.signatures, 0);
    expect(native.issues, 0);
    service.close();
  });
  test('long Retry-After is respected without an unbounded wait', () async {
    final clock = ReadClock();
    var calls = 0;
    final service = HiddenKasService(owner,
        security: HiddenSecurity(),
        clock: clock.now,
        sleep: clock.sleep, client: MockClient((r) async {
      calls++;
      return http.Response('limited', 429, headers: {'retry-after': '120'});
    }));
    for (var i = 0; i < 2; i++) {
      await expectLater(
          service.get('${HiddenKasService.history}/read'), throwsStateError);
    }
    expect(calls, 1);
    expect(clock.waits, isEmpty);
    service.close();
  });
  test('retired keys skip history but always fetch live UTXOs; exact gap only',
      () async {
    final native = HiddenSecurity()
      ..state['receiveCount'] = 1
      ..state['exposed'] = <String>['0:0'];
    var utxos = 0, histories = 0;
    final service =
        hiddenService(owner, security: native, client: MockClient((r) async {
      if (r.url.path.endsWith('/utxos')) {
        utxos++;
      } else {
        histories++;
        expect(r.url.path, isNot(contains(p2sh)));
      }
      return http.Response('[]', 200);
    }));
    for (var i = 0; i < 2; i++) {
      final snapshot = await service.scan();
      expect((snapshot['addresses'] as List).length, 41);
    }
    expect(utxos, 82);
    expect(histories, 80);
    service.close();
  });
  for (final reject in [false, true]) {
    testWidgets(
        reject
            ? 'submit error keeps saved-payment UI and is not masked by refresh'
            : 'confirmation is not followed by discovery; later 429 cannot erase success',
        (tester) async {
      final native = HiddenSecurity()
        ..confirm = true
        ..state['pending'] = {
          'transactionId': signedId,
          'submitJson': 'EXACT SAVED SIGNED BYTES'
        };
      final service = ConfirmedPaymentService(native)..rejectSubmit = reject;
      await tester.pumpWidget(
          MaterialApp(home: HiddenKasScreen(address: owner, service: service)));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      final resume = find.text('Check payment status');
      // Existing signed payments are now checked automatically on opening.
      expect(service.scans, 0);
      expect(service.submits, 1);
      if (reject) {
        expect(find.text('Original node submission error'), findsOneWidget);
        expect(resume, findsOneWidget);
        expect(native.state['pending'], isNotNull);
      } else {
        expect(find.text('Payment confirmed by the Kaspire node.'),
            findsOneWidget);
        expect(resume, findsNothing);
        final back = find.text('Return to account');
        await tester.ensureVisible(back);
        await tester.tap(back);
        await tester.pumpAndSettle();
        expect(service.scans, 1);
        expect(service.submits, 1);
        expect(find.text('Payment confirmed by the Kaspire node.'),
            findsOneWidget);
        expect(
            find.textContaining('Do not repeat the payment.'), findsOneWidget);
        expect(find.text('Review payment'), findsNothing);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  test('restore scans issued ranges past ordinary gap', () async {
    final native = HiddenSecurity()..state['receiveCount'] = 45;
    final service = hiddenService(owner,
        security: native,
        client: MockClient((r) async => http.Response('[]', 200)));
    final snapshot = await service.scan();
    expect((snapshot['addresses'] as List).length, 65);
    service.close();
  });
  test('already retired receive address is not offered again', () async {
    final native = HiddenSecurity()
      ..state['receiveCount'] = 1
      ..state['exposed'] = <String>['0:0'];
    final service = hiddenService(owner, security: native);
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
        hiddenService(owner, security: native, client: MockClient((r) async {
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
  test('delayed node indexing confirms automatically after a single POST',
      () async {
    final native = HiddenSecurity()
      ..confirmOnAttempt = 4
      ..state['pending'] = {
        'transactionId': signedId,
        'submitJson': 'EXACT SAVED SIGNED BYTES'
      };
    var posts = 0;
    final progress = <String?>[];
    final service =
        hiddenService(owner, security: native, client: MockClient((r) async {
      posts++;
      expect(r.body, 'EXACT SAVED SIGNED BYTES');
      return http.Response('{}', 201);
    }))
          ..onPaymentProgress = progress.add;
    await service.resume();
    expect(posts, 1);
    expect(native.confirmations, 4);
    expect(native.signatures, 0);
    expect(native.state['pending'], isNull);
    expect(
        progress, contains('Waiting for confirmation from the Kaspire node…'));
    expect(progress.last, isNull);
    service.close();
  });
  test('uncertain/already-known broadcast still waits for native acceptance',
      () async {
    for (final status in [409, 503]) {
      final native = HiddenSecurity()
        ..confirmOnAttempt = 3
        ..state['pending'] = {
          'transactionId': signedId,
          'submitJson': 'EXACT SAVED SIGNED BYTES'
        };
      var posts = 0;
      final service =
          hiddenService(owner, security: native, client: MockClient((r) async {
        posts++;
        return http.Response('already known or unavailable', status);
      }));
      await service.resume();
      expect(posts, 1);
      expect(native.state['pending'], isNull);
      expect(native.signatures, 0);
      service.close();
    }
  });
  test('concurrent status checks share one operation and one saved-byte POST',
      () async {
    final native = HiddenSecurity()
      ..confirmOnAttempt = 4
      ..state['pending'] = {
        'transactionId': signedId,
        'submitJson': 'EXACT SAVED SIGNED BYTES'
      };
    var posts = 0;
    final service =
        hiddenService(owner, security: native, client: MockClient((r) async {
      posts++;
      return http.Response('{}', 201);
    }));
    await Future.wait([service.resume(), service.resume(), service.resume()]);
    expect(posts, 1);
    expect(native.confirmations, 4);
    expect(native.signatures, 0);
    service.close();
  });
  test('security errors are not retried or treated as pending confirmation',
      () async {
    final native = HiddenSecurity()
      ..confirmationErrorCode = 'SECURITY_ERROR'
      ..state['pending'] = {
        'transactionId': signedId,
        'submitJson': 'EXACT SAVED SIGNED BYTES'
      };
    final service =
        hiddenService(owner, security: native, client: MockClient((r) async {
      fail('No POST after a journal/security error');
    }));
    await expectLater(service.resume(), throwsA(isA<PlatformException>()));
    expect(native.confirmations, 1);
    expect(native.state['pending'], isNotNull);
    service.close();
  });
  test(
      'closing during confirmation stops polling without signing or losing recovery',
      () async {
    final native = HiddenSecurity()
      ..state['pending'] = {
        'transactionId': signedId,
        'submitJson': 'EXACT SAVED SIGNED BYTES'
      };
    final clock = ReadClock();
    late HiddenKasService service;
    service = HiddenKasService(owner, security: native, clock: clock.now,
        sleep: (duration) async {
      await clock.sleep(duration);
      service.close();
    }, client: MockClient((r) async => http.Response('{}', 201)));
    await expectLater(service.resume(), throwsStateError);
    expect(native.confirmations, 2);
    expect(native.state['pending'], isNotNull);
    expect(native.signatures, 0);
  });
  testWidgets('activity copy button copies the entire transaction ID',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final service = ConfirmedPaymentService(HiddenSecurity())
      ..activities = [
        WalletTransaction(
            id: signedId,
            timestamp: DateTime.utc(2026, 10, 19),
            amountSompi: 100000000,
            incoming: false)
      ];
    await tester.pumpWidget(
        MaterialApp(home: HiddenKasScreen(address: owner, service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Activity'));
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    final copy = find.byTooltip('Copy transaction ID');
    await tester.scrollUntilVisible(copy, 300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(copied, signedId);
    expect(find.text('Transaction ID copied'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  test('already confirmed transaction is cleared without rebroadcast',
      () async {
    final native = HiddenSecurity()
      ..confirm = true
      ..state['pending'] = {
        'transactionId': signedId,
        'submitJson': 'EXACT SAVED SIGNED BYTES'
      };
    final service = hiddenService(owner,
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
    final service = hiddenService(owner, security: native);
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
  test('empty Max recipient fails before scanning or reserving an address',
      () async {
    final native = HiddenSecurity();
    final service = hiddenService(owner, security: native);
    await expectLater(service.prepare(' ', 0, sendAll: true), throwsStateError);
    expect(native.derivations, 0);
    expect(native.issues, 0);
    expect(native.signatures, 0);
    service.close();
  });
  for (final theme in KaspireTheme.values) {
    testWidgets('P2SH receive/send/activity inherit $theme at narrow width',
        (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final previous = AppSettings.theme.value;
      AppSettings.theme.value = theme;
      addTearDown(() => AppSettings.theme.value = previous);
      final native = HiddenSecurity();
      final service = MaxPreviewService(native);
      // Deliberately default host: P2SH must not inherit Midnight controls
      // while its decorative surfaces read the active HUB21/Glacier setting.
      await tester.pumpWidget(MaterialApp(
          home: HiddenKasScreen(
              address: owner, service: service, embedded: true)));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      final backup =
          find.widgetWithText(FilledButton, 'Save encrypted recovery backup');
      await tester.ensureVisible(backup);
      await tester.pumpAndSettle();
      final themed = Theme.of(tester.element(backup));
      final expected = KasVaultTheme.forTheme(theme);
      expect(themed.colorScheme.primary, expected.colorScheme.primary);
      final decorative = [
        KaspireTheme.hub21,
        KaspireTheme.glacier,
        KaspireTheme.neptune
      ].contains(theme);
      if (decorative || theme == KaspireTheme.midnight) {
        await expectLater(find.byType(HiddenKasScreen),
            matchesGoldenFile('goldens/p2sh-${theme.name}-receive.png'));
      }
      expect(find.descendant(of: backup, matching: find.byType(Hub21Panel)),
          decorative ? findsOneWidget : findsNothing);
      expect(find.byType(KasReceiveRequest), findsOneWidget);
      expect(find.text('Send KAS'), findsNothing);
      final qr = find.byType(QrImageView);
      await tester.scrollUntilVisible(qr, 180,
          scrollable: find.byType(Scrollable).first);
      expect(
          tester
              .widget<KasReceiveRequest>(find.byType(KasReceiveRequest))
              .address,
          p2sh);
      expect(tester.widget<QrImageView>(qr).dataModuleStyle.color,
          KasVaultTheme.qrInk);
      await tester.scrollUntilVisible(find.text('Send'), -180,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(find.byType(KasReceiveRequest), findsNothing);
      expect(find.text('Send KAS'), findsOneWidget);
      expect(find.text('Available'), findsOneWidget);
      if (decorative || theme == KaspireTheme.midnight) {
        await expectLater(find.byType(HiddenKasScreen),
            matchesGoldenFile('goldens/p2sh-${theme.name}-send.png'));
      }
      await tester.scrollUntilVisible(find.text('Review transaction'), 180,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Review transaction'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Activity'), -180,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Activity'));
      await tester.pumpAndSettle();
      expect(find.text('Account activity'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(service.preparations, 0);
      expect(native.signatures, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  for (final theme in [
    KaspireTheme.midnight,
    KaspireTheme.hub21,
    KaspireTheme.glacier,
    KaspireTheme.neptune
  ]) {
    testWidgets(
        'Max previews the native fee-adjusted amount without signing in $theme',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final previous = AppSettings.theme.value;
      addTearDown(() => AppSettings.theme.value = previous);
      AppSettings.theme.value = theme;
      final native = HiddenSecurity();
      final service = MaxPreviewService(native);
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: HiddenKasScreen(address: owner, service: service)));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Send'));
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      final maxButton = find.text('Max');
      await tester.scrollUntilVisible(maxButton, 250,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(maxButton);
      await tester.pumpAndSettle();
      await tester.tap(maxButton);
      await tester.pumpAndSettle();
      expect(service.preparations, 0);
      final fields =
          tester.widgetList<TextField>(find.byType(TextField)).toList();
      expect(fields.last.readOnly, isTrue);
      final destination = find.byType(TextField).first;
      await tester.ensureVisible(destination);
      await tester.enterText(destination, owner);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final review = find.text('Review transaction');
      await tester.scrollUntilVisible(review, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(review);
      await tester.pumpAndSettle();
      await tester.tap(review);
      await tester.pumpAndSettle();
      expect(service.requestedMax, isTrue);
      expect(service.requestedAmount, 0);
      expect(service.preparations, 1);
      expect(fields.last.controller!.text, '0.9999');
      expect(find.text('Change address'), findsNothing);
      expect(native.signatures, 0);
      final cancel = find.text('Cancel');
      await tester.ensureVisible(cancel);
      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(tester.widgetList<TextField>(find.byType(TextField)).last.readOnly,
          isFalse);
      expect(find.text('Authenticate, sign and send'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
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
              service: hiddenService(owner, security: HiddenSecurity()))));
      await tester.pumpAndSettle();
      expect(find.text('P2SH account'), findsNWidgets(2));
      expect(
          find.textContaining('to aid in quantum resistance.'), findsOneWidget);
      expect(
          find.textContaining('Test with small amounts only.'), findsNothing);
      expect(find.textContaining('KIP-22 draft'), findsNothing);
      expect(find.text('Copy address'), findsNothing);
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pump();
      expect(tester.takeException(), isNull);
      AppSettings.theme.value = KaspireTheme.midnight;
    });
  }
}
