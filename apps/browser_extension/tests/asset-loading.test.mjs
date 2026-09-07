import test from 'node:test';
import assert from 'node:assert/strict';
import {walletAssetCategory} from './generated/api.mjs';

test('KRC20 uses the healthy direct mirror, sorts A-Z and does not query unrelated categories', async () => {
  const previous = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async url => {
    calls.push(String(url));
    if (String(url).includes('api.kasplex.org')) throw new Error('Kasplex offline');
    assert.match(String(url), /kcc\.kaslab\.space.*tokenlist/);
    return new Response(JSON.stringify({result:[{tick:'ZZZ',balance:'100',dec:0},{tick:'AAA',balance:'200',dec:0}]}));
  };
  try {
    const rows = await walletAssetCategory('kaspa:test-loading', 'mainnet', 'tokens');
    assert.deepEqual(rows.map(row=>row.symbol), ['AAA','ZZZ']);
    assert.equal(calls.length, 2);
  } finally {globalThis.fetch=previous;}
});

test('invalid fast mirror cannot hide tokens from a slower valid response', async () => {
  const previous=globalThis.fetch;
  globalThis.fetch=async url=>new Response(JSON.stringify(String(url).includes('kcc.kaslab.space')?{}:{result:[{tick:'TEST',dec:8,balance:'100000000'}]}));
  try {assert.equal((await walletAssetCategory('kaspa:test-invalid', 'mainnet', 'tokens'))[0].symbol,'TEST');}
  finally {globalThis.fetch=previous;}
});
