import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../theme.dart';
import 'hub21_material.dart';

/// Native counterpart of KasCoven's `vaultIntro` (page.jsx / globals.css).
/// Keep its copy and centered layout, using the active wallet theme's surfaces.
class KasCovenVaultHeader extends StatelessWidget {
  const KasCovenVaultHeader({super.key});

  static const eyebrow = 'KASPA L1 · NON-CUSTODIAL · COVENANT ENFORCED';
  static const title = 'Your money. Your rules.';
  static const lead =
      'Programmable self-custody and true sovereignty. Secured by covenant logic and Kaspa consensus.';
  static const guarantees = [
    'Your keys stay in your wallet',
    'Rules enforced on Kaspa L1',
    'Portable recovery path',
  ];
  static const mint = Color(0xFF49EAD9);

  Widget _guarantee(BuildContext context, String text, Color accent) {
    final scheme = Theme.of(context).colorScheme;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: accent,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: accent, blurRadius: 10)],
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(text,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: scheme.onSurface,
                  fontFamily: 'sans-serif',
                  fontSize: 12.8,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                  height: 1.2)),
        ),
      ]),
    );
    if (KasVaultTheme.isDecorative) {
      return Hub21Panel(radius: 999, rim: 2, child: content);
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: accent.withValues(alpha: .15)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: content,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final originalPalette = AppSettings.theme.value == KaspireTheme.midnight;
    final decorative = KasVaultTheme.isDecorative;
    final accent = originalPalette ? mint : scheme.primary;
    final width = MediaQuery.sizeOf(context).width;
    final mobile = width <= 620;
    final fontSize = mobile
        ? (width * .16).clamp(44.0, 72.0)
        : width <= 920
            ? (width * .08).clamp(48.0, 107.2)
            : (width * .054).clamp(48.0, 67.2);
    final content = DecoratedBox(
      decoration: decorative
          ? const BoxDecoration()
          : BoxDecoration(
              gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: originalPalette
                      ? const [
                          Color(0xFF04100F),
                          Color(0xFF05080B),
                          Color(0xFF030707)
                        ]
                      : [
                          scheme.surface,
                          Theme.of(context).canvasColor,
                          scheme.surface
                        ],
                  stops: const [0, .48, 1]),
            ),
      child: DecoratedBox(
        decoration: decorative
            ? const BoxDecoration()
            : BoxDecoration(
                gradient: RadialGradient(
                    center: const Alignment(-.64, -.76),
                    radius: .64,
                    colors: [
                      accent.withValues(alpha: .18),
                      accent.withValues(alpha: 0)
                    ]),
              ),
        child: DecoratedBox(
          decoration: decorative
              ? const BoxDecoration()
              : BoxDecoration(
                  gradient: RadialGradient(
                      center: const Alignment(.72, -.8),
                      radius: .56,
                      colors: originalPalette
                          ? const [Color(0x1FFF8A20), Color(0x00FF8A20)]
                          : [
                              scheme.secondary.withValues(alpha: .12),
                              scheme.secondary.withValues(alpha: 0)
                            ]),
                ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                mobile ? (decorative ? 16 : 4) : 20,
                mobile
                    ? 48
                    : width <= 920
                        ? 54
                        : (width * .09).clamp(64.0, 118.0),
                mobile ? (decorative ? 16 : 4) : 20,
                mobile ? 34 : (width * .06).clamp(38.0, 68.0)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(eyebrow,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: accent,
                        fontFamily: 'sans-serif',
                        fontSize: 11.2,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.456)),
                const SizedBox(height: 12),
                ShaderMask(
                  blendMode: BlendMode.srcIn,
                  shaderCallback: (bounds) => LinearGradient(
                    begin: const Alignment(-.94, -.34),
                    end: const Alignment(.94, .34),
                    colors: originalPalette
                        ? [
                            const Color(0xFFF4FFFD),
                            mint,
                            Color.lerp(mint, const Color(0xFFFFB16B), 7 / 9)!,
                          ]
                        : [scheme.onSurface, accent, scheme.secondary],
                    stops: const [.12, .58, 1],
                  ).createShader(bounds),
                  child: Text(title,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.white,
                          fontFamily: 'sans-serif',
                          fontSize: fontSize,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -fontSize * .07,
                          height: .91)),
                ),
                const SizedBox(height: 18),
                Center(
                    child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 680),
                        child: Text(lead,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: originalPalette
                                    ? const Color(0xB3EEFCFF)
                                    : KasVaultTheme.detailText,
                                fontFamily: 'sans-serif',
                                fontSize: 16,
                                fontWeight: FontWeight.w400,
                                letterSpacing: 0,
                                height: 1.65)))),
                const SizedBox(height: 28),
                if (mobile) ...[
                  for (var i = 0; i < guarantees.length; i++) ...[
                    if (i > 0) const SizedBox(height: 10),
                    _guarantee(context, guarantees[i], accent),
                  ]
                ] else
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 10,
                    runSpacing: 10,
                    children: guarantees
                        .map((text) => IntrinsicWidth(
                            child: _guarantee(context, text, accent)))
                        .toList(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    return decorative
        ? Hub21Panel(radius: 24, gold: true, child: content)
        : content;
  }
}
