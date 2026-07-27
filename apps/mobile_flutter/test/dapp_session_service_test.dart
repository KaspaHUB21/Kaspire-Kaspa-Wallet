import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/dapp_session_service.dart';

void main() {
  final topic = 'a' * 64;
  final symKey = 'b' * 64;

  test('advertises generic reviewed PSKT signing', () {
    expect(
      DappSessionService.supportedMethods,
      contains('kaspa_signPskt'),
    );
  });

  test('accepts raw and verified-link WalletConnect QR payloads', () {
    final pairing = 'wc:$topic@2?relay-protocol=irn&symKey=$symKey';
    expect(
      DappSessionService.pairingUriFromQrPayload(pairing),
      pairing,
    );
    expect(
      DappSessionService.pairingUriFromQrPayload(
        'https://kaspire.kaslab.space/kaspire/wc'
        '?uri=${Uri.encodeQueryComponent(pairing)}',
      ),
      pairing,
    );
  });

  test('rejects hostile and malformed dApp QR payloads', () {
    final invalid = [
      'https://evil.example/kaspire/wc?uri=wc:$topic@2',
      'https://kaspire.kaslab.space/kaspire/wc?uri=one&uri=two',
      'wc:$topic@1?relay-protocol=irn&symKey=$symKey',
      'wc:$topic@2?relay-protocol=evil&symKey=$symKey',
      'not a pairing',
    ];
    for (final payload in invalid) {
      expect(
        () => DappSessionService.pairingUriFromQrPayload(payload),
        throwsA(isA<FormatException>()),
      );
    }
  });

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

  test('adversarial pairing corpus always fails closed', () async {
    final oversized = 'wc:$topic@2?relay-protocol=irn&symKey=${'a' * 3000}';
    final corpus = <String>[
      '',
      'https://example.com',
      'wc:../@2?relay-protocol=irn&symKey=$symKey',
      'wc:$topic@2?relay-protocol=irn&symKey=${'z' * 64}',
      'wc:$topic@2?relay-protocol=evil&symKey=$symKey',
      'wc:$topic@2?relay-protocol=irn&symKey=$symKey#fragment',
      'wc:$topic@2?relay-protocol=irn&relay-protocol=irn&symKey=$symKey',
      oversized,
    ];
    for (final value in corpus) {
      await expectLater(
        DappSessionService.instance.pair(value),
        throwsA(anyOf(isA<FormatException>(), isA<StateError>())),
        reason: value.length > 100 ? 'oversized input' : value,
      );
    }
  });

  test('app-link parser rejects duplicate, fragmented and oversized input',
      () async {
    final links = [
      Uri.parse('https://kaspire.kaslab.space/kaspire/wc?uri=one&uri=two'),
      Uri.parse('https://kaspire.kaslab.space/kaspire/wc?uri=redacted#hidden'),
      Uri.parse(
        'https://kaspire.kaslab.space/kaspire/wc?uri=${Uri.encodeQueryComponent('x' * 3000)}',
      ),
    ];
    for (final link in links) {
      await expectLater(
        DappSessionService.instance.handleAppLink(link),
        throwsA(isA<FormatException>()),
      );
    }
  });
}
