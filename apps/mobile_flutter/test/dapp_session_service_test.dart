import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/dapp_session_service.dart';

void main() {
  final topic = 'a' * 64;
  final symKey = 'b' * 64;

  test('rejects untrusted app-link origins before reading pairing data',
      () async {
    await expectLater(
      DappSessionService.instance.handleAppLink(
        Uri.parse('https://evil.example/kaspire/wc?uri=redacted'),
      ),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      DappSessionService.instance.handleAppLink(
        Uri.parse('kaspire://evil?uri=redacted'),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('accepts only the dedicated Kaspire custom-scheme route', () async {
    await expectLater(
      DappSessionService.instance.handleAppLink(
        Uri.parse('kaspire://wc?uri=redacted'),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'Invalid WalletConnect URI.',
        ),
      ),
    );
  });

  test('accepts the canonical and legacy verified HTTPS routes', () async {
    for (final host in ['kaspire.kaslab.space', 'kaslab.space']) {
      await expectLater(
        DappSessionService.instance.handleAppLink(
          Uri.parse('https://$host/kaspire/wc?uri=redacted'),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Invalid WalletConnect URI.',
          ),
        ),
      );
    }
  });

  test('accepts the query-free dApp wake route', () async {
    await DappSessionService.instance
        .handleAppLink(Uri.parse('kaspire://dapp'));
    await expectLater(
      DappSessionService.instance.handleAppLink(
        Uri.parse('kaspire://dapp?uri=must-not-be-accepted'),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects WalletConnect v1 and unknown pairing fields', () async {
    await expectLater(
      DappSessionService.instance.pair(
        'wc:$topic@1?relay-protocol=irn&symKey=$symKey',
      ),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      DappSessionService.instance.pair(
        'wc:$topic@2?relay-protocol=irn&symKey=$symKey&callback=https://evil.example',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects expired pairing URIs', () async {
    await expectLater(
      DappSessionService.instance.pair(
        'wc:$topic@2?relay-protocol=irn&symKey=$symKey&expiryTimestamp=1',
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
