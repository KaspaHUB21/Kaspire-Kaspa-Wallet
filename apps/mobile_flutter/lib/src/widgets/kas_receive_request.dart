import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../models/kaspa_payment_request.dart';
import '../theme.dart';
import 'hub21_material.dart';

/// Shared by ordinary and P2SH Receive. Only the address source differs.
class KasReceiveRequest extends StatefulWidget {
  const KasReceiveRequest({super.key, required this.address});
  final String address;

  @override
  State<KasReceiveRequest> createState() => _KasReceiveRequestState();
}

class _KasReceiveRequestState extends State<KasReceiveRequest> {
  final _amount = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final uri =
        KaspaPaymentRequest.encode(widget.address, amount: _amount.text);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LayoutBuilder(builder: (context, constraints) {
        final size = math.min(238.0, math.max(1.0, constraints.maxWidth - 36));
        return Center(
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(28),
              boxShadow: [
                BoxShadow(
                    color: KasVaultTheme.mint.withValues(alpha: .33),
                    blurRadius: 40),
              ],
            ),
            child: QrImageView(
              data: uri,
              size: size,
              eyeStyle: QrEyeStyle(
                  eyeShape: QrEyeShape.square, color: KasVaultTheme.qrInk),
              dataModuleStyle: QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: KasVaultTheme.qrInk),
            ),
          ),
        );
      }),
      const SizedBox(height: 30),
      TextField(
        controller: _amount,
        onChanged: (_) => setState(() {}),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(
            labelText: 'Requested amount (optional)',
            suffixText: 'KAS',
            hintText: '0.00'),
      ),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(17),
        decoration: KasVaultTheme.isDecorative
            ? kaspireDecorativeDecoration(radius: 18, rim: 2.5)
            : BoxDecoration(
                color: KasVaultTheme.panel,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: KasVaultTheme.line)),
        child: SelectableText(widget.address,
            textAlign: TextAlign.center,
            textWidthBasis: TextWidthBasis.longestLine,
            style: TextStyle(
                fontFamily: 'monospace',
                color: KasVaultTheme.mint,
                fontSize: 13,
                height: 1.45)),
      ),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: uri));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Payment request copied')));
            },
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copy'),
            style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(54)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton.icon(
            onPressed: () => Share.share(uri, subject: 'Kaspa payment request'),
            icon: const Icon(Icons.ios_share_rounded),
            label: const Text('Share'),
            style:
                FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
          ),
        ),
      ]),
    ]);
  }
}
