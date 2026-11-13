import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../services/update_service.dart';
import 'android_update_dialog.dart';

/// Theme-independent public lock surface. PIN entry stays in the native host.
class AndroidWalletLock extends StatelessWidget {
  const AndroidWalletLock({
    super.key,
    required this.methods,
    required this.busy,
    required this.error,
    required this.onBiometrics,
    required this.onPin,
    required this.onDeviceUnlock,
  });

  final Future<({bool biometrics, bool pin})> methods;
  final bool busy;
  final String? error;
  final VoidCallback onBiometrics, onPin, onDeviceUnlock;

  static const background = Color(0xFF000D10);
  static const mint = Color(0xFF69F4EB);

  @override
  Widget build(BuildContext context) => Theme(
        data: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          fontFamily: 'sans-serif',
          scaffoldBackgroundColor: background,
          colorScheme: const ColorScheme.dark(
            primary: mint,
            surface: background,
            onSurface: Color(0xFFF5FBFB),
            error: Color(0xFFFF9A9A),
          ),
        ),
        child: AnnotatedRegion<SystemUiOverlayStyle>(
          value: const SystemUiOverlayStyle(
            statusBarColor: background,
            statusBarIconBrightness: Brightness.light,
            systemNavigationBarColor: background,
            systemNavigationBarIconBrightness: Brightness.light,
          ),
          child: Scaffold(
            backgroundColor: background,
            body: SafeArea(
              child: LayoutBuilder(builder: (context, viewport) {
                final compact =
                    viewport.maxWidth < 360 || viewport.maxHeight < 700;
                return SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: viewport.maxHeight),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 480),
                        child: _LockLayout(
                            availableHeight: viewport.maxHeight,
                            children: [
                              ValueListenableBuilder<UpdateCheckState>(
                                valueListenable: UpdateService.instance.state,
                                builder: (context, state, _) {
                                  final update = state.update;
                                  if (update == null) {
                                    return SizedBox(height: compact ? 8 : 24);
                                  }
                                  return Padding(
                                    padding:
                                        const EdgeInsets.fromLTRB(26, 4, 26, 0),
                                    child: Align(
                                      alignment: Alignment.centerRight,
                                      child: TextButton.icon(
                                        onPressed: busy
                                            ? null
                                            : () => showAndroidUpdate(
                                                context, update),
                                        icon: const Icon(
                                            Icons.system_update_alt,
                                            size: 20),
                                        label: const Text('Update available'),
                                        style: TextButton.styleFrom(
                                          foregroundColor: mint,
                                          minimumSize: const Size(44, 44),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                              const _ReferenceArt(top: 60, height: 74),
                              const _ReferenceArt(top: 134, height: 406),
                              Padding(
                                padding: EdgeInsets.symmetric(
                                    horizontal: compact ? 18 : 26),
                                child: Column(children: [
                                  Text('Wallet Locked',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          color: Color(0xFFF7FDFD),
                                          fontSize: compact ? 28 : 34,
                                          height: 1.12,
                                          fontWeight: FontWeight.w700)),
                                  const SizedBox(height: 8),
                                  Text('Authenticate to access your wallet',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          color: Color(0xFFC5DBDA),
                                          fontSize: compact ? 14 : 16,
                                          height: 1.4)),
                                  SizedBox(height: compact ? 14 : 22),
                                  FutureBuilder<({bool biometrics, bool pin})>(
                                    future: methods,
                                    builder: (context, snapshot) {
                                      final capabilities = snapshot.data;
                                      final ready = snapshot.connectionState ==
                                          ConnectionState.done;
                                      final biometrics =
                                          capabilities?.biometrics ?? false;
                                      final pin = capabilities?.pin ?? false;
                                      final enabled = !busy && ready;
                                      return Column(children: [
                                        if (biometrics) ...[
                                          _LockButton(
                                            label: 'Use Biometrics',
                                            icon: Icons.fingerprint_rounded,
                                            primary: true,
                                            onPressed:
                                                enabled ? onBiometrics : null,
                                          ),
                                          Padding(
                                            padding: EdgeInsets.symmetric(
                                                vertical: compact ? 8 : 14),
                                            child: const Row(children: [
                                              Expanded(
                                                  child: Divider(
                                                      color:
                                                          Color(0xFF327E7C))),
                                              Padding(
                                                padding: EdgeInsets.symmetric(
                                                    horizontal: 18),
                                                child: Text('or',
                                                    style: TextStyle(
                                                        fontSize: 16)),
                                              ),
                                              Expanded(
                                                  child: Divider(
                                                      color:
                                                          Color(0xFF327E7C))),
                                            ]),
                                          ),
                                        ],
                                        if (pin) ...[
                                          _LockButton(
                                            label: 'Enter wallet PIN',
                                            icon: Icons.lock_outline_rounded,
                                            field: true,
                                            onPressed: enabled ? onPin : null,
                                          ),
                                          const SizedBox(height: 14),
                                        ],
                                        _LockButton(
                                          label: pin || biometrics
                                              ? 'Unlock'
                                              : 'Use device lock',
                                          onPressed: enabled
                                              ? (pin ? onPin : onDeviceUnlock)
                                              : null,
                                        ),
                                      ]);
                                    },
                                  ),
                                  if (busy)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 14),
                                      child: Semantics(
                                        label: 'Authenticating',
                                        liveRegion: true,
                                        child: const SizedBox.square(
                                          dimension: 22,
                                          child: CircularProgressIndicator(
                                              color: mint, strokeWidth: 2),
                                        ),
                                      ),
                                    ),
                                  if (error != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 14),
                                      child: Semantics(
                                        liveRegion: true,
                                        child: Text(error!,
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                                color: Color(0xFFFF9A9A))),
                                      ),
                                    ),
                                ]),
                              ),
                              const _ReferenceArt(top: 1020, height: 260),
                            ]),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      );
}

class _LockButton extends StatelessWidget {
  const _LockButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.primary = false,
    this.field = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool primary, field;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          color: primary ? null : const Color(0xFF00262C),
          gradient: primary
              ? const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                      Color(0xFF91FFF7),
                      Color(0xFF24EDDF),
                      Color(0xFF09C6B8)
                    ],
                  stops: [
                      0,
                      .6,
                      1
                    ])
              : null,
          boxShadow: field
              ? null
              : [
                  BoxShadow(
                    color: Color(primary ? 0x7018FFF6 : 0x185BE9E4),
                    blurRadius: primary ? 18 : 10,
                  )
                ],
        ),
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            minimumSize: Size(double.infinity, primary ? 54 : 52),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            foregroundColor:
                primary ? const Color(0xFF001A1B) : const Color(0xFFE2F3F2),
            disabledForegroundColor: const Color(0xFF789A99),
            side: BorderSide(
                color: primary
                    ? const Color(0xFFB0FFFA)
                    : field
                        ? const Color(0xFF62BABB)
                        : const Color(0xFF5BE9E4),
                width: field ? 1.5 : 2),
            shape: const StadiumBorder(),
            textStyle: TextStyle(
                fontFamily: 'sans-serif',
                fontSize: field ? 16 : 20,
                fontWeight: field ? FontWeight.w400 : FontWeight.w700),
          ),
          child: Row(
            mainAxisAlignment:
                field ? MainAxisAlignment.start : MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: primary ? 30 : 24),
                const SizedBox(width: 14),
              ],
              if (field)
                Expanded(child: Text(label, textAlign: TextAlign.left))
              else
                Flexible(child: Text(label, textAlign: TextAlign.center)),
              // A native PIN dialog owns entry and visibility; do not imitate
              // an editable Flutter field or show a nonfunctional eye button.
              if (field) ...[
                const Icon(Icons.chevron_right_rounded, size: 24),
              ],
            ],
          ),
        ),
      );
}

