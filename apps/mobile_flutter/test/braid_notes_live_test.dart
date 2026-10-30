import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/braid_service.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';

void main() {
  for (final mainnet in [true, false]) {
    test(
        'live read-only ${mainnet ? 'Mainnet' : 'TN10'} production token-note lookup',
        () async {
      NetworkSettings.network.value =
          mainnet ? KaspaNetwork.mainnet : KaspaNetwork.tn10;
      final service = BraidService();
      try {
        final token = BraidService.tokens[1];
        final data = await service.notes(service.feeAddress, token);
        expect(data['net'], service.net);
        expect(data['tokenId'], token.id);
        expect(data['notes'], isA<List>());
        for (final note in data['notes'] as List) {
          expect(
              BraidService.integer(
                      note['amount'] ?? note['state']?['amount']) >=
                  BigInt.zero,
              isTrue);
        }
        print(
            '${service.net}: verified token identity, ${(data['notes'] as List).length} notes; no signing or submission');
      } finally {
        service.client.close();
      }
    }, skip: Platform.environment['KASPIRE_BRAID_NOTES_LIVE'] != '1');
  }
}
