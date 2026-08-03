import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/kaspa_address.dart';

void main() {
  test('encodes a KCC20 owner pubkey as its Kaspa P2PK address', () {
    expect(
      kaspaAddressFromOwnerId(
        '1bacea84ca721c95d67ecace19bc499a77c03726bc8739af637bcd89abaaf058',
      ),
      'kaspa:qqd6e65yefepe9wk0m9vuxdufxd80sphy67gwwd0vdaumzdt4tc9s3qt0lqeh',
    );
  });

  test('rejects malformed owner IDs', () {
    expect(kaspaAddressFromOwnerId('not-a-pubkey'), isEmpty);
  });

  test('decodes a Kaspa P2PK address to its KCC20 owner pubkey', () {
    const owner =
        '1bacea84ca721c95d67ecace19bc499a77c03726bc8739af637bcd89abaaf058';
    const address =
        'kaspa:qqd6e65yefepe9wk0m9vuxdufxd80sphy67gwwd0vdaumzdt4tc9s3qt0lqeh';
    expect(kaspaOwnerIdFromAddress(address), owner);
  });

  test('converts the same wallet safely between Mainnet and TN10', () {
    const mainnet =
        'kaspa:qqd6e65yefepe9wk0m9vuxdufxd80sphy67gwwd0vdaumzdt4tc9s3qt0lqeh';
    final testnet = kaspaAddressWithPrefix(mainnet, 'kaspatest');
    expect(testnet, startsWith('kaspatest:'));
    expect(kaspaOwnerIdFromAddress(testnet), kaspaOwnerIdFromAddress(mainnet));
    expect(kaspaAddressWithPrefix(testnet, 'kaspa'), mainnet);
  });

  test('rejects malformed or checksum-invalid Kaspa addresses', () {
    expect(kaspaOwnerIdFromAddress('kaspa:qtestaddress'), isEmpty);
    expect(
      kaspaOwnerIdFromAddress(
        'kaspa:qqd6e65yefepe9wk0m9vuxdufxd80sphy67gwwd0vdaumzdt4tc9s3qt0lqeq',
      ),
      isEmpty,
    );
  });
}
