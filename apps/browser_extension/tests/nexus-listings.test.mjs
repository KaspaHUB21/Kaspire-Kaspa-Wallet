import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { nexusListing, kaspaComNftUrl } from './generated/nexusListings.mjs';
const nft = { collectionId: 'kasgoths', tokenId: '187', listingPriceSompi: '1100000000', marketplaceListing: { source: 'kaspacom', ticker: 'KASGOTHS', tokenId: '187', orderId: 'order-123', priceSompi: '1100000000' } };
test('Nexus recognizes KaspaCom venue and price and opens exactly the NFT on a pinned site', () => {
  assert.equal(nexusListing(nft).venue, 'KaspaCom');
  assert.equal(nexusListing(nft).priceSompi, '1100000000');
  assert.equal(kaspaComNftUrl(nft), 'https://kaspa.com/nft/collections/KASGOTHS/187');
});
test('Nexus continues recognizing Kaspire listings and treats unavailable prices separately', () => {
  const own = { ...nft, marketplaceListing: { ...nft.marketplaceListing, source: 'kaspire' } };
  assert.equal(nexusListing(own).venue, 'Kaspire'); assert.throws(() => kaspaComNftUrl(own));
  assert.equal(nexusListing({ ...nft, marketplaceListing: null, listingPriceUnavailable: true }), null);
});
test('Nexus never opens a wrong token, injected order URL or malformed price', () => {
  for (const mutation of [{ ticker: '../../other' }, { tokenId: '188' }, { orderId: 'https://attacker.invalid' }, { priceSompi: 'NaN' }, { source: 'other' }]) {
    const data = { ...nft, marketplaceListing: { ...nft.marketplaceListing, ...mutation } };
    assert.equal(nexusListing(data), null); assert.throws(() => kaspaComNftUrl(data));
  }
});
test('Nexus uses its shared cached resolver rather than direct KaspaCom card requests', () => {
  const ui = readFileSync(new URL('../src/ui/nexus.ts', import.meta.url), 'utf8');
  assert.match(ui, /nexusListing\(data\)/); assert.doesNotMatch(ui, /fetch\(|api\.kaspa\.com/);
  assert.match(ui, /View current listing/); assert.doesNotMatch(ui, /Buy on Kaspire · review PSKT/);
});
