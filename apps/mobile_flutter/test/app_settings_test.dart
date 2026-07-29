import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('persists lock interval, display preferences and theme', () async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.initialize();

    await AppSettings.setLockMinutes(15);
    await AppSettings.setShowSubwallets(false);
    await AppSettings.setUppercaseButtons(false);
    await AppSettings.setTheme(KaspireTheme.amethyst);

    AppSettings.lockMinutes.value = 0;
    AppSettings.showSubwallets.value = true;
    AppSettings.uppercaseButtons.value = true;
    AppSettings.theme.value = KaspireTheme.midnight;
    await AppSettings.initialize();

    expect(AppSettings.lockMinutes.value, 15);
    expect(AppSettings.showSubwallets.value, isFalse);
    expect(AppSettings.uppercaseButtons.value, isFalse);
    expect(AppSettings.theme.value, KaspireTheme.amethyst);
  });

  test('rejects unsupported lock intervals', () async {
    await expectLater(AppSettings.setLockMinutes(7), throwsArgumentError);
  });

  test('defaults automatic locking to fifteen minutes', () async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.initialize();

    expect(AppSettings.lockMinutes.value, 15);
    expect(AppSettings.uppercaseButtons.value, isTrue);
  });

  test('persists the last background time across process restarts', () async {
    SharedPreferences.setMockInitialValues({});
    final timestamp = DateTime.utc(2026, 7, 29, 12, 34, 56);

    await AppSettings.recordBackgroundedAt(timestamp);

    expect(await AppSettings.lastBackgroundedAt(), timestamp);
  });

  test('display labels follow the uppercase preference', () {
    AppSettings.uppercaseButtons.value = true;
    expect(buttonLabel('IMPORT WALLET'), 'IMPORT WALLET');

    AppSettings.uppercaseButtons.value = false;
    expect(buttonLabel('IMPORT WALLET'), 'Import Wallet');
    expect(buttonLabel('PAIR DAPP QR'), 'Pair dApp QR');
    expect(displayLabel('ASSETS & NAMES'), 'Assets & Names');
    expect(displayLabel('KRC-20 TOKENS'), 'KRC-20 Tokens');
  });
}
