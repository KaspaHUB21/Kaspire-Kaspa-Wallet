import test from 'node:test';
import assert from 'node:assert/strict';
import {completion,marketAnalytics,REGISTRY,discoverCompletion} from './dotk-market-analytics.mjs';
const offer={listingTxId:'1'.repeat(64),terms:{name:'example',seller:'seller',feeAddress:'fee',priceSompi:3000000000}};
const tx={transaction_id:'2'.repeat(64),is_accepted:true,accepting_block_time:Date.UTC(2026,8,15,12),
  inputs:[0,1].map(i=>({previous_outpoint_hash:offer.listingTxId,previous_outpoint_index:String(i)})),
  outputs:[{index:0,amount:100000000,covenant_id:REGISTRY,script_public_key:'buyer',script_public_key_address:'buyer-deed'},
    {index:1,amount:3037000000,covenant_id:null,script_public_key_address:'seller'},
    {index:2,amount:63000000,covenant_id:null,script_public_key_address:'fee'}]};
test('requires accepted spend of exact listing pair and exact payouts',()=>{
  assert.equal(completion(offer,tx,'seller-deed').status,'sold');
  for(const mutate of [t=>t.is_accepted=false,t=>t.inputs.pop(),t=>t.inputs.push(t.inputs[0]),
    t=>t.outputs[2].amount++,t=>t.outputs[1].script_public_key_address='other',
    t=>t.outputs[0].covenant_id='fake',t=>t.accepting_block_time=null]){
    const t=structuredClone(tx); mutate(t); assert.equal(completion(offer,t,'seller-deed'),null);
  }
});
test('cancel is not a sale',()=>{
  const t=structuredClone(tx);t.outputs[0].script_public_key='seller-deed';t.outputs[1].amount=100000000;
  const done=completion(offer,t,'seller-deed');assert.equal(done.status,'cancelled');
  const stats=marketAnalytics({records:{a:{offer,completion:done}},startedAt:1,updatedAt:2});
  assert.equal(stats.totals.trades,0);assert.equal(stats.totals.volume_sompi,'0');
});
test('gross volume excludes bond/refund, deduplicates and builds UTC days',()=>{
  const record={offer,completion:completion(offer,tx,'seller-deed')};
  const archive={records:{a:record,b:record,c:{offer,completion:null}},startedAt:1,updatedAt:2};
  const stats=marketAnalytics(archive);
  assert.equal(stats.totals.trades,1);assert.equal(stats.totals.volume_sompi,'3000000000');
  assert.deepEqual(stats.graph,[{time:Date.UTC(2026,8,15)/1000,total_volume_kas:30,total_trades:1}]);
  assert.equal(stats.top_domains[0].domain,'example.k');assert.equal(stats.pending_verification,1);
  const search=marketAnalytics(archive,'missing');
  assert.equal(search.recent_sales.length,0);assert.equal(search.totals.trades,1);
});
test('daily series matches KNS: chronological reported days without zero padding',()=>{
  const a={offer,completion:{status:'sold',transactionId:'a'.repeat(64),timestamp:Date.UTC(2026,8,15,22)}};
  const b={offer,completion:{status:'sold',transactionId:'b'.repeat(64),timestamp:Date.UTC(2026,8,10,23)}};
  const c={offer,completion:{status:'sold',transactionId:'c'.repeat(64),timestamp:Date.UTC(2026,8,15,23)}};
  const archive={records:{a,b,c},startedAt:1,updatedAt:2};
  assert.deepEqual(marketAnalytics(archive).graph,[
    {time:Date.UTC(2026,8,10)/1000,total_volume_kas:30,total_trades:1},
    {time:Date.UTC(2026,8,15)/1000,total_volume_kas:60,total_trades:2},
  ]);
  assert.deepEqual(marketAnalytics({records:{},startedAt:1,updatedAt:2}).graph,[]);
});
test('history is only a discovery hint, node evidence determines completion',async()=>{
  const calls=[];
  const deps={derive:async()=>({deed:{scriptPublicKey:'seller-deed'}}),node:'https://node',json:async url=>{
    calls.push(url);
    if(url.endsWith('/key'))return {key:'3'.repeat(64),registryCovenantId:REGISTRY};
    if(url.includes('/history'))return {registryCovenantId:REGISTRY,complete:true,entries:[{txid:tx.transaction_id}]};
    return tx;
  }};
  assert.equal((await discoverCompletion(offer,deps)).status,'sold');
  assert.ok(calls.some(u=>u.startsWith('https://node/transactions/')));
  await assert.rejects(discoverCompletion(offer,{...deps,json:async()=>{throw Error('Unavailable')}}));
});
test('complete history still follows pagination until the total is reached',async()=>{
  const offsets=[];
  const result=await discoverCompletion(offer,{
    derive:async()=>({deed:{scriptPublicKey:'seller-deed'}}),node:'https://node',
    json:async url=>{
      if(url.endsWith('/key'))return {key:'3'.repeat(64),registryCovenantId:REGISTRY};
      if(url.includes('/history')){
        const offset=Number(new URL(url).searchParams.get('offset'));offsets.push(offset);
        return {registryCovenantId:REGISTRY,total:101,complete:true,
          entries:offset===0?Array.from({length:100},()=>({txid:'invalid'})):[{txid:tx.transaction_id}]};
      }
      return tx;
    }
  });
  assert.deepEqual(offsets,[0,100]);assert.equal(result.status,'sold');
});
