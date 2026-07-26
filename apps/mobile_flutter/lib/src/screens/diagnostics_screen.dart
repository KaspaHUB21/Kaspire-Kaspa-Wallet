import 'package:flutter/material.dart';

import '../models/network_diagnostics.dart';
import '../services/dapp_session_service.dart';
import '../services/kaspa_api.dart';
import '../services/network_settings.dart';
import '../theme.dart';

class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key, required this.address});

  final String address;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  late Future<List<DiagnosticCheck>> _checks;

  @override
  void initState() {
    super.initState();
    _checks = KaspaApi().runDiagnostics(widget.address);
  }

  void _retry() =>
      setState(() => _checks = KaspaApi().runDiagnostics(widget.address));

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Network diagnostics')),
        body: FutureBuilder<List<DiagnosticCheck>>(
          future: _checks,
          builder: (context, snapshot) => ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                'Checks the configured Kaspa node gateway, token indexers and '
                'encrypted WalletConnect relay. No secret or private key is sent.',
                style: const TextStyle(color: KasVaultTheme.muted),
              ),
              const SizedBox(height: 14),
              SelectableText(
                'Kaspa endpoint\n${NetworkSettings.kaspaRestUrl}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              const SizedBox(height: 20),
              if (snapshot.connectionState == ConnectionState.waiting)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: CircularProgressIndicator(),
                  ),
                ),
              if (snapshot.hasError)
                _DiagnosticCard(
                  check: DiagnosticCheck(
                    name: 'Diagnostics',
                    endpoint: '',
                    ok: false,
                    detail: '${snapshot.error}',
                    elapsedMs: 0,
                  ),
                ),
              ...?snapshot.data?.map((check) => _DiagnosticCard(check: check)),
              _DiagnosticCard(
                check: DiagnosticCheck(
                  name: 'WalletConnect',
                  endpoint: 'Reown encrypted relay',
                  ok: DappSessionService.instance.ready,
                  detail: DappSessionService.instance.ready
                      ? 'WalletKit initialized and ready'
                      : DappSessionService.instance.lastError ??
                          'WalletKit is still initializing',
                  elapsedMs: 0,
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _retry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('RUN AGAIN'),
              ),
            ],
          ),
        ),
      );
}

class _DiagnosticCard extends StatelessWidget {
  const _DiagnosticCard({required this.check});

  final DiagnosticCheck check;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: KasVaultTheme.panel,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: check.ok ? const Color(0x5549EACB) : const Color(0x66FF8A65),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              check.ok ? Icons.check_circle_rounded : Icons.error_rounded,
              color: check.ok ? KasVaultTheme.mint : const Color(0xFFFF8A65),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(check.name,
                      style: const TextStyle(fontWeight: FontWeight.w900)),
                  if (check.endpoint.isNotEmpty)
                    Text(
                      check.endpoint,
                      style: const TextStyle(
                        color: KasVaultTheme.muted,
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  const SizedBox(height: 5),
                  Text(check.detail),
                  if (check.elapsedMs > 0)
                    Text(
                      '${check.elapsedMs} ms',
                      style: const TextStyle(
                          color: KasVaultTheme.muted, fontSize: 11),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
}
