import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('persists lock interval, subwallet visibility and theme', () async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.initialize();

    await AppSettings.setLockMinutes(15);
    await AppSettings.setShowSubwallets(false);
    await AppSettings.setTheme(KaspireTheme.amethyst);

    AppSettings.lockMinutes.value = 0;
    AppSettings.showSubwallets.value = true;
    AppSettings.theme.value = KaspireTheme.midnight;
    await AppSettings.initialize();

    expect(AppSettings.lockMinutes.value, 15);
    expect(AppSettings.showSubwallets.value, isFalse);
    expect(AppSettings.theme.value, KaspireTheme.amethyst);
  });

  test('rejects unsupported lock intervals', () async {
    await expectLater(AppSettings.setLockMinutes(7), throwsArgumentError);
  });

  test('defaults automatic locking to fifteen minutes', () async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.initialize();

    expect(AppSettings.lockMinutes.value, 15);
  });
}
