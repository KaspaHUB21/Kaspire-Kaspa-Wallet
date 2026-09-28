import "package:flutter_test/flutter_test.dart";
import "package:kasvault_wallet/src/services/hd_account_service.dart";
import "package:kasvault_wallet/src/services/native_security.dart";

const primary =
    "kaspa:qz03mracsz6c0pjxmsdaql39453tn3jgmrldkqpy24ea39rxtvd9xxynslpyc";
const rotated =
    "kaspa:qqd6e65yefepe9wk0m9vuxdufxd80sphy67gwwd0vdaumzdt4tc9s3qt0lqeh";
const subwallet =
    "kaspa:qypm6qg6p6r9j0x94qg2k8mq6rmwa3zkhlu3xmuac2p7vuqhuh9rqzq7n3t8a";

NativeHdAddress hd(
  String address,
  int index, {
  bool receiveRotation = false,
}) =>
    NativeHdAddress(
      address: address,
      derivationPath: "path-$index",
      coinType: 111111,
      account: 0,
      change: 0,
      index: index,
      explicit: index > 0,
      receiveRotation: receiveRotation,
    );

class FakeNativeSecurity extends NativeSecurity {
  @override
  Future<List<NativeWalletInfo>> listWallets() async => [
        NativeWalletInfo(
          id: "wallet",
          address: primary,
          name: "Wallet 1",
          kind: "mnemonic",
          active: true,
          addresses: [
            hd(primary, 0),
            hd(rotated, 1, receiveRotation: true),
            hd(subwallet, 2),
          ],
        ),
      ];
}

class FakePrivateKeySecurity extends NativeSecurity {
  @override
  Future<List<NativeWalletInfo>> listWallets() async => [
        NativeWalletInfo(
          id: "private",
          address: primary,
          name: "Imported key",
          kind: "private-key",
          active: true,
          addresses: [
            NativeHdAddress(
              address: primary,
              derivationPath: "private-key",
              coinType: 111111,
              account: 0,
              change: 0,
              index: 0,
            ),
          ],
        ),
      ];
}

void main() {
  test("primary and rotated addresses resolve to one KAS account", () async {
    final service = HdAccountService(security: FakeNativeSecurity());

    final fromPrimary = await service.resolve(primary);
    final fromRotated = await service.resolve(rotated);

    expect(fromPrimary.primaryAddress, primary);
    expect(fromPrimary.networkAddresses, [primary, rotated]);
    expect(fromRotated.primaryAddress, primary);
    expect(fromRotated.networkAddresses, [primary, rotated]);
    expect(fromPrimary.transactionSigners, [
      {"address": primary, "derivationPath": "path-0"},
      {"address": rotated, "derivationPath": "path-1"},
    ]);
  });

  test("private-key wallets keep the established single-signer flow", () async {
    final account = await HdAccountService(security: FakePrivateKeySecurity())
        .resolve(primary);

    expect(account.primaryAddress, primary);
    expect(account.networkAddresses, [primary]);
    expect(account.transactionSigners, isEmpty);
  });

  test("ordinary address-index subwallet remains separate", () async {
    final account = await HdAccountService(security: FakeNativeSecurity())
        .resolve(subwallet);

    expect(account.primaryAddress, subwallet);
    expect(account.networkAddresses, [subwallet]);
    expect(account.transactionSigners, isEmpty);
  });
}
