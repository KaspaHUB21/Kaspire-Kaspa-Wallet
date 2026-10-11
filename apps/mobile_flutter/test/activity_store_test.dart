import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/models/wallet_snapshot.dart';
import 'package:kasvault_wallet/src/services/activity_store.dart';
import 'package:kasvault_wallet/src/services/encrypted_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kasvault_wallet/src/services/kron_dex_service.dart';

void main() {
  test('KRON buys and sells record exact units and replay idempotently',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = ActivityStore(encryptedStore: _MemoryEncryptedStore());
    for (final side in ['buy', 'sell']) {
      final receipt = {
        'ticker': 'KRON',
        'decimals': 3,
        'tokenId': 'a' * 64,
        'timestamp': '2026-10-10T12:00:00.000Z',
        'summary': {'side': side, 'tokenAmount': '420290'}
      };
      await KronDexService.recordReceipt('wallet', receipt, side,
          activity: store);
      await KronDexService.recordReceipt('wallet', receipt, side,
          activity: store);
    }
    final rows = await store.load('wallet');
    expect(rows, hasLength(2));
    expect(rows.map((r) => r.amountLabel).toSet(), {'420.29 KRON'});
    expect(rows.map((r) => r.incoming).toSet(), {true, false});
    expect(rows.every((r) => r.tokenId == 'a' * 64), isTrue);
  });
  test('concurrent mixed assets and different wallets never overwrite entries',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = ActivityStore(encryptedStore: _MemoryEncryptedStore());
    await Future.wait([
      for (final wallet in ['one', 'two'])
        for (final operation in [
          {'kind': 'krc20', 'ticker': 'X'},
          {'kind': 'krc721', 'ticker': 'X', 'tokenId': '1'},
          {'kind': 'kcc20', 'ticker': 'X', 'covenantId': 'a' * 64},
          {'kind': 'kcc20', 'ticker': 'X', 'covenantId': 'b' * 64},
          {'kind': 'kns', 'domainName': 'Demo.kas'},
          {'kind': 'dotk', 'name': 'Demo.k'},
        ])
          store.recordAssetTransfer(
              wallet: wallet,
              operation: operation,
              transactionId: 'same',
              timestamp: DateTime.utc(2026, 10, 10)),
    ]);
    expect(await store.load('one'), hasLength(6));
    expect(await store.load('two'), hasLength(6));
    expect(
        (await store.load('one'))
            .singleWhere((r) => r.assetKind == 'DOT.K')
            .assetSymbol,
        'Demo.k');
  });
  test('marketplace receipt records received tokens, not an outgoing transfer',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = ActivityStore(encryptedStore: _MemoryEncryptedStore());
    await store.recordAssetTransfer(
        wallet: 'buyer',
        incoming: true,
        operation: const {
          'kind': 'krc20',
          'ticker': 'KASBTC',
          'displayAmount': '4',
          'recipient': 'seller'
        },
        transactionId: 'purchase',
        timestamp: DateTime.utc(2026, 10, 9));
    final tx = (await store.load('buyer')).single;
    expect(tx.incoming, isTrue);
    expect(tx.assetKind, 'KRC-20');
    expect(tx.displayAmount, '4');
    expect(tx.counterparty, 'seller');
  });
  test('persists completed KRC-721 and KNS activity per wallet', () async {
    SharedPreferences.setMockInitialValues({});
    final store = ActivityStore(encryptedStore: _MemoryEncryptedStore());
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
    final store = ActivityStore(encryptedStore: _MemoryEncryptedStore());
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

  test('persists covenant wyrm lifecycle transactions with readable labels',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = ActivityStore(encryptedStore: _MemoryEncryptedStore());
    await store.recordCovenantWyrmTransaction(
      wallet: 'kaspa:qwallet',
      transactionId: 'wyrm-transition',
      operationLabel: 'Covenant Wyrm Incubation Started',
      stateLabel: 'Covenant Wyrm #1',
      timestamp: DateTime.utc(2026, 9, 29),
    );

    final stored = await store.load('kaspa:qwallet');
    expect(stored, hasLength(1));
    expect(stored.single.assetKind, 'COVENANT');
    expect(stored.single.operationLabel, 'Covenant Wyrm Incubation Started');
    expect(stored.single.amountLabel, 'Covenant Wyrm #1');
    expect(stored.single.status, TransactionStatus.accepted);
  });

  test('falls back when Android encrypted activity storage is unavailable',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = ActivityStore(encryptedStore: _FailingEncryptedStore());
    await store.recordCovenantWyrmTransaction(
      wallet: 'kaspa:qwallet',
      transactionId: 'wyrm-genesis',
      operationLabel: 'Covenant Egg Minted',
      stateLabel: 'Covenant Wyrm #2 · Genesis Egg',
      timestamp: DateTime.utc(2026, 9, 29),
    );

    final stored = await store.load('kaspa:qwallet');
    expect(stored, hasLength(1));
    expect(stored.single.id, 'wyrm-genesis');
    expect(stored.single.operationLabel, 'Covenant Egg Minted');
  });
}

class _MemoryEncryptedStore implements EncryptedStore {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class _FailingEncryptedStore implements EncryptedStore {
  @override
  Future<void> delete(String key) => throw StateError('keystore unavailable');
  @override
  Future<String?> read(String key) => throw StateError('keystore unavailable');
  @override
  Future<void> write(String key, String value) =>
      throw StateError('keystore unavailable');
}
