import assert from 'node:assert/strict';
import test from 'node:test';
import { sortedAssets, assetTicker, sameAsset } from './generated/assetPresentation.mjs';

test('all token categories sort A–Z without mutating source or signing fields', () => {
  const assets = [{symbol:'Zulu',covenantId:'2'}, {symbol:'burtle',covenantId:'3'}, {symbol:'KASBTC',covenantId:'1'}];
  const original = structuredClone(assets);
  assert.deepEqual(sortedAssets(assets).map(x=>assetTicker(x.symbol)), ['BURTLE','KASBTC','ZULU']);
  assert.deepEqual(assets, original);
  assert.equal(sortedAssets(assets)[0], assets[1]);
});
test('KNS names retain their case and are sorted independently', () => {
  const names = [{name:'zulu.kas'}, {name:'Alpha.kas'}, {name:'beta.kas'}];
  assert.deepEqual(sortedAssets(names).map(x=>x.name), ['Alpha.kas','beta.kas','zulu.kas']);
});
test('identical tickers have stable covenant ordering and are not dropped', () => {
  const assets=[{symbol:'ABC',covenantId:'b'}, {symbol:'abc',covenantId:'a'}];
  assert.deepEqual(sortedAssets(assets).map(x=>x.covenantId), ['a','b']);
  assert.equal(assetTicker(' Kasbtc '),'KASBTC');
});

test('send preselection ignores ticker casing but distinguishes covenant IDs', () => {
  assert(sameAsset({symbol:'Kasbtc'}, {symbol:'KASBTC'}, 'krc20'));
  assert(!sameAsset({symbol:'ABC',covenantId:'a'}, {symbol:'ABC',covenantId:'b'}, 'kcc20'));
  assert(!sameAsset({name:'one.kas'}, {name:'two.kas'}, 'kns'));
});
