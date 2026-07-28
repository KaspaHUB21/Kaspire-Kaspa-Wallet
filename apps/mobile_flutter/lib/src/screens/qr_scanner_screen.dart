import 'package:flutter/material.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';

import '../models/kaspa_payment_request.dart';
import '../theme.dart';

class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  final _scannerKey = GlobalKey(debugLabel: 'kaspire-qr-scanner');
  bool _handled = false;
  bool _torchOn = false;
  String? _error;
  QRViewController? _controller;

  void _onScannerCreated(QRViewController controller) {
    _controller = controller;
    controller.scannedDataStream.listen((barcode) {
      if (_handled || !mounted) return;
      final value = barcode.code;
      if (value != null && KaspaPaymentRequest.tryParse(value) != null) {
        _handled = true;
        controller.pauseCamera();
        Navigator.pop(context, value);
        return;
      }
      setState(() => _error = 'This is not a Kaspa payment QR code.');
    });
  }

  Future<void> _toggleTorch() async {
    await _controller?.toggleFlash();
    if (mounted) setState(() => _torchOn = !_torchOn);
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Scan Kaspa payment')),
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
                width: 250,
                height: 250,
                decoration: BoxDecoration(
                  border: Border.all(color: KasVaultTheme.mint, width: 3),
                  borderRadius: BorderRadius.circular(28),
                ),
              ),
            ),
            Align(
              alignment: const Alignment(0, .62),
              child: SafeArea(
                child: FilledButton.tonalIcon(
                  onPressed: _toggleTorch,
                  icon: Icon(
                    _torchOn ? Icons.flashlight_off : Icons.flashlight_on,
                  ),
                  label: Text(_torchOn ? 'TURN OFF LIGHT' : 'TURN ON LIGHT'),
                ),
              ),
            ),
            if (_error != null)
              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  child: Container(
                    margin: const EdgeInsets.all(20),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: KasVaultTheme.panel,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(_error!),
                  ),
                ),
              ),
          ],
        ),
      );
}
