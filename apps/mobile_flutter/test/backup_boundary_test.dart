import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android backup KDF uses mutable password and key buffers', () {
    const base = 'android/app/src/main/kotlin/space/kasvault/wallet';
    final activity = File('$base/MainActivity.kt').readAsStringSync();
    final bridge = File('$base/SecureCore.kt').readAsStringSync();
    final start = activity.indexOf('private fun argon2BackupKey');
    final end = activity.indexOf('private fun readBackup', start);
    final kdf = activity.substring(start, end);
    expect(kdf, isNot(contains('String(password)')));
    expect(kdf, isNot(contains('saltHex')));
    expect(kdf, contains('CharBuffer.wrap(password)'));
    expect(kdf, contains('encoded.array().fill(0)'));
    expect(kdf, contains('passwordBytes?.fill(0)'));
    expect(bridge, contains('deriveBackupKeyBytes(password: ByteArray, salt: ByteArray, version: Int): ByteArray'));
    expect(bridge, isNot(contains('deriveBackupKey(password: String')));
    expect(activity, isNot(contains('argon2BackupKey(password.text.toString()')));
    final native = File('../../crates/kaspa_secure_core/src/android.rs').readAsStringSync();
    final function = native.substring(native.indexOf('fn Java_space_kasvault_wallet_SecureCore_deriveBackupKeyBytes'), native.indexOf('fn Java_space_kasvault_wallet_SecureCore_prepareTransaction'));
    expect(function, contains('Zeroizing::new(env.convert_byte_array(&password)'));
    expect(function, contains('set_byte_array_region(&password'));
    expect(function, contains('byte_array_from_slice(key.as_slice())'));
    expect(function, isNot(contains('password: JString')));
    expect(function, isNot(contains('hex::encode')));
  });
}
