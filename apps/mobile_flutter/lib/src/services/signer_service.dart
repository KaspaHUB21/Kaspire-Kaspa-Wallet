import 'native_security.dart';

class PreparedPayment {
  const PreparedPayment({
    required this.request,
    required this.reviewHash,
    required this.amountSompi,
    required this.feeSompi,
    required this.changeSompi,
    required this.mass,
    required this.inputCount,
    required this.outputCount,
  });

  final Map<String, Object?> request;
  final String reviewHash;
  final int amountSompi;
  final int feeSompi;
  final int changeSompi;
  final int mass;
  final int inputCount;
  final int outputCount;

  double get amountKas => amountSompi / 100000000;
  double get feeKas => feeSompi / 100000000;
  double get changeKas => changeSompi / 100000000;
}

class SignedPayment {
  const SignedPayment({required this.transactionId, required this.submitJson});
  final String transactionId;
  final String submitJson;
}

class SignerService {
  SignerService({NativeSecurity? security})
      : _security = security ?? NativeSecurity();
  final NativeSecurity _security;

  Future<PreparedPayment> prepare({
    required String sender,
    required String recipient,
    required int amountSompi,
    required double feeRate,
    required String utxosJson,
    bool sendAll = false,
  }) async {
    final request = <String, Object?>{
      'sender': sender,
      'recipient': recipient,
      'amountSompi': amountSompi,
      'feeRate': feeRate,
      'utxosJson': utxosJson,
      'sendAll': sendAll,
    };
    final result = await _security.prepareTransaction(request);
    int integer(String key) => (result[key] as num).toInt();
    return PreparedPayment(
      request: request,
      reviewHash: result['reviewHash']! as String,
      amountSompi: integer('amountSompi'),
      feeSompi: integer('feeSompi'),
      changeSompi: integer('changeSompi'),
      mass: integer('mass'),
      inputCount: integer('inputCount'),
      outputCount: integer('outputCount'),
    );
  }

  Future<SignedPayment> sign(PreparedPayment payment) async {
    final result = await _security.signTransaction(
      payment.request,
      payment.reviewHash,
    );
    return SignedPayment(
      transactionId: result['transactionId']! as String,
      submitJson: result['submitJson']! as String,
    );
  }
}
