import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/kasforge_service.dart';
import 'package:kasvault_wallet/src/services/kasforge_trading.dart';
import 'package:kasvault_wallet/src/services/native_security.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/services/encrypted_store.dart';

class Memory implements EncryptedStore {
  final data = <String, String>{};
  @override
  Future<String?> read(String k) async => data[k];
  @override
  Future<void> write(String k, String v) async {
    data[k] = v;
  }

  @override
  Future<void> delete(String k) async {
    data.remove(k);
  }
}

class Inspector extends NativeSecurity {
  @override
  Future<Map<String, Object?>> preparePskt(Map<String, Object?> request,
      {bool kaspacomReview = false}) async {
    final p = await Process.start('../../target/debug/kasforge_inspect', []);
    p.stdin.write(jsonEncode(request));
    await p.stdin.close();
    final out = p.stdout.transform(utf8.decoder).join(),
        errors = p.stderr.transform(utf8.decoder).join();
    if (await p.exitCode != 0) throw StateError(await errors);
    return Map<String, Object?>.from(jsonDecode(await out) as Map);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test(
      'live Forge curve/pool buy/sell builds pass the independent native review',
      () async {
    NetworkSettings.network.value = KaspaNetwork.tn10;
    const address =
        'kaspatest:qp2srppaehqgjxxw4fyf2ckdzha9nz573eapxw0acg4ntc27cy2w23jck27ql';
    final read = KasForgeService(),
        trade = KasForgeTrading(store: Memory(), security: Inspector());
    final tokens = await read.catalogue();
    for (final cid in [
      'e6f41426e62a3c1250a3d08daf8de3edcaed95e35ff062fec8dc021023b49f53',
      'a846ff488043fb36626c5af59c03782477ff1a91f690168d42d3e241907c1384'
    ]) {
      final token = tokens.singleWhere((t) => t.id == cid);
      for (final side in ['buy', 'sell']) {
        // The public pool fixture has 100% of its tokens in the pool and no
        // funded holder. Never sign a real buy just to manufacture coverage.
        if (token.graduated && side == 'sell') continue;
        final amount = side == 'buy' ? '10' : '100000';
        final quote = await read.quote(token, side, amount);
        final receipt = await trade.build(address, token, side, amount, quote);
        expect(receipt['reviews'], isNotEmpty);
      }
    }
    read.client.close();
    trade.client.close();
  },
      skip: !const bool.fromEnvironment('KASPIRE_FORGE_LIVE'),
      timeout: const Timeout(Duration(minutes: 3)));
}
