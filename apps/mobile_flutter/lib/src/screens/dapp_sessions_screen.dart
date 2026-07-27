import 'dart:async';

import 'package:flutter/material.dart';

import '../services/dapp_session_service.dart';
import '../theme.dart';
import 'dapp_qr_scanner_screen.dart';

class DappSessionsScreen extends StatefulWidget {
  const DappSessionsScreen({super.key});

  @override
  State<DappSessionsScreen> createState() => _DappSessionsScreenState();
}

class _DappSessionsScreenState extends State<DappSessionsScreen> {
  final _service = DappSessionService.instance;
  final _pairing = TextEditingController();
  StreamSubscription<void>? _changes;
  bool _working = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _changes = _service.changes.listen((_) {
      if (mounted) setState(() {});
    });
    _service.initialize();
  }

  @override
  void dispose() {
    _changes?.cancel();
    _pairing.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    final value = _pairing.text.trim();
    _pairing.clear();
    if (value.isEmpty) return;
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      await _service.pair(value);
      if (mounted) {
        setState(() => _message = 'Encrypted pairing started…');
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = error
              .toString()
              .replaceFirst('FormatException: ', '')
              .replaceFirst('Bad state: ', '');
        });
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _scan() async {
    final payload = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const DappQrScannerScreen()),
    );
    if (payload == null || !mounted) return;
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      await _service.pairQrPayload(payload);
      if (mounted) {
        setState(() => _message = 'Encrypted pairing started…');
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = error
              .toString()
              .replaceFirst('FormatException: ', '')
              .replaceFirst('Bad state: ', '');
        });
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _disconnect(String topic, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Disconnect $name?'),
        content: const Text(
          'The dApp will lose access to the approved account and must pair again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('DISCONNECT'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _service.disconnect(topic);
  }

  @override
  Widget build(BuildContext context) {
    final sessions = _service.activeSessions().entries.toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Pair dApps')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: KasVaultTheme.panel,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: KasVaultTheme.line),
            ),
            child: Row(
              children: [
                Icon(
                  _service.ready ? Icons.link_rounded : Icons.cloud_off_rounded,
                  color: _service.ready
                      ? KasVaultTheme.mint
                      : const Color(0xFFFFB65C),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _service.ready
                            ? 'WalletConnect relay active'
                            : 'WalletConnect relay unavailable',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _service.lastError ??
                            'Kaspa Mainnet · encrypted Reown WalletKit session',
                        style: const TextStyle(
                          color: KasVaultTheme.muted,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF0D312F), Color(0xFF102126)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: KasVaultTheme.mint),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(
                  Icons.qr_code_scanner_rounded,
                  size: 46,
                  color: KasVaultTheme.mint,
                ),
                const SizedBox(height: 14),
                const Text(
                  'Connect to a dApp',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 23, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 7),
                const Text(
                  'Open the connection QR code on a desktop or another device, then scan it securely inside Kaspire.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: KasVaultTheme.muted, height: 1.4),
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: _working || !_service.ready ? null : _scan,
                  icon: const Icon(Icons.center_focus_strong_rounded),
                  label: const Text('SCAN DAPP QR CODE'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 26),
          const Text(
            'PAIR MANUALLY',
            style: TextStyle(
              color: KasVaultTheme.muted,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _pairing,
            autocorrect: false,
            enableSuggestions: false,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Paste WalletConnect v2 URI',
              hintText: 'wc:…@2?relay-protocol=irn&symKey=…',
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _working ? null : _pair,
            icon: _working
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_link_rounded),
            label: const Text('PAIR SECURELY'),
          ),
          if (_message != null) ...[
            const SizedBox(height: 10),
            Text(
              _message!,
              style: const TextStyle(color: KasVaultTheme.muted),
            ),
          ],
          const SizedBox(height: 28),
          const Text(
            'ACTIVE SESSIONS',
            style: TextStyle(
              color: KasVaultTheme.muted,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          if (sessions.isEmpty)
            const Text(
              'No dApps connected.',
              style: TextStyle(color: KasVaultTheme.muted),
            ),
          ...sessions.map((entry) {
            final session = entry.value;
            final methods = session.namespaces['kaspa']?.methods ?? const [];
            return Card(
              color: KasVaultTheme.panel,
              child: ListTile(
                leading: const Icon(
                  Icons.language_rounded,
                  color: KasVaultTheme.cyan,
                ),
                title: Text(
                  session.peer.metadata.name,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                subtitle: Text(
                  '${session.peer.metadata.url}\n${methods.join(' · ')}',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                isThreeLine: true,
                trailing: IconButton(
                  tooltip: 'Disconnect',
                  onPressed: () => _disconnect(
                    entry.key,
                    session.peer.metadata.name,
                  ),
                  icon: const Icon(Icons.link_off_rounded),
                ),
              ),
            );
          }),
          const SizedBox(height: 24),
          const Text(
            'Pairing does not authorize transactions. You approve the dApp, account permissions, and every later signing request separately. Reown domain verification provides anti-phishing context but does not guarantee that a dApp is safe.',
            style: TextStyle(color: KasVaultTheme.muted, height: 1.45),
          ),
        ],
      ),
    );
  }
}