/// Original reference pixels, clipped to artwork only. Never displays the
/// screenshot's status bar, baked-in buttons or text. All hit targets are native
/// Flutter controls above; these decorative viewports cannot intercept input.
class _ReferenceArt extends StatelessWidget {
  const _ReferenceArt({required this.top, required this.height});
  final double top, height;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: IgnorePointer(
          child: AspectRatio(
            aspectRatio: 591 / height,
            child: LayoutBuilder(builder: (context, constraints) {
              final scale = math.min(
                  constraints.maxWidth / 591, constraints.maxHeight / height);
              if (scale <= 0) return const SizedBox.shrink();
              final art = ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topCenter,
                  minWidth: 0,
                  minHeight: 0,
                  maxWidth: 591 * scale,
                  maxHeight: 1280 * scale,
                  child: Transform.translate(
                    offset: Offset(0, -top * scale),
                    child: Image.asset(
                      'assets/branding/lock_reference_v2.jpg',
                      width: 591 * scale,
                      height: 1280 * scale,
                      fit: BoxFit.fill,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                ),
              );
              // Only soften the lower landscape's cut edge. The mountain and
              // wordmark retain the reference's original contrast and colors.
              return top == 1020
                  ? ShaderMask(
                      blendMode: BlendMode.dstIn,
                      shaderCallback: (bounds) => const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x00FFFFFF), Color(0xFFFFFFFF)],
                        stops: [0, .12],
                      ).createShader(bounds),
                      child: art,
                    )
                  : art;
            }),
          ),
        ),
      );
}

