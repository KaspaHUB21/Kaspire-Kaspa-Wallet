import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

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
                  label: const Text('USE BIOMETRICS'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.pin_rounded),
                  label: const Text('USE KASPIRE PIN'),
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
      return await _auth.authenticate(
        localizedReason: reason,
        options: AuthenticationOptions(
          biometricOnly: pinAvailable && biometricsAvailable,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
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

  Future<void> initializeVault() =>
      _channel.invokeMethod<void>('initializeVault');

  Future<bool> hasNativeWallet() async =>
      await _channel.invokeMethod<bool>('hasNativeWallet') ?? false;

  Future<bool> hasNativeWalletFor(String address) async =>
      await _channel
          .invokeMethod<bool>('hasNativeWallet', {'address': address}) ??
      false;

  Future<String?> getNativeAddress() =>
      _channel.invokeMethod<String>('getNativeAddress');

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

  Future<void> exportPrivateKey() =>
      _channel.invokeMethod<void>('exportPrivateKey');

  Future<void> exportRecoveryPhrase() =>
      _channel.invokeMethod<void>('exportRecoveryPhrase');

  Future<void> exportEncryptedBackup() =>
      _channel.invokeMethod<void>('exportEncryptedBackup');

  Future<String?> restoreEncryptedBackup() =>
      _channel.invokeMethod<String>('restoreEncryptedBackup');

  Future<void> deleteWallet() => _channel.invokeMethod<void>('deleteWallet');

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

  Future<void> deleteWalletById(String walletId) =>
      _channel.invokeMethod<void>('deleteWallet', {'walletId': walletId});

  Future<bool> hasPin() async =>
      await _channel.invokeMethod<bool>('hasPin') ?? false;

  Future<bool> configurePin() async =>
      await _channel.invokeMethod<bool>('configurePin') ?? false;

  Future<void> removePin() => _channel.invokeMethod<void>('removePin');

  Future<String> signPersonalMessage(String address, String message) async {
    final raw = await _channel.invokeMethod<String>('signPersonalMessage', {
      'address': address,
      'message': message,
    });
    final result = (jsonDecode(raw!) as Map).cast<String, Object?>();
    return result['signature']! as String;
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
    final raw = await _channel.invokeMethod<String>('signTransaction', {
      'request': jsonEncode(request),
      'reviewHash': reviewHash,
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
    final raw = await _channel.invokeMethod<String>('signKcc20Transfer', {
      'request': jsonEncode(request),
      'reviewHash': reviewHash,
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
    final raw = await _channel.invokeMethod<String>('signReveal', {
      'request': jsonEncode(request),
      'reviewHash': reviewHash,
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
