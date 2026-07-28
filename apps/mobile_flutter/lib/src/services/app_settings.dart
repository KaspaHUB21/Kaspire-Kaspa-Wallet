import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum KaspireTheme {
  midnight,
  emerald,
  amethyst,
  sakura,
  crimson,
  phoenix,
  cypherpunk,
}

class AppSettings {
  static const _lockMinutesKey = 'security_lock_minutes_v1';
  static const _showSubwalletsKey = 'wallet_show_subwallets_v1';
  static const _themeKey = 'appearance_theme_v1';

  static final ValueNotifier<int> lockMinutes = ValueNotifier(0);
  static final ValueNotifier<bool> showSubwallets = ValueNotifier(true);
  static final ValueNotifier<KaspireTheme> theme =
      ValueNotifier(KaspireTheme.midnight);

  static Future<void> initialize() async {
    final preferences = await SharedPreferences.getInstance();
    lockMinutes.value = preferences.getInt(_lockMinutesKey) ?? 0;
    showSubwallets.value = preferences.getBool(_showSubwalletsKey) ?? true;
    final stored = preferences.getString(_themeKey);
    theme.value = KaspireTheme.values.firstWhere(
      (item) => item.name == stored,
      orElse: () => KaspireTheme.midnight,
    );
  }

  static Future<void> setLockMinutes(int value) async {
    if (!const {0, 5, 10, 15}.contains(value)) {
      throw ArgumentError.value(value, 'value', 'Unsupported lock interval');
    }
    lockMinutes.value = value;
    await (await SharedPreferences.getInstance())
        .setInt(_lockMinutesKey, value);
  }

  static Future<void> setShowSubwallets(bool value) async {
    showSubwallets.value = value;
    await (await SharedPreferences.getInstance())
        .setBool(_showSubwalletsKey, value);
  }

  static Future<void> setTheme(KaspireTheme value) async {
    theme.value = value;
    await (await SharedPreferences.getInstance())
        .setString(_themeKey, value.name);
  }
}
