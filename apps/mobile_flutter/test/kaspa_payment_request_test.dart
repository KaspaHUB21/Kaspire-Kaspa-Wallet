import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/models/kaspa_payment_request.dart';

void main() {
  const address =
      'kaspa:qz03mracsz6c0pjxmsdaql39453tn3jgmrldkqpy24ea39rxtvd9xxynslpyc';

  test('parses a Kaspa address and optional amount', () {
    final plain = KaspaPaymentRequest.tryParse(address);
    expect(plain?.address, address);
    expect(plain?.amount, isNull);

    final request = KaspaPaymentRequest.tryParse('$address?amount=3.125');
    expect(request?.address, address);
    expect(request?.amount, '3.125');
  });

  test('rejects malformed, over-precise and encoded query values', () {
    expect(KaspaPaymentRequest.tryParse('$address?amount=1.000000001'), isNull);
    expect(KaspaPaymentRequest.tryParse('$address?amount=%ZZ'), isNull);
    expect(KaspaPaymentRequest.tryParse('https://example.com'), isNull);
    expect(
      KaspaPaymentRequest.tryParse('$address?amount=1&amount=2'),
      isNull,
    );
    expect(
      KaspaPaymentRequest.tryParse('$address?amount=1&redirect=https://evil'),
      isNull,
    );
  });

  test('adversarial QR corpus cannot smuggle fields or invalid amounts', () {
    for (final value in [
      '$address?amount=-1',
      '$address?amount=NaN',
      '$address?amount=1e8',
      '$address?amount=0.000000001',
      '$address?amount=1%00',
      '$address?amount=${'9' * 10000}',
      'kaspa:../../etc/passwd',
      '$address#amount=1',
    ]) {
      expect(KaspaPaymentRequest.tryParse(value), isNull, reason: value);
    }
  });

  test('encodes an amount using an English decimal point', () {
    expect(
      KaspaPaymentRequest.encode(address, amount: '1,25'),
      '$address?amount=1.25',
    );
  });
}
