import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../services/app_settings.dart';
import '../services/explorer_read_policy.dart';
import '../theme.dart';

class ExplorerScreen extends StatefulWidget {
  const ExplorerScreen({super.key});
  @override
  State<ExplorerScreen> createState() => _ExplorerScreenState();
}

class _ExplorerScreenState extends State<ExplorerScreen> {
  late final WebViewController _controller;
  final _client = http.Client();
  bool _ready = false;
  int _active = 0;
  String? _error;
  @override
  void initState() {
    super.initState();
    AppSettings.theme.addListener(_theme);
    _controller = WebViewController();
    _start();
  }

  Future<void> _start() async {
    try {
      if (_controller.platform is AndroidWebViewController) {
        await AndroidWebViewController.enableDebugging(false);
        await (_controller.platform as AndroidWebViewController)
            .setOnShowFileSelector((_) async => <String>[]);
      }
      await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await _controller.setBackgroundColor(KasVaultTheme.ink);
      await _controller.addJavaScriptChannel('ExplorerRead',
          onMessageReceived: (message) {
        _read(message.message);
      });
      await _controller.setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          final uri = Uri.tryParse(request.url);
          // No remote documents or dApps in this privileged local view.
          return uri != null &&
                  uri.scheme == 'file' &&
                  uri.path.startsWith(
                      '/android_asset/flutter_assets/assets/explorer/')
              ? NavigationDecision.navigate
              : NavigationDecision.prevent;
        },
        onPageFinished: (_) async {
          await _theme();
          if (mounted) setState(() => _ready = true);
        },
        onWebResourceError: (e) {
          if (mounted && e.isForMainFrame == true)
            setState(() => _error = e.description);
        },
      ));
      await _controller.loadFlutterAsset('assets/explorer/index.html');
    } catch (e) {
      if (mounted) setState(() => _error = 'Explorer could not open: $e');
    }
  }

  Future<void> _read(String raw) async {
    String? id;
    try {
      if (raw.length > 65536) throw StateError('Explorer request too large.');
      final data = jsonDecode(raw) as Map<String, dynamic>;
      id = data['id'] as String?;
      if (id == null || !RegExp(r'^\d{1,12}$').hasMatch(id)) return;
      final url = Uri.parse(data['url'] as String),
          method = data['method'] as String;
      if (!explorerReadAllowed(method, url))
        throw StateError('Only public explorer reads are allowed.');
      if (_active >= 16) throw StateError('Explorer is busy. Please retry.');
      _active++;
      try {
        final request = http.Request(method, url)..followRedirects = false;
        request.headers['accept'] = 'application/json';
        if (method == 'POST') {
          request.headers['content-type'] = 'application/json';
          request.body = data['body'] as String? ?? '';
        }
        final response =
            await _client.send(request).timeout(const Duration(seconds: 35));
        final bytes = <int>[];
        await for (final chunk
            in response.stream.timeout(const Duration(seconds: 15))) {
          if (bytes.length + chunk.length > 8 * 1024 * 1024)
            throw StateError('Explorer response too large.');
          bytes.addAll(chunk);
        }
        await _reply(
            id, {'status': response.statusCode, 'body': utf8.decode(bytes)});
      } finally {
        _active--;
      }
    } catch (e) {
      if (id != null) await _reply(id, {'error': e.toString()});
    }
  }

  Future<void> _reply(String id, Map<String, Object?> data) async {
    if (!mounted) return;
    try {
      await _controller.runJavaScript(
          'window.__explorerReply?.(${jsonEncode(id)},${jsonEncode(data)});');
    } catch (_) {}
  }

  Future<void> _theme() async {
    if (!mounted) return;
    String rgb(Color c) =>
        '${(c.r * 255).round()} ${(c.g * 255).round()} ${(c.b * 255).round()}';
    final theme = AppSettings.theme.value.name;
    final colors = <String, String>{
      '--kaspa-primary': rgb(KasVaultTheme.mint),
      '--kaspa-background': rgb(KasVaultTheme.ink),
      '--kaspa-card': rgb(KasVaultTheme.panel),
      '--kaspa-border': rgb(KasVaultTheme.line),
      '--kaspa-text': KasVaultTheme.isGlacier ? '23 58 71' : '241 248 251',
      '--kaspa-muted': rgb(KasVaultTheme.detailText),
      '--wallet-art':
          "url('../themes/$theme/${theme == 'cosmic' ? 'nebula.png' : theme == 'neptune' ? 'ocean.png' : theme == 'glacier' ? 'aurora-glacier.png' : 'relief.png'}')",
      '--wallet-surface': "url('../themes/cosmic/surface-nebula.png')",
    };
    await _controller.setBackgroundColor(KasVaultTheme.ink);
    try {
      await _controller.runJavaScript(
          '(()=>{const root=document.documentElement;root.dataset.kaspireTheme=${jsonEncode(theme)};root.dataset.theme=${jsonEncode(theme == 'hub21' ? 'hub21' : 'kaspire')};for(const [key,value]of Object.entries(${jsonEncode(colors)}))root.style.setProperty(key,value);})();');
    } catch (_) {}
  }

  @override
  void dispose() {
    AppSettings.theme.removeListener(_theme);
    _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _controller.canGoBack()) {
          await _controller.goBack();
        } else if (context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
          appBar: AppBar(
              title: const Text('Explorer'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Back to Kaspire'))
              ],
              leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () async {
                    if (await _controller.canGoBack()) {
                      await _controller.goBack();
                    } else if (context.mounted) {
                      Navigator.of(context).pop();
                    }
                  })),
          body: _error != null
              ? Center(
                  child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(_error!),
                        TextButton(
                            onPressed: () {
                              setState(() {
                                _error = null;
                                _ready = false;
                              });
                              _controller.loadFlutterAsset(
                                  'assets/explorer/index.html');
                            },
                            child: const Text('Retry'))
                      ])))
              : Stack(children: [
                  WebViewWidget(controller: _controller),
                  if (!_ready) const Center(child: CircularProgressIndicator())
                ])));
}
