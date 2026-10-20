import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../services/dapp_browser_policy.dart';
import '../services/dapp_session_service.dart';
import '../services/dapp_browser_catalog.dart';
import '../services/vault_recovery_download.dart';

class DappBrowserScreen extends StatefulWidget {
  const DappBrowserScreen({super.key, required this.dapp});
  final BrowserDapp dapp;

  @override
  State<DappBrowserScreen> createState() => _DappBrowserScreenState();
}

class _DappBrowserScreenState extends State<DappBrowserScreen> {
  final _controller = WebViewController();
  final _handledLinks = <String>{};
  bool _ready = false;
  bool _trustedPage = false;
  int _progress = 0;
  String? _error;
  bool _connected = false;
  String? _exportCapability;
  bool _savingRecovery = false;
  StreamSubscription<void>? _sessionChanges;

  @override
  void initState() {
    super.initState();
    if (widget.dapp.walletConnectEnabled) {
      final sessions = DappSessionService.instance;
      _sessionChanges = sessions.changes.listen((_) => _updateConnection());
      _updateConnection();
      unawaited(sessions
          .initialize()
          .then((_) => _updateConnection())
          .catchError((Object _) {
        /* Keep the connection hint on initialization failure. */
      }));
    }
    unawaited(_initialize());
  }

  void _updateConnection() {
    final connected =
        DappSessionService.instance.activeSessions().values.any((session) {
      final peer = Uri.tryParse(session.peer.metadata.url);
      return peer != null && DappBrowserPolicy.sameDapp(peer, widget.dapp.home);
    });
    if (mounted && connected != _connected) {
      setState(() => _connected = connected);
    }
  }

