// Read-only live probe using actual Rust derivation and actual REST proof.
// Run flutter test tool/dotk_probe.dart after building the dotk_derive example.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kasvault_wallet/src/services/dotk_service.dart';

void main() {
  test('live dot.k directory and node proof using native Rust derivation',
      () async {
    final client = http.Client();
    try {
      final service = DotkService(
          client: client,
          nodeBaseUrl: 'https://kaspire.kaslab.space/api',
          derive: (request) async {
            final result =
                await Process.run('../../target/debug/examples/dotk_derive', [
              request['name'].toString(),
              request['ownerType'].toString(),
              request['owner'].toString()
            ]);
            if (result.exitCode != 0) {
              throw StateError('Rust derivation failed: ${result.stderr}');
            }
            return (jsonDecode(result.stdout as String) as Map)
                .cast<String, Object?>();
          });
      final result = await service.resolve('21millioncoven.k');
      expect(result.verified, true);
      final names = await service.namesOf(result.address);
      expect(names.any((name) => name.name == result.name), true);
      // Public data only, never wallet secrets.
      // ignore: avoid_print
      print(jsonEncode({
        'name': result.name,
        'address': result.address,
        'deedAddress': result.deedAddress,
        'outpoint': result.outpoint,
        'holdings': names.length
      }));
    } finally {
      client.close();
    }
  });
}
