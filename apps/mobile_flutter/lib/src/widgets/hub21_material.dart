import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/app_settings.dart';

/// Opaque reading surface for text that normally sits directly on the plain
/// background. Other themes keep their original layout and spacing.
class Hub21Readable extends StatelessWidget {
  const Hub21Readable(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 10)});
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    // Depend on the inherited theme so even const headings update immediately.
    Theme.of(context);
    if (AppSettings.theme.value != KaspireTheme.hub21) return child;
    return Container(
        padding: padding,
        decoration: BoxDecoration(
            color: const Color(0xFF141611),
            border: Border.all(color: const Color(0xFF756647)),
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x99000000), blurRadius: 8, offset: Offset(0, 2))
            ]),
        child: child);
  }
}

/// HUB21's raster relief is decorative only. All wallet data and controls are
/// live Flutter widgets; no amounts or security information are baked in.
class Hub21Backdrop extends StatelessWidget {
  const Hub21Backdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (AppSettings.theme.value != KaspireTheme.hub21) return child;
    return Stack(fit: StackFit.expand, children: [
      Positioned.fill(
        child: ExcludeSemantics(
          child: RepaintBoundary(
            child: Image.asset('assets/themes/hub21/relief.png',
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                filterQuality: FilterQuality.medium),
          ),
        ),
      ),
      const Positioned.fill(
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
                gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x14000000), Color(0x33000000), Color(0x99000000)],
              stops: [0, .65, 1],
            )),
          ),
        ),
      ),
      child,
    ]);
  }
}

/// Machined metal is drawn at device resolution, with deterministic horizontal
/// brushing and multiple bevels. It does not animate or intercept gestures.
class Hub21MetalDecoration extends Decoration {
  const Hub21MetalDecoration(
      {this.radius = 20, this.gold = false, this.rim = 4, this.shadow = true});
  final double radius;
  final bool gold;
  final double rim;
  final bool shadow;

  @override
  bool get isComplex => true;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _MetalPainter(this, onChanged);
}

class _MetalPainter extends BoxPainter {
  _MetalPainter(this.decoration, VoidCallback? onChanged) : super(onChanged) {
    _grain = const DecorationImage(
      image: AssetImage('assets/themes/hub21/brushed-metal.png'),
      fit: BoxFit.cover,
      opacity: .38,
      filterQuality: FilterQuality.low,
    ).createPainter(onChanged ?? () {});
  }
  final Hub21MetalDecoration decoration;
  late final DecorationImagePainter _grain;
  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final rect = offset & configuration.size!;
    _paintMetal(canvas, rect, decoration.radius, decoration.gold,
        decoration.rim, decoration.shadow);
    final face =
        RRect.fromRectAndRadius(rect, Radius.circular(decoration.radius))
            .deflate(decoration.rim + 1.5);
    _grain.paint(canvas, face.outerRect, Path()..addRRect(face), configuration,
        blendMode: BlendMode.softLight);
  }

  @override
  void dispose() {
    _grain.dispose();
    super.dispose();
  }
}

const _edge = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [
    Color(0xFFFFF4CE),
    Color(0xFF8F8270),
    Color(0xFFFFE4A1),
    Color(0xFF80500D),
    Color(0xFFFFD26E),
    Color(0xFF29231B),
    Color(0xFFFAE4AC)
  ],
  stops: [0, .17, .35, .53, .72, .86, 1],
);

