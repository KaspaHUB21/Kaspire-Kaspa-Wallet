import "package:flutter_test/flutter_test.dart";
import "package:kasvault_wallet/src/services/hd_discovery_service.dart";
import "package:kasvault_wallet/src/services/native_security.dart";

NativeHdAddress address({
  required int index,
  bool used = false,
  bool explicit = false,
  bool receiveRotation = false,
}) =>
    NativeHdAddress(
      address: "kaspa:address-$index",
      derivationPath: "path-$index",
      coinType: 111111,
      account: 0,
      change: 0,
      index: index,
      used: used,
      explicit: explicit,
      receiveRotation: receiveRotation,
    );

void main() {
  test("discovery preserves manually rotated unused receive addresses", () {
    final merged = HdDiscoveryService.mergeRegisteredAddresses(
      [address(index: 0), address(index: 1, used: true)],
      [
        address(index: 0),
        address(index: 2, explicit: true, receiveRotation: true),
      ],
    );

    expect(merged.map((item) => item.index), [0, 1, 2]);
    expect(merged.last.explicit, isTrue);
    expect(merged.last.receiveRotation, isTrue);
  });

  test("discovery keeps rotation metadata when an address becomes used", () {
    final merged = HdDiscoveryService.mergeRegisteredAddresses(
      [address(index: 2, used: true)],
      [address(index: 2, explicit: true, receiveRotation: true)],
    );

    expect(merged.single.used, isTrue);
    expect(merged.single.explicit, isTrue);
    expect(merged.single.receiveRotation, isTrue);
  });

  test("discovery drops old inactive look-ahead addresses", () {
    final merged = HdDiscoveryService.mergeRegisteredAddresses(
      [address(index: 0)],
      [address(index: 7)],
    );

    expect(merged.map((item) => item.index), [0]);
  });
}
