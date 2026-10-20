import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform.dart';
import '../theme.dart';

/// Flutter draws only public dialog chrome/review data. Secret text lives in
/// the native child control; neither its content nor keystrokes enter Dart.
class WindowsSecurityDialogs {
  static const channel = MethodChannel('space.kaspire/security-windows');
  static final _routes = <int, RawDialogRoute<void>>{};
  static final _states = <int, _WindowsSecurityDialogState>{};
  static VoidCallback? _interaction;

  static void install(GlobalKey<NavigatorState> navigator,
      {VoidCallback? onInteraction}) {
    if (!isWindowsDesktop) return;
    _interaction = onInteraction;
    channel.setMethodCallHandler((call) async {
      final args = (call.arguments as Map).cast<String, Object?>();
      final id = args['id'] as int;
      switch (call.method) {
        case 'showPrompt':
          if (_routes.containsKey(id)) return;
          final nav = navigator.currentState;
          if (nav == null) {
            await channel.invokeMethod<void>(
                'finishPrompt', {'id': id, 'accepted': false});
            return;
          }
          final route = RawDialogRoute<void>(
            barrierDismissible: false,
            barrierColor: Colors.black.withValues(alpha: .65),
            transitionDuration: Duration.zero,
            pageBuilder: (context, _, __) => WindowsSecurityDialog(
              id: id,
              mode: args['mode'] as int,
              title: args['title'] as String,
              body: args['body'] as String,
            ),
          );
          _routes[id] = route;
          unawaited(nav.push(route).whenComplete(() {
            if (_routes.remove(id) != null) {
              unawaited(channel.invokeMethod<void>(
                  'finishPrompt', {'id': id, 'accepted': false}));
            }
          }));
        case 'closePrompt':
          final route = _routes.remove(id);
          if (route?.navigator != null) route!.navigator!.removeRoute(route);
        case 'promptError':
          _states[id]?.showError(args['message'] as String);
        case 'focusActions':
          _states[id]?.focusActions(args['backwards'] == true);
        case 'promptActivity':
          if (_routes.containsKey(id)) _interaction?.call();
        default:
          throw MissingPluginException('Unknown Windows dialog command.');
      }
    });
  }

  static void dispose() {
    if (!isWindowsDesktop) return;
    for (final id in _routes.keys.toList()) {
      unawaited(channel
          .invokeMethod<void>('finishPrompt', {'id': id, 'accepted': false}));
    }
    _routes.clear();
    _states.clear();
    _interaction = null;
    channel.setMethodCallHandler(null);
  }
}

class WindowsSecurityDialog extends StatefulWidget {
  const WindowsSecurityDialog({
    super.key,
    required this.id,
    required this.mode,
    required this.title,
    required this.body,
  });
  final int id, mode;
  final String title, body;

  @override
  State<WindowsSecurityDialog> createState() => _WindowsSecurityDialogState();
}

