import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import init, * as rawCore from './generated/wasm/kaspa_secure_core.mjs';
import { secureCore } from './generated/secretInputs.mjs';
import { p2shCommand, emptyP2shState, validateP2shState, clearP2shReviews, parseP2shKas } from './generated/p2sh.mjs';

const wasm = await readFile(new URL('./generated/wasm/kaspa_secure_core_bg.wasm', import.meta.url));
const exports = await init({ module_or_path: wasm });
const { deriveHiddenKas, validateHiddenKasUtxos, prepareHiddenKas, signHiddenKas, verifyHiddenKasRecovery } = secureCore(rawCore, exports.memory);
const fixture = JSON.parse(execFileSync('cargo', ['run','--locked','--quiet','-p','kaspa_secure_core','--example','hidden_browser_fixture'], { cwd: '../..', maxBuffer: 2 * 1024 * 1024 }).toString());
const parse = JSON.parse, secret = fixture.secret;
test('KIP-22 WASM matches native/Android addresses, reviews, signature IDs, VM and recovery for fixed amount and Max', () => {
  assert.deepEqual(parse(deriveHiddenKas(secret, 0, 0, 2)), fixture.addresses);
  for (const c of fixture.cases) {
    assert.deepEqual(parse(prepareHiddenKas(secret, JSON.stringify(c.request))), c.review);
    const saved = parse(signHiddenKas(secret, JSON.stringify(c.request), c.review.reviewHash)); saved.request = c.request;
    assert.equal(saved.transactionId, c.saved.transactionId);
    assert.equal(verifyHiddenKasRecovery(secret, JSON.stringify(saved)), 'true');
    const changed = structuredClone(saved); changed.transactionId = 'f'.repeat(64);
    assert.throws(() => verifyHiddenKasRecovery(secret, JSON.stringify(changed)), /differs/);
    assert.throws(() => signHiddenKas(secret, JSON.stringify({ ...c.request, recipient: fixture.addresses[0].address }), c.review.reviewHash));
  }
  assert.throws(() => deriveHiddenKas('private:' + '09'.repeat(32), 0, 0, 1), /root mnemonic/);
  const a = fixture.addresses[0];
  assert.equal(validateHiddenKasUtxos(secret, JSON.stringify(a), JSON.stringify([fixture.rows[0]])), '1000000000');
  assert.throws(() => validateHiddenKasUtxos(secret, JSON.stringify(a), JSON.stringify([fixture.rows[1]])));
  assert.throws(() => validateHiddenKasUtxos(secret, JSON.stringify({ ...a, index: 2 }), JSON.stringify([])), /active seed/);
});
test('serialized WASM P2SH transactions pass the independent unmodified official node validator', () => {
  const cases=fixture.cases.map(c=>({...c,saved:parse(signHiddenKas(secret,JSON.stringify(c.request),c.review.reviewHash))}));
  const checked=JSON.parse(execFileSync('node',['../../scripts/check_p2sh_consensus.mjs','-'],{input:JSON.stringify({cases}),maxBuffer:2*1024*1024}));
  assert.equal(checked.nodeRelease,'v2.1.0');assert.equal(checked.networkAccess,false);
  assert.equal(checked.validTransactions,cases.length);assert.equal(checked.rejectedMutations,cases.length*7);
});
test('P2SH recovery validation preserves issued/retired keys and rejects malformed journals', () => {
  assert.deepEqual(validateP2shState(emptyP2shState()), emptyP2shState());
  const s = { ...emptyP2shState(), receiveCount: 2, changeCount: 1, exposed: ['0:0','0:1','1:0'], pending: fixture.cases[0].saved };
  assert.deepEqual(validateP2shState(s), s);
  for (const changed of [{ ...s, receiveCount: -1 }, { ...s, exposed: ['0:3'] }, { ...s, exposed: ['0:0','0:0'] }, { ...s, descriptor: 'foreign' }, { ...s, pending: { ...s.pending, transactionId: 'wrong' } }]) assert.throws(() => validateP2shState(changed));
  assert.equal(parseP2shKas('1.00000001'), '100000001');
  for (const text of ['0','-1','NaN','1,2','1e8','1.000000001']) assert.throws(() => parseP2shKas(text));
});
let virtual = Date.now();
function environment(t) {
  const oldFetch = globalThis.fetch, oldChrome = globalThis.chrome, events = [], starts = [];
  let state = emptyP2shState(), persisted = structuredClone(state), locked = false, accepted = true, proof = false, broadcastProof = true, unavailable = false, badResponse = false, response429 = 0, failureAt = '', lastBytes = '', afterApprove = null, postReply = null;
  const funding = new Map(fixture.addresses.map((a,i) => [a.address, [fixture.rows[i]]]));
  globalThis.chrome = { runtime: { getURL: () => wasm } };
  globalThis.fetch = async (url, options = {}) => {
    url = String(url); starts.push({time:virtual, method:options.method ?? 'GET',url});
    if (options.method === 'POST') {
      assert.equal(url,'https://kaspire.kaslab.space/api/transactions','POST must never use the read-only /local-node namespace');
      events.push('broadcast'); assert(persisted.pending, 'signed journal must be durable before broadcast'); assert(persisted.exposed.includes('1:0'));
      assert.equal(options.body, persisted.pending.submitJson); lastBytes = options.body;
      if (unavailable) throw Error('offline');
      if (postReply) { proof = postReply.accepted; return new Response(JSON.stringify(postReply.body),{status:postReply.status}); }
      proof = broadcastProof; return new Response(JSON.stringify({transactionId:state.pending.transactionId}));
    }
    if (response429 > 0) { response429--; return new Response('{}', {status:429, headers:{'retry-after':'1'}}); }
    if (badResponse) return new Response('{}', {status:503});
    if (url.includes('/info/fee-estimate')) return new Response(JSON.stringify({priorityBucket:{feerate:100}}));
    if (url.includes('/full-transactions')) assert(url.startsWith('https://kaspire.kaslab.space/api/local-node/'), 'P2SH history must not fan out through the public merged indexer');
    if (url.includes('/transactions/') && !url.includes('/full-transactions')) {
      assert(url.startsWith('https://kaspire.kaslab.space/api/local-node/transactions/'),'confirmation must stay pinned to the own-node route');
      return new Response(JSON.stringify(proof ? {transaction_id:state.pending.transactionId, is_accepted:true} : {}), {status:proof?200:404});
    }
    const address = decodeURIComponent(url.match(/\/addresses\/([^/]+)/)?.[1] ?? '');
    if (url.includes('/utxos')) return new Response(JSON.stringify(funding.get(address) ?? []));
    if (url.includes('/full-transactions')) return new Response('[]');
    throw Error('Unexpected test request: '+url);
  };
  clearP2shReviews(); t.after(() => { globalThis.fetch = oldFetch; globalThis.chrome = oldChrome; clearP2shReviews(); });
  const context = {
    walletId:'synthetic-wallet', binding:'generation:revision:root-wallet:address', clock:()=>virtual, delay:async ms=>{virtual+=ms;},
    guard: async () => { if (locked) throw Error('Wallet locked'); }, load:()=>structuredClone(state),
    save: async next => { events.push(next.pending ? 'persist-signed' : 'persist'); state = structuredClone(next); if (failureAt === (next.pending ? 'signed' : 'retirement') && (next.pending || next.exposed.includes('1:0'))) throw Error('Persistence failed'); persisted = structuredClone(state); },
    derive: async (...args) => parse(deriveHiddenKas(secret, ...args)),
    validate: async (a, rows) => validateHiddenKasUtxos(secret, JSON.stringify(a), JSON.stringify(rows)),
    prepare: async request => parse(prepareHiddenKas(secret, JSON.stringify(request))),
    sign: async (request, hash) => { events.push('sign'); assert(persisted.exposed.includes('1:0'), 'retirement must be durable before signing'); return parse(signHiddenKas(secret, JSON.stringify(request), hash)); },
    verify: async saved => { verifyHiddenKasRecovery(secret, JSON.stringify(saved)); },
    approve: async () => { events.push('approve'); afterApprove?.(); return accepted; }, progress:stage=>{events.push(stage);},
  };
  return {context, events, starts, funding, command:(command, data={})=>p2shCommand(context,{command,...data}), state:()=>structuredClone(state), persisted:()=>structuredClone(persisted), bytes:()=>lastBytes,
    setLocked:value=>{locked=value;}, setAccepted:value=>{accepted=value;}, setProof:value=>{proof=value;}, setBroadcastProof:value=>{broadcastProof=value;}, setOffline:value=>{unavailable=value;}, setBadResponse:value=>{badResponse=value;}, set429:value=>{response429=value;}, fail:value=>{failureAt=value;}, afterApprove:fn=>{afterApprove=fn;}, reply:(status,body,accepted=false)=>{postReply={status,body,accepted};}};
}
const prepare = e => e.command('p2shPrepare',{recipient:fixture.cases[0].request.recipient, amount:'1'});
test('P2SH discovery reads fresh outputs, retires used keys and issues only after persistence', async t => {
  const e = environment(t); const result = await e.command('p2shRefresh');
  assert.equal(result.balanceSompi, '2000000000'); assert.equal(result.receive.index, 2);
  assert.deepEqual(e.persisted().exposed, ['0:0','0:1']); assert.equal(e.persisted().receiveCount, 3);
  assert(!e.events.includes('sign')); assert(!e.events.includes('broadcast'));
  const starts = e.starts.filter(s=>s.method==='GET'); for(let i=1;i<starts.length;i++) assert(starts[i].time-starts[i-1].time>=100);
  e.funding.set(fixture.addresses[1].address, []);
  const next=await e.command('p2shRefresh');assert.equal(next.balanceSompi,'1000000000'); assert.equal(next.receive.index,2);
});
test('three repeated reloads and activity use only the own node, not public history', async t => {
  const e=environment(t);
  for(let i=0;i<3;i++) assert.equal((await e.command('p2shRefresh')).balanceSompi,'2000000000');
  const histories=e.starts.filter(row=>row.url.includes('/full-transactions'));
  assert(histories.length>0);
  assert(histories.every(row=>row.url.startsWith('https://kaspire.kaslab.space/api/local-node/')));
  assert(!e.events.includes('sign'));assert(!e.events.includes('broadcast'));
});
test('P2SH approval, retirement, signing, persistence, broadcast, and proof execute in that order', async t => {
  const e = environment(t), p = await prepare(e);
  const result = await e.command('p2shSubmit',{id:p.id}); assert.equal(result.confirmed,true); assert(!e.state().pending);
  const stages=e.events.filter(s=>['approve','sign','persist-signed','broadcast'].includes(s)); assert.deepEqual(stages,['approve','sign','persist-signed','persist-signed','broadcast']);
  assert(e.state().exposed.includes('1:0'));
});
test('Max is rebuilt in WASM with fee deduction and no change output', async t => {
  const e = environment(t), p = await e.command('p2shPrepare',{recipient:fixture.cases[0].request.recipient, sendAll:true});
  assert.equal(BigInt(p.review.amountSompi)+BigInt(p.review.feeSompi),2000000000n); assert.equal(p.review.changeSompi,0); assert.equal(p.review.sendAll,true);
  assert.equal((await e.command('p2shSubmit',{id:p.id})).confirmed,true);
});
test('lock during approval, rejected approval and changed context never sign', async t => {
  const e = environment(t), p = await prepare(e);
  await assert.rejects(p2shCommand({...e.context,binding:'other'},{command:'p2shSubmit',id:p.id}),/expired/);
  e.setAccepted(false); await assert.rejects(e.command('p2shSubmit',{id:p.id}),/rejected/);
  e.setAccepted(true); e.afterApprove(()=>e.setLocked(true));
  await assert.rejects(e.command('p2shSubmit',{id:p.id}),/Wallet locked/);
  assert(!e.events.includes('sign')); assert(!e.events.includes('broadcast'));
});
test('changed UTXOs prevent signing and failed persistence never broadcasts', async t => {
  const e = environment(t), p = await prepare(e);
  e.afterApprove(()=>e.funding.set(fixture.addresses[0].address,[]));
  await assert.rejects(e.command('p2shSubmit',{id:p.id}),/outputs changed/); assert(!e.events.includes('sign'));
  e.afterApprove(null); e.funding.set(fixture.addresses[0].address,[fixture.rows[0]]);
  e.fail('retirement'); await assert.rejects(e.command('p2shSubmit',{id:p.id}),/Persistence failed/); assert(!e.events.includes('sign')); assert(!e.events.includes('broadcast'));
});
test('unconfirmed/ambiguous submission saves exact bytes, prevents replacements and resumes without signing', async t => {
  const e = environment(t), p = await prepare(e); e.setBroadcastProof(false);e.setOffline(true);
  const result = await e.command('p2shSubmit',{id:p.id}); assert.equal(result.confirmed,false); const saved=e.state().pending.submitJson;
  await assert.rejects(prepare(e),/saved payment/);
  e.setOffline(false);e.setBroadcastProof(true);
  const resumed = await e.command('p2shResume');assert.equal(resumed.confirmed,true);assert.equal(e.bytes(),saved);assert.equal(e.events.filter(x=>x==='sign').length,1);
});
test('already-accepted saved payments are cleared without another POST', async t => {
  const e = environment(t), p = await prepare(e);e.setBroadcastProof(false);
  await e.command('p2shSubmit',{id:p.id});const count=e.events.filter(x=>x==='broadcast').length;e.setProof(true);
  assert.equal((await e.command('p2shResume')).confirmed,true);assert.equal(e.events.filter(x=>x==='broadcast').length,count);
});
test('a failed signed-journal write cannot broadcast, and aborting a view stops approval/signing', async t => {
  const e=environment(t),p=await prepare(e);e.fail('signed');
  await assert.rejects(e.command('p2shSubmit',{id:p.id}),/Persistence failed/);
  assert.equal(e.events.filter(x=>x==='sign').length,1);assert(!e.events.includes('broadcast'));assert(e.persisted().exposed.includes('1:0'));assert(!e.persisted().pending);
  await assert.rejects(e.command('p2shResume'),/Persistence failed/);assert(!e.events.includes('broadcast'));
  e.fail('');assert.equal((await e.command('p2shResume')).confirmed,true);assert.equal(e.events.filter(x=>x==='sign').length,1);
  const abort=new AbortController();abort.abort();
  await assert.rejects(p2shCommand({...e.context,signal:abort.signal,guard:async()=>abort.signal.throwIfAborted()},{command:'p2shResume'}));
  assert.equal(e.events.filter(x=>x==='broadcast').length,1);
});
test('429 GET retries are paced and lookup failure never becomes a zero balance', async t => {
  const e=environment(t);e.set429(2);assert.equal((await e.command('p2shRefresh')).balanceSompi,'2000000000');
  e.setBadResponse(true);await assert.rejects(e.command('p2shRefresh'),/lookup unavailable/);assert(!e.events.includes('sign'));
});
for(const status of [400,401,403,404,405,422]) {
  test(`definitive HTTP ${status} submission rejection is shown immediately, with exact bytes retained`,async t=>{
    const e=environment(t),p=await prepare(e);e.reply(status,{detail:'Explicit rejection from node'});
    const before=virtual;
    await assert.rejects(e.command('p2shSubmit',{id:p.id}),new RegExp(`HTTP ${status}.*Explicit rejection from node`));
    assert(virtual-before<2000,'do not disguise rejection as a 30-second confirmation wait');
    assert(!e.events.includes('Waiting for own-node confirmation…'));assert(e.persisted().pending);
    assert(e.starts.filter(row=>row.method==='POST').every(row=>row.url.endsWith('/api/transactions')));
    const saved=e.persisted().pending.submitJson;e.reply(200,{transactionId:e.state().pending.transactionId},true);
    assert.equal((await e.command('p2shResume')).confirmed,true);assert.equal(e.bytes(),saved);assert.equal(e.events.filter(x=>x==='sign').length,1);
  });
}
test('a mismatching submission ID is not swallowed or treated as confirmation',async t=>{
  const e=environment(t),p=await prepare(e);e.reply(200,{transactionId:'f'.repeat(64)},true);
  await assert.rejects(e.command('p2shSubmit',{id:p.id}),/different transaction ID/);
  assert(e.persisted().pending);assert(!e.events.includes('Waiting for own-node confirmation…'));
  const count=e.events.filter(x=>x==='broadcast').length;
  assert.equal((await e.command('p2shResume')).confirmed,true);assert.equal(e.events.filter(x=>x==='broadcast').length,count);
});
test('already-known responses and acceptance races still require exact own-node confirmation',async t=>{
  const e=environment(t),p=await prepare(e);e.reply(409,{detail:'Transaction already in mempool'},false);
  const result=await e.command('p2shSubmit',{id:p.id});assert.equal(result.confirmed,false);assert(e.state().pending);assert.match(result.submissionIssue,/HTTP 409/);
  e.reply(400,{detail:'Transient race: node accepted transaction'},true);
  assert.equal((await e.command('p2shResume')).confirmed,true);assert.equal(e.events.filter(x=>x==='sign').length,1);
});
test('ambiguous server failures expose the HTTP reason after the bounded confirmation check',async t=>{
  const e=environment(t),p=await prepare(e);e.reply(503,{detail:'Node temporarily unavailable'},false);
  const result=await e.command('p2shSubmit',{id:p.id});assert.equal(result.confirmed,false);assert.match(result.submissionIssue,/HTTP 503.*Node temporarily unavailable/);assert(e.persisted().pending);
});
test('a payment journal saved by 0.5.10 resumes through the corrected route without creating or signing another payment',async t=>{
  const e=environment(t),saved=structuredClone(fixture.cases[0].saved);
  // Previous extension requests used decimal strings at the JS boundary.
  saved.request.amountSompi=String(saved.request.amountSompi);
  await e.context.save({...emptyP2shState(),receiveCount:2,changeCount:1,exposed:['0:0','0:1','1:0'],pending:saved});
  const bytes=saved.submitJson,id=saved.transactionId;
  const result=await e.command('p2shResume');
  assert.equal(result.confirmed,true);assert.equal(result.transactionId,id);assert.equal(e.bytes(),bytes);
  assert(!e.events.includes('approve'));assert(!e.events.includes('sign'));assert(!e.persisted().pending);
});
