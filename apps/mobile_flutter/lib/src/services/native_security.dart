import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import 'app_settings.dart';
import 'network_settings.dart';

class NativeSecurity {
  static const _channel = MethodChannel('space.kasvault/security');
  final LocalAuthentication _auth = LocalAuthentication();

  Future<bool> authenticate(BuildContext context, String reason) async {
    final pinAvailable = await hasPin();
    final biometricsAvailable = await _hasBiometrics();
    if (pinAvailable && !biometricsAvailable) {
      return await _channel
              .invokeMethod<bool>('verifyPin', {'reason': reason}) ??
          false;
    }
    if (pinAvailable && biometricsAvailable && context.mounted) {
      final usePin = await showModalBottomSheet<bool>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(reason, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(context, false),
                  icon: const Icon(Icons.fingerprint_rounded),
                  label: Text(buttonLabel('USE BIOMETRICS')),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.pin_rounded),
                  label: Text(buttonLabel('USE KASPIRE PIN')),
                ),
              ],
            ),
          ),
        ),
      );
      if (usePin == null) return false;
      if (usePin) {
        return await _channel
                .invokeMethod<bool>('verifyPin', {'reason': reason}) ??
            false;
      }
    }
    try {
      if (!await _auth.isDeviceSupported()) return false;
      final authenticated = await _auth.authenticate(
        localizedReason: reason,
        options: AuthenticationOptions(
          biometricOnly: pinAvailable && biometricsAvailable,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
      if (authenticated || !pinAvailable) return authenticated;
      return await _channel
              .invokeMethod<bool>('verifyPin', {'reason': reason}) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> _hasBiometrics() async {
    try {
      if (!await _auth.canCheckBiometrics) return false;
      return (await _auth.getAvailableBiometrics()).isNotEmpty;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> isHardwareBacked() async {
    try {
      return await _channel.invokeMethod<bool>('isHardwareBacked') ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> verifyUpdateManifest({
    required String payload,
    required String signature,
  }) async =>
      await _channel.invokeMethod<bool>('verifyUpdateManifest', {
        'payload': payload,
        'signature': signature,
      }) ??
      false;

  Future<void> initializeVault() =>
      _channel.invokeMethod<void>('initializeVault');

  Future<bool> hasNativeWallet() async =>
      await _channel.invokeMethod<bool>('hasNativeWallet') ?? false;

  Future<bool> hasNativeWalletFor(String address) async =>
      await _channel.invokeMethod<bool>('hasNativeWallet', {
        'address': NetworkSettings.storageAddress(address),
      }) ??
      false;

  Future<String?> getNativeAddress() =>
      _channel.invokeMethod<String>('getNativeAddress');

  Future<String> getEvmAddress() async {
    final raw = await _channel.invokeMethod<String>('deriveEvmAddress');
    final decoded = jsonDecode(raw ?? '{}') as Map;
    final address = decoded['address']?.toString() ?? '';
    if (!RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(address)) {
      throw StateError('Native EVM address derivation failed.');
    }
    return address;
  }

  Future<Map<String, Object?>> prepareEvmTransaction(
      Map<String, Object?> request) async {
    final raw = await _channel.invokeMethod<String>(
      'prepareEvmTransaction',
      {'request': jsonEncode(request)},
    );
    return (jsonDecode(raw ?? '{}') as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> signEvmTransaction(
    Map<String, Object?> request,
    String reviewHash,
  ) async {
    final token = await _authorizeOperation(
      operation: 'signEvmTransaction',
      binding: reviewHash,
    );
    final raw = await _channel.invokeMethod<String>('signEvmTransaction', {
      'request': jsonEncode(request),
      'reviewHash': reviewHash,
      'authorizationToken': token,
    });
    return (jsonDecode(raw ?? '{}') as Map).cast<String, Object?>();
  }

  Future<String> createWallet() async {
    final address = await _channel.invokeMethod<String>('createWallet');
    if (address == null) throw StateError('Native wallet creation failed');
    return address;
  }

  Future<String> importWallet() async {
    final address = await _channel.invokeMethod<String>('importWallet');
    if (address == null) throw StateError('Native wallet import failed');
    return address;
  }

  Future<String> importPrivateKey() async {
    final address = await _channel.invokeMethod<String>('importPrivateKey');
    if (address == null) throw StateError('Native private-key import failed');
    return address;
  }

  Future<String> _authorizeOperation({
    required String operation,
    required String binding,
  }) async {
    final token = await _channel.invokeMethod<String>('authorizeOperation', {
      'operation': operation,
      'binding': binding,
      'sessionMinutes': AppSettings.lockMinutes.value,
    });
    if (token == null) throw StateError('Authorization cancelled.');
    return token;
  }

  Future<void> exportPrivateKey(String address) async {
    address = NetworkSettings.storageAddress(address);
    final token = await _authorizeOperation(
      operation: 'exportPrivateKey',
      binding: address,
    );
    await _channel.invokeMethod<void>(
      'exportPrivateKey',
      {
        'address': address,
        'authorizationToken': token,
      },
    );
  }

  Future<Map<String, String>> exportPrivateKeys(String address) async {
    address = NetworkSettings.storageAddress(address);
    final token = await _authorizeOperation(
        operation: 'exportPrivateKey', binding: address);
    final raw = await _channel.invokeMethod<String>('exportPrivateKeys', {
      'address': address,
      'authorizationToken': token,
    });
    return (jsonDecode(raw ?? '{}') as Map)
        .map((key, value) => MapEntry(key.toString(), value.toString()));
  }

  Future<void> exportRecoveryPhrase() async {
    final binding = await getNativeAddress() ?? '';
    final token = await _authorizeOperation(
      operation: 'exportRecoveryPhrase',
      binding: binding,
    );
    await _channel.invokeMethod<void>(
      'exportRecoveryPhrase',
      {'authorizationToken': token},
    );
  }

  Future<void> exportEncryptedBackup() async {
    final binding = await getNativeAddress() ?? '';
    final token = await _authorizeOperation(
      operation: 'exportEncryptedBackup',
      binding: binding,
    );
    await _channel.invokeMethod<void>(
      'exportEncryptedBackup',
      {'authorizationToken': token},
    );
  }

  Future<String?> restoreEncryptedBackup() =>
      _channel.invokeMethod<String>('restoreEncryptedBackup');

  Future<void> deleteWallet() async {
    NativeWalletInfo? active;
    for (final wallet in await listWallets()) {
      if (wallet.active) {
        active = wallet;
        break;
      }
    }
    if (active == null) throw StateError('No active wallet.');
    await deleteWalletById(active.id);
  }

  Future<List<NativeWalletInfo>> listWallets() async {
    final raw = await _channel.invokeMethod<String>('listWallets');
    return (jsonDecode(raw ?? '[]') as List)
        .whereType<Map>()
        .map((item) => NativeWalletInfo.fromJson(item.cast<String, Object?>()))
        .toList();
  }

  Future<void> selectWallet(String walletId) =>
      _channel.invokeMethod<void>('selectWallet', {'walletId': walletId});

  Future<void> renameWallet(String walletId, String name) =>
      _channel.invokeMethod<void>(
        'renameWallet',
        {'walletId': walletId, 'name': name},
      );

  Future<List<NativeHdAddress>> deriveAddresses({
    required int coinType,
    int account = 0,
    required int change,
    required int start,
    int count = 20,
  }) async {
    final raw = await _channel.invokeMethod<String>('deriveAddresses', {
      'coinType': coinType,
      'account': account,
      'change': change,
      'start': start,
      'count': count,
    });
    return (jsonDecode(raw ?? '[]') as List)
        .whereType<Map>()
        .map((item) => NativeHdAddress.fromJson(
              item.cast<String, Object?>(),
            ))
        .toList();
  }

  Future<void> registerHdAddresses(List<NativeHdAddress> addresses) =>
      _channel.invokeMethod<void>('registerHdAddresses', {
        'addresses':
            jsonEncode(addresses.map((item) => item.toJson()).toList()),
      });

  Future<void> deleteWalletById(String walletId) async {
    final token = await _authorizeOperation(
      operation: 'deleteWallet',
      binding: walletId,
    );
    await _channel.invokeMethod<void>(
      'deleteWallet',
      {'walletId': walletId, 'authorizationToken': token},
    );
  }

  Future<bool> hasPin() async =>
      await _channel.invokeMethod<bool>('hasPin') ?? false;

  Future<bool> configurePin() async =>
      await _channel.invokeMethod<bool>('configurePin') ?? false;

  Future<void> removePin() => _channel.invokeMethod<void>('removePin');

  Future<String> signPersonalMessage(String address, String message) async {
    final token = await _authorizeOperation(
      operation: 'signPersonalMessage',
      binding: '$address\u0000$message',
    );
    final raw = await _channel.invokeMethod<String>('signPersonalMessage', {
      'address': address,
      'message': message,
      'authorizationToken': token,
    });
    final result = (jsonDecode(raw!) as Map).cast<String, Object?>();
    return result['signature']! as String;
  }

  Future<String> publicKey(String address) async {
    final raw = await _channel.invokeMethod<String>('publicKey', {
      'address': address,
    });
    final result = (jsonDecode(raw!) as Map).cast<String, Object?>();
    return result['publicKey']! as String;
  }

  Future<Map<String, Object?>> prepareTransaction(
    Map<String, Object?> request,
  ) async {
    final raw = await _channel.invokeMethod<String>('prepareTransaction', {
      'request': jsonEncode(request),
    });
    return (jsonDecode(raw!) as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> signTransaction(
    Map<String, Object?> request,
    String reviewHash,
  ) async {
    final token = await _authorizeOperation(
      operation: 'signTransaction',
      binding: reviewHash,
    );
    final raw = await _channel.invokeMethod<String>('signTransaction', {
      'request': jsonEncode(request),
      'reviewHash': reviewHash,
      'authorizationToken': token,
    });
    return (jsonDecode(raw!) as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> prepareKcc20Transfer(
    Map<String, Object?> request,
  ) async {
    final raw = await _channel.invokeMethod<String>('prepareKcc20Transfer', {
      'request': jsonEncode(request),
    });
    return (jsonDecode(raw!) as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> signKcc20Transfer(
    Map<String, Object?> request,
    String reviewHash,
  ) async {
    final token = await _authorizeOperation(
      operation: 'signKcc20Transfer',
      binding: reviewHash,
    );
    final raw = await _channel.invokeMethod<String>('signKcc20Transfer', {
      'request': jsonEncode(request),
      'reviewHash': reviewHash,
      'authorizationToken': token,
    });
    return (jsonDecode(raw!) as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> prepareInscription(
      Map<String, Object?> request) async {
    final raw = await _channel.invokeMethod<String>(
        'prepareInscription', {'request': jsonEncode(request)});
    return (jsonDecode(raw!) as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> prepareReveal(
      Map<String, Object?> request) async {
    final raw = await _channel.invokeMethod<String>(
        'prepareReveal', {'request': jsonEncode(request)});
    return (jsonDecode(raw!) as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> signReveal(
      Map<String, Object?> request, String reviewHash) async {
    final token = await _authorizeOperation(
      operation: 'signReveal',
      binding: reviewHash,
    );
    final raw = await _channel.invokeMethod<String>('signReveal', {
      'request': jsonEncode(request),
      'reviewHash': reviewHash,
      'authorizationToken': token,
    });
    return (jsonDecode(raw!) as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> preparePolicyTransaction(
      Map<String, Object?> request) async {
    final raw = await _channel.invokeMethod<String>(
        'preparePolicyTransaction', {'request': jsonEncode(request)});
    return (jsonDecode(raw!) as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> signPolicyTransaction(
      Map<String, Object?> request, String reviewHash) async {
    final token = await _authorizeOperation(
      operation: 'signPolicyTransaction',
      binding: reviewHash,
    );
    final raw = await _channel.invokeMethod<String>('signPolicyTransaction', {
      'request': jsonEncode(request),
      'reviewHash': reviewHash,
      'authorizationToken': token,
    });
    return (jsonDecode(raw!) as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> preparePskt(Map<String, Object?> request) async {
    final raw = await _channel
        .invokeMethod<String>('preparePskt', {'request': jsonEncode(request)});
    return (jsonDecode(raw!) as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> prepareKronTransfer(
      Map<String, Object?> request) async {
    final raw = await _channel.invokeMethod<String>(
        'prepareKronTransfer', {'request': jsonEncode(request)});
    return (jsonDecode(raw!) as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> signPskt(
      Map<String, Object?> request, String reviewHash) async {
    final token = await _authorizeOperation(
      operation: 'signPskt',
      binding: reviewHash,
    );
    final raw = await _channel.invokeMethod<String>('signPskt', {
      'request': jsonEncode(request),
      'reviewHash': reviewHash,
      'authorizationToken': token,
    });
    return (jsonDecode(raw!) as Map).cast<String, Object?>();
  }
}

class NativeWalletInfo {
  const NativeWalletInfo(
      {required this.id,
      required this.address,
      required this.name,
      required this.kind,
      required this.active,
      required this.addresses});
  factory NativeWalletInfo.fromJson(Map<String, Object?> json) =>
      NativeWalletInfo(
        id: json['id']!.toString(),
        address: json['address']!.toString(),
        name: json['name']?.toString() ?? 'Wallet',
        kind: json['kind']?.toString() ?? 'native',
        active: json['active'] == true,
        addresses: (json['addresses'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => NativeHdAddress.fromJson(
                  item.cast<String, Object?>(),
                ))
            .toList(),
      );
  final String id;
  final String address;
  final String name;
  final String kind;
  final bool active;
  final List<NativeHdAddress> addresses;
}

class NativeHdAddress {
  const NativeHdAddress({
    required this.address,
    required this.derivationPath,
    required this.coinType,
    required this.account,
    required this.change,
    required this.index,
    this.used = false,
    this.explicit = false,
  });

  factory NativeHdAddress.fromJson(Map<String, Object?> json) =>
      NativeHdAddress(
        address: json['address']!.toString(),
        derivationPath: json['derivationPath']!.toString(),
        coinType: (json['coinType'] as num).toInt(),
        account: (json['account'] as num?)?.toInt() ?? 0,
        change: (json['change'] as num).toInt(),
        index: (json['index'] as num).toInt(),
        used: json['used'] == true,
        explicit: json['explicit'] == true,
      );

  final String address;
  final String derivationPath;
  final int coinType;
  final int account;
  final int change;
  final int index;
  final bool used;
  final bool explicit;

  NativeHdAddress copyWith({bool? used, bool? explicit}) => NativeHdAddress(
        address: address,
        derivationPath: derivationPath,
        coinType: coinType,
        account: account,
        change: change,
        index: index,
        used: used ?? this.used,
        explicit: explicit ?? this.explicit,
      );

  Map<String, Object?> toJson() => {
        'address': address,
        'derivationPath': derivationPath,
        'coinType': coinType,
        'account': account,
        'change': change,
        'index': index,
        'used': used,
        'explicit': explicit,
      };
}
