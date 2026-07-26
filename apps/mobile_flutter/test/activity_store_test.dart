import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/models/wallet_snapshot.dart';
import 'package:kasvault_wallet/src/services/activity_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('persists completed KRC-721 and KNS activity per wallet', () async {
    SharedPreferences.setMockInitialValues({});
    final store = ActivityStore();
    await store.recordAssetTransfer(
      wallet: 'kaspa:qwallet-one',
      operation: const {
        'kind': 'krc721',
        'ticker': 'TOCCATA',
        'tokenId': '42',
        'recipient': 'kaspa:qrecipient',
      },
      transactionId: 'reveal-721',
      timestamp: DateTime.utc(2026, 7, 16),
    );
    await store.recordAssetTransfer(
      wallet: 'kaspa:qwallet-two',
      operation: const {
        'kind': 'kns',
        'domainName': 'demo.kas',
        'recipient': 'kaspa:qrecipient',
      },
      transactionId: 'reveal-kns',
      timestamp: DateTime.utc(2026, 7, 16, 1),
    );

    final first = await store.load('kaspa:qwallet-one');
    expect(first, hasLength(1));
    expect(first.single.assetKind, 'KRC-721');
    expect(first.single.amountLabel, '1 TOCCATA #42');
    expect(first.single.incoming, isFalse);
    expect(await store.load('kaspa:qwallet-two'), hasLength(1));
  });

  test('keeps KAS and KCC20 activity from the same transaction', () async {
    SharedPreferences.setMockInitialValues({});
    final store = ActivityStore();
    final timestamp = DateTime.utc(2026, 7, 24);
    await store.recordKasTransfer(
      wallet: 'kaspa:qwallet',
      recipient: 'kaspa:qrecipient',
      transactionId: 'shared-tx',
      amountSompi: 1234,
      timestamp: timestamp,
      status: TransactionStatus.accepted,
    );
    await store.recordAssetTransfer(
      wallet: 'kaspa:qwallet',
      operation: const {
        'kind': 'kcc20',
        'ticker': 'TOKEN',
        'displayAmount': '42',
        'recipient': 'kaspa:qrecipient',
      },
      transactionId: 'shared-tx',
      timestamp: timestamp,
    );

    final stored = await store.load('kaspa:qwallet');
    expect(stored.map((item) => item.assetKind).toSet(), {'KAS', 'KCC20'});

    final merged = mergeWalletActivity(
      stored,
      [
        WalletTransaction(
          id: 'shared-tx',
          timestamp: timestamp,
          amountSompi: 1200,
          incoming: false,
        ),
      ],
    );
    expect(merged, hasLength(2));
    expect(merged.map((item) => item.assetKind).toSet(), {'KAS', 'KCC20'});
    expect(
      merged.singleWhere((item) => item.assetKind == 'KAS').amountSompi,
      1200,
    );
  });
}
