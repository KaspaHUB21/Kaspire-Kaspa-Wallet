import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../services/app_settings.dart';

const cosmicCyan = Color(0xFF85E5EF);
const cosmicViolet = Color(0xFFE084FF);

/// A static space-glass surface. Texture and sparkle are decoration only;
/// wallet values, controls and all approval information stay live widgets.
class CosmicSurfaceDecoration extends Decoration {
  const CosmicSurfaceDecoration(
      {this.radius = 20, this.strong = false, this.rich = false});
  final double radius;
  final bool strong;
  final bool rich;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      CosmicSurfacePainter(radius,
          strong: strong, rich: rich, onChanged: onChanged);
}

class CosmicSurfacePainter extends BoxPainter {
  CosmicSurfacePainter(this.radius,
      {this.strong = false, this.rich = false, VoidCallback? onChanged})
      : super(onChanged) {
    if (onChanged != null) {
      _stars = DecorationImage(
        image: const AssetImage('assets/themes/cosmic/surface-nebula.png'),
        fit: BoxFit.fill,
        alignment: Alignment.center,
        opacity: rich ? .72 : .30,
      ).createPainter(onChanged);
    }
  }
  final double radius;
  final bool strong;
  final bool rich;
  DecorationImagePainter? _stars;

  @override
  void dispose() {
    _stars?.dispose();
    super.dispose();
  }

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final rect = offset & configuration.size!;
    final shape = RRect.fromRectAndRadius(rect.deflate(1.4),
        Radius.circular(math.min(radius, rect.shortestSide / 2)));
    const spectrum = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        cosmicCyan,
        cosmicViolet,
        Color(0xFFBC59FF),
        cosmicCyan,
        cosmicViolet
      ],
      stops: [0, .25, .49, .72, 1],
    );
    canvas.drawRRect(
        shape,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = rich
              ? 3.2
              : strong
                  ? 2
                  : 1.3
          ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, rich ? 4 : 3)
          ..shader = spectrum.scale(rich ? .75 : .4).createShader(rect));
    canvas.save();
    canvas.clipRRect(shape);
    canvas.drawRRect(
        shape,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xF0100B28), Color(0xFA020518), Color(0xF20D0825)],
          ).createShader(rect));
    _stars?.paint(canvas, rect, Path()..addRRect(shape), configuration);
    final random = math.Random(2142);
    final count =
        math.min(90, (rect.width * rect.height / (rich ? 460 : 950)).ceil());
    for (var i = 0; i < count; i++) {
      canvas.drawCircle(
          Offset(rect.left + random.nextDouble() * rect.width,
              rect.top + random.nextDouble() * rect.height),
          .2 + random.nextDouble() * .45,
          Paint()
            ..color = (i.isEven ? cosmicCyan : cosmicViolet)
                .withValues(alpha: rich ? .65 : .25));
    }
    canvas.restore();
    canvas.drawRRect(
        shape,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = rich
              ? 1.8
              : strong
                  ? 1.8
                  : 1.25
          ..shader = spectrum.createShader(rect));
    canvas.drawRRect(
        shape.deflate(1.7),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = .45
          ..color = rich ? const Color(0xBFE3C9FF) : const Color(0x6FE3C9FF));
    if (rich) {
      // A luminous core over the colored rim, with restrained broad halos.
      // All highlights are static, do not animate, and stay away from labels.
      canvas.drawRRect(
          shape.deflate(.3),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = .55
            ..shader = const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFFF5FFFF),
                  Color(0x30FFFFFF),
                  Color(0xFFFFFFFF),
                  Color(0x40FFFFFF),
                  Color(0xFFFBE6FF)
                ],
                stops: [
                  0,
                  .28,
                  .55,
                  .8,
                  1
                ]).createShader(rect));
      for (final highlight in [
        (Offset(rect.left + rect.width * .18, rect.top + 1.5), cosmicCyan),
        (Offset(rect.right - rect.width * .14, rect.top + 1.5), cosmicViolet),
        (Offset(rect.left + rect.width * .62, rect.bottom - 1.5), cosmicCyan),
      ]) {
        canvas.drawCircle(
            highlight.$1,
            5.5,
            Paint()
              ..color = highlight.$2.withValues(alpha: .8)
              ..maskFilter =
                  const ui.MaskFilter.blur(ui.BlurStyle.normal, 3.5));
        canvas.drawLine(
            highlight.$1 - const Offset(5, 0),
            highlight.$1 + const Offset(5, 0),
            Paint()
              ..color = Colors.white
              ..strokeWidth = .7);
        canvas.drawLine(
            highlight.$1 - const Offset(0, 3),
            highlight.$1 + const Offset(0, 3),
            Paint()
              ..color = highlight.$2
              ..strokeWidth = .55);
      }
    }
    // Small edge glints, not animated or painted over interactive content.
    if (rect.width > 90 && rect.height > 50) {
      for (final point in [
        Offset(rect.left + rect.width * .52, rect.top + 1.5),
        Offset(rect.left + rect.width * .16, rect.bottom - 1.5)
      ]) {
        canvas.drawCircle(
            point,
            2.2,
            Paint()
              ..color = const Color(0xDDE7B7FF)
              ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 3));
        canvas.drawLine(
            point - const Offset(4, 0),
            point + const Offset(4, 0),
            Paint()
              ..color = const Color(0xBFFFFFFF)
              ..strokeWidth = .6);
      }
    }
  }
}

