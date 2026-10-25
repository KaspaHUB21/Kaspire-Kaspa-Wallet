import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/update_service.dart';

Future<void> showAndroidUpdate(BuildContext context, KaspireUpdate update) =>
    showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AndroidUpdateDialog(update: update));

class AndroidUpdateDialog extends StatefulWidget {
  const AndroidUpdateDialog(
      {super.key, required this.update, this.service, this.openWebsite});
  final KaspireUpdate update;
  final UpdateService? service;
  final Future<bool> Function(Uri)? openWebsite;
  @override
  State<AndroidUpdateDialog> createState() => _AndroidUpdateDialogState();
}

class _AndroidUpdateDialogState extends State<AndroidUpdateDialog> {
  UpdateService get service => widget.service ?? UpdateService.instance;
  String stage = 'choose';
  String? token, error;
  double? progress;
  bool stopped = false;
  bool cancelRequested = false;
  bool get busy => {'downloading', 'verifying', 'installing'}.contains(stage);

  String readable(Object value) => value is PlatformException
      ? value.message ?? 'The update could not continue. Please retry.'
      : value.toString().replaceFirst('Bad state: ', '');

  Future<void> website() async {
    setState(() {
      error = null;
    });
    try {
      final opened = await (widget.openWebsite?.call(widget.update.apkUrl) ??
          launchUrl(widget.update.apkUrl,
              mode: LaunchMode.externalApplication));
      if (!opened) {
        throw StateError('Could not open the official download. Please retry.');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = readable(e);
        });
      }
    }
  }

  Future<void> internal() async {
    setState(() {
      stage = 'downloading';
      error = null;
      progress = null;
    });
    stopped = false;
    try {
      final start = await service.startAndroidUpdate(widget.update);
      token = start['token'] as String;
      if (!mounted || stopped) {
        if (cancelRequested) await service.cancelAndroidUpdate(token!);
        return;
      }
      while (mounted && !stopped) {
        final state = await service.androidUpdateStatus(token!);
        if (!mounted || stopped) return;
        final next = state['stage'] as String;
        if (next == 'failed' || next == 'cancelled') {
          throw StateError(state['error']?.toString() ??
              'Update unavailable. Retry or use the website.');
        }
        if (next == 'ready' ||
            next == 'permission-required' ||
            next == 'installer-opened') {
          await install();
          return;
        }
        final total = (state['totalBytes'] as num?)?.toDouble() ?? 0;
        final received = (state['receivedBytes'] as num?)?.toDouble() ?? 0;
        setState(() {
          stage = next;
          progress = total > 0 ? (received / total).clamp(0, 1) : null;
        });
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    } catch (e) {
      if (mounted && !stopped) {
        setState(() {
          stage = 'failed';
          error = readable(e);
        });
      }
    }
  }

  Future<void> install() async {
    setState(() {
      stage = 'installing';
      error = null;
      progress = null;
    });
    try {
      final result = await service.installAndroidUpdate(token!);
      if (mounted && !stopped) {
        setState(() {
          stage = result;
        });
      }
    } catch (e) {
      if (mounted && !stopped) {
        setState(() {
          stage = 'failed';
          error = readable(e);
        });
      }
    }
  }

  Future<void> close() async {
    cancelRequested = true;
    stopped = true;
    if (token != null && stage != 'installer-opened') {
      try {
        await service.cancelAndroidUpdate(token!);
      } catch (_) {}
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    stopped = true;
    // Auto-lock can dispose this view during Android's permission screen.
    // Keep the public APK/session for reopening; only explicit Cancel/Close
    // abandons it. Native downloads have a size and time bound.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !busy,
      child: AlertDialog(
        icon: const Icon(Icons.system_update_alt_rounded),
        title: Text('Update Kaspire ${widget.update.version}'),
        content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                  const Text('How would you like to update?'),
                  const SizedBox(height: 12),
                  const Text(
                      'Both options use the same official APK and signed release information. Your wallets and settings are kept.'),
                  const SizedBox(height: 18),
                  OutlinedButton.icon(
                      onPressed: busy ? null : website,
                      icon: const Icon(Icons.open_in_browser_rounded),
                      label: const Text('Download from official website')),
                  const SizedBox(height: 6),
                  const Text(
                      'Classic download in your browser. Open the APK to install.'),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                      onPressed: busy
                          ? null
                          : stage == 'permission-required' ||
                                  stage == 'installer-opened'
                              ? install
                              : internal,
                      icon: const Icon(Icons.download_rounded),
                      label: Text(stage == 'permission-required'
                          ? 'Continue installation'
                          : stage == 'installer-opened'
                              ? 'Open Android installer again'
                              : 'Download & install from GitHub')),
                  const SizedBox(height: 6),
                  const Text(
                      'Download inside Kaspire, verify the APK, then confirm installation in Android. No external browser needed.'),
                  if (busy) ...[
                    const SizedBox(height: 18),
                    LinearProgressIndicator(
                        value: stage == 'downloading' ? progress : null),
                    const SizedBox(height: 8),
                    Text(stage == 'downloading'
                        ? progress == null
                            ? 'Downloading from GitHub…'
                            : 'Downloading… ${(progress! * 100).round()}%'
                        : 'Verifying update…'),
                  ],
                  if (stage == 'permission-required') ...[
                    const SizedBox(height: 12),
                    const Text(
                        'Allow “Install unknown apps” for Kaspire in Android settings, return here, then tap Continue installation.'),
                  ],
                  if (stage == 'installer-opened') ...[
                    const SizedBox(height: 12),
                    const Text(
                        'Android installer opened. Confirm the update there. Opening the installer alone does not mean the update is installed.'),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ],
                ]))),
        actions: [
          TextButton(
              onPressed: stage == 'installing' ? null : close,
              child: Text(busy ? 'Cancel download' : 'Close'))
        ],
      ));
}
