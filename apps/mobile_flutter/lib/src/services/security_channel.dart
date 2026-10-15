import 'dart:convert';
import 'package:flutter/services.dart';
import '../platform.dart';

/// Only public arguments/results cross Flutter's desktop channel. The Windows
/// host collects secrets in embedded native fields inside themed Flutter
/// dialogs. Secret contents/keystrokes never cross this public channel.
class SecurityChannel {
  const SecurityChannel();
  static const _android = MethodChannel('space.kasvault/security');
  static const _windows = MethodChannel('space.kaspire/security-windows');

  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    if (!isWindowsDesktop) return _android.invokeMethod<T>(method, arguments);
    final raw = await _windows.invokeMethod<String>('call', {
      'payload': jsonEncode({'method': method, 'arguments': arguments ?? {}}),
      'lock': method == 'lockWindowsSession' ||
          (method == 'setInternalNexusUnlocked' &&
              arguments is Map &&
              arguments['enabled'] == false),
      'forgetPin': method == 'lockWindowsSession',
    });
    if (raw == null) {
      throw StateError('The Windows security core did not respond.');
    }
    final envelope = jsonDecode(raw) as Map;
    if (envelope['error'] != null) {
      throw PlatformException(
          code: 'SECURITY_ERROR', message: envelope['error'].toString());
    }
    return envelope['result'] as T?;
  }
}
