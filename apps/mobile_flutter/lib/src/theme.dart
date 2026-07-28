import 'package:flutter/material.dart';

import 'services/app_settings.dart';

class KasVaultTheme {
  static const mint = Color(0xFF49EACB);
  static const cyan = Color(0xFF37B8FF);
  static const ink = Color(0xFF050A0D);
  static const panel = Color(0xFF0D151A);
  static const line = Color(0xFF1A2A30);
  static const muted = Color(0xFF82949C);

  static ThemeData forTheme(KaspireTheme theme) {
    final accent = switch (theme) {
      KaspireTheme.midnight => mint,
      KaspireTheme.emerald => const Color(0xFF36E39A),
      KaspireTheme.amethyst => const Color(0xFFB56CFF),
      KaspireTheme.sakura => const Color(0xFFFF72B6),
      KaspireTheme.crimson => const Color(0xFFFF5364),
      KaspireTheme.phoenix => const Color(0xFFFF9D42),
      KaspireTheme.cypherpunk => const Color(0xFF39FF14),
    };
    final background = switch (theme) {
      KaspireTheme.amethyst => const Color(0xFF09050E),
      KaspireTheme.sakura => const Color(0xFF10070C),
      KaspireTheme.crimson => const Color(0xFF100607),
      KaspireTheme.phoenix => const Color(0xFF100A05),
      KaspireTheme.cypherpunk => Colors.black,
      _ => ink,
    };
    final surface = Color.alphaBlend(
      accent.withValues(alpha: 0.055),
      panel,
    );
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
      surface: surface,
    );
    return ThemeData(
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      useMaterial3: true,
      fontFamily: 'sans-serif',
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        hintStyle: const TextStyle(color: muted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: accent, width: 1.5),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Color.alphaBlend(
          accent.withValues(alpha: 0.04),
          const Color(0xFF0A1115),
        ),
        indicatorColor: accent.withValues(alpha: 0.2),
        labelTextStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  static ThemeData get dark => forTheme(KaspireTheme.midnight);
}
