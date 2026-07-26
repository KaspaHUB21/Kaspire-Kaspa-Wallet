import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/hd_wallet_structure.dart';
import 'package:kasvault_wallet/src/services/native_security.dart';

NativeHdAddress address({
  required int account,
  required int index,
  int coinType = 111111,
  int change = 0,
  bool used = false,
  bool explicit = false,
}) =>
    NativeHdAddress(
      address: 'kaspa:$coinType-$account-$change-$index',
      derivationPath: "m/44'/$coinType'/$account'/$change/$index",
      coinType: coinType,
      account: account,
      change: change,
      index: index,
      used: used,
      explicit: explicit,
    );

void main() {
  test('groups KasWare address-index subwallets under their BIP-44 account',
      () {
    final groups = HdWalletStructure.receiveGroups([
      address(account: 0, index: 2, used: true),
      address(account: 1, index: 0, explicit: true),
      address(account: 0, index: 0),
      address(account: 0, index: 1, used: true),
      address(account: 0, index: 1, change: 1),
    ]);

    expect(groups, hasLength(2));
    expect(groups[0].account, 0);
    expect(groups[0].addresses.map((item) => item.index), [0, 1, 2]);
    expect(groups[1].account, 1);
    expect(groups[1].addresses.single.index, 0);
  });

  test('creates the next receive index without confusing it with an account',
      () {
    final source = [
      address(account: 0, index: 0),
      address(account: 0, index: 1, used: true),
      address(account: 0, index: 2, explicit: true),
      address(account: 1, index: 8),
      address(account: 0, index: 9, change: 1),
    ];

    expect(
      HdWalletStructure.nextSubwalletIndex(
        source,
        coinType: 111111,
        account: 0,
      ),
      3,
    );
  });

  test('ignores unused gap-limit lookahead addresses from older imports', () {
    final source = [
      address(account: 0, index: 0),
      address(account: 0, index: 1, used: true),
      for (var index = 2; index < 20; index++)
        address(account: 0, index: index),
    ];

    final group = HdWalletStructure.receiveGroups(source).single;
    expect(group.addresses.map((item) => item.index), [0, 1]);
    expect(
      HdWalletStructure.nextSubwalletIndex(
        source,
        coinType: 111111,
        account: 0,
      ),
      2,
    );
  });

  test('hides the unused terminal account scanned by an older release', () {
    final source = [
      address(account: 0, index: 0),
      for (var index = 0; index < 20; index++)
        address(account: 1, index: index),
    ];

    final groups = HdWalletStructure.receiveGroups(source);
    expect(groups.map((item) => item.account), [0]);
  });

  test('keeps an explicitly created BIP-44 account separate', () {
    final groups = HdWalletStructure.receiveGroups([
      address(account: 0, index: 0),
      address(account: 1, index: 0, explicit: true),
    ]);

    expect(groups.map((item) => item.account), [0, 1]);
  });
}
