import 'package:flutter/material.dart';

import '../services/preferences_service.dart';
import '../services/native_security.dart';
import '../services/kaspa_api.dart';
import '../services/hd_discovery_service.dart';
import '../theme.dart';
import '../widgets/kaspire_brand.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onConnected});
  final ValueChanged<String> onConnected;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _nativeWallet({required bool create}) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final security = NativeSecurity();
      final authenticated = await security.authenticate(
        context,
        create
            ? 'Create encrypted Kaspa wallet'
            : 'Import encrypted Kaspa wallet',
      );
      if (!authenticated) {
        throw StateError('Biometric authorization is required.');
      }
      var address = create
          ? await security.createWallet()
          : await security.importWallet();
      if (!create) {
        address = await HdDiscoveryService().discoverAndRegister(
          address,
          security,
        );
      }
      await PreferencesService().setAddress(address);
      widget.onConnected(address);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _importPrivateKey() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final security = NativeSecurity();
      final authenticated = await security.authenticate(
        context,
        'Import encrypted Kaspa private key',
      );
      if (!authenticated) {
        throw StateError('Device authorization is required.');
      }
      final address = await security.importPrivateKey();
      await PreferencesService().setAddress(address);
      widget.onConnected(address);
    } catch (error) {
      if (mounted) {
        setState(
            () => _error = error.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _continue() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final address = await KaspaApi().resolveWalletInput(_controller.text);
      await PreferencesService().addWatchWallet(address);
      await PreferencesService().setAddress(address);
      widget.onConnected(address);
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
          decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.8, -0.7),
            radius: 1.2,
            colors: [
              KasVaultTheme.mint.withValues(alpha: .2),
              KasVaultTheme.ink,
            ],
          ),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 36, 24, 24),
            children: [
              const Align(alignment: Alignment.centerLeft, child: _Mark()),
              const SizedBox(height: 56),
              const Text(
                'YOUR KASPA.\nYOUR CONTROL.',
                style: TextStyle(
                  fontSize: 42,
                  height: .98,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1.8,
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'A fast, private Android wallet built around a native security boundary.',
                style: TextStyle(
                  color: KasVaultTheme.muted,
                  fontSize: 17,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 42),
              FilledButton.icon(
                onPressed: _saving ? null : () => _nativeWallet(create: true),
                icon: const Icon(Icons.add_rounded),
                label: const Text('CREATE 24-WORD WALLET'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(58),
                  backgroundColor: KasVaultTheme.mint,
                  foregroundColor: KasVaultTheme.ink,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _saving ? null : () => _nativeWallet(create: false),
                icon: const Icon(Icons.key_rounded),
                label: const Text('IMPORT 12 / 24 WORDS'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(58),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _saving ? null : _importPrivateKey,
                icon: const Icon(Icons.password_rounded),
                label: const Text('IMPORT PRIVATE KEY'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(58),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 22),
                child: Row(
                  children: [
                    Expanded(child: Divider()),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        'OR WATCH ONLY',
                        style: TextStyle(
                          color: KasVaultTheme.muted,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Expanded(child: Divider()),
                  ],
                ),
              ),
              TextField(
                controller: _controller,
                autocorrect: false,
                enableSuggestions: false,
                minLines: 2,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: 'Watch a Kaspa address or KNS domain',
                  hintText: 'kaspa:q… or name.kas',
                  errorText: _error,
                ),
              ),
              const SizedBox(height: 14),
              FilledButton(
                onPressed: _saving ? null : _continue,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(58),
                  backgroundColor: KasVaultTheme.mint,
                  foregroundColor: KasVaultTheme.ink,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: Text(
                  _saving ? 'CONNECTING…' : 'OPEN WALLET',
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    letterSpacing: .8,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const _SecurityNotice(),
            ],
          ),
        ),
      ),
    );
  }
}

class _Mark extends StatelessWidget {
  const _Mark();
  @override
  Widget build(BuildContext context) => const KaspireWordmark(height: 34);
}

class _SecurityNotice extends StatelessWidget {
  const _SecurityNotice();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: KasVaultTheme.panel,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: KasVaultTheme.line),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.shield_outlined, color: KasVaultTheme.mint, size: 21),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Recovery words stay in the native Rust/Android security boundary and are encrypted with Android Keystore.',
                style: TextStyle(color: KasVaultTheme.muted, height: 1.35),
              ),
            ),
          ],
        ),
      );
}
