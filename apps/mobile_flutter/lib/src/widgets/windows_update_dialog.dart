import 'dart:io';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/update_service.dart';

Future<void> showWindowsUpdate(BuildContext context, KaspireUpdate update) =>
    showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => WindowsUpdateDialog(update: update));

class WindowsUpdateDialog extends StatefulWidget {
  const WindowsUpdateDialog({super.key, required this.update});
  final KaspireUpdate update;
  @override
  State<WindowsUpdateDialog> createState() => _WindowsUpdateDialogState();
}

class _WindowsUpdateDialogState extends State<WindowsUpdateDialog> {
  bool busy = false;
  double? progress;
  String? error;
  Future<void> install() async {
    setState(() {
      busy = true;
      error = null;
      progress = 0;
    });
    try {
      await UpdateService.instance.installWindows(widget.update, (value) {
        if (mounted) setState(() => progress = value);
      });
      // The verified per-user installer now owns the upgrade. Close the old
      // process so its EXE/DLLs can be replaced; user data is outside that folder.
      exit(0);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = e.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !busy,
      child: AlertDialog(
        icon: const Icon(Icons.system_update_alt_rounded),
        title: Text('Kaspire ${widget.update.version} available'),
        content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('Windows x64 · Build ${widget.update.build}'),
                  const SizedBox(height: 12),
                  const Text(
                      'Download the official GitHub release and install it directly. Kaspire verifies the signed release manifest and the complete installer before starting it. The application closes during installation and reopens afterward. Your wallets, PIN and vault records are kept.'),
                  if (busy) ...[
                    const SizedBox(height: 18),
                    LinearProgressIndicator(value: progress),
                    const SizedBox(height: 8),
                    Text(progress == null
                        ? 'Verifying installer…'
                        : 'Downloading… ${(progress! * 100).round()}%')
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error))
                  ],
                ]))),
        actions: [
          TextButton(
              onPressed: busy
                  ? null
                  : () => launchUrl(widget.update.releaseNotesUrl,
                      mode: LaunchMode.externalApplication),
              child: const Text('View changes')),
          TextButton(
              onPressed: busy
                  ? null
                  : () {
                      UpdateService.instance.remindLater(widget.update);
                      Navigator.pop(context);
                    },
              child: const Text('Later')),
          FilledButton.icon(
              onPressed: busy ? null : install,
              icon: const Icon(Icons.download_rounded),
              label: const Text('Download & install')),
        ],
      ));
}
