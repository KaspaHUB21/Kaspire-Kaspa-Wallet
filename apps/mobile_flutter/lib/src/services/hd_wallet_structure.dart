import 'native_security.dart';

class HdReceiveGroup {
  const HdReceiveGroup({
    required this.coinType,
    required this.account,
    required this.addresses,
  });

  final int coinType;
  final int account;
  final List<NativeHdAddress> addresses;
}

class HdWalletStructure {
  const HdWalletStructure._();

  static List<HdReceiveGroup> receiveGroups(
    Iterable<NativeHdAddress> source,
  ) {
    final all = source.toList();
    final grouped = <(int, int), List<NativeHdAddress>>{};
    final activeGroups = <(int, int)>{
      for (final item in all.where((item) => item.used || item.explicit))
        (item.coinType, item.account),
      (111111, 0),
    };
    for (final address in all.where((item) {
      final key = (item.coinType, item.account);
      return activeGroups.contains(key) &&
          item.change == 0 &&
          (item.index == 0 || item.used || item.explicit);
    })) {
      grouped.putIfAbsent(
          (address.coinType, address.account), () => []).add(address);
    }
    final keys = grouped.keys.toList()
      ..sort((left, right) {
        final coin = left.$1.compareTo(right.$1);
        return coin != 0 ? coin : left.$2.compareTo(right.$2);
      });
    return keys.map((key) {
      final addresses = grouped[key]!
        ..sort((left, right) => left.index.compareTo(right.index));
      return HdReceiveGroup(
        coinType: key.$1,
        account: key.$2,
        addresses: addresses,
      );
    }).toList();
  }

  static int nextSubwalletIndex(
    Iterable<NativeHdAddress> source, {
    required int coinType,
    required int account,
  }) {
    final all = source.toList();
    final groupActive = (coinType == 111111 && account == 0) ||
        all.any(
          (item) =>
              item.coinType == coinType &&
              item.account == account &&
              (item.used || item.explicit),
        );
    if (!groupActive) return 0;
    final indices = all
        .where(
          (item) =>
              item.coinType == coinType &&
              item.account == account &&
              item.change == 0 &&
              (item.index == 0 || item.used || item.explicit),
        )
        .map((item) => item.index);
    return indices.isEmpty ? 0 : indices.reduce((a, b) => a > b ? a : b) + 1;
  }
}
