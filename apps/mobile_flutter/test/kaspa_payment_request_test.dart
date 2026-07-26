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
  });

  test('encodes an amount using an English decimal point', () {
    expect(
      KaspaPaymentRequest.encode(address, amount: '1,25'),
      '$address?amount=1.25',
    );
  });
}
