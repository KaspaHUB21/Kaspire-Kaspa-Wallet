import test from 'node:test';
import assert from 'node:assert/strict';
import {createTn10UtxoReader} from './tn10-utxos.mjs';
const opts={timeoutMs:20,disconnectMs:5};
function client(overrides={}){
  return {connect:async()=>{},getInfo:async()=>({isSynced:true,isUtxoIndexed:true}),
    getBlockDagInfo:async()=>({network:'testnet-10'}),
    getUtxosByAddresses:async()=>({entries:[{outpoint:{transactionId:'a'.repeat(64),index:0}}]}),
    disconnect:async()=>{},free(){this.freed=true;},...overrides};
}
test('healthy first node is bounded and its completed connection is freed',async()=>{
  const c=client(),urls=[];
  const read=createTn10UtxoReader(url=>{urls.push(url);return c;},opts);
  assert.equal((await read('public fixture')).length,1);assert.equal(c.freed,true);
  assert.match(urls[0],/^wss:\/\/vector-10\.kaspa\.green\//);
});
test('stalled RPC falls back and is never freed while its operation is pending',async()=>{
  const first=client({getInfo:()=>new Promise(()=>{})}),second=client(),urls=[];
  const read=createTn10UtxoReader(url=>{urls.push(url);return urls.length===1?first:second;},opts);
  assert.equal((await read('public fixture')).length,1);
  assert.equal(first.freed,undefined);assert.equal(second.freed,true);
  assert.match(urls[1],/^wss:\/\/muon-10\.kaspa\.blue\//);
});
test('wrong network, unsynced and incomplete coverage never become an empty balance',async()=>{
  for(const overrides of [{getBlockDagInfo:async()=>({network:'mainnet'})},{getInfo:async()=>({isSynced:false,isUtxoIndexed:true})},{getUtxosByAddresses:async()=>({})}]){
    const read=createTn10UtxoReader(()=>client(overrides),opts);
    await assert.rejects(read('public fixture'),/temporarily unavailable/);
  }
});
test('two stalled nodes fail boundedly and quarantined endpoints are not allocated again',async()=>{
  let created=0;
  const read=createTn10UtxoReader(()=>{created++;return client({connect:()=>new Promise(()=>{}),disconnect:()=>new Promise(()=>{})});},opts);
  await assert.rejects(read('public fixture'),/temporarily unavailable/);
  assert.equal(created,2);
  await assert.rejects(read('public fixture'),/temporarily unavailable/);
  assert.equal(created,2);
});
test('late resolution after retirement cannot continue into another RPC operation',async()=>{
  let resume,calls=0;
  const first=client({connect:()=>new Promise(resolve=>{resume=resolve;}),getInfo:async()=>{calls++;return {};}});
  let created=0;
  const read=createTn10UtxoReader(()=>++created===1?first:client(),opts);
  await read('public fixture');resume();await new Promise(resolve=>setImmediate(resolve));
  assert.equal(calls,0);assert.equal(first.freed,true);
});