void _paintMetal(Canvas canvas, Rect rect, double radius, bool gold, double rim,
    bool shadow) {
  final outer = RRect.fromRectAndRadius(rect, Radius.circular(radius));
  if (shadow) {
    canvas.drawShadow(
        Path()..addRRect(outer), const Color(0xEE000000), 7, true);
  }
  canvas.drawRRect(outer, Paint()..shader = _edge.createShader(rect));
  final recess = outer.deflate(rim * .43);
  canvas.drawRRect(recess, Paint()..color = const Color(0xFF20180D));
  final bevel = outer.deflate(rim * .73);
  canvas.drawRRect(bevel, Paint()..shader = _edge.createShader(rect));
  final face = outer.deflate(rim + 1);
  final faceRect = face.outerRect;
  final gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: gold
        ? const [
            Color(0xFF69645A),
            Color(0xFF252725),
            Color(0xFF494339),
            Color(0xFFAF790F),
            Color(0xFF433013),
            Color(0xFFBD8315)
          ]
        : const [
            Color(0xFF77766D),
            Color(0xFF323431),
            Color(0xFF1C201F),
            Color(0xFF50452D),
            Color(0xFF1C1E1C)
          ],
    stops: gold ? const [0, .22, .44, .67, .84, 1] : const [0, .2, .53, .82, 1],
  );
  canvas.drawRRect(face, Paint()..shader = gradient.createShader(faceRect));
  canvas.save();
  canvas.clipRRect(face);
  // Deterministic fine metal grain; a bounded number of strokes even on tablets.
  final random = math.Random(21);
  final strokes = math.min(700, (rect.height * 2).ceil());
  for (var i = 0; i < strokes; i++) {
    final y = faceRect.top + random.nextDouble() * faceRect.height;
    final x = faceRect.left + random.nextDouble() * faceRect.width;
    canvas.drawLine(
        Offset(x, y),
        Offset(math.min(faceRect.right, x + 15 + random.nextDouble() * 160), y),
        Paint()
          ..strokeWidth = .35
          ..color = (i.isEven ? Colors.white : Colors.black)
              .withValues(alpha: i.isEven ? .075 : .14));
  }
  canvas.drawRect(
      faceRect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x33FFFFFF), Color(0x00FFFFFF), Color(0x55000000)],
          stops: [0, .13, 1],
        ).createShader(faceRect));
  canvas.restore();
  canvas.drawRRect(
      face,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = .8
        ..color = const Color(0x88FFF0C9));
}

class Hub21Panel extends StatelessWidget {
  const Hub21Panel(
      {super.key,
      required this.child,
      this.gold = false,
      this.radius = 20,
      this.padding = EdgeInsets.zero,
      this.rim = 4});
  final Widget child;
  final bool gold;
  final double radius;
  final double rim;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: Hub21MetalDecoration(radius: radius, gold: gold, rim: rim),
        child: Padding(padding: padding, child: child),
      );
}

/// Used by Material cards and dialogs, including settings and send reviews.
class Hub21CardShape extends RoundedRectangleBorder {
  const Hub21CardShape()
      : super(borderRadius: const BorderRadius.all(Radius.circular(18)));
  @override
  bool get preferPaintInterior => true;
  @override
  void paintInterior(Canvas canvas, Rect rect, Paint paint,
          {TextDirection? textDirection}) =>
      _paintMetal(canvas, rect, 18, false, 2.5, false);
  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}
}

class Hub21Action extends StatelessWidget {
  const Hub21Action(
      {super.key,
      required this.icon,
      required this.label,
      required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(14),
              child: Hub21Panel(
                  radius: 14,
                  rim: 3.5,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 15),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(icon,
                        size: 29,
                        color: const Color(0xFFFFE5A4),
                        shadows: const [
                          Shadow(
                              color: Colors.black,
                              blurRadius: 3,
                              offset: Offset(0, 2))
                        ]),
                    const SizedBox(height: 6),
                    Text(buttonLabel(label),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFFF2EBDD),
                            shadows: [
                              Shadow(
                                  color: Colors.black,
                                  offset: Offset(0, 2),
                                  blurRadius: 3),
                            ])),
                  ])),
            )),
      );
}

class Hub21BalanceCard extends StatelessWidget {
  const Hub21BalanceCard(
      {super.key,
      required this.walletName,
      required this.amount,
      required this.symbol,
      required this.fiat,
      required this.hideAmounts,
      required this.onTogglePrivacy});
  final String walletName;
  final String amount;
  final String symbol;
  final String fiat;
  final bool hideAmounts;
  final VoidCallback onTogglePrivacy;

