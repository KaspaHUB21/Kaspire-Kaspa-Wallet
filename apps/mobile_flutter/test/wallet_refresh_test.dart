import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kasvault_wallet/src/models/wallet_snapshot.dart';
import 'package:kasvault_wallet/src/screens/wallet_screen.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';

WalletSnapshot holdings(String? locked,
        {bool ready = true, List<KnsDomain> names = const []}) =>
    WalletSnapshot(
      balanceSompi: 100000000,
      kasUsd: 0.1,
      transactions: [],
      knsDomains: names,
      krc721Collections: [],
      krc20Tokens: locked == null
          ? []
          : [
              WalletAsset(
                  symbol: 'KASBTC',
                  balance: 1,
                  decimals: 8,
                  rawBalance: '100000000',
                  rawLockedBalance: locked,
                  kind: 'KRC-20')
            ],
      loadedAssetCategories: ready ? {'krc20'} : {},
    );

class RefreshApi extends KaspaApi {
  final jobs = <Completer<WalletSnapshot>>[];
  final callbacks = <void Function(WalletSnapshot)?>[];
  @override
  Future<WalletSnapshot> loadWallet(String address,
      {int transactionLimit = 20,
      bool includeNativeTransactions = true,
      bool includeAssetHistory = true,
      bool includeMarketData = true,
      void Function(WalletSnapshot)? onProgress}) {
    callbacks.add(onProgress);
    final job = Completer<WalletSnapshot>();
    jobs.add(job);
    return job.future;
  }

  @override
  Future<int> loadBalanceSompiForAddresses(Iterable<String> addresses) async =>
      100000000;
  @override
  Future<WalletSnapshot> loadWalletBalance(String address,
          {Future<int>? balanceSompi}) async =>
      holdings(null);
  @override
  Future<String> loadUtxosForAddresses(Iterable<String> addresses) async =>
      '[]';
}

void main() {
  test(
      'fresh completed empty source clears holdings; failed or pending source retains them',
      () {
    final old = holdings('2100000000');
    expect(
        old
            .withFreshHoldings(holdings('9000000000'))
            .krc20Tokens
            .single
            .rawLockedBalance,
        '9000000000');
    expect(
        old
            .withFreshHoldings(holdings(null, ready: false))
            .krc20Tokens
            .single
            .rawLockedBalance,
        '2100000000');
    expect(old.withFreshHoldings(holdings(null)).krc20Tokens, isEmpty);
    final known = holdings(null, names: [const KnsDomain(name: 'known.kas')]);
    final partial = known.withFreshHoldings(holdings(null,
        ready: false, names: [const KnsDomain(name: 'new.kas')]));
    expect(
        partial.knsDomains.map((name) => name.name), ['known.kas', 'new.kas']);
  });
  testWidgets(
      'pull refresh publishes 21 to 90 locked before slow final snapshot; waits for completion',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('space.kasvault/security');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel, (call) async => call.method == 'listWallets' ? '[]' : null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final api = RefreshApi();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: WalletScreen(
                address: 'kaspa:test',
                api: api,
                onSend: () {},
                onReceive: () {},
                onPairDapps: () {},
                onSendAsset: (_) {},
                onSwitchWallet: () {},
                onSettings: () {}))));
    await tester.pump();
    api.jobs[0].complete(holdings('2100000000'));
    await tester.pump();
    await tester.pump();
    // Inspect actual row widgets even if their expansion is currently collapsed.
    Iterable<WalletAssetRow> rows() => tester
        .widgetList<ExpansionTile>(
            find.byType(ExpansionTile, skipOffstage: false))
        .expand((tile) => tile.children.whereType<WalletAssetRow>());
    WalletAsset row() => rows().single.asset;
    expect(row().rawLockedBalance, '2100000000');
    final indicator =
        tester.widget<RefreshIndicator>(find.byType(RefreshIndicator));
    var finished = false;
    final pending = indicator.onRefresh().then((_) => finished = true);
    await tester.pump();
    api.callbacks[1]!(holdings('9000000000'));
    await tester.pump();
    expect(row().rawLockedBalance, '9000000000');
    expect(finished, isFalse);
    api.jobs[1].complete(holdings('9000000000'));
    await tester.pump();
    await pending;
    expect(finished, isTrue);
    expect(row().rawLockedBalance, '9000000000');
    final second = indicator.onRefresh();
    await tester.pump();
    api.callbacks[2]!(holdings(null));
    await tester.pump();
    expect(rows(), isEmpty);
    api.jobs[2].complete(holdings(null));
    await tester.pump();
    await second;
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
  });
}
