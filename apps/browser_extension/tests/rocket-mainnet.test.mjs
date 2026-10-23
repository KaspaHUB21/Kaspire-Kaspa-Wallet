import test, {afterEach} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {confirmedRocketConflict, retireRocketSwap, resumeRocketSwap, exclusiveRocket, RocketConflict, RocketQuoteExpired} from './generated/rocketSwaps.mjs';

const fetchBefore = globalThis.fetch;
afterEach(() => { globalThis.fetch = fetchBefore; });
let instance = 0;
const api = () => import(`./generated/kasparocket.mjs?case=${++instance}`);
const response = (value, status = 200) => new Response(JSON.stringify(value), {status,headers:{'content-type':'application/json'}});
const protocol = {network:'mainnet',token:{decimals:3}};

test('Mainnet catalogue uses the pinned gateway without any client API key', async () => {
  const rocket = await api(), calls=[];
  globalThis.fetch = async (url, init) => {
    assert.equal(new URL(url).host,'kaspire.kaslab.space');
    assert.equal(init.headers.Authorization,undefined);
    calls.push(String(url));
    return response(String(url).endsWith('/protocol')?protocol:String(url).endsWith('/api/tokens')?[]:{tokens:[]});
  };
  assert.deepEqual(await rocket.rocketTokens('mainnet'),[]);
  assert.equal(calls.length,3);
  await assert.rejects(rocket.rocketTokens('testnet-10'),/Mainnet/);
  assert.equal(calls.length,3);
});
test('A wrong upstream network is rejected before reading its catalogue',async()=>{
  const rocket=await api();let calls=0;
  globalThis.fetch=async()=>{calls++;return response({...protocol,network:'testnet-10'});};
  await assert.rejects(rocket.rocketTokens('mainnet'),/expected network/);
  assert.equal(calls,1);
});
test('Bonding-curve holdings do not call Kasvio and prices use complete token units',async()=>{
  const rocket=await api();
  globalThis.fetch=async(url,init)=>{
    assert.match(String(url),/kaspire[.]kaslab[.]space\/api\/kasparocket\/pro-api\/tokens\//);
    assert.equal(init.headers.Authorization,undefined);
    return response({tokens:[{kcc20_covenant_id:'a'.repeat(64),ticker:'NACHOBRO',balance_tokens:69913139,
      price_sompi:6452.192432542098,image_url:'https://example.invalid/token.png'}]});
  };
  const [asset]=await rocket.rocketWalletAssets('kaspa:qfixture');
  assert.equal(asset.rawBalance,'69913139');assert.equal(asset.decimals,3);
  assert.equal(asset.standard,'kasparocket-kcc20');assert.equal(asset.discoveryComplete,false);
  assert(Math.abs(asset.priceKas-0.06452192432542098)<1e-12);
  assert.equal(asset.image_url,'https://example.invalid/token.png');
  assert.throws(()=>rocket.rocketSigningRequest('kaspatest:qfixture',{},'', 'buy',{},{}),/Mainnet/);
});
test('Combining independent indexers never duplicates or sums the same token',async()=>{
  const {mergeRocketAssets}=await api(), id='a'.repeat(64);
  const rocket={covenantId:id,symbol:'ROCKET',rawBalance:'7000',discoveryComplete:false};
  assert.deepEqual(mergeRocketAssets([{covenantId:id,symbol:'ROCKET',rawBalance:'0',discoveryComplete:false}],[rocket]),[rocket]);
  const verified={...rocket,rawBalance:'7000',discoveryComplete:true};
  assert.deepEqual(mergeRocketAssets([verified],[rocket]),[verified]);
});
test('Mainnet plans bind network, direction and the requested amount',async()=>{
  const rocket=await api();
  let plan={networkId:'testnet-10',summary:{direction:'buy',kasFlowSompi:'99'}};
  globalThis.fetch=async url=>response(String(url).endsWith('/protocol')?protocol:String(url).endsWith('/route')?{}:plan);
  await assert.rejects(rocket.rocketPlan('kaspa:qfixture','a'.repeat(64),'b'.repeat(64),'buy','100'),/differs/);
  plan={...plan,networkId:'mainnet',summary:{direction:'sell',kasFlowSompi:'99'}};
  await assert.rejects(rocket.rocketPlan('kaspa:qfixture','a'.repeat(64),'b'.repeat(64),'buy','100'),/differs/);
  plan={...plan,summary:{direction:'buy',kasFlowSompi:'101'}};
  await assert.rejects(rocket.rocketPlan('kaspa:qfixture','a'.repeat(64),'b'.repeat(64),'buy','100'),/differs/);
});

const wallet='kaspa:qfixture', origin='a'.repeat(64), savedId='c'.repeat(64), competing='b'.repeat(64);
function fixture(next=0) {
  return {address:wallet,network:'mainnet',token:{ticker:'ROCKET',tokenId:'d'.repeat(64)},side:'buy',poolId:'e'.repeat(64),
    signed:[{inputs:[{previousOutpoint:{transactionId:origin,index:0},utxo:{covenantId:'d'.repeat(64)}}]}],
    transactionIds:[savedId],next,receipts:[],summary:{amountTokensDisplay:'69.913'},reviews:[],plan:{},timestamp:123};
}
function context(receipt=fixture(), accepted=async()=>false) {
  let state={pending:receipt},locked=false;const records=[];
  const guard=async()=>{if(locked)throw Error('Wallet locked');};
  return {context:{address:wallet,network:'mainnet',binding:'session:wallet:path',guard,
    load:()=>structuredClone(state),save:async value=>{await guard();state=structuredClone(value);},
    accepted,record:async(a,row)=>{await guard();records.push({a,row});}},
    state:()=>state,lock:()=>locked=true,records};
}
for(const scenario of ['confirmed','unaccepted','wrong-output','own-transaction','empty','rate-limit']) {
  test(`Stale plan proof requires an exact confirmed competing spend: ${scenario}`,async()=>{
    const f=context();
    const candidate=scenario==='own-transaction'?savedId:competing;
    const spends={previous_outpoint_hash:origin,previous_outpoint_index:scenario==='wrong-output'?'1':'0'};
    const get=async url=>{
      if(scenario==='rate-limit')throw Object.assign(Error('Unavailable'),{httpStatus:429});
      if(url.endsWith('/transactions/'+origin))return{transaction_id:origin,is_accepted:true,outputs:[{index:0,script_public_key_address:'kaspa:qpool'}]};
      if(url.includes('/full-transactions'))return scenario==='empty'?[]:[{transaction_id:candidate,inputs:[spends]}];
      return{transaction_id:candidate,is_accepted:scenario!=='unaccepted',inputs:[spends]};
    };
    const find=(tx,ids)=>confirmedRocketConflict(tx,ids,get);
    if(scenario==='rate-limit')await assert.rejects(retireRocketSwap(f.context,find),/Unavailable/);
    else assert.equal(await retireRocketSwap(f.context,find),scenario==='confirmed');
    if(scenario==='confirmed'){
      assert.equal(f.state().pending,undefined);assert.equal(f.state().obsolete.conflictingTransactionId,competing);
      assert.deepEqual(f.state().obsolete.signed,fixture().signed);
    }else assert.deepEqual(f.state().pending,fixture());
  });
}
test('An already accepted swap completes without re-broadcasting or querying the provider',async()=>{
  const f=context(fixture(),async()=>true);
  globalThis.fetch=async()=>{throw Error('Must not contact provider');};
  await resumeRocketSwap(f.context);
  assert.equal(f.state().pending,undefined);assert.equal(f.records.length,1);
  assert.equal(f.records[0].row.displayAmount,'69.913');assert.equal(f.records[0].row.assetSymbol,'ROCKET');
});
test('Conflict search covers the fourth address, older pages and every outpoint at a shared address',async()=>{
  const ids=[1,2,3,4].map(n=>String(n).padStart(64,'0'));
  const tx={inputs:ids.map(transactionId=>({previousOutpoint:{transactionId,index:0}}))};
  const seen=[];
  const row={transaction_id:competing,is_accepted:true,inputs:[{previous_outpoint_hash:ids[3],previous_outpoint_index:'0'}]};
  const get=async url=>{
    if(url.endsWith('/transactions/'+competing))return row;
    const originId=ids.find(id=>url.endsWith('/transactions/'+id));
    if(originId)return {transaction_id:originId,is_accepted:true,outputs:[{index:0,script_public_key_address:'kaspa:q'+(ids.indexOf(originId)+1)}]};
    const u=new URL(url),address=decodeURIComponent(u.pathname),offset=Number(u.searchParams.get('offset'));seen.push({address,offset});
    if(!address.includes('kaspa:q4'))return [];
    return offset===0?Array.from({length:50},(_,n)=>({transaction_id:(n+100).toString(16).padStart(64,'0'),inputs:[]})):[row];
  };
  assert.equal(await confirmedRocketConflict(tx,new Set([savedId]),get),competing);
  assert(seen.some(s=>s.address.includes('kaspa:q4')&&s.offset===50));
  const shared={inputs:[0,1].map(index=>({previousOutpoint:{transactionId:origin,index}}))};
  const second={...row,inputs:[{previous_outpoint_hash:origin,previous_outpoint_index:'1'}]};
  assert.equal(await confirmedRocketConflict(shared,new Set(),async url=>url.includes('/full-transactions')?[second]:url.endsWith('/'+competing)?second:
    {transaction_id:origin,is_accepted:true,outputs:[0,1].map(index=>({index,script_public_key_address:'kaspa:qpool'}))}),competing);
});
test('Repeated pages explicitly preserve an indeterminate swap rather than silently clearing it',async()=>{
  const f=context();
  const get=async url=>url.includes('/full-transactions')?Array.from({length:50},(_,n)=>({transaction_id:String(n+100).padStart(64,'0'),inputs:[]})):
    {transaction_id:origin,is_accepted:true,outputs:[{index:0,script_public_key_address:'kaspa:qpool'}]};
  await assert.rejects(retireRocketSwap(f.context,(tx,ids)=>confirmedRocketConflict(tx,ids,get)),/Unable to determine/);
  assert.deepEqual(f.state().pending,fixture());
});
test('Existing obsolete journals become refreshable without another broadcast',async()=>{
  const f=context();let submits=0;
  await assert.rejects(resumeRocketSwap(f.context,true,{conflict:async()=>competing,submit:async()=>{submits++;}}),RocketQuoteExpired);
  assert.equal(submits,0);assert.equal(f.state().pending,undefined);
});
test('409 is not retried or discarded without independently confirmed conflict',async()=>{
  const f=context();let submits=0;
  globalThis.fetch=async()=>response(protocol);
  await assert.rejects(resumeRocketSwap(f.context,false,{conflict:async()=>null,
    submit:async()=>{submits++;throw new RocketConflict('specific provider reason');}}),/specific provider reason/);
  assert.equal(submits,1);assert.deepEqual(f.state().pending,fixture());
});
test('A proven stale first submission archives the old bytes and releases the lock',async()=>{
  const f=context();let submits=0;
  globalThis.fetch=async()=>response(protocol);
  await assert.rejects(exclusiveRocket(f.context,()=>resumeRocketSwap(f.context,false,{conflict:async()=>competing,
    submit:async()=>{submits++;throw new RocketConflict('input already spent');}})),RocketQuoteExpired);
  assert.equal(submits,1);assert.equal(f.state().pending,undefined);
  assert.equal(await exclusiveRocket(f.context,async()=>true),true);
});
test('Ambiguous acknowledgement preserves the signed bytes and allows status checks',async()=>{
  const f=context();let submits=0;
  globalThis.fetch=async()=>response(protocol);
  await assert.rejects(exclusiveRocket(f.context,()=>resumeRocketSwap(f.context,false,{submit:async()=>{submits++;return{ok:true};},sleep:async()=>{}})),/confirmation is still pending/);
  assert.equal(submits,1);assert.equal(f.state().pending.next,0);assert.equal(f.state().pending.receipts.length,1);
  assert.equal(await exclusiveRocket(f.context,async()=>true),true);
});
test('Partial plans and acceptance arriving during lookup cannot be discarded',async()=>{
  const partial=context(fixture(1));
  assert.equal(await retireRocketSwap(partial.context,async()=>competing),false);
  let checks=0;const late=context(fixture(),async()=>++checks>1);
  assert.equal(await retireRocketSwap(late.context,async()=>competing),false);assert(late.state().pending);
});
test('Lock or account guard stops a prepared recovery operation before any network action',async()=>{
  const f=context();f.lock();
  globalThis.fetch=async()=>{throw Error('Must not send');};
  await assert.rejects(exclusiveRocket(f.context,()=>resumeRocketSwap(f.context)),/Wallet locked/);
  assert.deepEqual(f.state().pending,fixture());
});
test('Signed swap journals live inside the encrypted wallet vault, not plain storage',async()=>{
  const source=await readFile(new URL('../src/background/index.ts',import.meta.url),'utf8');
  const recovery=source.slice(source.indexOf('function rocketRecoveryContext'),source.indexOf('interface ApprovalView'));
  assert.match(recovery,/persistVault\(guard\)/);assert.match(recovery,/selected[.]path !== entry[.]path/);
  assert.match(recovery,/generation !== sessionGeneration/);assert.match(recovery,/fresh[.]network !== network/);
  assert.doesNotMatch(recovery,/chrome[.]storage[.]local[.]set/);
});
