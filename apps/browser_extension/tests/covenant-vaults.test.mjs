import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile, writeFile, mkdtemp, rm} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import init, {describeCovenantVault, prepareCovenantVault, signCovenantVault, validateVaultRecord, sealVaultRecovery, openVaultRecovery} from './generated/wasm/kaspa_secure_core.mjs';
import {covenantVaultCommand, clearCovenantVaultReviews, parseVaultJson, parseVaultKas, vaultSaved} from './generated/covenantVaults.mjs';
const wasm = await readFile(new URL('./generated/wasm/kaspa_secure_core_bg.wasm', import.meta.url));
await init({module_or_path:wasm});
const repo = new URL('../../../', import.meta.url).pathname;
const cargo = (args) => execFileSync('cargo', ['run','--locked','--quiet','-p','kaspa_secure_core','--example','vault_browser_fixture','--',...args], {cwd:repo, maxBuffer:2*1024*1024, env:process.env}).toString();
const native = JSON.parse(cargo([]));
const fixture = native.cases[0], address = fixture.request.sender, cid = fixture.review.covenantId;
const parsed = value => JSON.parse(value);

test('WASM contracts, review hashes and transaction IDs match Android/native for every vault action', () => {
  for (const c of native.cases) {
    assert.deepEqual(parsed(prepareCovenantVault(JSON.stringify(c.request))), c.review);
    assert.equal(parsed(describeCovenantVault(JSON.stringify(c.request.terms))).redeemScript, c.review.record.redeemScript);
    const signed = parsed(signCovenantVault(c.secret, JSON.stringify(c.request), c.review.reviewHash));
    assert.equal(signed.transactionId,c.review.transactionId);
    assert.equal(parsed(signed.wrpcJson).id,c.review.transactionId);
    assert.throws(()=>signCovenantVault(c.secret, JSON.stringify({...c.request,amountSompi:c.request.amountSompi+1}),c.review.reviewHash));
    assert.throws(()=>signCovenantVault('private:'+'09'.repeat(32),JSON.stringify(c.request),c.review.reviewHash),/does not control/);
  }
});
test('WASM opens native recovery, wipes password bytes and rejects tampering/wrong passwords', () => {
  const password = new TextEncoder().encode(native.password);
  assert.deepEqual(parsed(openVaultRecovery(password,native.sealed)),native.record);
  assert(password.every(b=>b===0));
  const wrong = new TextEncoder().encode('Different password 2026!');
  assert.throws(()=>openVaultRecovery(wrong,native.sealed)); assert(wrong.every(b=>b===0));
  const changed=parsed(native.sealed);changed.ciphertext='00';
  assert.throws(()=>openVaultRecovery(new TextEncoder().encode(native.password),JSON.stringify(changed)));
  assert.throws(()=>validateVaultRecord(JSON.stringify({...native.record,privateKey:'not allowed'})));
});
test('native Android/desktop core opens the extension recovery format without conversion', async () => {
  const bytes = new TextEncoder().encode(native.password);
  const sealed = sealVaultRecovery(bytes,JSON.stringify(native.record));
  assert(bytes.every(b=>b===0)); assert(!sealed.includes(native.record.terms.name));
  const directory = await mkdtemp(join(tmpdir(),'kaspire-vault-cross-platform-'));
  try { const path=join(directory,'recovery.json'); await writeFile(path,sealed); assert.deepEqual(parsed(cargo(['open',path])),native.record); }
  finally { await rm(directory,{recursive:true,force:true}); }
});
test('exact sompi arithmetic preserves large node integers and rejects malformed KAS amounts', () => {
  const data=parseVaultJson('{"amount":2870000000000000000,"name":"1234567890123456789","escaped":"\\\"2870000000000000000","small":5000}');
  assert.equal(data.amount,'2870000000000000000'); assert.equal(data.name,'1234567890123456789'); assert.equal(data.small,5000);
  assert.equal(parseVaultKas('28700000000'),'2870000000000000000'); assert.equal(parseVaultKas('1.00000001'),'100000001');
  for(const text of ['0','0.9','1.000000001','1e2','1,2','-1','28700000001'])assert.throws(()=>parseVaultKas(text));
  const large={...native.record,amountSompi:'2870000000000000000'};
  assert.equal(parsed(validateVaultRecord(JSON.stringify(large))).amountSompi,large.amountSompi);
});
function environment(t) {
  const oldChrome=globalThis.chrome, oldFetch=globalThis.fetch, store={},events=[];
  const funding=parsed(fixture.request.fundingUtxosJson), transactions=new Map();let live=[],failBroadcast=false,locked=false,approved=true;
  globalThis.chrome={runtime:{getURL:()=>wasm},storage:{local:{get:async key=>({[key]:structuredClone(store[key])}),set:async data=>{events.push('persist');Object.assign(store,structuredClone(data));}}}};
  globalThis.fetch=async (url,options)=>{
    url=String(url);
    if(url.endsWith('/covenant-broadcast')){
      events.push('broadcast');assert(store.covenantVaultsV1[0]?.pending,'must persist before broadcasting');
      if(failBroadcast)throw Error('offline');
      return new Response(JSON.stringify({transactionId:store.covenantVaultsV1[0].pending.transactionId}));
    }
    if(url.endsWith('/info/blockdag'))return new Response(JSON.stringify({networkName:'kaspa-mainnet',virtualDaaScore:2000}));
    if(url.includes('/utxos'))return new Response(JSON.stringify(url.includes(encodeURIComponent(address))?funding:live));
    if(url.includes('/full-transactions'))return new Response('[]');
    const tx=transactions.get(url.split('/').pop());return new Response(JSON.stringify(tx??{}),{status:tx?200:404});
  };
  clearCovenantVaultReviews();t.after(()=>{globalThis.chrome=oldChrome;globalThis.fetch=oldFetch;clearCovenantVaultReviews();});
  const context={address,binding:'1:1:wallet',guard:async()=>{if(locked)throw Error('Wallet locked');},
    approve:async()=>{events.push('approve');return approved;},
    sign:async(request,hash)=>{events.push('sign');return parsed(signCovenantVault(fixture.secret,JSON.stringify(request),hash));}};
  const command=(command,fields={})=>covenantVaultCommand(context,{command,...fields});
  const prepare=()=>command('covenantVaultPrepare',{action:'create',kind:'timeLock',name:'Browser vault',amount:'1',deadline:5000});
  const backup=async id=>command('covenantVaultExport',{id,password:Array.from(new TextEncoder().encode(native.password))});
  const confirm=()=>{
    const r=store.covenantVaultsV1[0].record,p=store.covenantVaultsV1[0].pending;
    live=[{outpoint:{transactionId:p.transactionId,index:0},utxoEntry:{amount:String(r.amountSompi),blockDaaScore:2001,isCoinbase:false,scriptPublicKey:{scriptPublicKey:r.scriptPublicKey}}}];
    transactions.set(p.transactionId,{transaction_id:p.transactionId,is_accepted:true,outputs:[{index:0,covenant_id:r.covenantId,script_public_key:r.scriptPublicKey,amount:String(r.amountSompi)}]});
  };
  return {context,store,events,command,prepare,backup,confirm,transactions,setLive:v=>{live=v;},setLocked:v=>{locked=v;},setApproved:v=>{approved=v;},setOffline:v=>{failBroadcast=v;}};
}
test('creation requires portable recovery, then approval, durable journal and exact-byte broadcast', async t=>{
  const e=environment(t),p=await e.prepare();
  await assert.rejects(e.command('covenantVaultSubmit',{id:p.id,recoverySaved:true}),/Save the encrypted/);
  await e.backup(p.id);const result=await e.command('covenantVaultSubmit',{id:p.id,recoverySaved:true});
  assert.equal(result.confirmed,false);assert.deepEqual(e.events.slice(0,4),['approve','sign','persist','broadcast']);
  assert(e.store.covenantVaultsV1[0].pending.submitted);assert.equal((await vaultSaved(address)).length,1);
  await assert.rejects(e.prepare(),/Resume or refresh/);
  const broadcasts=e.events.filter(x=>x==='broadcast').length;e.confirm();
  const resumed=await e.command('covenantVaultResume',{covenantId:p.review.covenantId});assert.equal(resumed.confirmed,true);
  assert.equal(e.events.filter(x=>x==='broadcast').length,broadcasts);assert(!e.store.covenantVaultsV1[0].pending);
  assert.equal(e.store.covenantVaultsV1[0].record.status,'locked');
});
test('failure preserves exact signed bytes; resume never signs another deposit or erases the journal',async t=>{
  const e=environment(t),p=await e.prepare();await e.backup(p.id);e.setOffline(true);
  await assert.rejects(e.command('covenantVaultSubmit',{id:p.id,recoverySaved:true}),/offline/);
  const bytes=e.store.covenantVaultsV1[0].pending.wrpcJson;
  await assert.rejects(e.prepare(),/Resume or refresh/);e.setOffline(false);
  await e.command('covenantVaultResume',{covenantId:p.review.covenantId});
  assert.equal(e.store.covenantVaultsV1[0].pending.wrpcJson,bytes);assert.equal(e.events.filter(x=>x==='sign').length,1);
});
test('lock during approval, context changes and rejection all prevent signing',async t=>{
  const e=environment(t),p=await e.prepare();await e.backup(p.id);
  await assert.rejects(covenantVaultCommand({...e.context,binding:'2:1:wallet'},{command:'covenantVaultSubmit',id:p.id,recoverySaved:true}),/review expired/);
  e.context.approve=async()=>{e.setLocked(true);return true;};
  await assert.rejects(e.command('covenantVaultSubmit',{id:p.id,recoverySaved:true}),/Wallet locked/);
  assert(!e.events.includes('sign'));assert(!e.store.covenantVaultsV1);
  e.setLocked(false);e.context.approve=async()=>false;
  await assert.rejects(e.command('covenantVaultSubmit',{id:p.id,recoverySaved:true}),/rejected/);
});
test('import never replaces a newer pending transaction journal; unspent absence is not a payout',async t=>{
  const e=environment(t),p=await e.prepare(),backup=await e.backup(p.id);e.setOffline(true);
  await assert.rejects(e.command('covenantVaultSubmit',{id:p.id,recoverySaved:true}),/offline/);
  const before=structuredClone(e.store.covenantVaultsV1);
  await e.command('covenantVaultImport',{envelope:backup.envelope,password:Array.from(new TextEncoder().encode(native.password))});
  assert.deepEqual(e.store.covenantVaultsV1,before);
  const refreshed=await e.command('covenantVaultRefresh');assert(refreshed.items[0].pending);assert.notEqual(refreshed.items[0].record.status,'opened');
});
