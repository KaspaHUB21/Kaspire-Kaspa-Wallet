import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/kron_dex_service.dart';

void main() {
  test('human display preserves token decimals exactly', () {
    expect(KronDexService.display('420290', 3), '420.29');
    expect(KronDexService.display('420', 0), '420');
    expect(KronDexService.parseAmount('420.29', 3), BigInt.from(420290));
    expect(() => KronDexService.parseAmount('1.1', 0), throwsStateError);
    expect(() => KronDexService.parseAmount('1,000', 3), throwsStateError);
  });
}
