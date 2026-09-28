import 'package:flutter/material.dart';

import 'services/app_settings.dart';
import 'widgets/hub21_material.dart';

class KasVaultTheme {
  static const _midnight = _KaspirePalette(
    accent: Color(0xFF49EACB),
    secondary: Color(0xFF37B8FF),
    background: Color(0xFF050A0D),
    panel: Color(0xFF0D151A),
    line: Color(0xFF1A2A30),
    muted: Color(0xFF82949C),
  );

  static _KaspirePalette get _current => _palette(AppSettings.theme.value);

  static Color get mint => _current.accent;
  static Color get cyan => _current.secondary;
  static Color get ink => _current.background;
  // QR modules must retain scanner-grade contrast on Glacier's light canvas.
  static Color get qrInk =>
      isGlacier ? const Color(0xFF071E2B) : _current.background;
  static Color get panel => _current.panel;
  static Color get line => _current.line;
  static const muted = Color(0xFF82949C);
  static bool get isHub21 => AppSettings.theme.value == KaspireTheme.hub21;
  static bool get isGlacier => AppSettings.theme.value == KaspireTheme.glacier;
  static bool get isDecorative => isHub21 || isGlacier;
  static Color get detailText => isHub21
      ? const Color(0xFFE0DACB)
      : isGlacier
          ? const Color(0xFF344E5C)
          : muted;
  static Color get filledButtonText => isHub21
      ? const Color(0xFFFFEDC7)
      : isGlacier
          ? const Color(0xFF173A47)
          : ink;

  static _KaspirePalette _palette(KaspireTheme theme) => switch (theme) {
        KaspireTheme.midnight => _midnight,
        KaspireTheme.hub21 => const _KaspirePalette(
            accent: Color(0xFFFFD779),
            secondary: Color(0xFFE7E4DD),
            background: Color(0xFF100F0B),
            panel: Color(0xFF252520),
            line: Color(0xFF8D7749),
            muted: Color(0xFFC4BEAC),
          ),
        KaspireTheme.glacier => const _KaspirePalette(
            accent: Color(0xFF087F86),
            secondary: Color(0xFF506B91),
            background: Color(0xFFE7F2F7),
            panel: Color(0xE8F4FBFD),
            line: Color(0xFF83B5C1),
            muted: Color(0xFF526D7A),
          ),
        KaspireTheme.emerald => const _KaspirePalette(
            accent: Color(0xFF35F2A0),
            secondary: Color(0xFF60FFD0),
            background: Color(0xFF020D08),
            panel: Color(0xFF082219),
            line: Color(0xFF16533C),
            muted: Color(0xFF8ABDAC),
          ),
        KaspireTheme.amethyst => const _KaspirePalette(
            accent: Color(0xFFC073FF),
            secondary: Color(0xFFE1A7FF),
            background: Color(0xFF0D0515),
            panel: Color(0xFF21102F),
            line: Color(0xFF573074),
            muted: Color(0xFFBCA4CA),
          ),
        KaspireTheme.sakura => const _KaspirePalette(
            accent: Color(0xFFFF4FB3),
            secondary: Color(0xFFFFA6D8),
            background: Color(0xFF1B0714),
            panel: Color(0xFF351126),
            line: Color(0xFF8A2D64),
            muted: Color(0xFFE1A9C8),
          ),
        KaspireTheme.crimson => const _KaspirePalette(
            accent: Color(0xFFFF4E62),
            secondary: Color(0xFFFF8B82),
            background: Color(0xFF150405),
            panel: Color(0xFF2D0B0E),
            line: Color(0xFF70252D),
            muted: Color(0xFFC9A0A3),
          ),
        KaspireTheme.phoenix => const _KaspirePalette(
            accent: Color(0xFFFF9D36),
            secondary: Color(0xFFFFCA62),
            background: Color(0xFF160A02),
            panel: Color(0xFF2D1606),
            line: Color(0xFF70421C),
            muted: Color(0xFFCDB09A),
          ),
        KaspireTheme.cypherpunk => const _KaspirePalette(
            accent: Color(0xFF39FF14),
            secondary: Color(0xFF00D94A),
            background: Color(0xFF000000),
            panel: Color(0xFF031207),
            line: Color(0xFF0A4817),
            muted: Color(0xFF78AF82),
          ),
      };

