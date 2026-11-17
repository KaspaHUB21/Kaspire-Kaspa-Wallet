import 'package:flutter_test/flutter_test.dart';
import '../lib/src/services/pskt_token_review.dart';

void main() {
  test('kUSDT review keeps six decimal units separate from carrier KAS', () {
    final token = <String, Object?>{'ticker':'kUSDT','covenantId':'pinned','decimals':6,'complete':true,'outputsBound':true,'walletNetRaw':'-1',
      'inputs':[{'index':0,'amountRaw':'9007199254740991','walletOwned':true,'reserveSompi':'150000000'}],
      'outputs':[{'index':0,'amountRaw':'1','walletOwned':false,'reserveSompi':'150000000','signatureBound':true}]};
    final text = psktTokenDetails({'tokenReviews':[token]}).join('\n');
    expect(text, contains('-0.000001 kUSDT'));
    expect(text, contains('9007199254.740991 kUSDT'));
    expect(text, contains('1.5 KAS (not token amount)'));
    expect(psktTokenDetails({'tokenReviews':[{...token,'outputsBound':false}]}).join('\n'),contains('NOT FIXED BY THIS SIGNATURE'));
    expect(psktTokenDetails({'tokenReviews':[{...token,'walletNetRaw':null,'complete':false}]}).join('\n'),contains('Unknown does not mean zero'));
    expect(psktTokenDetails({}), isEmpty);
  });
}
