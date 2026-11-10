import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/models/evm_address.dart';

void main() {
  const address = '0x17Ec7E1768c813E2a3a9b0f94A35605CA520C242';
  test('accepts plain Igra/Kasplex QR addresses without altering case', () {
    expect(EvmAddress.tryParse(address), address);
    expect(EvmAddress.tryParse('  $address\n'), address);
    expect(EvmAddress.tryParse(address.toLowerCase()), address.toLowerCase());
  });
  test('rejects L1, malformed addresses and payment/function URIs', () {
    for (final value in [
      'kaspa:qqre4wt08dp0rvmxwqgwdkz4zu4m36g9uvmfledd27mx939uxe2yjpmmd37zq',
      address.substring(1),
      '${address}0',
      '${address.substring(0, 41)}g',
      '$address\n$address',
      '$address?amount=1',
      'ethereum:$address@38833',
      'ethereum:$address/transfer?address=$address',
      'https://example.com/$address',
      '',
    ]) {
      expect(EvmAddress.tryParse(value), isNull, reason: value);
    }
  });
}