  static ThemeData forTheme(KaspireTheme theme) {
    final hub21 = theme == KaspireTheme.hub21;
    final glacier = theme == KaspireTheme.glacier;
    final decorative = hub21 || glacier;
    final palette = _palette(theme);
    final accent = palette.accent;
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: glacier ? Brightness.light : Brightness.dark,
      primary: accent,
      secondary: palette.secondary,
      surface: palette.panel,
    );
    final shape = decorative
        ? Hub21CardShape(glacier: glacier)
        : RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: palette.line),
          );
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide(color: palette.line),
    );
    return ThemeData(
      brightness: glacier ? Brightness.light : Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor:
          decorative ? Colors.transparent : palette.background,
      canvasColor: palette.background,
      cardColor: palette.panel,
      dividerColor: palette.line,
      shadowColor: accent.withValues(
        alpha: theme == KaspireTheme.sakura ? 0.42 : 0.18,
      ),
      splashColor: accent.withValues(alpha: 0.12),
      highlightColor: accent.withValues(alpha: 0.08),
      useMaterial3: true,
      fontFamily: 'sans-serif',
      appBarTheme: AppBarTheme(
        backgroundColor: glacier ? const Color(0xE8EAF4F8) : palette.background,
        foregroundColor: scheme.onSurface,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: palette.panel,
        surfaceTintColor: accent.withValues(alpha: 0.08),
        shape: shape,
      ),
      dialogTheme: DialogThemeData(
        shape: decorative ? Hub21CardShape(glacier: glacier) : null,
        backgroundColor: palette.panel,
        surfaceTintColor: accent.withValues(alpha: 0.08),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: Color.alphaBlend(
          accent.withValues(alpha: 0.18),
          palette.panel,
        ),
        contentTextStyle: TextStyle(color: scheme.onSurface),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.panel,
        hintStyle: TextStyle(color: palette.muted),
        labelStyle: TextStyle(color: palette.muted),
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: accent, width: 1.8),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: palette.background,
        ).copyWith(
          shape: decorative
              ? const WidgetStatePropertyAll(RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(16))))
              : null,
          foregroundColor: decorative
              ? WidgetStatePropertyAll(
                  hub21 ? const Color(0xFFFFEDC7) : const Color(0xFF173A47))
              : null,
          backgroundBuilder: decorative
              ? (context, states, child) => Padding(
                    padding: const EdgeInsets.all(2),
                    child: Hub21Panel(
                      gold: true,
                      radius: 14,
                      rim: 2.5,
                      child: Opacity(
                          opacity:
                              states.contains(WidgetState.disabled) ? .4 : 1,
                          child: child),
                    ),
                  )
              : null,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: accent,
          side: BorderSide(color: accent),
        ).copyWith(
          shape: decorative
              ? const WidgetStatePropertyAll(RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(16))))
              : null,
          side:
              decorative ? const WidgetStatePropertyAll(BorderSide.none) : null,
          backgroundBuilder: decorative
              ? (context, states, child) => Padding(
                    padding: const EdgeInsets.all(2),
                    child: Hub21Panel(
                      radius: 14,
                      rim: 2,
                      child: Opacity(
                          opacity:
                              states.contains(WidgetState.disabled) ? .4 : 1,
                          child: child),
                    ),
                  )
              : null,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
            foregroundColor: accent,
            backgroundColor: decorative ? palette.panel : null),
      ),
      segmentedButtonTheme: decorative
          ? SegmentedButtonThemeData(
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.resolveWith((states) =>
                    states.contains(WidgetState.selected)
                        ? (hub21
                            ? const Color(0xFF6C5120)
                            : const Color(0xB8C7F4F1))
                        : palette.background),
                foregroundColor: WidgetStatePropertyAll(
                    hub21 ? const Color(0xFFF4E8CD) : const Color(0xFF173A47)),
              ),
            )
          : const SegmentedButtonThemeData(),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: accent),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? accent : palette.muted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? accent.withValues(alpha: 0.35)
              : palette.line,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: accent),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: decorative ? Colors.transparent : palette.panel,
        surfaceTintColor: decorative ? Colors.transparent : null,
        indicatorColor: accent.withValues(alpha: decorative ? 0.34 : 0.24),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color:
                states.contains(WidgetState.selected) ? accent : palette.muted,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            color:
                states.contains(WidgetState.selected) ? accent : palette.muted,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: palette.panel,
        surfaceTintColor: accent.withValues(alpha: 0.08),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: accent,
        selectedColor: accent,
      ),
    );
  }

  static ThemeData get dark => forTheme(KaspireTheme.midnight);
}

class _KaspirePalette {
  const _KaspirePalette({
    required this.accent,
    required this.secondary,
    required this.background,
    required this.panel,
    required this.line,
    required this.muted,
  });

  final Color accent;
  final Color secondary;
  final Color background;
  final Color panel;
  final Color line;
  final Color muted;
}
