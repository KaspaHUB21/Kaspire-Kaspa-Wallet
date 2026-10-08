import {test} from 'node:test';
import assert from 'node:assert/strict';
import {compareNftListings} from './nft-market-sort.mjs';
const rows = [{createdAt: 1, rarityRank: null, priceSompi: 5}, {createdAt: 4, rarityRank: 10, priceSompi: 3}, {createdAt: 2, rarityRank: -1, priceSompi: 7}, {createdAt: 3, rarityRank: 1, priceSompi: 2}];
test('newest first; prices retain legacy ascending/descending behavior', () => {
  assert.deepEqual([...rows].sort(compareNftListings).map(r=>r.createdAt), [4,3,2,1]);
  assert.deepEqual([...rows].sort((a,b)=>compareNftListings(a,b,'low')).map(r=>r.priceSompi), [2,3,5,7]);
});
test('rank sorting always puts unavailable ranks last', () => {
  assert.deepEqual([...rows].sort((a,b)=>compareNftListings(a,b,'rank-low')).map(r=>r.rarityRank), [-1,1,10,null]);
  assert.deepEqual([...rows].sort((a,b)=>compareNftListings(a,b,'rank-high')).map(r=>r.rarityRank), [10,1,-1,null]);
});
test('price pagination is global, not limited to the first loaded ten NFTs', () => {
  const inventory=Array.from({length:35},(_,i)=>({priceSompi:(35-i)*100000000,createdAt:i,listingTransactionId:String(i)}));
  const cheap=[...inventory].sort((a,b)=>compareNftListings(a,b,'low'));
  const costly=[...inventory].sort((a,b)=>compareNftListings(a,b,'high'));
  assert.deepEqual(cheap.slice(0,10).map(r=>r.priceSompi/100000000),[1,2,3,4,5,6,7,8,9,10]);
  assert.deepEqual(cheap.slice(10,20).map(r=>r.priceSompi/100000000),[11,12,13,14,15,16,17,18,19,20]);
  assert.deepEqual(costly.slice(0,10).map(r=>r.priceSompi/100000000),[35,34,33,32,31,30,29,28,27,26]);
});
