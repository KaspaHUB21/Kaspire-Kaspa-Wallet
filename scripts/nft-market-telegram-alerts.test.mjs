import test from 'node:test';
import assert from 'node:assert/strict';
import {alertCaption, formatKas, initialListingPlan} from './nft-market-telegram-alerts.mjs';

test('formats sompi exactly without floating point rounding', () => {
  assert.equal(formatKas('39900000000'), '399');
  assert.equal(formatKas('12100000001'), '121.00000001');
});

test('initial setup backfills only the newest four listings in chronological order', () => {
  const offers = Array.from({length: 7}, (_, index) => ({createdAt:index, listingTransactionId:String(index)}));
  const plan = initialListingPlan(offers, 4);
  assert.deepEqual(plan.alreadySeen.map(x => x.listingTransactionId), ['0','1','2']);
  assert.deepEqual(plan.backfill.map(x => x.listingTransactionId), ['3','4','5','6']);
});

test('captions contain escaped identity, rank and exact KAS price', () => {
  const caption = alertCaption('listing', {ticker:'KDC<',tokenId:'778',rarityRank:501,priceSompi:'12100000000'});
  assert.match(caption, /KDC&lt; #778/);
  assert.match(caption, /#501/);
  assert.match(caption, /121 KAS/);
});
