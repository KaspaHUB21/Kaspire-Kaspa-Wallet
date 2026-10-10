import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/wallet_snapshot.dart';
import 'encrypted_store.dart';

class ActivityStore {
  ActivityStore({EncryptedStore? encryptedStore})
      : _encryptedStore = encryptedStore ?? const KeystoreEncryptedStore();

  final EncryptedStore _encryptedStore;
  static const _key = 'kaspire_asset_activity_v1';
  static const _fallbackKey = 'kaspire_asset_activity_fallback_v1';
  static const _maxEntries = 200;
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  static void _notifyChanged() => changes.value++;

  Future<List<WalletTransaction>> load(String address) async {
    final raw = await _readRaw();
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
    bool incoming = false,
  }) async {
    List<Object?> entries;
    try {
      entries = (jsonDecode(await _readRaw() ?? '[]') as List).toList();
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
      'incoming': incoming,
      'status': TransactionStatus.accepted.name,
    };
    entries.removeWhere((item) => item is Map && _sameEntry(item, value));
    entries.insert(0, value);
    await _writeRaw(jsonEncode(entries.take(_maxEntries).toList()));
    _notifyChanged();
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

  Future<void> recordCovenantWyrmTransaction({
    required String wallet,
    required String transactionId,
    required String operationLabel,
    required String stateLabel,
    required DateTime timestamp,
  }) async {
    await _upsert(<String, Object?>{
      'wallet': wallet,
      'transactionId': transactionId,
      'timestamp': timestamp.toIso8601String(),
      'assetKind': 'COVENANT',
      'assetSymbol': 'WYRM',
      'operationLabel': operationLabel,
      'amountLabelOverride': stateLabel,
      'incoming': false,
      'status': TransactionStatus.accepted.name,
    });
  }

  Future<void> updateStatus(
    String transactionId,
    TransactionStatus status,
  ) async {
    List<Object?> entries;
    try {
      entries = (jsonDecode(await _readRaw() ?? '[]') as List).toList();
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
    if (changed) {
      await _writeRaw(jsonEncode(entries));
      _notifyChanged();
    }
  }

  Future<void> _upsert(Map<String, Object?> value) async {
    List<Object?> entries;
    try {
      entries = (jsonDecode(await _readRaw() ?? '[]') as List).toList();
    } catch (_) {
      entries = [];
    }
    entries.removeWhere((item) => item is Map && _sameEntry(item, value));
    entries.insert(0, value);
    await _writeRaw(jsonEncode(entries.take(_maxEntries).toList()));
    _notifyChanged();
  }

  Future<String?> _readRaw() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final fallback = preferences.getString(_fallbackKey);
      if (fallback != null) return fallback;
    } catch (_) {
      // The encrypted store remains the primary source when preferences are
      // temporarily unavailable.
    }
    try {
      return await readWithPlaintextMigration(_encryptedStore, _key);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeRaw(String value) async {
    try {
      await _encryptedStore.write(_key, value);
      try {
        await (await SharedPreferences.getInstance()).remove(_fallbackKey);
      } catch (_) {}
      return;
    } catch (_) {
      // Activity is public transaction metadata. Persist it in app-private
      // preferences if an Android keystore plugin is temporarily unavailable.
      await (await SharedPreferences.getInstance()).setString(
        _fallbackKey,
        value,
      );
    }
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
