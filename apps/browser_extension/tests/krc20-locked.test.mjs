import test from 'node:test';
import assert from 'node:assert/strict';
import {walletAssetCategory} from './generated/api.mjs';
import {lockedTokenLabel} from './generated/tokenAmount.mjs';
test('KRC20 includes locked-only tokens, exact formatting, refresh bypass and zero clearing',async t=>{
 const old=globalThis.fetch;t.after(()=>globalThis.fetch=old);let count=0,locked='2100000000';
 globalThis.fetch=async(url,options)=>{
  assert.match(String(url),/api\.kasplex\.org\/v1\/krc20\/address\//);assert.equal(options.cache,'no-store');count++;
  return Response.json({result:[{tick:'KASBTC',dec:8,balance:'100000000',locked},{tick:'SOULS',dec:8,balance:'0',locked:'200000000000'},{tick:'MISSING',dec:8,locked:'100'}]});
 };
 const read=(fresh=false)=>walletAssetCategory('kaspa:locked-refresh','mainnet','tokens',fresh);
 let rows=await read();assert.equal(count,1);assert.equal(rows.length,2);
 assert.equal(lockedTokenLabel(rows[0]),'+21 KASBTC locked');assert.equal(rows[0].raw_balance,'100000000');
 assert.equal(lockedTokenLabel(rows[1]),'+2,000 SOULS locked');assert.equal(rows[1].balance,0);
 locked='9000000000';assert.equal((await read())[0].raw_locked_balance,'2100000000');assert.equal(count,1);
 rows=await read(true);assert.equal(count,2);assert.equal(lockedTokenLabel(rows[0]),'+90 KASBTC locked');
 locked='0';rows=await read(true);assert.equal(lockedTokenLabel(rows[0]),null);
 assert.equal(lockedTokenLabel(rows[1],true),'•••••• locked');
});
test('older pending read cannot overwrite the force-refreshed cache',async t=>{
 const old=globalThis.fetch;t.after(()=>globalThis.fetch=old);let finish,reads=0;
 globalThis.fetch=async()=>{const call=++reads;if(call===1)await new Promise(r=>finish=r);return Response.json({result:[{tick:'TEST',dec:0,balance:'1',locked:call===1?'21':'90'}]});};
 const read=(fresh=false)=>walletAssetCategory('kaspa:locked-race','mainnet','tokens',fresh);
 const pending=read();await new Promise(r=>setTimeout(r,0));
 assert.equal((await read(true))[0].raw_locked_balance,'90');finish();await pending;
 assert.equal((await read())[0].raw_locked_balance,'90');assert.equal(reads,2);
});
