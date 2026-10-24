import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reown_walletkit/reown_walletkit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kasvault_wallet/src/app.dart';
import 'package:kasvault_wallet/src/models/wallet_snapshot.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/services/dapp_session_service.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';

const wallet =
    'kaspa:qqnvxvumjvzwmn755v8nrp4jxm2w50dv9mr2u4qrfqpq3h2hzyjx7tgkdtdgs';
const topic =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const verification = VerifyContext(
    origin: 'https://gothdag.kaslab.space',
    validation: Validation.VALID,
    verifyUrl: 'https://verify.walletconnect.org');
SessionRequest payment(int id) => SessionRequest(
    id: id,
    topic: topic,
    chainId: 'kaspa:mainnet',
    method: 'kaspa_sendKrc20',
    params: {
      'from': wallet,
      'to': wallet,
      'ticker': 'KASBTC',
      'amount': '100000000'
    },
    verifyContext: verification);
ProposalData proposal(int id, String host) => ProposalData(
    id: id,
    expiry: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
    relays: [Relay('irn')],
    proposer: ConnectionMetadata(
        publicKey: 'b' * 64,
        metadata: PairingMetadata(
            name: host,
            description: 'Public test dApp',
            url: 'https://$host',
            icons: const [])),
    requiredNamespaces: const {
      'kaspa': RequiredNamespace(
          chains: ['kaspa:mainnet'],
          methods: ['kaspa_getAccounts', 'kaspa_getNetwork', 'kaspa_signPskt'],
          events: ['accountsChanged'])
    },
    optionalNamespaces: const {},
    pairingTopic: 'c' * 64);

class FakeKit implements ReownWalletKit {
  @override
  final onSessionProposal = Event<SessionProposalEvent>();
  @override
  final onSessionRequest = Event<SessionRequestEvent>();
  @override
  final onSessionConnect = Event<SessionConnect>();
  @override
  final onSessionDelete = Event<SessionDelete>();
  @override
  final onSessionExpire = Event<SessionExpire>();
  final requests = <String, SessionRequest>{};
  final pendingProposals = <String, ProposalData>{};
  final responses = <JsonRpcResponse>[];
  @override
  Map<String, SessionRequest> getPendingSessionRequests() => Map.of(requests);
  @override
  Map<String, ProposalData> getPendingSessionProposals() =>
      Map.of(pendingProposals);
  @override
  Map<String, SessionData> getActiveSessions() => {
        topic: SessionData(
            topic: topic,
            pairingTopic: 'c' * 64,
            relay: Relay('irn'),
            expiry: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
            acknowledged: true,
            controller: 'd' * 64,
            namespaces: {
              'kaspa': Namespace(
                  chains: ['kaspa:mainnet'],
                  accounts: ['kaspa:mainnet:${wallet.substring(6)}'],
                  methods: ['kaspa_sendKrc20'],
                  events: [])
            },
            self: const ConnectionMetadata(
                publicKey: 'test',
                metadata: PairingMetadata(
                    name: 'Kaspire',
                    description: '',
                    url: 'https://kaspire.kaslab.space',
                    icons: [])),
            peer: const ConnectionMetadata(
                publicKey: 'test',
                metadata: PairingMetadata(
                    name: 'GothDAG',
                    description: '',
                    url: 'https://gothdag.kaslab.space',
                    icons: [])))
      };
  @override
  Future<void> respondSessionRequest(
      {required String topic, required JsonRpcResponse response}) async {
    responses.add(response);
    requests.remove('${response.id}');
  }

