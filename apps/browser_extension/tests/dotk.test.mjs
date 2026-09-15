import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import init, {deriveDotkDeed} from './generated/wasm/kaspa_secure_core.mjs';
import {dotkBareName,dotkNamesOf,resolveDotkName,DOTK_REGISTRY} from './generated/dotk.mjs';
await init(await readFile(new URL('./generated/wasm/kaspa_secure_core_bg.wasm',import.meta.url)));
const owner='079ab96f3b42f1b3667010e6d855172bb8e905e3369fe5ad57b662c4bc365449';
const native = async req => JSON.parse(deriveDotkDeed(JSON.stringify(req)));
const d = await native({name:'21millioncoven',ownerType:0,owner});
const txid='e65cc49d882b85146ed844f8461c8c743ffacf267e940160cface39fe885b7f8';
test('same Rust WASM derivation as Android mainnet vector',()=>{
  assert.equal(d.address,'kaspa:qqre4wt08dp0rvmxwqgwdkz4zu4m36g9uvmfledd27mx939uxe2yjpmmd37zq');
  assert.equal(d.deedAddress,'kaspa:pz7hc3eyu6z6f6xgmp5e843a7xpwqag6rywp3s8r96a0yvg0kgy2xcazlrru8');
  assert.equal(dotkBareName(' 21MillionCoven.K '),'21millioncoven');
  for(const n of ['a.kas','a.b.k','téšt.k','-a.k','a-.k','a'.repeat(33)+'.k']) assert.throws(()=>dotkBareName(n));
});
test('node-backed resolution rejects fake, stale, unaccepted and foreign-covenant claims',async()=>{
  const previous=globalThis.fetch;
  try {
    for(const mode of ['valid','owner','deed','registry','spent','foreign','unaccepted','script','bond']) {
      let utxos=0;
      globalThis.fetch=async url=>{
        let value;
        if(String(url).includes('/names/')) value={...d,ownerType:0,owner,
          ...(mode==='owner'?{address:'kaspa:wrong'}:{}),...(mode==='deed'?{deedAddress:'kaspa:wrong'}:{}),
          ...(mode==='registry'?{registryCovenantId:'00'.repeat(32)}:{})};
        else if(String(url).endsWith('/utxos')) {utxos++;value=mode==='spent'&&utxos>1?[]:[{
          address:d.deedAddress,outpoint:{transactionId:txid,index:0},utxoEntry:{amount:mode==='bond'?'1':'100000000',
            isCoinbase:false,scriptPublicKey:{scriptPublicKey:mode==='script'?'bad':d.scriptPublicKey}}}];}
        else value={transaction_id:txid,is_accepted:mode!=='unaccepted',outputs:[{index:0,amount:100000000,
          covenant_id:mode==='foreign'?'00'.repeat(32):DOTK_REGISTRY,script_public_key:d.scriptPublicKey,script_public_key_address:d.deedAddress}]};
        return new Response(JSON.stringify(value));
      };
      if(mode==='valid') assert.equal((await resolveDotkName('21millioncoven.k',native)).address,d.address);
      else await assert.rejects(resolveDotkName('21millioncoven.k',native));
    }
  } finally {globalThis.fetch=previous;}
});
test('complete alphabetical holdings remain unverified until opened',async()=>{
 const previous=globalThis.fetch;
 globalThis.fetch=async()=>new Response(JSON.stringify({address:d.address,registryCovenantId:DOTK_REGISTRY,
  names:['zebra','aaa','zebra',...Array.from({length:150},(_,i)=>`name-${i}`)]}));
 try {const names=await dotkNamesOf(d.address);assert.equal(names.length,152);assert.equal(names[0].name,'aaa.k');assert.ok(names.every(n=>!n.verified));}
 finally {globalThis.fetch=previous;}
});
