import test from 'node:test';
import assert from 'node:assert/strict';
import {nativeSwapJournal} from './generated/nativeSwapJournal.mjs';
import {nativeSwapResponse} from './generated/nativeSwapResponse.mjs';
import {nativeSwapBackup,restoreNativeSwapBackup} from './generated/nativeSwapBackup.mjs';
import {nativeBalance} from './generated/nativeSwap.mjs';
import {loadState,saveState,setCurrencyPreference} from './generated/state.mjs';

test('currency selection survives old snapshots, reload, lock and unrelated settings',async()=>{
 const store={},copy=v=>structuredClone(v);
 globalThis.chrome={storage:{local:{get:async keys=>Object.fromEntries(keys.map(k=>[k,copy(store[k])])),set:async obj=>Object.assign(store,copy(obj))}},tabs:{query:async()=>[]}};
 const first=await loadState(),second=await loadState();first.settings.currency='JPY';assert.equal(second.settings.currency,'USD');
 const stale=await loadState();await saveState(stale);await setCurrencyPreference('EUR');const fresh=await loadState();assert.equal(fresh.settings.currency,'EUR');
 stale.settings.hideBalances=true;stale.network='igra';await saveState(stale);assert.equal((await loadState()).settings.currency,'EUR');
 await setCurrencyPreference('CHF');await Promise.all([saveState(stale),saveState(fresh)]);assert.equal((await loadState()).settings.currency,'CHF');
 await assert.rejects(setCurrencyPreference('unknown'));assert.equal((await loadState()).settings.currency,'CHF');
});

test('only node-clock telemetry is projected; all financial integers remain exact',()=>{
 const enc=s=>new TextEncoder().encode(s),url='https://kaspire.kaslab.space/api/local-node/info/blockdag';
 assert.deepEqual(JSON.parse(new TextDecoder().decode(nativeSwapResponse(url,enc('{"difficulty":1.58e16,"virtualDaaScore":"599000000"}')))),{virtualDaaScore:'599000000'});
 for(const daa of ['9007199254740993','-1','null','"9"','"bad"'])assert.throws(()=>nativeSwapResponse(url,enc('{"virtualDaaScore":'+daa+'}')),/clock/);
 const raw=enc('{"amount":1234567,"exact":"999999999999999999999"}');assert.equal(nativeSwapResponse('https://api.trestly.io/api/v1/pool',raw),raw);
 assert.throws(()=>nativeSwapResponse('https://api.trestly.io/api/v1/pool',enc('{"amount":9007199254740993}')),/integer range/);
 assert.throws(()=>nativeSwapResponse(url+'?other',enc('{"difficulty":1.58e16,"virtualDaaScore":599000000}')),/integer range/);
});

test('MAX is exact, partial remains unknown, and malformed balance cannot become zero',()=>{
 const value={verifiedRaw:'3000001',maximumRaw:'2000000',maximumAmount:'2',count:2,complete:true};assert.equal(nativeBalance(value),value);
 assert.equal(nativeBalance({...value,complete:false}).complete,false);
 for(const edit of [{verifiedRaw:3000001},{maximumRaw:'4000000'},{maximumAmount:'2.000001'},{complete:null},{maximumAmount:2}])assert.throws(()=>nativeBalance({...value,...edit}));
 assert.equal(nativeBalance({verifiedRaw:'0',maximumRaw:'0',maximumAmount:'0',count:0,complete:true}).verifiedRaw,'0');
});

test('signature gap recovers exact bytes; unknown cannot erase and altered bytes cannot send',async()=>{
 const address='kaspa:public',key='trestly.pending.v1.'+address,id='ab'.repeat(32),review={profile:'trestly-mainnet-v2',reviewHash:'cafe'},request={sender:address},result={transactionId:id,wrpcJson:' {"inputs":[{}],"outputs":[]} ',feeSompi:'100',review};
 const signatures={[id]:{operation:'signTrestly',walletAddress:address,request:JSON.stringify(request),result,reviewHash:'cafe',at:1}},store={};let confirmed=false,writes=0;
 const journal=nativeSwapJournal({address,rootAddress:address,guard:async()=>{},read:async k=>store[k]??null,write:async(k,v)=>{writes++;v===null?delete store[k]:store[k]=v;},signed:async()=>signatures,check:async()=>({confirmed})});
 const recovered=JSON.parse(await journal.read(key));assert.equal(recovered.wrpcJson,result.wrpcJson);assert.equal(writes,1);
 await journal.beforeSubmit(id,result.wrpcJson);await assert.rejects(journal.beforeSubmit(id,result.wrpcJson.trim()),/exact/);await assert.rejects(journal.beforeSubmit('cd'.repeat(32),result.wrpcJson),/exact/);
 await assert.rejects(journal.write(key,null),/confirmation/);await journal.write(key+'.last',JSON.stringify({...recovered,status:'confirmed'}));await assert.rejects(journal.write(key,null),/confirmation/);assert(store[key]);
 const backup=nativeSwapBackup(signatures,store);const restored=await restoreNativeSwapBackup(backup,[address],async()=>review);assert.equal(restored.signatures[id].result.wrpcJson,result.wrpcJson);assert.equal(restored.receipts[key],store[key]);
 await assert.rejects(restoreNativeSwapBackup(backup,['kaspa:other'],async()=>review));await assert.rejects(restoreNativeSwapBackup(backup,[address],async()=>({...review,reviewHash:'wrong'})));
 confirmed=true;await journal.write(key,null);assert(!store[key]);
});
