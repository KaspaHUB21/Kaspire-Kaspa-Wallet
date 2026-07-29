import 'package:flutter/material.dart';

import 'services/app_settings.dart';

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
  static Color get panel => _current.panel;
  static Color get line => _current.line;
  static const muted = Color(0xFF82949C);

  static _KaspirePalette _palette(KaspireTheme theme) => switch (theme) {
        KaspireTheme.midnight => _midnight,
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
    final palette = _palette(theme);
    final accent = palette.accent;
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
      primary: accent,
      secondary: palette.secondary,
      surface: palette.panel,
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: BorderSide(color: palette.line),
    );
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide(color: palette.line),
    );
    return ThemeData(
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: palette.background,
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
        backgroundColor: palette.background,
        foregroundColor: scheme.onSurface,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: palette.panel,
        surfaceTintColor: accent.withValues(alpha: 0.08),
        shape: shape,
      ),
      dialogTheme: DialogThemeData(
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
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: accent,
          side: BorderSide(color: accent),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: accent),
      ),
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
        backgroundColor: palette.panel,
        indicatorColor: accent.withValues(alpha: 0.24),
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
