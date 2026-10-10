import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('persists lock interval, display preferences and theme', () async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.initialize();

    await AppSettings.setLockMinutes(15);
    await AppSettings.setShowSubwallets(false);
    await AppSettings.setFiatCurrency(FiatCurrency.eur);
    await AppSettings.setRecipientAllowlist(true);
    await AppSettings.setTheme(KaspireTheme.amethyst);

    AppSettings.lockMinutes.value = 0;
    AppSettings.showSubwallets.value = true;
    AppSettings.fiatCurrency.value = FiatCurrency.usd;
    AppSettings.theme.value = KaspireTheme.midnight;
    AppSettings.recipientAllowlist.value = false;
    await AppSettings.initialize();

    expect(AppSettings.lockMinutes.value, 15);
    expect(AppSettings.showSubwallets.value, isFalse);
    expect(AppSettings.fiatCurrency.value, FiatCurrency.eur);
    expect(AppSettings.theme.value, KaspireTheme.amethyst);
    expect(AppSettings.recipientAllowlist.value, isTrue);
  });

  test('removes the retired uppercase preference on upgrade', () async {
    SharedPreferences.setMockInitialValues(
        {'appearance_uppercase_buttons_v1': true});
    await AppSettings.initialize();
    expect(buttonLabel('SEND'), 'Send');
    expect(buttonLabel('PAIR DAPP'), 'Pair dApp');
    expect(
        (await SharedPreferences.getInstance())
            .containsKey('appearance_uppercase_buttons_v1'),
        isFalse);
  });

  test('rejects unsupported lock intervals', () async {
    await expectLater(AppSettings.setLockMinutes(7), throwsArgumentError);
  });

  test('defaults automatic locking to fifteen minutes', () async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.initialize();

    expect(AppSettings.lockMinutes.value, 15);
    expect(AppSettings.fiatCurrency.value, FiatCurrency.usd);
    expect(AppSettings.recipientAllowlist.value, isFalse);
  });

  test('persists the last background time across process restarts', () async {
    SharedPreferences.setMockInitialValues({});
    final timestamp = DateTime.utc(2026, 7, 29, 12, 34, 56);

    await AppSettings.recordBackgroundedAt(timestamp);

    expect(await AppSettings.lastBackgroundedAt(), timestamp);
  });

  test('display labels always use conventional capitalization', () {
    expect(buttonLabel('IMPORT WALLET'), 'Import Wallet');
    expect(buttonLabel('PAIR DAPP QR'), 'Pair dApp QR');
    expect(displayLabel('ASSETS & NAMES'), 'Assets & Names');
    expect(displayLabel('KRC-20 TOKENS'), 'KRC-20 Tokens');
    expect(buttonLabel('K-AGORA'), 'K-Agora');
  });
}
