import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';
import '../services/dapp_browser_catalog.dart';
import '../services/dapp_browser_policy.dart';
import '../services/dapp_session_service.dart';
import '../services/security_channel.dart';
import '../services/vault_recovery_download.dart';
import '../widgets/hub21_material.dart';

/// Windows WebView2 host; the pairing/export policies are Android's unchanged
/// policies. Web content has no channel for seeds or native signing methods.
class WindowsDappBrowserScreen extends StatefulWidget {
  const WindowsDappBrowserScreen({super.key, required this.dapp});
  final BrowserDapp dapp;
  @override
  State<WindowsDappBrowserScreen> createState() => _WindowsDappBrowserState();
}

class _WindowsDappBrowserState extends State<WindowsDappBrowserScreen> {
  final controller = WebviewController();
  final subscriptions = <StreamSubscription<dynamic>>[];
  final handled = <String>{};
  String? error, capability;
  Uri? current;
  bool ready = false, connected = false, saving = false;
  @override
  void initState() {
    super.initState();
    unawaited(initialize());
  }

  void connectionChanged() {
    final found =
        DappSessionService.instance.activeSessions().values.any((session) {
      final peer = Uri.tryParse(session.peer.metadata.url);
      return peer != null && DappBrowserPolicy.sameDapp(peer, widget.dapp.home);
    });
    if (mounted) setState(() => connected = found);
  }

  Future<void> initialize() async {
    try {
      if (await WebviewController.getWebViewVersion() == null) {
        throw StateError(
            'Install Microsoft Edge WebView2 Runtime to use Kaspire Browser.');
      }
      await controller.initialize();
      await controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      subscriptions.add(DappSessionService.instance.changes
          .listen((_) => connectionChanged()));
      subscriptions.add(controller.url.listen((value) {
        capability = null;
        current = Uri.tryParse(value);
      }));
      subscriptions.add(controller.webMessage.listen((message) {
        if (message is! Map) return;
        if (message['kaspireWalletLink'] is String &&
            message['source'] == widget.dapp.home.origin) {
          final link = DappBrowserPolicy.walletLink(
              message['kaspireWalletLink'] as String);
          if (link != null) unawaited(pair(link));
        } else if (message['recovery'] is String) {
          unawaited(saveRecovery(message['recovery'] as String));
        }
      }));
      subscriptions.add(controller.loadingState.listen((state) {
        if (state == LoadingState.navigationCompleted) unawaited(loaded());
      }));
      subscriptions.add(controller.onLoadError.listen((_) {
        if (mounted) {
          setState(() => error =
              'Could not load this dApp. Check your connection and reload.');
        }
      }));
      await controller.addScriptToExecuteOnDocumentCreated('''
        (() => {
          if (window.top !== window || location.origin !== ${jsonEncode(widget.dapp.home.origin)}) return;
          Object.defineProperty(window, 'KaspireVaultRecovery', {
            value: Object.freeze({postMessage: message => window.chrome.webview.postMessage({recovery: message})}),
            writable: false, configurable: false
          });
        })();
      ''');
      await DappSessionService.instance.initialize();
      await controller.loadUrl(widget.dapp.home.toString());
      connectionChanged();
      if (mounted) setState(() => ready = true);
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Bad state: ', ''));
      }
    }
  }

  Future<void> loaded() async {
    if (current == null ||
        !DappBrowserPolicy.sameDapp(current!, widget.dapp.home)) {
      return;
    }
    if (VaultRecoveryDownload.allowedOrigin(current!)) {
      final random = Random.secure();
      final value =
          base64UrlEncode(List.generate(32, (_) => random.nextInt(256)));
      capability = value;
      await controller.executeScript(VaultRecoveryDownload.script(value));
    }
    if (current!.host == 'gothdag.kaslab.space') {
      await controller.executeScript('''
        (() => { if(location.origin !== 'https://gothdag.kaslab.space') return;
          const style = document.createElement('style');
          style.textContent = ${jsonEncode(DappBrowserPolicy.gothdagMobileStyle)};
          document.head.appendChild(style); })();
      ''');
    }
  }

  Future<void> pair(Uri link) async {
    final wake = link.host == 'dapp';
    String? topic;
    try {
      final pairing = wake
          ? null
          : DappSessionService.pairingUriFromQrPayload(link.toString());
      topic = pairing == null ? null : Uri.parse(pairing).path;
      if (topic != null && !handled.add(topic)) return;
      if (wake) {
        await DappSessionService.instance.handleAppLink(link);
      } else {
        await DappSessionService.instance
            .pair(pairing!, browserOrigin: widget.dapp.home);
      }
      if (mounted) setState(() => error = null);
    } catch (_) {
      if (topic != null) handled.remove(topic);
      if (mounted) {
        setState(() => error =
            'Connection could not be started. Choose Kaspire again for a fresh connection.');
      }
    }
  }

  Future<void> saveRecovery(String message) async {
    if (saving ||
        capability == null ||
        current == null ||
        !VaultRecoveryDownload.allowedOrigin(current!) ||
        !VaultRecoveryDownload.allowedOrigin(widget.dapp.home) ||
        message.length > VaultRecoveryDownload.maxBytes + 8192) {
      return;
    }
    final captured = capability;
    try {
      final envelope = jsonDecode(message);
      if (envelope is! Map || envelope['capability'] != captured) return;
      final recovery = VaultRecoveryDownload.parse(message);
      saving = true;
      if (!mounted) return;
      final approved = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
                title: const Text('Save Vault recovery file'),
                content: Text(
                    '${recovery.fileName}\n\nSave this recovery metadata for future claims.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(c, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(c, true),
                      child: const Text('Save'))
                ],
              ));
      if (approved != true ||
          captured != capability ||
          current == null ||
          !VaultRecoveryDownload.allowedOrigin(current!)) {
        return;
      }
      final path = await const SecurityChannel().invokeMethod<String>(
          'saveVaultRecovery',
          {'fileName': recovery.fileName, 'json': recovery.json});
      if (!mounted) return;
      await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
                title: const Text('Recovery file saved'),
                content: Text(path ?? recovery.fileName),
                actions: [
                  FilledButton(
                      onPressed: () => Navigator.pop(c),
                      child: const Text('Done'))
                ],
              ));
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      saving = false;
    }
  }

  @override
  void dispose() {
    for (final s in subscriptions) {
      unawaited(s.cancel());
    }
    unawaited(controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.dapp.name), actions: [
          IconButton(
              tooltip: 'Previous page',
              onPressed: ready ? controller.goBack : null,
              icon: const Icon(Icons.arrow_back)),
          IconButton(
              tooltip: 'dApp home',
              onPressed: ready
                  ? () => controller.loadUrl(widget.dapp.home.toString())
                  : null,
              icon: const Icon(Icons.home_outlined)),
          IconButton(
              tooltip: 'Reload',
              onPressed: ready ? controller.reload : null,
              icon: const Icon(Icons.refresh)),
        ]),
        body: Column(children: [
          if (!connected)
            Hub21Readable(
                child: ListTile(
                    leading: const Icon(Icons.lock_outline),
                    title: Text(widget.dapp.home.host),
                    subtitle: const Text(
                        'Choose Kaspire App in Connect Wallet. Approvals stay inside Kaspire.'))),
          if (error != null)
            Padding(padding: const EdgeInsets.all(16), child: Text(error!)),
          Expanded(
              child: ready
                  ? Webview(controller,
                      permissionRequested: (_, __, ___) async =>
                          WebviewPermissionDecision.deny)
                  : const Center(child: CircularProgressIndicator())),
        ]),
      );
}
