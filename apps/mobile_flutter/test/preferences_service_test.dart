import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/preferences_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('stores multiple watch wallets without duplicates', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = PreferencesService();

    await preferences.addWatchWallet('kaspa:qfirst');
    await preferences.addWatchWallet('kaspa:qsecond', name: 'Cold wallet');
    await preferences.addWatchWallet('kaspa:qfirst');

    final wallets = await preferences.getWatchWallets();
    expect(wallets, hasLength(2));
    expect(wallets.first.name, 'Watch wallet 1');
    expect(wallets.last.name, 'Cold wallet');

    await preferences.renameWatchWallet(wallets.last.id, 'Main observer');
    expect((await preferences.getWatchWallets()).last.name, 'Main observer');

    await preferences.removeWatchWallet(wallets.first.id);
    final remaining = await preferences.getWatchWallets();
    expect(remaining.map((wallet) => wallet.address), ['kaspa:qsecond']);
  });
}
