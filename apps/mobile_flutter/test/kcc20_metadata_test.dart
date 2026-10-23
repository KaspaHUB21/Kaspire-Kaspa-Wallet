import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/kcc20_metadata.dart';

void main() {
  final cid =
      '82f033aed87d6eb39f509b51b1c817a49e0b07c4789b619cab08d4c8fb82d18e';
  final source = {
    'covenant_id': cid,
    'name': 'brave-cobalt-urchin',
    'kcc23': {
      'binding': 'verified',
      'declaration': jsonEncode({
        'name': 'Kaspire',
        'ticker': 'KASPIREISTHEBESTKASPAWALLET',
        'decimals': 8
      })
    }
  };
  test('Verified KCC23 ticker wins over the Kascov technical alias', () {
    final m = verifiedKascovDeclaration(cid, source)!;
    expect(m['ticker'], 'KASPIREISTHEBESTKASPAWALLET');
    expect(m['decimals'], 8);
  });
  test('Foreign or unbound declarations cannot rename assets', () {
    expect(verifiedKascovDeclaration('a' * 64, source), isNull);
    expect(
        verifiedKascovDeclaration(cid, {
          ...source,
          'kcc23': {...(source['kcc23'] as Map), 'binding': 'unverified'}
        }),
        isNull);
    for (final text in [
      'not json',
      jsonEncode({'ticker': '<script>', 'decimals': 8}),
      jsonEncode({'ticker': 'WALLET', 'decimals': 99})
    ]) {
      expect(
          verifiedKascovDeclaration(cid, {
            ...source,
            'kcc23': {'binding': 'verified', 'declaration': text}
          }),
          isNull);
    }
  });
}
