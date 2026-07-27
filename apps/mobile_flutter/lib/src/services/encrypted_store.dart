import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class EncryptedStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class KeystoreEncryptedStore implements EncryptedStore {
  const KeystoreEncryptedStore();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Reads encrypted data first and moves a legacy plaintext value exactly once.
Future<String?> readWithPlaintextMigration(
  EncryptedStore store,
  String key,
) async {
  final encrypted = await store.read(key);
  if (encrypted != null) return encrypted;
  final preferences = await SharedPreferences.getInstance();
  final legacy = preferences.getString(key);
  if (legacy == null) return null;
  await store.write(key, legacy);
  await preferences.remove(key);
  return legacy;
}
