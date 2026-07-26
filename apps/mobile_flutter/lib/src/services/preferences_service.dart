import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

class PreferencesService {
  static const _addressKey = 'watch_address_v1';
  static const _watchWalletsKey = 'watch_wallets_v2';
  static const _addressBookKey = 'address_book_v1';

  Future<String?> getAddress() async =>
      (await SharedPreferences.getInstance()).getString(_addressKey);

  Future<void> setAddress(String address) async {
    await (await SharedPreferences.getInstance()).setString(
      _addressKey,
      address,
    );
  }

  Future<void> clearAddress() async {
    await (await SharedPreferences.getInstance()).remove(_addressKey);
  }

  Future<List<WatchWalletInfo>> getWatchWallets() async {
    final raw =
        (await SharedPreferences.getInstance()).getString(_watchWalletsKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((item) => WatchWalletInfo.fromJson(item.cast<String, Object?>()))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> addWatchWallet(String address, {String? name}) async {
    final prefs = await SharedPreferences.getInstance();
    final wallets = await getWatchWallets();
    if (wallets.any((wallet) => wallet.address == address)) return;
    wallets.add(WatchWalletInfo(
      id: 'watch-${DateTime.now().microsecondsSinceEpoch}',
      address: address,
      name: name ?? 'Watch wallet ${wallets.length + 1}',
    ));
    await prefs.setString(
      _watchWalletsKey,
      jsonEncode(wallets.map((wallet) => wallet.toJson()).toList()),
    );
  }

  Future<void> removeWatchWallet(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final wallets = (await getWatchWallets())
      ..removeWhere((wallet) => wallet.id == id);
    await prefs.setString(
      _watchWalletsKey,
      jsonEncode(wallets.map((wallet) => wallet.toJson()).toList()),
    );
  }

  Future<void> renameWatchWallet(String id, String name) async {
    final normalized = name.trim();
    if (normalized.isEmpty || normalized.length > 40) {
      throw ArgumentError('Wallet name must contain 1 to 40 characters.');
    }
    final prefs = await SharedPreferences.getInstance();
    final wallets = await getWatchWallets();
    final index = wallets.indexWhere((wallet) => wallet.id == id);
    if (index < 0) throw StateError('Watch wallet not found.');
    wallets[index] = WatchWalletInfo(
      id: wallets[index].id,
      address: wallets[index].address,
      name: normalized,
    );
    await prefs.setString(
      _watchWalletsKey,
      jsonEncode(wallets.map((wallet) => wallet.toJson()).toList()),
    );
  }

  Future<List<AddressBookEntry>> getAddressBook() async {
    final raw =
        (await SharedPreferences.getInstance()).getString(_addressBookKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((item) => AddressBookEntry.fromJson(
                item.cast<String, Object?>(),
              ))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveAddressBookEntry(AddressBookEntry entry) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = await getAddressBook();
    entries.removeWhere((item) =>
        item.id == entry.id ||
        item.address.toLowerCase() == entry.address.toLowerCase());
    entries.add(entry);
    entries
        .sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    await prefs.setString(
      _addressBookKey,
      jsonEncode(entries.map((item) => item.toJson()).toList()),
    );
  }

  Future<void> removeAddressBookEntry(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = (await getAddressBook())
      ..removeWhere((item) => item.id == id);
    await prefs.setString(
      _addressBookKey,
      jsonEncode(entries.map((item) => item.toJson()).toList()),
    );
  }
}

class AddressBookEntry {
  const AddressBookEntry({
    required this.id,
    required this.name,
    required this.address,
  });

  factory AddressBookEntry.fromJson(Map<String, Object?> json) =>
      AddressBookEntry(
        id: json['id']!.toString(),
        name: json['name']!.toString(),
        address: json['address']!.toString(),
      );

  final String id;
  final String name;
  final String address;
  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'address': address,
      };
}

class WatchWalletInfo {
  WatchWalletInfo(
      {required this.id, required this.address, required this.name});
  factory WatchWalletInfo.fromJson(Map<String, Object?> json) =>
      WatchWalletInfo(
        id: json['id']!.toString(),
        address: json['address']!.toString(),
        name: json['name']?.toString() ?? 'Watch wallet',
      );
  final String id;
  final String address;
  final String name;
  Map<String, Object?> toJson() => {'id': id, 'address': address, 'name': name};
}
