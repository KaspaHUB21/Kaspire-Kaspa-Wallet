import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform.dart';
import '../services/app_settings.dart';

/// Public UI only. Authentication and secret input remain in the native host.
String? authenticationErrorMessage(Object error) {
  final message = error is PlatformException ? error.message ?? '' : '$error';
  final lower = message.toLowerCase();
  if (lower.startsWith('cancelled') || lower.startsWith('canceled')) {
    return null;
  }
  if (lower.contains('too many incorrect')) {
    return 'Too many incorrect attempts. Please wait one minute before trying again.';
  }
  if (lower.contains('incorrect') &&
      (lower.contains('pin') || lower.contains('password'))) {
    return isWindowsDesktop
        ? 'Incorrect password. Please try again. Passwords are case-sensitive.'
        : 'Incorrect PIN. Please try again.';
  }
  if (lower.contains('passwords do not match')) {
    return 'Passwords do not match. Please try again.';
  }
  if (lower.contains('6–128')) {
    return 'Use a password with 6–128 characters.';
  }
  return 'Could not authenticate. Please try again. Your wallet remains locked.';
}

class WalletUnlockScreen extends StatefulWidget {
  const WalletUnlockScreen(
      {super.key,
      required this.authenticate,
      required this.activateSession,
      required this.onUnlocked});
  final Future<bool> Function() authenticate;
  final Future<void> Function() activateSession;
  final VoidCallback onUnlocked;

  @override
  State<WalletUnlockScreen> createState() => _WalletUnlockScreenState();
}

class _WalletUnlockScreenState extends State<WalletUnlockScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!await widget.authenticate() || !mounted) return;
      await widget.activateSession();
      if (mounted) widget.onUnlocked();
    } catch (error) {
      if (mounted) setState(() => _error = authenticationErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      body: SafeArea(
          child: Center(
              child: SingleChildScrollView(
                  padding: const EdgeInsets.all(32),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.lock_rounded, size: 58),
                    const SizedBox(height: 18),
                    const Text('Kaspire is locked',
                        style: TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 8),
                    const Text('Authenticate to restore your wallet session.',
                        textAlign: TextAlign.center),
                    if (_error != null)
                      Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Semantics(
                              liveRegion: true,
                              child: Text(_error!,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error)))),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                        onPressed: _busy ? null : _unlock,
                        icon: _busy
                            ? const SizedBox.square(
                                dimension: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : Icon(isWindowsDesktop
                                ? Icons.password_rounded
                                : Icons.fingerprint_rounded),
                        label: Text(buttonLabel('UNLOCK KASPIRE'))),
                  ])))));
}
