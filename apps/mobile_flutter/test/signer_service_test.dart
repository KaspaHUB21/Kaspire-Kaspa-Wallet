import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/signer_service.dart';

void main() {
  test('prepared payment exposes exact sompi values as KAS', () {
    final payment = PreparedPayment(
      request: const <String, Object?>{},
      reviewHash:
          '0000000000000000000000000000000000000000000000000000000000000000',
      amountSompi: 123456789,
      feeSompi: 1000,
      changeSompi: 42,
      mass: 2036,
      inputCount: 1,
      outputCount: 2,
    );

    expect(payment.amountKas, 1.23456789);
    expect(payment.feeKas, 0.00001);
    expect(payment.changeKas, 0.00000042);
  });
}
