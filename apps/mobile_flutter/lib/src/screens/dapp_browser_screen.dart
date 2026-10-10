import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../services/dapp_browser_policy.dart';
import '../services/dapp_session_service.dart';
import '../services/dapp_browser_catalog.dart';

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

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
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
      await _controller.setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: _navigate,
        onPageStarted: (url) {
          final uri = Uri.tryParse(url);
          _trustedPage =
              uri != null && DappBrowserPolicy.sameDapp(uri, widget.dapp.home);
          if (!_trustedPage) {
            unawaited(_controller.loadRequest(widget.dapp.home));
          }
        },
        onPageFinished: (url) async {
          final uri = Uri.tryParse(url);
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
    if (_trustedPage && link != null) {
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
