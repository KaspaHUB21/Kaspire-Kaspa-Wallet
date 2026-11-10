import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
import {webcrypto} from 'node:crypto';
import {ownerAddress,publicDigest} from './generated/publicCrypto.mjs';
import {braidRouteLabel,forgeSwapConfirmed,covenantSwapConfirmation} from './generated/dexPresentation.mjs';
const code=await readFile(new URL('../generated/dex/engine.js',import.meta.url),'utf8');
const address='kaspa:qp0mtdvzscrkfft702j85s8yzdl8a87n5d6pgtm8vrxg6hqu0wywzvwkevdk3';
export async function engine(handler=()=>null){
  const calls=[],c={console,setTimeout,clearTimeout,crypto:webcrypto,performance,
    kaspireDexHost:async raw=>{const m=JSON.parse(raw);calls.push(m);try{return JSON.stringify({ok:true,value:await handler(m)});}catch(e){return JSON.stringify({ok:false,error:e.message});}}};
  c.self=c;vm.createContext(c);vm.runInContext(code,c);await new Promise(r=>setTimeout(r,10));
  return {calls,async run(venue,action,args={},options={}){const r=JSON.parse(await c.kaspireDexInvoke(JSON.stringify({venue,action,args,address,network:'mainnet',...options})));if(!r.ok)throw Error(r.error);return r.value;}};
}
test('compiled shared engine preserves exact address, 64-bit state, digest and partner address',async()=>{
  const e=await engine(),v=await e.run('braid','selfTest');
  assert.equal(v.address,address);assert.equal(v.wideIntegerLimit,'4503599627370496');assert.equal(v.wideState,'9223372036854775807');
  assert.equal(v.publicDigest,await publicDigest('010203ff'));
  assert.equal(v.feeAddress,'kaspa:qqre4wt08dp0rvmxwqgwdkz4zu4m36g9uvmfledd27mx939uxe2yjpmmd37zq');
});
test('compiled Braid catalogue keeps mainnet/testnet covenant identities and units separate',async()=>{
  const e=await engine(),main=await e.run('braid','tokens'),tn=await e.run('braid','tokens',{}, {network:'testnet-10'});
  assert.equal(main.find(t=>t.symbol==='GUZA').decimals,3);assert.equal(main.find(t=>t.symbol==='KRON').decimals,0);
  assert.equal(main[0].symbol,'KAS');assert.equal(main[0].decimals,8);assert.equal(tn[0].decimals,8);
  assert(!tn.some(t=>main.some(m=>m.id===t.id)&&t.symbol!=='KAS'));
});
test('Braid route labels never show null placeholders',()=>{
  assert.equal(braidRouteLabel({venue:'kr',from:null,to:'null',tick:'GUZA',side:'sell'}),'KaspaRocket: GUZA → KAS');
  assert.equal(braidRouteLabel({venue:'krc',tick:'THEN',side:'buy'}),'KaspaRocket Launchpad: KAS → THEN');
});
test('Forge success requires a verified fill, never a refund or an obsolete order',()=>{
  assert.equal(forgeSwapConfirmed('kforge',{state:'confirmed'}),true);
  assert.equal(forgeSwapConfirmed('kforge',{state:'obsolete'}),false);
  for(const state of ['open','refunded','cancelled'])assert.equal(forgeSwapConfirmed('kasforge',{state,finalVerified:true}),false);
  assert.equal(forgeSwapConfirmed('kasforge',{state:'filled',finalVerified:false}),false);
  assert.equal(forgeSwapConfirmed('kasforge',{state:'filled',finalVerified:true}),true);
  assert.match(covenantSwapConfirmation({name:'KasForge',network:'MAINNET',buttonId:'dex-return',raw:{ticker:'<token>'}}),/SWAP CONFIRMED[\s\S]+&lt;token&gt;[\s\S]+Return to KasForge/);
});
test('Braid quotes bind KAS budget, minimum and exact one-percent fee on both networks',async()=>{
  for(const [network,net,pin]of [['mainnet','mainnet','f994470f9bd84d2ca2578a5d8294cc403bb699f19f7e73922c51d04cbb17027d'],['testnet-10','tn10','905df466072298313e1cc9e86132ba61f26e2a359f7a7dbd5028fa1963872646']]){
    const owner='5fb5b582860764a57e7aa47a40e4137e7e9fd3a374142f6760cc8d5c1c7b88e1',wallet=await ownerAddress(owner,network);let bad=false,fee;
    const e=await engine(m=>{
      assert.equal(m.operation,'http');const u=new URL(m.body.url);let data;
      if(u.pathname.endsWith('/info'))data={net,pin,expectedPin:pin,pinOk:true,enabled:true,executorStatus:{healthy:true}};
      else{assert(u.pathname.endsWith('/quote'));assert.equal(u.searchParams.get('payTotal'),'10000000000');assert.equal(u.searchParams.get('walletFeeBps'),'100');assert.equal(u.searchParams.get('walletFeeAddress'),fee.feeAddress);data={net,pin,from:'KAS',to:u.searchParams.get('to'),payTotal:'10000000000',staged:false,amountOut:'1230000',walletFee:{mode:'bps',bps:100,address:fee.feeAddress,pk:fee.feeOwner,amount:bad?'100000001':'100000000',basis:'10000000000',basisKind:'payTotal',unit:'KAS'}};}
      return {status:200,headers:{},body:Buffer.from(JSON.stringify(data)).toString('base64')};
    });
    const options={address:wallet,network},[from,to]=await e.run('braid','tokens',{},options);fee=await e.run('braid','selfTest',{},options);
    const args={from:from.id,to:to.id,amount:'100'},quote=await e.run('braid','quote',args,options);assert.equal(quote.localFloor,'1217700');
    bad=true;await assert.rejects(e.run('braid','quote',args,options),/approved 1%/);
  }
});
test('compiled services use the exact wallet/network recovery namespaces',async()=>{
  const e=await engine(m=>{assert.equal(m.operation,'storeRead');return null;});
  for(const [venue,suffix]of [['braid','receipts'],['kforge','atomic'],['kasforge','orders']]){
    assert.deepEqual(await e.run(venue,'saved'),[]);assert.equal(e.calls.at(-1).body.key,`${venue}_mainnet_${suffix}_v1_${address}`);
  }
});
test('missing or corrupt recovery is never silently treated as an empty saved list',async()=>{
  const e=await engine(()=>'{bad');for(const venue of ['braid','kforge','kasforge'])await assert.rejects(e.run(venue,'saved'));
});
test('a stale or foreign quote ID cannot prepare/sign and never writes recovery',async()=>{
  const e=await engine(()=>{throw Error('No host side effects allowed');});
  for(const venue of ['braid','kforge','kasforge'])await assert.rejects(e.run(venue,'prepare',{id:'foreign'}),/expired/);
  assert.equal(e.calls.length,0);
});
test('unavailable balances remain null, not zero, while saved recovery stays visible',async()=>{
  const e=await engine(m=>{if(m.operation==='storeRead')return '[]';if(m.operation==='http')return {status:503,headers:{},body:Buffer.from('{}').toString('base64')};throw Error('Unexpected side effect');});
  const v=await e.run('braid','context');assert.equal(v.balanceSompi,null);assert.deepEqual(v.saved,[]);
});
