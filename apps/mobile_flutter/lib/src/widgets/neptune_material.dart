import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/app_settings.dart';

class NeptuneAssetArtwork extends StatelessWidget {
  const NeptuneAssetArtwork({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    if (AppSettings.theme.value != KaspireTheme.neptune) return child;
    return Stack(children: [
      Positioned.fill(
          child: IgnorePointer(
              child: ExcludeSemantics(
                  child: Align(
                      alignment: Alignment.bottomRight,
                      child: Opacity(
                          opacity: .48,
                          child: Image.asset(
                              'assets/themes/neptune/assets-ornament.png',
                              width: 280,
                              fit: BoxFit.contain)))))),
      child,
    ]);
  }
}

/// Decorative water-glass surface; never contains baked-in wallet information.
class NeptuneWaterDecoration extends Decoration {
  const NeptuneWaterDecoration({this.radius = 20});
  final double radius;
  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      NeptuneWaterPainter(radius, onChanged);
}

class NeptuneWaterPainter extends BoxPainter {
  NeptuneWaterPainter(this.radius, [VoidCallback? onChanged])
      : super(onChanged) {
    if (onChanged != null) {
      _water = const DecorationImage(
              image: AssetImage('assets/themes/neptune/water-glass.png'),
              fit: BoxFit.cover,
              opacity: .62)
          .createPainter(onChanged);
    }
  }
  final double radius;
  DecorationImagePainter? _water;
  @override
  void dispose() {
    _water?.dispose();
    super.dispose();
  }

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final rect = offset & configuration.size!;
    final shape =
        RRect.fromRectAndRadius(rect.deflate(1), Radius.circular(radius));
    canvas.drawShadow(
        Path()..addRRect(shape), const Color(0xFF001820), 7, false);
    canvas.save();
    canvas.clipRRect(shape);
    canvas.drawRect(
        rect,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xE5226670),
              Color(0xF0072E3B),
              Color(0xEE07333E),
              Color(0xE0145360)
            ],
            stops: [0, .34, .75, 1],
          ).createShader(rect));
    _water?.paint(canvas, rect, Path()..addRRect(shape), configuration);
    canvas.restore();
    canvas.drawRRect(
        shape,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.25
          ..shader = const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFFFFF4B9),
                Color(0xFFB2C6AB),
                Color(0xFFEBD49B),
                Color(0xFF749C99),
                Color(0xFFFFE5AB)
              ]).createShader(rect));
    canvas.drawRRect(
        shape.deflate(2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = .6
          ..color = const Color(0x447AF3EF));
  }
}

class NeptuneMoonOrnament extends StatelessWidget {
  const NeptuneMoonOrnament({super.key});
  @override
  Widget build(BuildContext context) => const SizedBox(
      height: 23,
      width: double.infinity,
      child: CustomPaint(painter: _MoonPainter()));
}