  @override
  void dispose() {
    unawaited(_sessionChanges?.cancel());
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final android = _controller.platform as AndroidWebViewController;
      await AndroidWebViewController.enableDebugging(false);
      await android.setAllowContentAccess(false);
      await android.setAllowFileAccess(false);
      await android.setGeolocationEnabled(false);
      await android.setMixedContentMode(MixedContentMode.neverAllow);
      await android.setOnShowFileSelector((_) async => <String>[]);
      await android.setOnPlatformPermissionRequest((request) => request.deny());
      await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (VaultRecoveryDownload.allowedOrigin(widget.dapp.home)) {
        await _controller.addJavaScriptChannel('KaspireVaultRecovery',
            onMessageReceived: (message) =>
                unawaited(_saveRecovery(message.message)));
      }
      await _controller.setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: _navigate,
        onPageStarted: (url) {
          _exportCapability = null;
          final uri = Uri.tryParse(url);
          _trustedPage =
              uri != null && DappBrowserPolicy.sameDapp(uri, widget.dapp.home);
          if (!_trustedPage) {
            unawaited(_controller.loadRequest(widget.dapp.home));
          }
        },
        onPageFinished: (url) async {
          final uri = Uri.tryParse(url);
          if (_exportCapability == null &&
              uri != null &&
              VaultRecoveryDownload.allowedOrigin(uri) &&
              VaultRecoveryDownload.allowedOrigin(widget.dapp.home)) {
            final random = Random.secure();
            final capability =
                base64UrlEncode(List.generate(32, (_) => random.nextInt(256)));
            _exportCapability = capability;
            await _controller
                .runJavaScript(VaultRecoveryDownload.script(capability));
          }
          if (uri == null ||
              !DappBrowserPolicy.sameDapp(uri, widget.dapp.home) ||
              uri.host != 'gothdag.kaslab.space') {
            return;
          }
          await _controller.runJavaScript('''
            (() => {
              if (location.origin !== 'https://gothdag.kaslab.space') return;
              const id = 'kaspire-mobile-header-fix';
              let style = document.getElementById(id);
              if (!style) {
                style = document.createElement('style');
                style.id = id;
                document.head.appendChild(style);
              }
              style.textContent = ${jsonEncode(DappBrowserPolicy.gothdagMobileStyle)};
            })();
          ''');
        },
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
        onWebResourceError: (error) {
          if (mounted && error.isForMainFrame == true) {
            setState(() => _error =
                '${widget.dapp.name} could not be loaded. Check your connection and reload.');
          }
        },
      ));
      await _controller.loadRequest(widget.dapp.home);
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Could not start Android WebView. Check that Android System WebView is installed and up to date.');
      }
    }
  }

  Future<void> _saveRecovery(String message) async {
    if (_savingRecovery ||
        !_trustedPage ||
        _exportCapability == null ||
        !VaultRecoveryDownload.allowedOrigin(widget.dapp.home) ||
        message.length > VaultRecoveryDownload.maxBytes + 8192) {
      return;
    }
    final capability = _exportCapability;
    try {
      final envelope = jsonDecode(message);
      if (envelope is! Map || envelope['capability'] != capability) return;
      final current = Uri.tryParse(await _controller.currentUrl() ?? '');
      if (current == null || !VaultRecoveryDownload.allowedOrigin(current)) {
        return;
      }
      final recovery = VaultRecoveryDownload.parse(message);
      _savingRecovery = true;
      if (!mounted) return;
      final approved = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
                  title: const Text('Save Vault recovery file'),
                  content: Text(
                      '${recovery.fileName}\n\nSave the Vault recovery metadata to Downloads/Kaspire-Vault-Recovery? Keep this file for future claims.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(c, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: const Text('Save')),
                  ]));
      if (approved != true || !mounted || _exportCapability != capability) {
        return;
      }
      final afterReview = Uri.tryParse(await _controller.currentUrl() ?? '');
      if (afterReview == null ||
          !VaultRecoveryDownload.allowedOrigin(afterReview)) {
        return;
      }
      await const MethodChannel('space.kasvault/security')
          .invokeMethod<String>('saveVaultRecovery', {
        'fileName': recovery.fileName,
        'json': recovery.json,
      });
      if (!mounted) return;
      await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
                  title: const Text('Recovery file saved'),
                  content: Text(
                      'Downloads/Kaspire-Vault-Recovery/${recovery.fileName}'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(c),
                        child: const Text('Done'))
                  ]));
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not save Vault recovery file: $e');
      }
    } finally {
      _savingRecovery = false;
    }
  }

  Future<NavigationDecision> _navigate(NavigationRequest request) async {
    final uri = Uri.tryParse(request.url);
    // Frames cannot initiate a wallet connection. Their ordinary HTTPS content
    // can load, but never file/content/javascript or custom scheme navigation.
    if (!request.isMainFrame) {
      return uri?.scheme == 'https'
          ? NavigationDecision.navigate
          : NavigationDecision.prevent;
    }
    if (uri != null && DappBrowserPolicy.sameDapp(uri, widget.dapp.home)) {
      return NavigationDecision.navigate;
    }
    final link = DappBrowserPolicy.walletLink(request.url);
    if (_trustedPage && widget.dapp.walletConnectEnabled && link != null) {
      // Do not await a relay operation while WebView is deciding navigation.
      unawaited(_handleWalletLink(link));
    } else if (mounted) {
      setState(() => _error =
          'External navigation was blocked. Return to the dApp selection to open another approved dApp.');
    }
    return NavigationDecision.prevent;
  }

  Future<void> _handleWalletLink(Uri link) async {
    final wake = link.host == 'dapp';
    String? topic;
    try {
      final pairing = wake
          ? null
          : DappSessionService.pairingUriFromQrPayload(link.toString());
      topic = pairing == null ? null : Uri.parse(pairing).path;
      if (topic != null && !_handledLinks.add(topic)) return;
      final service = DappSessionService.instance;
      if (wake) {
        await service.handleAppLink(link);
      } else {
        await service.pair(pairing!, browserOrigin: widget.dapp.home);
      }
      if (mounted) setState(() => _error = null);
    } catch (_) {
      if (topic != null) _handledLinks.remove(topic);
      if (mounted) {
        setState(() => _error =
            'Connection could not be started. Choose Kaspire again in ${widget.dapp.name} to request a fresh connection.');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        appBar: AppBar(
          title: Text(widget.dapp.name),
          actions: [
            IconButton(
                tooltip: 'Previous page',
                icon: const Icon(Icons.arrow_back),
                onPressed: !_ready
                    ? null
                    : () async {
                        if (await _controller.canGoBack()) {
                          await _controller.goBack();
                        }
                      }),
            IconButton(
                tooltip: '${widget.dapp.name} home',
                icon: const Icon(Icons.home_outlined),
                onPressed: !_ready
                    ? null
                    : () => _controller.loadRequest(widget.dapp.home)),
            IconButton(
                tooltip: 'Reload',
                icon: const Icon(Icons.refresh),
                onPressed: !_ready
                    ? null
                    : () {
                        setState(() => _error = null);
                        unawaited(_controller.reload());
                      }),
          ],
        ),
        body: SafeArea(
            child: Column(children: [
          if (widget.dapp.walletConnectEnabled && !_connected)
            ListTile(
                dense: true,
                leading: const Icon(Icons.lock_outline),
                title: Text(widget.dapp.home.host),
                subtitle: const Text(
                    'Choose Kaspire App in Connect Wallet. Approvals stay inside Kaspire.')),
          if (_error != null)
            Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
          if (_progress < 100) LinearProgressIndicator(value: _progress / 100),
          Expanded(
              child: _ready
                  ? WebViewWidget(controller: _controller)
                  : Center(
                      child: _error == null
                          ? const CircularProgressIndicator()
                          : const Icon(Icons.public_off, size: 48))),
        ])),
      );
}
