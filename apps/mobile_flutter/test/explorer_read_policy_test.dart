import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/explorer_read_policy.dart';

void main() {
  test(
      'read-only explorer allowlist cannot access signing, sessions or arbitrary targets',
      () {
    for (final url in [
      'https://kaspatoken.kaslab.space/api/tokens?layer=KRC20',
      'https://kaspanftnexus.com/api/collections/hash/tokens?limit=24',
      'https://kaspanftnexus.com/api/collections/hash/traits',
      'https://kaspire.kaslab.space/api/explorer/blockdag',
      'https://kaspire.kaslab.space/api/local-node/transactions/${'a' * 64}?inputs=true&outputs=true&resolve_previous_outpoints=light&blockHash=${'b' * 64}',
      'https://kaspire.kaslab.space/api/local-node/transactions/${'a' * 64}'
    ]) {
      expect(explorerReadAllowed('GET', Uri.parse(url)), true, reason: url);
    }
    for (final url in [
      'https://evil.test/api/tokens',
      'https://kaspatoken.kaslab.space.evil.test/api/tokens',
      'http://kaspatoken.kaslab.space/api/tokens',
      'https://user@kaspatoken.kaslab.space/api/tokens',
      'https://kaspanftnexus.com/api/auth/session',
      'https://kaspire.kaslab.space/api/native-kusdt/submit',
      'https://kaspire.kaslab.space/api/explorer/blockdag?rpc=submitTransaction',
      'https://kaspire.kaslab.space/api/explorer/blockdag/submit',
      'https://kaspanftnexus.com/api/offers'
    ]) {
      expect(explorerReadAllowed('GET', Uri.parse(url)), false, reason: url);
      expect(explorerReadAllowed('POST', Uri.parse(url)), false, reason: url);
    }
    expect(
        explorerReadAllowed('POST',
            Uri.parse('https://kaspire.kaslab.space/api/explorer/blockdag')),
        false);
    expect(
        explorerReadAllowed('POST',
            Uri.parse('https://kaspanftnexus.com/api/collections/resolve')),
        true);
    expect(
        explorerReadAllowed(
            'POST',
            Uri.parse(
                'https://kaspire.kaslab.space/api/local-node/transactions/${'a' * 64}')),
        false);
  });
}
