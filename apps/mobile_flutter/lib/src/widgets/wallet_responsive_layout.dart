import 'package:flutter/material.dart';
import '../platform.dart';

/// Reuse the existing dashboard widgets. The desktop dashboard keeps separate
/// scroll regions and a nested content navigator, never replacing its balance.
class WalletResponsiveLayout extends StatelessWidget {
  const WalletResponsiveLayout(
      {super.key,
      required this.children,
      this.desktopNavigator,
      this.desktopSection = 'assets',
      this.onDesktopOverview});
  final List<Widget> children;
  final GlobalKey<NavigatorState>? desktopNavigator;
  final String desktopSection;
  final VoidCallback? onDesktopOverview;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, size) {
        if (isWindowsDesktop &&
            desktopNavigator != null &&
            children.length >= 6) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child:
                Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(
                  flex: 5,
                  child: ListView(
                    key: const PageStorageKey('desktop-balance-pane'),
                    children: children.take(6).toList(),
                  )),
              const SizedBox(width: 24),
              Expanded(
                  flex: 6,
                  child: Column(children: [
                    Row(children: [
                      IconButton(
                          tooltip: 'Back',
                          icon: const Icon(Icons.arrow_back_rounded),
                          onPressed: () =>
                              desktopNavigator?.currentState?.maybePop()),
                      const Spacer(),
                      IconButton(
                          tooltip: 'Wallet overview',
                          icon: const Icon(Icons.home_outlined),
                          onPressed: onDesktopOverview ??
                              () => desktopNavigator?.currentState
                                  ?.popUntil((route) => route.isFirst)),
                    ]),
                    Expanded(
                        child: Navigator(
                      key: desktopNavigator,
                      pages: [
                        MaterialPage<void>(
                          key: const ValueKey('desktop-assets-home'),
                          child: Scaffold(
                              body: ListView(
                            key: PageStorageKey('desktop-$desktopSection-pane'),
                            padding: const EdgeInsets.only(bottom: 32),
                            children: children.sublist(6),
                          )),
                        )
                      ],
                      onDidRemovePage: (_) {},
                    )),
                  ])),
            ]),
          );
        }
        final wide =
            isWindowsDesktop && size.maxWidth >= 1000 && children.length >= 6;
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: wide
              ? [
                  ...children.take(2),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                        flex: 5,
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: children.sublist(2, 6))),
                    const SizedBox(width: 28),
                    Expanded(
                        flex: 6,
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: children.sublist(6))),
                  ]),
                ]
              : children,
        );
      });
}
