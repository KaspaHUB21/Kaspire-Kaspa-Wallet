import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import init,* as raw from './generated/wasm/kaspa_secure_core.mjs';
import {secureCore} from './generated/secretInputs.mjs';
import {confirmedRocketConflict} from './generated/rocketSwaps.mjs';
const exports=await init({module_or_path:await readFile(new URL('./generated/wasm/kaspa_secure_core_bg.wasm',import.meta.url))});
const core=secureCore(raw,exports.memory);
// Public deterministic key 1 and fake UTXOs only: nothing is broadcast.
const key='private:'+'1'.padStart(64,'0');
for(const kind of ['curve-buy','pool-buy','pool-sell','split','merge']){
  const request=JSON.parse(await readFile(new URL(`../../../crates/kaspa_secure_core/src/fixtures/kasseal-mainnet-${kind}.json`,import.meta.url),'utf8'));
  test(`packaged WASM rebuilds, executes and recovers actual SafeJSON for Kasseal Mainnet ${kind}`,async()=>{
    const review=JSON.parse(core.preparePskt(JSON.stringify(request)));
    assert.equal(review.profile,request.profile);assert(review.reviewHash);
    const signed=JSON.parse(core.signPskt(key,JSON.stringify(request),review.reviewHash));assert.equal(signed.transactionId,review.transactionId);assert(signed.wrpcJson);
    const bytes=signed.wrpcJson,tx=JSON.parse(bytes);
    assert(tx.inputs.length>0);assert(tx.inputs.every(i=>i.previousOutpoint===undefined&&typeof i.transactionId==='string'));
    const get=async url=>{
      if(url.includes('/full-transactions'))return [];
      const origin=url.split('/').at(-1);
      return {transaction_id:origin,is_accepted:true,outputs:tx.inputs.filter(i=>i.transactionId===origin).map(i=>({index:i.index,script_public_key_address:request.sender}))};
    };
    assert.equal(await confirmedRocketConflict(tx,new Set([signed.transactionId]),get),null);
    assert.equal(JSON.stringify(tx),bytes);
    const changed=structuredClone(request);changed.tradeSummary.rawAmount='1';assert.throws(()=>core.signPskt(key,JSON.stringify(changed),review.reviewHash));
  });
}