  @override
  Widget build(BuildContext context) => Hub21Panel(
        gold: true,
        radius: 24,
        rim: 5,
        child: LayoutBuilder(builder: (context, constraints) {
          final medallion = constraints.maxWidth >= 350 &&
              MediaQuery.textScalerOf(context).scale(1) < 1.4;
          return Stack(children: [
            if (medallion)
              Positioned(
                  right: 8,
                  bottom: 13,
                  child: ExcludeSemantics(
                      child: _Medallion(
                          size: math.min(100, constraints.maxWidth * .23)))),
            Padding(
                padding: const EdgeInsets.fromLTRB(21, 21, 17, 24),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                            child: Text(walletName,
                                style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w900,
                                    color: Color(0xFFF0EDE4),
                                    shadows: [
                                      Shadow(
                                          color: Colors.black,
                                          offset: Offset(0, 2),
                                          blurRadius: 3)
                                    ]))),
                        IconButton(
                            onPressed: onTogglePrivacy,
                            tooltip:
                                hideAmounts ? 'Show balances' : 'Hide balances',
                            icon: Icon(hideAmounts
                                ? Icons.visibility_off_rounded
                                : Icons.visibility_rounded),
                            color: const Color(0xFFFFDF91)),
                      ]),
                      Text(displayLabel('TOTAL BALANCE'),
                          style: const TextStyle(
                              fontSize: 11,
                              letterSpacing: 1.8,
                              color: Color(0xFFE8E1D2),
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 7),
                      Padding(
                          padding: EdgeInsets.only(right: medallion ? 78 : 0),
                          child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: ShaderMask(
                                blendMode: BlendMode.srcIn,
                                shaderCallback: (rect) => const LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Color(0xFFFFFFFF),
                                      Color(0xFFE4DED1),
                                      Color(0xFFB8AB91),
                                      Color(0xFFFFE2A0)
                                    ],
                                    stops: [
                                      0,
                                      .36,
                                      .67,
                                      1
                                    ]).createShader(rect),
                                child: Text(
                                    hideAmounts
                                        ? '•••••• $symbol'
                                        : '$amount $symbol',
                                    style: const TextStyle(
                                        fontSize: 38,
                                        height: 1.2,
                                        letterSpacing: -1.5,
                                        fontWeight: FontWeight.w900)),
                              ))),
                      const SizedBox(height: 9),
                      Padding(
                          padding: EdgeInsets.only(right: medallion ? 92 : 0),
                          child: Text(hideAmounts ? 'Amounts hidden' : fiat,
                              style: const TextStyle(
                                  color: Color(0xFFFFE5A5),
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  shadows: [
                                    Shadow(
                                        color: Colors.black,
                                        offset: Offset(0, 1),
                                        blurRadius: 2)
                                  ]))),
                    ])),
          ]);
        }),
      );
}

class _Medallion extends StatelessWidget {
  const _Medallion({required this.size});
  final double size;
  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: Hub21Panel(
            gold: true,
            radius: size / 2,
            rim: 4,
            padding: EdgeInsets.all(size * .19),
            child: Image.asset('assets/branding/kaspire_app_icon_v4.png',
                fit: BoxFit.contain)),
      );
}

class KaspireNavigationBar extends StatelessWidget {
  const KaspireNavigationBar(
      {super.key,
      required this.selectedIndex,
      required this.onDestinationSelected,
      required this.destinations});
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<Widget> destinations;
  @override
  Widget build(BuildContext context) {
    final navigation = NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: onDestinationSelected,
        destinations: destinations);
    if (AppSettings.theme.value != KaspireTheme.hub21) return navigation;
    return Hub21Panel(radius: 0, rim: 2, child: navigation);
  }
}
