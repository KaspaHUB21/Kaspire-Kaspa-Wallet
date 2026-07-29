import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../theme.dart';
import '../services/app_settings.dart';
import '../models/kaspa_payment_request.dart';

class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key, required this.address});
  final String address;

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  final _amount = TextEditingController();

  String get paymentUri => KaspaPaymentRequest.encode(
        widget.address,
        amount: _amount.text,
      );

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const SizedBox(height: 8),
            const Text(
              'RECEIVE KAS',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w900,
                letterSpacing: -.8,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Share this address for Kaspa mainnet payments.',
              style: TextStyle(color: KasVaultTheme.muted),
            ),
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
                      blurRadius: 40,
                    ),
                  ],
                ),
                child: QrImageView(
                  data: paymentUri,
                  size: 238,
                  eyeStyle: QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: KasVaultTheme.ink,
                  ),
                  dataModuleStyle: QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: KasVaultTheme.ink,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 30),
            TextField(
              controller: _amount,
              onChanged: (_) => setState(() {}),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Requested amount (optional)',
                suffixText: 'KAS',
                hintText: '0.00',
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(17),
              decoration: BoxDecoration(
                color: KasVaultTheme.panel,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: KasVaultTheme.line),
              ),
              child: Text(
                widget.address,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: KasVaultTheme.mint,
                  height: 1.45,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: paymentUri));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Payment request copied')),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded),
                    label: Text(buttonLabel('COPY')),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(54),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => Share.share(
                      paymentUri,
                      subject: 'Kaspa payment request',
                    ),
                    icon: const Icon(Icons.ios_share_rounded),
                    label: Text(buttonLabel('SHARE')),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(54),
                      backgroundColor: KasVaultTheme.mint,
                      foregroundColor: KasVaultTheme.ink,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 18, color: KasVaultTheme.muted),
                SizedBox(width: 9),
                Expanded(
                  child: Text(
                    'Only send Kaspa mainnet assets to this address. Always verify the first and last characters.',
                    style: TextStyle(
                      color: KasVaultTheme.muted,
                      height: 1.4,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
}