class _WindowsSecurityDialogState extends State<WindowsSecurityDialog>
    with WidgetsBindingObserver {
  final _input = GlobalKey();
  final _approve = FocusNode();
  final _cancel = FocusNode();
  String? _error;
  bool _busy = false, _focused = false;
  bool _passwordVisible = false, _togglingVisibility = false;
  bool _layoutScheduled = false;
  List<Object>? _lastLayout;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WindowsSecurityDialogs._states[widget.id] = this;
  }

  @override
  void dispose() {
    WindowsSecurityDialogs._states.remove(widget.id);
    WidgetsBinding.instance.removeObserver(this);
    _approve.dispose();
    _cancel.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // The native control is hidden during a real resize. Resend its placement
    // even when rounding leaves the logical field bounds unchanged.
    _lastLayout = null;
    _scheduleLayout();
  }

  void showError(String message) {
    if (mounted) setState(() => _error = message);
  }

  void focusActions(bool backwards) =>
      (backwards ? _cancel : _approve).requestFocus();

  void _scheduleLayout() {
    if (widget.mode == 3 || _layoutScheduled) return;
    _layoutScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _layoutScheduled = false;
      if (!mounted) return;
      final box = _input.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      final offset = box.localToGlobal(Offset.zero);
      final theme = Theme.of(context);
      final background =
          Color.alphaBlend(theme.colorScheme.surface, theme.canvasColor);
      final layout = <Object>[
        offset.dx,
        offset.dy,
        box.size.width,
        box.size.height,
        MediaQuery.devicePixelRatioOf(context),
        background.toARGB32(),
        theme.colorScheme.onSurface.toARGB32(),
      ];
      if (_lastLayout != null &&
          List.generate(layout.length, (i) => layout[i] == _lastLayout![i])
              .every((equal) => equal)) {
        return;
      }
      _lastLayout = layout;
      unawaited(
          WindowsSecurityDialogs.channel.invokeMethod<void>('layoutPrompt', {
        'id': widget.id,
        'x': offset.dx,
        'y': offset.dy,
        'width': box.size.width,
        'height': box.size.height,
        'scale': MediaQuery.devicePixelRatioOf(context),
        'background': background.toARGB32(),
        'foreground': theme.colorScheme.onSurface.toARGB32(),
        'focus': !_focused,
      }).catchError((Object error) {
        _lastLayout = null;
        showError('The secure input could not be opened. Cancel and retry.');
      }));
      _focused = true;
    });
  }

  Future<void> _finish(bool accepted) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await WindowsSecurityDialogs.channel.invokeMethod<void>(
          'finishPrompt', {'id': widget.id, 'accepted': accepted});
    } on PlatformException catch (error) {
      showError(error.message ?? 'Please check the field and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _togglePasswordVisibility() async {
    if (_busy || _togglingVisibility) return;
    final visible = !_passwordVisible;
    setState(() => _togglingVisibility = true);
    try {
      await WindowsSecurityDialogs.channel.invokeMethod<void>(
          'setPromptVisibility', {'id': widget.id, 'visible': visible});
      if (mounted) setState(() => _passwordVisible = visible);
    } catch (_) {
      showError('Could not change password visibility. Please try again.');
    } finally {
      if (mounted) setState(() => _togglingVisibility = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    _scheduleLayout();
    final size = MediaQuery.sizeOf(context);
    final review = widget.mode == 3;
    final display = widget.mode == 6;
    final compact = widget.mode == 1;
    return PopScope(
      canPop: false,
      child: Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: SizedBox(
          width: math.min(680, size.width - 32),
          height: math.min(compact ? 380 : 650, size.height - 48),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Icon(display ? Icons.key_outlined : Icons.shield_outlined,
                        color: KasVaultTheme.mint),
                    const SizedBox(width: 12),
                    Expanded(
                        child: Text(widget.title,
                            style: Theme.of(context).textTheme.titleLarge)),
                  ]),
                  const SizedBox(height: 16),
                  Expanded(
                    child: review
                        ? SingleChildScrollView(
                            key: const Key('windows-review-scroll'),
                            child: SelectableText(widget.body,
                                style: Theme.of(context).textTheme.bodyMedium))
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                                Flexible(
                                    child: SingleChildScrollView(
                                        child: Text(widget.body,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodyMedium))),
                                const SizedBox(height: 16),
                                if (compact)
                                  _secureField(60)
                                else
                                  Expanded(child: _secureField(null)),
                                const SizedBox(height: 10),
                                Text(
                                    display
                                        ? 'Displayed securely by the native wallet core.'
                                        : 'Secure input · kept outside Flutter/Dart memory',
                                    style:
                                        Theme.of(context).textTheme.bodySmall),
                              ]),
                  ),
                  if (_error != null)
                    Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(_error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error))),
                  const SizedBox(height: 16),
                  Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        OutlinedButton(
                            focusNode: _cancel,
                            onPressed: _busy ? null : () => _finish(false),
                            child: const Text('Cancel')),
                        FilledButton(
                            focusNode: _approve,
                            onPressed: _busy ? null : () => _finish(true),
                            child: Text(display
                                ? 'Done'
                                : review
                                    ? 'Confirm'
                                    : 'Continue')),
                      ]),
                ]),
          ),
        ),
      ),
    );
  }

  Widget _secureField(double? height) => Container(
        height: height,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: KasVaultTheme.line),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: widget.mode == 1
            ? Row(children: [
                Expanded(child: SizedBox.expand(key: _input)),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: _passwordVisible ? 'Hide password' : 'Show password',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints.tightFor(width: 36, height: 36),
                  onPressed: _busy || _togglingVisibility
                      ? null
                      : _togglePasswordVisibility,
                  icon: Icon(_passwordVisible
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined),
                ),
              ])
            : SizedBox.expand(key: _input),
      );
}
