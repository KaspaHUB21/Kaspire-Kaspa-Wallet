import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';

import '../services/dapp_session_service.dart';
import '../theme.dart';

class DappQrScannerScreen extends StatefulWidget {
  const DappQrScannerScreen({super.key});

  @override
  State<DappQrScannerScreen> createState() => _DappQrScannerScreenState();
}

class _DappQrScannerScreenState extends State<DappQrScannerScreen> {
  final _scannerKey = GlobalKey(debugLabel: 'kaspire-dapp-qr-scanner');
  StreamSubscription<Barcode>? _subscription;
  bool _handled = false;
  bool _torchOn = false;
  String? _error;
  QRViewController? _controller;

  void _onScannerCreated(QRViewController controller) {
    _controller = controller;
    _subscription = controller.scannedDataStream.listen((barcode) {
      if (_handled || !mounted) return;
      final value = barcode.code;
      if (value == null) return;
      try {
        DappSessionService.pairingUriFromQrPayload(value);
        _handled = true;
        unawaited(controller.pauseCamera());
        Navigator.pop(context, value);
      } on FormatException catch (error) {
        setState(() => _error = error.message);
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _toggleTorch() async {
    await _controller?.toggleFlash();
    if (mounted) setState(() => _torchOn = !_torchOn);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Scan dApp QR code')),
        body: Stack(
          fit: StackFit.expand,
          children: [
            QRView(
              key: _scannerKey,
              onQRViewCreated: _onScannerCreated,
              formatsAllowed: const [BarcodeFormat.qrcode],
            ),
            Center(
              child: Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  border: Border.all(color: KasVaultTheme.mint, width: 3),
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
            ),
            Align(
              alignment: const Alignment(0, .58),
              child: FilledButton.tonalIcon(
                onPressed: _toggleTorch,
                icon: Icon(
                  _torchOn ? Icons.flashlight_off : Icons.flashlight_on,
                ),
                label: Text(_torchOn ? 'TURN OFF LIGHT' : 'TURN ON LIGHT'),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                child: Container(
                  width: double.infinity,
                  margin: const EdgeInsets.all(20),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: KasVaultTheme.panel.withValues(alpha: 0.96),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: KasVaultTheme.line),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Scan the WalletConnect QR code shown by the dApp.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _error ??
                            'Kaspire accepts WalletConnect v2 and verified Kaspire pairing links.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _error == null
                              ? KasVaultTheme.muted
                              : const Color(0xFFFFB65C),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}
