import "native_security.dart";
import "network_settings.dart";

class HdAccountScope {
  const HdAccountScope({
    required this.primaryAddress,
    required this.addresses,
  });

  final String primaryAddress;
  final List<NativeHdAddress> addresses;

  List<String> get networkAddresses => addresses
      .map((item) => NetworkSettings.addressForNetwork(item.address))
      .toList(growable: false);

  // Preserve the established single-wallet signing flow. Explicit signer
  // metadata is needed only when one payment spends UTXOs controlled by more
  // than one derived receive address. In particular, imported private-key
  // wallets use the sentinel path "private-key", not a BIP-44 path.
  List<Map<String, Object?>> get transactionSigners => addresses.length < 2
      ? const []
      : addresses
          .map((item) => <String, Object?>{
                "address": NetworkSettings.addressForNetwork(item.address),
                "derivationPath": item.derivationPath,
              })
          .toList(growable: false);

  bool get rotates => addresses.length > 1;
}

class HdAccountService {
  HdAccountService({NativeSecurity? security})
      : _security = security ?? NativeSecurity();

  final NativeSecurity _security;

  Future<HdAccountScope> resolve(String requestedAddress) async {
    final storageAddress = NetworkSettings.storageAddress(requestedAddress);
    for (final wallet in await _security.listWallets()) {
      NativeHdAddress? selected;
      for (final item in wallet.addresses) {
        if (_sameAddress(item.address, storageAddress)) {
          selected = item;
          break;
        }
      }
      if (selected == null && _sameAddress(wallet.address, storageAddress)) {
        selected = wallet.addresses
            .where((item) => item.change == 0 && item.index == 0)
            .firstOrNull;
      }
      if (selected == null) continue;
      if (wallet.kind != "mnemonic" ||
          selected.change != 0 ||
          (selected.index != 0 && !selected.receiveRotation)) {
        return HdAccountScope(
          primaryAddress: NetworkSettings.addressForNetwork(selected.address),
          addresses: [selected],
        );
      }
      final members = wallet.addresses
          .where((item) =>
              item.coinType == selected!.coinType &&
              item.account == selected.account &&
              item.change == 0 &&
              (item.index == 0 || item.receiveRotation))
          .toList()
        ..sort((left, right) => left.index.compareTo(right.index));
      final primary = members.where((item) => item.index == 0).firstOrNull;
      if (primary == null) {
        return HdAccountScope(
          primaryAddress: NetworkSettings.addressForNetwork(selected.address),
          addresses: [selected],
        );
      }
      return HdAccountScope(
        primaryAddress: NetworkSettings.addressForNetwork(primary.address),
        addresses: members,
      );
    }
    return HdAccountScope(
      primaryAddress: requestedAddress,
      addresses: [
        NativeHdAddress(
          address: storageAddress,
          derivationPath: "watch-only",
          coinType: 111111,
          account: 0,
          change: 0,
          index: 0,
        ),
      ],
    );
  }

  bool _sameAddress(String left, String right) =>
      NetworkSettings.storageAddress(left).toLowerCase() ==
      NetworkSettings.storageAddress(right).toLowerCase();
}