class _HeartPainter extends CustomPainter {
  const _HeartPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width / 2, size.height)
      ..cubicTo(-size.width * .3, size.height * .4, 0, -size.height * .15,
          size.width / 2, size.height * .25)
      ..cubicTo(size.width, -size.height * .15, size.width * 1.3,
          size.height * .4, size.width / 2, size.height);
    canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFF9ACBCB)
          ..style = PaintingStyle.stroke
          ..strokeWidth = .8);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _MoonPainter extends CustomPainter {
  const _MoonPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFFE9D8A4);
    final center = size.width / 2;
    for (final direction in [-1.0, 1.0]) {
      for (var i = 0; i < 2; i++) {
        final x = center + direction * (69 + 24 * i);
        final radius = i == 0 ? 8.0 : 5.0;
        final moon = Path.combine(
            PathOperation.difference,
            Path()
              ..addOval(Rect.fromCircle(center: Offset(x, 11), radius: radius)),
            Path()
              ..addOval(Rect.fromCircle(
                  center: Offset(x + direction * 4, 9), radius: radius)));
        canvas.drawPath(moon, paint);
      }
      canvas.drawLine(Offset(center + direction * 22, 11),
          Offset(center + direction * 53, 11), paint..strokeWidth = .6);
      canvas.drawLine(
          Offset(center + direction * 107, 11),
          Offset(center + direction * math.min(170, size.width * .44), 11),
          paint);
    }
    final trident = Path()
      ..moveTo(center, 21)
      ..lineTo(center, 2)
      ..moveTo(center - 6, 3)
      ..cubicTo(center - 8, 15, center - 3, 15, center, 15)
      ..cubicTo(center + 3, 15, center + 8, 15, center + 6, 3)
      ..moveTo(center - 3, 18)
      ..lineTo(center + 3, 18);
    canvas.drawPath(
        trident,
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..strokeCap = StrokeCap.round);
    canvas.drawPath(
        Path()
          ..moveTo(center - 2, 4)
          ..lineTo(center, 0)
          ..lineTo(center + 2, 4),
        paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class NeptuneBalanceCard extends StatelessWidget {
  const NeptuneBalanceCard(
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
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const NeptuneWaterDecoration(radius: 24),
        child: LayoutBuilder(builder: (context, constraints) {
          final ornament = constraints.maxWidth >= 320 &&
              MediaQuery.textScalerOf(context).scale(1) < 1.5;
          final orbSize = math.min(120.0, constraints.maxWidth * .28);
          return Stack(children: [
            if (ornament && constraints.maxWidth >= 370)
              const Positioned(
                  right: 104,
                  top: 40,
                  child: ExcludeSemantics(
                      child: DefaultTextStyle(
                          style: TextStyle(
                              fontFamily: 'NeptuneScript',
                              fontSize: 18,
                              height: .95,
                              color: Color(0xFF9ACBCB)),
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                            Text('Deeper'),
                            Text('Stronger'),
                            Row(mainAxisSize: MainAxisSize.min, children: [
                              Text('Freer'),
                              SizedBox(width: 3),
                              SizedBox(
                                  width: 9,
                                  height: 10,
                                  child: CustomPaint(painter: _HeartPainter()))
                            ]),
                          ])))),
            if (ornament)
              Positioned(
                  right: 3,
                  bottom: 0,
                  width: orbSize,
                  height: orbSize,
                  child: ExcludeSemantics(
                      child: Stack(
                          key: const ValueKey('neptune-orb'),
                          fit: StackFit.expand,
                          children: [
                        Image.asset('assets/themes/neptune/orb.png'),
                        // The globe is centered at (55%, 40%) in the ornament.
                        // Its crescent, pearls and trident make the raster bounds
                        // asymmetric: centering in the full image misplaces it.
                        Positioned(
                            left: orbSize * .34,
                            top: orbSize * .19,
                            width: orbSize * .42,
                            height: orbSize * .42,
                            child: Image.asset(
                                key: const ValueKey('neptune-orb-logo'),
                                'assets/branding/kaspire_app_icon_v4.png')),
                      ]))),
            Padding(
                padding: const EdgeInsets.fromLTRB(17, 14, 15, 20),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                            child: Text(walletName,
                                style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFFE4FFFF)))),
                        IconButton(
                            onPressed: onTogglePrivacy,
                            tooltip:
                                hideAmounts ? 'Show balances' : 'Hide balances',
                            icon: Icon(
                                hideAmounts
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                                color: const Color(0xFF7EF4E7)))
                      ]),
                      const Text('Total Balance',
                          style: TextStyle(
                              color: Color(0xFFB0D9DF),
                              fontSize: 11,
                              letterSpacing: 1.5)),
                      const SizedBox(height: 14),
                      Padding(
                          padding: EdgeInsets.only(
                              right: ornament ? orbSize * .85 : 0),
                          child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                  hideAmounts
                                      ? '•••••• $symbol'
                                      : '$amount $symbol',
                                  style: const TextStyle(
                                      fontSize: 34,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFFE4FFFF))))),
                      const SizedBox(height: 12),
                      Padding(
                          padding:
                              EdgeInsets.only(right: ornament ? orbSize : 0),
                          child: Text(hideAmounts ? 'Amounts hidden' : fiat,
                              style: const TextStyle(
                                  fontSize: 15,
                                  color: Color(0xFF7EF4E7),
                                  fontWeight: FontWeight.w600))),
                    ])),
          ]);
        }),
      );
}
