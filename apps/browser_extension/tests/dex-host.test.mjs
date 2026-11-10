import test from 'node:test';
import assert from 'node:assert/strict';
const listeners=[];let invoke;
const origin='chrome-extension://test-id/';
globalThis.chrome={runtime:{id:'test-id',getURL:p=>origin+p,ContextType:{OFFSCREEN_DOCUMENT:'OFFSCREEN_DOCUMENT'},getContexts:async()=>[{contextType:'OFFSCREEN_DOCUMENT',documentId:'offscreen'}],onMessage:{addListener:fn=>listeners.push(fn)},sendMessage:async message=>message.kind==='dex-engine-invoke'?invoke(message):undefined}};
const {runDexEngine,sharedDexAssets}=await import('./generated/dexEngine.mjs');
const sender={id:'test-id',url:origin+'session.html',documentId:'offscreen'};
const context=()=>({address:'kaspa:public',network:'mainnet',guard:async()=>{},ensure:async()=>{},progress:()=>{},read:async()=>null,write:async()=>{},prepare:async()=>({reviewHash:'checked'}),sign:async()=>{throw Error('No real signing in tests');},broadcast:async()=>{throw Error('No broadcast in tests');}});
function request(capability,operation,body={},from=sender){return new Promise(resolve=>listeners[0]({kind:'dex-engine-host',capability,request:JSON.stringify({operation,body})},from,resolve));}
test('offscreen host rejects foreign surfaces and expired capabilities',async()=>{
  assert.equal((await request('expired','guard')).ok,false);
  invoke=async m=>{for(const wrong of [{...sender,url:origin+'wallet.html'},{...sender,documentId:'wrong'},{...sender,id:'foreign'},{...sender,tab:{id:1}}])assert.equal((await request(m.capability,'guard',{},wrong)).ok,false);
    assert.equal((await request(m.capability,'guard',{}, {...sender,documentId:undefined})).ok,true);
    return {result:'{"ok":true,"value":true}'};};
  assert.equal(await runDexEngine(context(),'braid','info'),true);
});
test('read-only discovery cannot sign, write recovery, POST or use external URLs',async()=>{
  invoke=async m=>{for(const [op,body]of [['sign',{request:{sender:'kaspa:public',profile:'braid-mainnet-deposit-v1'}}],['storeDelete',{key:'braid_mainnet_receipts_v1_kaspa:public'}],['http',{url:'https://app.braidswap.com/api/mainnet/router/submit',method:'POST',body:''}],['http',{url:'https://evil.example/',method:'GET',body:''}]])assert.equal((await request(m.capability,op,body)).ok,false);return {result:'{"ok":true,"value":[]}'};};
  assert.deepEqual(await runDexEngine(context(),'braid','assets'),[]);
});
test('review binds venue, sender, profile and storage wallet before native work',async()=>{
  invoke=async m=>{for(const r of [{sender:'wrong',profile:'kforge-mainnet-swap-v1'},{sender:'kaspa:public',profile:'kasforge-mainnet-order-v1'},{sender:'kaspa:public',profile:'kforge-tn10-swap-v1'}])assert.equal((await request(m.capability,'prepare',{request:r})).ok,false);
    assert.equal((await request(m.capability,'storeRead',{key:'kforge_mainnet_atomic_v1_other'})).ok,false);
    assert.deepEqual(await request(m.capability,'prepare',{request:{sender:'kaspa:public',profile:'kforge-mainnet-swap-v1'}}),{ok:true,value:{reviewHash:'checked'}});
    assert.equal((await request(m.capability,'sign',{request:{sender:'kaspa:public',profile:'kforge-mainnet-swap-v1'}})).ok,false);return {result:'{"ok":true,"value":true}'};};
  await runDexEngine(context(),'kforge','prepare');
});
test('asset jobs coalesce, replay, and cache independently of a reopened view',async()=>{
  let release,started=0;const barrier=new Promise(r=>release=r),c=context();
  invoke=async m=>{started++;await request(m.capability,'assets',{items:[{covenantId:'a',rawBalance:'42'}]});await barrier;return {result:'{"ok":true,"value":[{"covenantId":"a","rawBalance":"42"}]}'};};
  const a=sharedDexAssets(c,'kforge');await new Promise(r=>setTimeout(r,1));const b=sharedDexAssets(context(),'kforge');release();assert.deepEqual(await a,await b);assert.equal(started,1);assert.deepEqual(await sharedDexAssets(context(),'kforge'),await a);assert.equal(started,1);
});
