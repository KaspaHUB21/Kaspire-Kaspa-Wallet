import 'dart:convert';

import '../models/wallet_snapshot.dart';
import 'encrypted_store.dart';

class ActivityStore {
  ActivityStore({EncryptedStore? encryptedStore})
      : _encryptedStore = encryptedStore ?? const KeystoreEncryptedStore();

  final EncryptedStore _encryptedStore;
  static const _key = 'kaspire_asset_activity_v1';
  static const _maxEntries = 200;

  Future<List<WalletTransaction>> load(String address) async {
    final raw = await readWithPlaintextMigration(_encryptedStore, _key);
    if (raw == null) return const [];
    try {
      return (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((item) => item.cast<String, Object?>())
          .where((item) => item['wallet'] == address)
          .map(WalletTransaction.fromStoredJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> recordAssetTransfer({
    required String wallet,
    required Map operation,
    required String transactionId,
    required DateTime timestamp,
  }) async {
    List<Object?> entries;
    try {
      entries = (jsonDecode(
        await readWithPlaintextMigration(_encryptedStore, _key) ?? '[]',
      ) as List)
          .toList();
    } catch (_) {
      entries = [];
    }
    final kind = operation['kind'].toString();
    final symbol = kind == 'kns'
        ? operation['domainName']?.toString()
        : operation['ticker']?.toString().toUpperCase();
    final value = <String, Object?>{
      'wallet': wallet,
      'transactionId': transactionId,
      'timestamp': timestamp.toIso8601String(),
      'assetKind': kind == 'kcc20'
          ? 'KCC20'
          : kind == 'krc20'
              ? 'KRC-20'
              : kind == 'krc721'
                  ? 'KRC-721'
                  : 'KNS',
      'assetSymbol': symbol,
      'displayAmount': operation['displayAmount']?.toString() ??
          (kind == 'krc721' ? '1' : null),
      'tokenId': operation['tokenId']?.toString(),
      'counterparty': operation['recipient']?.toString(),
      'incoming': false,
      'status': TransactionStatus.accepted.name,
    };
    entries.removeWhere((item) => item is Map && _sameEntry(item, value));
    entries.insert(0, value);
    await _encryptedStore.write(
      _key,
      jsonEncode(entries.take(_maxEntries).toList()),
    );
  }

  Future<void> recordKasTransfer({
    required String wallet,
    required String recipient,
    required String transactionId,
    required int amountSompi,
    required DateTime timestamp,
    required TransactionStatus status,
  }) async {
    await _upsert(<String, Object?>{
      'wallet': wallet,
      'transactionId': transactionId,
      'timestamp': timestamp.toIso8601String(),
      'assetKind': 'KAS',
      'assetSymbol': 'KAS',
      'amountSompi': amountSompi,
      'counterparty': recipient,
      'incoming': false,
      'status': status.name,
    });
  }

  Future<void> updateStatus(
    String transactionId,
    TransactionStatus status,
  ) async {
    List<Object?> entries;
    try {
      entries = (jsonDecode(
        await readWithPlaintextMigration(_encryptedStore, _key) ?? '[]',
      ) as List)
          .toList();
    } catch (_) {
      return;
    }
    var changed = false;
    for (final entry in entries.whereType<Map>()) {
      if (entry['transactionId']?.toString() == transactionId) {
        entry['status'] = status.name;
        changed = true;
      }
    }
    if (changed) await _encryptedStore.write(_key, jsonEncode(entries));
  }

  Future<void> _upsert(Map<String, Object?> value) async {
    List<Object?> entries;
    try {
      entries = (jsonDecode(
        await readWithPlaintextMigration(_encryptedStore, _key) ?? '[]',
      ) as List)
          .toList();
    } catch (_) {
      entries = [];
    }
    entries.removeWhere((item) => item is Map && _sameEntry(item, value));
    entries.insert(0, value);
    await _encryptedStore.write(
      _key,
      jsonEncode(entries.take(_maxEntries).toList()),
    );
  }

  bool _sameEntry(Map item, Map value) =>
      item['transactionId']?.toString() == value['transactionId']?.toString() &&
      item['assetKind']?.toString() == value['assetKind']?.toString() &&
      item['assetSymbol']?.toString() == value['assetSymbol']?.toString() &&
      item['tokenId']?.toString() == value['tokenId']?.toString() &&
      item['incoming'] == value['incoming'];
}

List<WalletTransaction> mergeWalletActivity(
  List<WalletTransaction> local,
  List<WalletTransaction> network,
) {
  String identity(WalletTransaction transaction) => [
        transaction.id,
        transaction.assetKind,
        transaction.assetSymbol ?? '',
        transaction.tokenId ?? '',
        transaction.incoming.toString(),
      ].join('|');

  final merged = <String, WalletTransaction>{
    for (final transaction in local) identity(transaction): transaction,
    for (final transaction in network) identity(transaction): transaction,
  }.values.toList()
    ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  return merged;
}
