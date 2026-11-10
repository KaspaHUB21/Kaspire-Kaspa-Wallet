import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';

import '../models/kaspa_payment_request.dart';
import '../models/evm_address.dart';
import '../theme.dart';
import '../services/app_settings.dart';
import '../platform.dart';
import '../widgets/desktop_qr_input.dart';

class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key}) : evmNetworkName = null;

  const QrScannerScreen.evm({super.key, required String networkName})
      : evmNetworkName = networkName;

  final String? evmNetworkName;

  bool _accepts(String value) => evmNetworkName != null
      ? EvmAddress.tryParse(value) != null
      : KaspaPaymentRequest.tryParse(value) != null;

  String get _title =>
      evmNetworkName == null ? 'Kaspa payment' : '$evmNetworkName address';

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  final _scannerKey = GlobalKey(debugLabel: 'kaspire-qr-scanner');
  bool _handled = false;
  bool _torchOn = false;
  String? _error;
  QRViewController? _controller;
  StreamSubscription<Barcode>? _scans;

  void _onScannerCreated(QRViewController controller) {
    _controller = controller;
    _scans?.cancel();
    _scans = controller.scannedDataStream.listen((barcode) {
      if (_handled || !mounted) return;
      final value = barcode.code;
      if (value != null && widget._accepts(value)) {
        _handled = true;
        controller.pauseCamera();
        Navigator.pop(context, value);
        return;
      }
      setState(() => _error = widget.evmNetworkName == null
          ? 'This is not a Kaspa payment QR code.'
          : 'Scan a ${widget.evmNetworkName} 0x address QR code.');
    });
  }

  Future<void> _toggleTorch() async {
    await _controller?.toggleFlash();
    if (mounted) setState(() => _torchOn = !_torchOn);
  }

  @override
  void dispose() {
    _scans?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => isWindowsDesktop
      ? DesktopQrInput(title: widget._title, validate: widget._accepts)
      : Scaffold(
          appBar: AppBar(title: Text('Scan ${widget._title}')),
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
                    label: Text(buttonLabel(
                      _torchOn ? 'TURN OFF LIGHT' : 'TURN ON LIGHT',
                    )),
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
