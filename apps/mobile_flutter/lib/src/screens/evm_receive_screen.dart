import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../services/app_settings.dart';
import '../services/evm_api.dart';
import '../services/native_security.dart';
import '../theme.dart';

class EvmReceiveScreen extends StatelessWidget {
  const EvmReceiveScreen({super.key});
  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
        future: NativeSecurity().getEvmAddress(),
        builder: (context, address) {
          if (!address.hasData) {
            return Center(
                child: address.hasError
                    ? Text('${address.error}')
                    : const CircularProgressIndicator());
          }
          final value = address.data!;
          return SafeArea(
              child: ListView(padding: const EdgeInsets.all(20), children: [
            const SizedBox(height: 8),
            Text(
                displayLabel(
                    'RECEIVE ${EvmNetworkConfig.current.nativeSymbol}'),
                style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -.8)),
            const SizedBox(height: 8),
            Text(
                'Share this address only for L2 payments and assets.',
                style: const TextStyle(color: KasVaultTheme.muted)),
            const SizedBox(height: 34),
            Center(
                child: Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(28),
                        boxShadow: [
                          BoxShadow(
                              color: KasVaultTheme.mint.withValues(alpha: .33),
                              blurRadius: 40)
                        ]),
                    child: QrImageView(
                        data: value,
                        size: 238,
                        eyeStyle: QrEyeStyle(
                            eyeShape: QrEyeShape.square,
                            color: KasVaultTheme.ink),
                        dataModuleStyle: QrDataModuleStyle(
                            dataModuleShape: QrDataModuleShape.square,
                            color: KasVaultTheme.ink)))),
            const SizedBox(height: 30),
            Container(
                padding: const EdgeInsets.all(17),
                decoration: BoxDecoration(
                    color: KasVaultTheme.panel,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: KasVaultTheme.line)),
                child: Text(value,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontFamily: 'monospace',
                        color: KasVaultTheme.mint,
                        height: 1.45))),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                  child: OutlinedButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: value));
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Address copied')));
                      },
                      icon: const Icon(Icons.copy_rounded),
                      label: Text(buttonLabel('COPY')))),
              const SizedBox(width: 12),
              Expanded(
                  child: FilledButton.icon(
                      onPressed: () => Share.share(value,
                          subject: '${EvmNetworkConfig.current.name} address'),
                      icon: const Icon(Icons.ios_share_rounded),
                      label: Text(buttonLabel('SHARE')))),
            ]),
            const SizedBox(height: 20),
            const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.info_outline, size: 18, color: KasVaultTheme.muted),
              SizedBox(width: 9),
              Expanded(
                  child: Text(
                      'Only send assets from the selected EVM network to this 0x address. Always verify the first and last characters.',
                      style: TextStyle(
                          color: KasVaultTheme.muted,
                          height: 1.4,
                          fontSize: 12))),
            ]),
          ]));
        },
      );
}
