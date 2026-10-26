import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/braid_service.dart';
import 'package:kasvault_wallet/src/services/encrypted_store.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';

class _Memory implements EncryptedStore {
  final data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async {
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }
}

void main() {
  test('Braid real TN10 identity, independent clocks and KAS/token quote',
      () async {
    NetworkSettings.network.value = KaspaNetwork.tn10;
    final s = BraidService(store: _Memory());
    await s.info();
    final clocks = await s.clock.read();
    expect((clocks[0] - clocks[1]).abs(), lessThanOrEqualTo(600));
    final q = await s.quote(
        'kaspatest:qp2srppaehqgjxxw4fyf2ckdzha9nz573eapxw0acg4ntc27cy2w23jck27ql',
        BraidService.tokens[0],
        BraidService.tokens[1],
        '3000000000',
        100);
    expect(BraidService.integer(q['localFloor']) > BigInt.zero, true);
    const address =
        'kaspatest:qp2srppaehqgjxxw4fyf2ckdzha9nz573eapxw0acg4ntc27cy2w23jck27ql';
    // Only an unsigned builder call for a public reference wallet. No wallet
    // secret, signing operation, submission or broadcast exists in this test.
    final receipt = await s.build(address, q);
    final process = await Process.start('../../target/debug/braid_inspect', []);
    process.stdin.write(jsonEncode(receipt['request']));
    await process.stdin.close();
    final output = await process.stdout.transform(utf8.decoder).join();
    final errors = await process.stderr.transform(utf8.decoder).join();
    expect(await process.exitCode, 0, reason: errors);
    final review = jsonDecode(output) as Map;
    expect(review['transactionId'], (receipt['build'] as Map)['depositTxid']);
    expect(review['finalFeeKnown'], true);
    s.client.close();
  },
      skip: !const bool.fromEnvironment('KASPIRE_BRAID_LIVE'),
      timeout: const Timeout(Duration(seconds: 60)));
}