  @override
  Future<void> rejectSession(
      {required int id, required ReownSignError reason}) async {
    pendingProposals.remove('$id');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class HoldingsOnlyApi extends KaspaApi {
  int scans = 0, holdings = 0;
  @override
  Future<WalletSnapshot> loadWallet(String address,
      {int transactionLimit = 20,
      bool includeNativeTransactions = true,
      bool includeAssetHistory = true,
      bool includeMarketData = true,
      void Function(WalletSnapshot)? onProgress}) {
    scans++;
    return Completer<WalletSnapshot>().future;
  }

  @override
  Future<List<WalletAsset>> loadKrc20Holdings(String address) async {
    expect(address, wallet);
    holdings++;
    return const [
      WalletAsset(
          symbol: 'KASBTC',
          balance: 10,
          kind: 'KRC-20',
          decimals: 8,
          rawBalance: '1000000000')
    ];
  }

  @override
  Future<String> loadUtxos(String address) async => '[]';
  @override
  Future<double> loadFeeRate() async => 100;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'an initial relay failure is retryable; concurrent retry initializes once',
      () async {
    final gate = Completer<ReownWalletKit>(), kit = FakeKit();
    var calls = 0;
    final service = DappSessionService.forTesting(() {
      calls++;
      if (calls == 1) throw StateError('temporary relay failure');
      return gate.future;
    });
    await service.initialize();
    expect(service.ready, false);
    expect(service.lastError, isNotNull);
    final first = service.initialize(), second = service.initialize();
    expect(calls, 2);
    gate.complete(kit);
    await Future.wait([first, second]);
    expect(service.ready, true);
    expect(service.lastError, isNull);
    await service.initialize();
    expect(calls, 2);
  });
  test(
      'pending proposals and requests arriving before listeners are replayed exactly once',
      () async {
    final kit = FakeKit();
    kit.requests['1'] = payment(1);
    kit.pendingProposals['2'] = proposal(2, 'kasvio.network');
    final service = DappSessionService.forTesting(() async => kit);
    await service.initialize();
    final received = <SessionRequestEvent>[],
        proposed = <SessionProposalEvent>[];
    final a = service.requests.listen(received.add),
        b = service.proposals.listen(proposed.add);
    await service.refreshPending();
    await service.refreshPending();
    await Future<void>.delayed(Duration.zero);
    expect(received.map((r) => r.id), [1]);
    expect(proposed.map((r) => r.id), [2]);
    kit.onSessionRequest
        .broadcast(SessionRequestEvent.fromSessionRequest(payment(1)));
    await Future<void>.delayed(Duration.zero);
    expect(received, hasLength(1));
    await a.cancel();
    await b.cancel();
  });
  test(
      'every query-free wake can recover a new pending request, not just the first wake',
      () async {
    final kit = FakeKit(), received = <int>[];
    final service = DappSessionService.forTesting(() async => kit);
    final subscription = service.requests.listen((r) => received.add(r.id));
    for (final id in [1, 2, 3]) {
      kit.requests['$id'] = payment(id);
      await service.handleAppLink(Uri.parse('kaspire://dapp'));
    }
    await Future<void>.delayed(Duration.zero);
    expect(received, [1, 2, 3]);
    await subscription.cancel();
    for (final link in [
      'kaspire://dapp?uri=bad',
      'kaspire://evil',
      'kaspire://dapp#bad',
      'kaspire://user@dapp',
      'kaspire://dapp:443'
    ]) {
      expect(DappSessionService.isWakeLink(Uri.parse(link)), false);
    }
  });
  test('replayed proposals preserve original scam verification context',
      () async {
    final kit = FakeKit();
    final service = DappSessionService.forTesting(() async => kit);
    await service.initialize();
    final p = proposal(21, 'kasvio.network');
    kit.pendingProposals['21'] = p;
    kit.onSessionProposal.broadcast(SessionProposalEvent(
        21,
        p,
        const VerifyContext(
            origin: 'https://evil.invalid',
            validation: Validation.SCAM,
            isScam: true,
            verifyUrl: 'https://verify.walletconnect.org')));
    final received = <SessionProposalEvent>[];
    final subscription = service.proposals.listen(received.add);
    await service.refreshPending();
    await Future<void>.delayed(Duration.zero);
    expect(received, hasLength(1));
    expect(service.proposalProblem(received.single), contains('scam'));
    await subscription.cancel();
  });
  test('expired proposals are never restored into the approval queue',
      () async {
    final kit = FakeKit();
    kit.pendingProposals['31'] = proposal(31, 'dotk.name').copyWith(expiry: 1);
    final service = DappSessionService.forTesting(() async => kit);
    final received = <SessionProposalEvent>[];
    final subscription = service.proposals.listen(received.add);
    await service.refreshPending();
    await Future<void>.delayed(Duration.zero);
    expect(received, isEmpty);
    await subscription.cancel();
  });
  test(
      'restored Kasvio/dot.k proposals retain namespace validation and scam rejection',
      () async {
    final service = DappSessionService.forTesting(() async => FakeKit());
    for (final host in ['kasvio.network', 'dotk.name']) {
      final p = proposal(1, host);
      expect(service.proposalProblem(SessionProposalEvent(1, p)), null);
      expect(
          service.proposalProblem(SessionProposalEvent(
              1,
              p,
              const VerifyContext(
                  origin: 'https://evil.invalid',
                  validation: Validation.SCAM,
                  verifyUrl: 'https://verify.walletconnect.org',
                  isScam: true))),
          contains('scam'));
      expect(
          service.proposalProblem(SessionProposalEvent(
              1,
              p.copyWith(requiredNamespaces: const {
                'kaspa': RequiredNamespace(
                    chains: ['kaspa:mainnet'],
                    methods: ['drainWallet'],
                    events: [])
              }))),
          contains('unsupported'));
    }
  });
  testWidgets(
      'GothDAG KRC20 reaches approval without any full-wallet scan or signing',
      (tester) async {
    SharedPreferences.setMockInitialValues({'watch_address_v1': wallet});
    AppSettings.lockMinutes.value = 0;
    final kit = FakeKit(), api = HoldingsOnlyApi(), methods = <String>[];
    final service = DappSessionService.forTesting(() async => kit);
    const channel = MethodChannel('space.kasvault/security');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      switch (call.method) {
        case 'initializeVault':
        case 'setInternalNexusUnlocked':
          return null;
        case 'hasNativeWallet':
          return true;
        case 'prepareInscription':
          return jsonEncode(
              {'commitAddress': wallet, 'commitAmountSompi': 30000000});
        case 'prepareTransaction':
          return jsonEncode({
            'reviewHash': 'e' * 64,
            'amountSompi': 30000000,
            'feeSompi': 1000,
            'changeSompi': 100000,
            'mass': 2000,
            'inputCount': 1,
            'outputCount': 2
          });
        default:
          throw StateError(
              'Unexpected native signing/authentication: ${call.method}');
      }
    });
    for (final name in [
      'com.llfbandit.app_links/messages',
      'com.llfbandit.app_links/events'
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    await tester.pumpWidget(
        KasVaultApp(dappSessions: service, dappApiFactory: () => api));
    await tester.pumpAndSettle();
    kit.requests['1'] = payment(1);
    kit.onSessionRequest
        .broadcast(SessionRequestEvent.fromSessionRequest(payment(1)));
    await tester.pumpAndSettle();
    expect(find.text('GothDAG requests KRC-20'), findsOneWidget);
    expect(find.text('1 KASBTC'), findsOneWidget);
    expect(api.scans, 0);
    expect(api.holdings, 1);
    expect(methods, contains('prepareTransaction'));
    await tester.tap(find.byType(TextButton).last);
    await tester.pumpAndSettle();
    expect(kit.responses.single.error?.code, 4001);
    expect(
        methods.any((m) => m.startsWith('sign') || m.startsWith('authorize')),
        false);
    // New connection prompts must still reach the root navigator after the
    // payment prompt, including while an in-app route is underneath it.
    for (final (id, host) in [(2, 'kasvio.network'), (3, 'dotk.name')]) {
      final p = proposal(id, host);
      kit.pendingProposals['$id'] = p;
      kit.onSessionProposal.broadcast(SessionProposalEvent(id, p));
      await tester.pumpAndSettle();
      expect(find.text('Connect dApp?'), findsOneWidget);
      expect(find.text('https://$host'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Reject'));
      await tester.pumpAndSettle();
      expect(kit.pendingProposals, isEmpty);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    AppSettings.lockMinutes.value = 15;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}
