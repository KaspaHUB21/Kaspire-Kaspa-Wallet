import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/models/wallet_snapshot.dart';

void main() {
  for (final kind in ['KRC-20', 'KRC-721', 'KCC20']) {
    test('$kind is sorted A–Z, with deterministic ties and no mutation', () {
      final input = [
        WalletAsset(symbol: 'ZZZ', balance: 1, kind: kind, id: 'z'),
        WalletAsset(symbol: 'AAA', balance: 1, kind: kind, id: 'b'),
        WalletAsset(symbol: 'aaa', balance: 1, kind: kind, id: 'a'),
        WalletAsset(symbol: 'MMM', balance: 1, kind: kind, id: 'm'),
      ];
      final sorted = alphabeticalWalletAssets(input);
      expect(sorted.map((asset) => asset.id), ['a', 'b', 'm', 'z']);
      expect(input.first.id, 'z');
    });
  }
}
