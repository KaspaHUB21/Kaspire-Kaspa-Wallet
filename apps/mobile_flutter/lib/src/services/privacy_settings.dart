import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PrivacySettings {
  static const _key = 'privacy_hide_amounts_v1';
  static final ValueNotifier<bool> hideAmounts = ValueNotifier(false);

  static Future<void> initialize() async {
    hideAmounts.value =
        (await SharedPreferences.getInstance()).getBool(_key) ?? false;
  }

  static Future<void> setHideAmounts(bool value) async {
    hideAmounts.value = value;
    await (await SharedPreferences.getInstance()).setBool(_key, value);
  }
}
