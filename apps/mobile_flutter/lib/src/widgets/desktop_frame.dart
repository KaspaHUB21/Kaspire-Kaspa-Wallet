import 'package:flutter/material.dart';
import '../platform.dart';

/// The app's existing navigator, dialogs and screens are retained. Only the
/// Windows uses its full client area; phone layouts remain untouched.
class DesktopFrame extends StatelessWidget {
  const DesktopFrame({super.key, required this.child, this.onInteraction});
  final Widget child;
  final VoidCallback? onInteraction;
  @override
  Widget build(BuildContext context) {
    if (!isWindowsDesktop) return child;
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Focus(
          canRequestFocus: false,
          onKeyEvent: (_, __) {
            onInteraction?.call();
            return KeyEventResult.ignored;
          },
          child: child),
    );
  }
}