/// Measures live text/buttons before allocating any space to decoration. This
/// avoids guessing control heights (which change with font scale, update/error
/// messages and enrolled methods). Scrolling is a fallback only when the actual
/// controls themselves exceed the safe viewport, not because the art is tall.
class _LockLayout extends MultiChildRenderObjectWidget {
  const _LockLayout({required this.availableHeight, required super.children});
  final double availableHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLockLayout(availableHeight);

  @override
  void updateRenderObject(
      BuildContext context, _RenderLockLayout renderObject) {
    renderObject.availableHeight = availableHeight;
  }
}

class _LockParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderLockLayout extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _LockParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _LockParentData> {
  _RenderLockLayout(this._availableHeight);
  double _availableHeight;
  set availableHeight(double value) {
    if (_availableHeight == value) return;
    _availableHeight = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _LockParentData) {
      child.parentData = _LockParentData();
    }
  }

  @override
  void performLayout() {
    final children = <RenderBox>[];
    RenderBox? child = firstChild;
    while (child != null) {
      children.add(child);
      child = childAfter(child);
    }
    assert(children.length == 5);
    final width = constraints.maxWidth;
    final natural = BoxConstraints.tightFor(width: width);
    // Update/header, wordmark, controls: always retain their real layout and
    // minimum touch targets. Mountain and lower landscape take what remains.
    for (final index in [0, 1, 3]) {
      children[index].layout(natural, parentUsesSize: true);
    }
    final fixedHeight = children[0].size.height +
        children[1].size.height +
        children[3].size.height;
    final naturalArtHeight = width * (406 + 260) / 591;
    final artHeight = math.min(
        naturalArtHeight, math.max(0.0, _availableHeight - fixedHeight));
    children[2].layout(
        BoxConstraints.tightFor(width: width, height: artHeight * 406 / 666),
        parentUsesSize: true);
    children[4].layout(
        BoxConstraints.tightFor(width: width, height: artHeight * 260 / 666),
        parentUsesSize: true);
    size = constraints.constrain(
        Size(width, math.max(_availableHeight, fixedHeight + artHeight)));
    var y = 0.0;
    for (var index = 0; index < children.length; index++) {
      final data =
          children[index].parentData! as ContainerBoxParentData<RenderBox>;
      // Keep the lower landscape at the bottom on taller devices.
      if (index == 4) y = size.height - children[index].size.height;
      data.offset = Offset(0, y);
      y += children[index].size.height;
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
