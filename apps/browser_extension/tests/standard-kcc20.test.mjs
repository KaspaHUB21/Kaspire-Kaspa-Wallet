import {test} from 'node:test';
import assert from 'node:assert/strict';
import {standardKcc20Assets,standardKcc20TransferData,waitForStandardKcc20Cell,STANDARD_TEMPLATE} from './generated/standardKcc20.mjs';
const cid='c'.repeat(64),owner='d'.repeat(64),address='kaspa:'+'q'.repeat(61);
const reference='c8a087117735a1f87c5c6d115fcddeaf2562c784';
const templateHash='9703112ee6e3555107cd168858992b77d3b74f655205b2b463b1f9ec2ec73cf7';
const id=i=>i.toString(16).padStart(64,'0');
function source({amounts=[10,10,10,10],borrow=false,spent=false,wrongOwner=false,wrongCid=false,network='mainnet',programHash=templateHash}={}) {
  const seen=[];
  const get=async url=>{
    seen.push(url);const u=new URL(url),p=u.pathname;
    const envelope=data=>({data,meta:{network,reference_commit:reference}});
    if(p.endsWith('/status'))return envelope({status:'ready'});
    if(p.endsWith('/tokens'))return envelope([{covenant_id:cid,profile_id:'KCC20PublicMint@c8a0871',recognition:'hash_proven_reference_actor_family',metadata:{binding_verified:true,ticker:'test',decimals:0}}]);
    if(p.endsWith('/balance'))return envelope({covenant_id:cid,owner_value:owner,owner_scheme:0,available:true,balance_raw:String(amounts.reduce((s,x)=>s+x,0)),outputs:amounts.map((a,i)=>({txid:id(i),output_index:0,balance_raw:String(a),amount_sompi:'100000000'}))});
    if(p.includes('/local-node/transactions/'))return {transaction_id:p.split('/').at(-1),is_accepted:true,outputs:[{index:0,covenant_id:wrongCid?'e'.repeat(64):cid,amount:'100000000',script_public_key:'aa',script_public_key_address:address}]};
    if(p.endsWith('/utxos'))return spent?[]:amounts.map((a,i)=>({outpoint:{transactionId:id(i),index:0},utxoEntry:{amount:'100000000',blockDaaScore:'123',isCoinbase:false,scriptPublicKey:{scriptPublicKey:'aa'}}}));
    if(p.includes('/transactions/')) {
      const txid=p.split('/').at(-1),i=parseInt(txid,16);
      return envelope({txid,outputs:[{io_index:0,actor:'KCC20',covenant_id:cid,token_amount:String(amounts[i]),owner_scheme:0,owner_value:wrongOwner?'e'.repeat(64):owner,state_hash_verified:true,template_hash:programHash,borrow_scheme:borrow?1:0,borrow_guard:'0'.repeat(64),extension_commitment:'0'.repeat(64)}]});
    }
    throw Error('Unexpected URL '+url);
  };return {get,seen};
}
test('10/10 proof controls batching; eleven cells require a two-step payment plan',async()=>{
  const hash='ff3ae732e3a2819bf9181f5aed6b1e9d0f7abea70a1dd655b8e777cbcbd2422b';
  for(const n of [10,11]) {
    const s=source({amounts:Array(n).fill(10),programHash:hash});
    const batch=await standardKcc20TransferData(s.get,cid,owner,n*10-1);
    assert.equal(batch.inputLimit,10);assert.equal(batch.templateHash,'argent-kcc20-c8a0871-10x10');
    assert.equal(batch.cells.length,10);assert.equal(batch.compound,n>10);
    assert.equal(batch.transactionCount,n===10?1:2);
    const full=await standardKcc20TransferData(s.get,cid,owner,n*10-1,{fullPlan:true});
    assert.equal(full.cells.length,n);assert.equal(full.transactionCount,n===10?1:2);
  }
});
test('unsupported or mixed program hashes never become a ten-input transfer',async()=>{
  await assert.rejects(standardKcc20TransferData(source({programHash:'f'.repeat(64)}).get,cid,owner,40),/Unsupported KCC20 program/);
  const s=source({amounts:[10,10,10,10],programHash:'ff3ae732e3a2819bf9181f5aed6b1e9d0f7abea70a1dd655b8e777cbcbd2422b'});
  const get=async url=>{
    const r=await s.get(url);
    if(url.endsWith('/transactions/'+id(1)))r.data.outputs[0].template_hash=templateHash;
    return r;
  };
  await assert.rejects(standardKcc20TransferData(get,cid,owner,40),/reconstructed state differs/);
});
test('standard discovery is KCC20, never Last Call, and has verified decimals',async()=>{
  const s=source(),assets=await standardKcc20Assets(s.get,owner);
  assert.equal(assets[0].standard,'kcc20');assert.equal(assets[0].symbol,'TEST');assert.equal(assets[0].decimals,0);
});
test('one unavailable token never erases other standard KCC20 holdings',async()=>{
  const s=source();let warning='';
  const get=async url=>{
    const v=await s.get(url);
    if(new URL(url).pathname.endsWith('/tokens'))v.data.push({...v.data[0],covenant_id:'b'.repeat(64)});
    return v; // second balance fails the covenant-ID binding check
  };
  const rows=await standardKcc20Assets(get,owner,w=>{warning=w;});
  assert.equal(rows.length,1);assert.equal(rows[0].covenantId,cid);
  assert.match(warning,/Some standard KCC20 balances/);
});
test('concurrent holdings coalesce and cache, but signing always fetches fresh state',async()=>{
  const s=source();
  const [a,b]=await Promise.all([standardKcc20Assets(s.get,owner),standardKcc20Assets(s.get,owner)]);
  assert.deepEqual(a,b);await standardKcc20Assets(s.get,owner);
  assert.equal(s.seen.filter(u=>u.includes('/balance?')).length,1);
  await standardKcc20TransferData(s.get,cid,owner,10);
  assert.equal(s.seen.filter(u=>u.includes('/balance?')).length,2);
});
test('429 is retried with backoff and sequentially paced catalogue/balance requests',async()=>{
  const s=source(),starts=[];let attempts=0;
  const get=async url=>{
    starts.push(Date.now());
    if(url.includes('/balance?') && ++attempts===1)throw Object.assign(Error('HTTP 429'),{httpStatus:429});
    return s.get(url);
  };
  const rows=await standardKcc20Assets(get,owner);
  assert.equal(rows.length,1);assert.equal(attempts,2);
  for(let i=1;i<starts.length;i++)assert.ok(starts[i]-starts[i-1]>=250);
  assert.ok(starts.at(-1)-starts.at(-2)>=1400);
});
test('verified dotted KCC20 symbols remain visible',async()=>{
  const s=source();
  const rows=await standardKcc20Assets(async url=>{
    const v=await s.get(url);if(new URL(url).pathname.endsWith('/tokens'))v.data[0].metadata.ticker='Wobbly.k';return v;
  },owner);
  assert.equal(rows[0].symbol,'WOBBLY.K');
});
test('four cells produce three-input self-compound with pinned program and node proof',async()=>{
  const s=source(),p=await standardKcc20TransferData(s.get,cid,owner,40);
  assert.equal(p.compound,true);assert.equal(p.stepAmount,30);assert.equal(p.cells.length,3);
  assert.equal(p.requiredCells,4);assert.equal(p.transactionCount,2);
  assert.equal(p.templateHash,STANDARD_TEMPLATE);assert.ok(p.cells[0].redeemScript.includes(owner));
  assert.ok(s.seen.some(u=>u.includes('/local-node/transactions/')));
  assert.ok(s.seen.some(u=>u.endsWith('/utxos')));
});
test('normal payments use the covering cell plus small leftovers, without a separate compound',async()=>{
  const s=source({amounts:[1,1,1,90]});const p=await standardKcc20TransferData(s.get,cid,owner,80);
  assert.equal(p.compound,false);assert.equal(p.cells.length,3);assert.equal(p.cells[0].tokenAmount,90);
  assert.equal(p.transactionCount,1);assert.deepEqual(p.cells.slice(1).map(c=>c.tokenAmount),[1,1]);
});
test('an incompatible optional dust cell is skipped; it cannot break or alter a valid payment',async()=>{
  const s=source({amounts:[90,1,1,1]});
  const get=async url=>{
    const v=await s.get(url);
    if(url.endsWith('/transactions/'+id(2))&&!url.includes('/local-node/'))v.data.outputs[0].extension_commitment='e'.repeat(64);
    return v;
  };
  const p=await standardKcc20TransferData(get,cid,owner,80);
  assert.equal(p.compound,false);assert.equal(p.stepAmount,80);assert.equal(p.cells.length,2);
  assert.ok(p.cells.every(c=>!Object.hasOwn(c,'extension')));
});
test('waiting after a consolidation only checks readiness, not repeated signing/node proofs',async()=>{
  const s=source();await waitForStandardKcc20Cell(s.get,cid,owner,id(0));
  assert.equal(s.seen.length,1);assert.ok(s.seen[0].includes('/balance?'));
});
test('closing a preparation aborts before requesting another signing proof',async()=>{
  const s=source(),cancel=new AbortController();cancel.abort();
  await assert.rejects(standardKcc20TransferData(s.get,cid,owner,40,{signal:cancel.signal}));
  assert.equal(s.seen.length,0);
});
test('cells from one origin/address share their immutable transaction and fresh live-UTXO reads',async()=>{
  const calls=[];
  const get=async url=>{
    calls.push(url);const path=new URL(url).pathname;
    const envelope=data=>({data,meta:{network:'mainnet',reference_commit:reference}});
    if(path.endsWith('/balance'))return envelope({covenant_id:cid,owner_value:owner,owner_scheme:0,available:true,balance_raw:'30',outputs:[0,1,2].map(i=>({txid:id(0),output_index:i,balance_raw:'10',amount_sompi:'100000000'}))});
    if(path.includes('/local-node/transactions/'))return {transaction_id:id(0),is_accepted:true,outputs:[0,1,2].map(index=>({index,covenant_id:cid,amount:'100000000',script_public_key:'aa',script_public_key_address:address}))};
    if(path.endsWith('/utxos'))return [0,1,2].map(index=>({outpoint:{transactionId:id(0),index},utxoEntry:{amount:'100000000',blockDaaScore:'123',isCoinbase:false,scriptPublicKey:{scriptPublicKey:'aa'}}}));
    if(path.includes('/transactions/'))return envelope({txid:id(0),outputs:[0,1,2].map(io_index=>({io_index,actor:'KCC20',covenant_id:cid,token_amount:'10',owner_scheme:0,owner_value:owner,state_hash_verified:true,template_hash:templateHash,borrow_scheme:0,borrow_guard:'0'.repeat(64),extension_commitment:'0'.repeat(64)}))});
    throw Error('Unexpected '+url);
  };
  const p=await standardKcc20TransferData(get,cid,owner,30);
  assert.equal(p.cells.length,3);assert.equal(calls.length,4);
  assert.equal(new Set(calls).size,4);
});
test('spent cells, foreign owner/covenant, borrowing policy and network mismatches fail closed',async()=>{
  for(const options of [{spent:true},{wrongOwner:true},{wrongCid:true},{borrow:true},{network:'testnet'}]) {
    const s=source(options);await assert.rejects(standardKcc20TransferData(s.get,cid,owner,40));
  }
});