class CosmicAction extends StatelessWidget {
  const CosmicAction(
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
            borderRadius: BorderRadius.circular(16),
            child: DecoratedBox(
              decoration: const CosmicSurfaceDecoration(radius: 16, rich: true),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon,
                          size: 29,
                          color: icon == Icons.arrow_upward_rounded
                              ? cosmicViolet
                              : cosmicCyan,
                          shadows: [
                            Shadow(
                                color: (icon == Icons.arrow_upward_rounded
                                        ? cosmicViolet
                                        : cosmicCyan)
                                    .withValues(alpha: .45),
                                blurRadius: 5)
                          ]),
                      const SizedBox(height: 6),
                      FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(buttonLabel(label),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFFF8F4FF),
                                  shadows: [
                                    Shadow(color: Colors.black, blurRadius: 3)
                                  ]))),
                    ]),
              ),
            ),
          ),
        ),
      );
}

class CosmicBalanceCard extends StatelessWidget {
  const CosmicBalanceCard(
      {super.key,
      required this.walletName,
      required this.amount,
      required this.symbol,
      required this.fiat,
      required this.hideAmounts,
      required this.onTogglePrivacy});
  final String walletName, amount, symbol, fiat;
  final bool hideAmounts;
  final VoidCallback onTogglePrivacy;

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final artwork = MediaQuery.textScalerOf(context).scale(1) < 1.6;
        final planetSize = (constraints.maxWidth * .43).clamp(100.0, 168.0);
        return DecoratedBox(
          decoration: const CosmicSurfaceDecoration(radius: 24, strong: true),
          child: Padding(
              padding: const EdgeInsets.all(2.3),
              child: DecoratedBox(
                  decoration: const BoxDecoration(
                      borderRadius: BorderRadius.all(Radius.circular(22)),
                      image: DecorationImage(
                          image: AssetImage(
                              'assets/themes/cosmic/surface-nebula.png'),
                          fit: BoxFit.cover,
                          opacity: .68,
                          filterQuality: FilterQuality.high)),
                  child: Stack(children: [
                    // Square bounds and contain fitting keep the disc round.
                    Positioned(
                        right: 5,
                        bottom: 5,
                        width: planetSize,
                        height: planetSize,
                        child: IgnorePointer(
                            child: ExcludeSemantics(
                                child: Opacity(
                          opacity: artwork ? 1 : .28,
                          child: Image.asset(
                              'assets/themes/cosmic/planet-cutout.png',
                              key: const ValueKey('cosmic-planet-artwork'),
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.high),
                        )))),
                    Padding(
                        padding: const EdgeInsets.fromLTRB(18, 11, 12, 22),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Expanded(
                                    child: Text(walletName,
                                        style: const TextStyle(
                                            fontSize: 19,
                                            fontWeight: FontWeight.w800,
                                            color: Colors.white,
                                            shadows: [
                                              Shadow(
                                                  color: Colors.black,
                                                  blurRadius: 5)
                                            ]))),
                                IconButton(
                                    onPressed: onTogglePrivacy,
                                    tooltip: hideAmounts
                                        ? 'Show balances'
                                        : 'Hide balances',
                                    color: cosmicCyan,
                                    icon: Icon(hideAmounts
                                        ? Icons.visibility_off_rounded
                                        : Icons.visibility_rounded)),
                              ]),
                              const Text('Total Balance',
                                  style: TextStyle(
                                      fontSize: 12,
                                      letterSpacing: .7,
                                      color: Color(0xFFC2C9DC))),
                              const SizedBox(height: 13),
                              Padding(
                                  padding: EdgeInsets.only(
                                      right: artwork ? planetSize * .72 : 0),
                                  child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                          hideAmounts
                                              ? '•••••• $symbol'
                                              : '$amount $symbol',
                                          style: const TextStyle(
                                              fontSize: 34,
                                              height: 1.2,
                                              fontWeight: FontWeight.w900,
                                              color: Colors.white,
                                              shadows: [
                                                Shadow(
                                                    color: Color(0xFF010313),
                                                    blurRadius: 7)
                                              ])))),
                              const SizedBox(height: 12),
                              Padding(
                                  padding: EdgeInsets.only(
                                      right: artwork ? planetSize * .72 : 0),
                                  child: Text(
                                      hideAmounts ? 'Amounts hidden' : fiat,
                                      style: const TextStyle(
                                          fontSize: 15,
                                          color: cosmicCyan,
                                          shadows: [
                                            Shadow(
                                                color: Colors.black,
                                                blurRadius: 5)
                                          ]))),
                            ])),
                  ]))),
        );
      });
}

class CosmicNavigationFrame extends StatelessWidget {
  const CosmicNavigationFrame({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const CosmicSurfaceDecoration(radius: 0),
        child: SafeArea(
            top: false,
            child: Stack(children: [
              Positioned.fill(
                  child: ExcludeSemantics(
                      child: Opacity(
                          opacity: .8,
                          child: Image.asset('assets/themes/cosmic/nebula.png',
                              fit: BoxFit.cover,
                              alignment: Alignment.bottomCenter)))),
              MediaQuery.removePadding(
                  context: context,
                  removeBottom: true,
                  child: Padding(
                      padding: const EdgeInsets.only(bottom: 8), child: child)),
            ])),
      );
}
