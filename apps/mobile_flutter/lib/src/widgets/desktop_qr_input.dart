import 'package:flutter/material.dart';

/// A desktop has no Android camera surface. Preserve the payment/pairing parser
/// and allow pasting the exact QR payload using normal Windows clipboard keys.
class DesktopQrInput extends StatefulWidget {
  const DesktopQrInput(
      {super.key, required this.title, required this.validate});
  final String title;
  final bool Function(String) validate;
  @override
  State<DesktopQrInput> createState() => _DesktopQrInputState();
}

class _DesktopQrInputState extends State<DesktopQrInput> {
  final controller = TextEditingController();
  String? error;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: Center(
            child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                      'Paste the payment or WalletConnect link from the QR code. Use Ctrl+V.'),
                  const SizedBox(height: 16),
                  TextField(
                      controller: controller,
                      minLines: 3,
                      maxLines: 8,
                      decoration: InputDecoration(
                          labelText: 'QR code contents', errorText: error)),
                  const SizedBox(height: 16),
                  FilledButton(
                      onPressed: () {
                        final value = controller.text.trim();
                        if (widget.validate(value)) {
                          Navigator.pop(context, value);
                        } else {
                          setState(
                              () => error = 'This is not a supported link.');
                        }
                      },
                      child: const Text('Continue')),
                ],
              )),
        )),
      );
}
