import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/screens/qr_scanner_screen.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';

class _Camera extends Fake implements QRViewController {
  final scans = StreamController<Barcode>.broadcast();
  int pauses = 0;
  @override
  Stream<Barcode> get scannedDataStream => scans.stream;
  @override
  Future<void> pauseCamera() async => pauses++;
}

void main() {
  const evm = '0x17Ec7E1768c813E2a3a9b0f94A35605CA520C242';
  const kaspa =
      'kaspa:qz03mracsz6c0pjxmsdaql39453tn3jgmrldkqpy24ea39rxtvd9xxynslpyc';

  for (final network in [null, 'Igra Network', 'Kasplex zkEVM Mainnet']) {
    testWidgets('${network ?? 'L1'} scanner validates actual camera events',
        (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform_views, (_) async => null);
      final camera = _Camera();
      addTearDown(camera.scans.close);
      String? result;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
        return TextButton(
            onPressed: () async {
              result = await Navigator.of(context).push<String>(
                  MaterialPageRoute(
                      builder: (_) => network == null
                          ? const QrScannerScreen()
                          : QrScannerScreen.evm(networkName: network)));
            },
            child: const Text('Open scanner'));
      })));
      await tester.tap(find.text('Open scanner'));
      await tester.pumpAndSettle();
      tester.widget<QRView>(find.byType(QRView)).onQRViewCreated(camera);
      camera.scans.add(
          Barcode(network == null ? evm : kaspa, BarcodeFormat.qrcode, null));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(
          find.text(network == null
              ? 'This is not a Kaspa payment QR code.'
              : 'Scan a $network 0x address QR code.'),
          findsOneWidget);
      final accepted = network == null ? kaspa : evm;
      camera.scans.add(Barcode(accepted, BarcodeFormat.qrcode, null));
      camera.scans.add(Barcode(accepted, BarcodeFormat.qrcode, null));
      await tester.pumpAndSettle();
      expect(result, accepted);
      expect(camera.pauses, 1);
      expect(camera.scans.hasListener, isFalse);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}
