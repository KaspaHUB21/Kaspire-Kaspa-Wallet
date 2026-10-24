import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import init, * as rawCore from './generated/wasm/kaspa_secure_core.mjs';
import {secureCore} from './generated/secretInputs.mjs';
import {standardKcc20TransferData} from './generated/standardKcc20.mjs';
import initKaspa,{payToScriptHashScript} from '../node_modules/@kronsdk/kron-sdk/vendor/kaspa/kaspa.js';
await initKaspa({module_or_path:await readFile(new URL('../node_modules/@kronsdk/kron-sdk/vendor/kaspa/kaspa_bg.wasm',import.meta.url))});

const exports=await init({module_or_path:await readFile(new URL('./generated/wasm/kaspa_secure_core_bg.wasm',import.meta.url))});
const core=secureCore(rawCore,exports.memory);
const template=JSON.parse(await readFile(new URL('../../../crates/kaspa_secure_core/src/kcc20_standard_template.json',import.meta.url),'utf8'));
const template10=JSON.parse(await readFile(new URL('../../../crates/kaspa_secure_core/src/kcc20_reference_10_template.json',import.meta.url),'utf8'));
// Public synthetic keys/outpoints only. No network calls or real broadcasts.
const secret='private:'+'11'.repeat(32);
const sender=JSON.parse(core.importPrivateKey('11'.repeat(32))).address;
const recipient=JSON.parse(core.importPrivateKey('22'.repeat(32))).address;
const owner=core.publicKey(secret);
assert.equal(owner,'4f355bdcb7cc0af728ef3cceb9615d90684bb5b2ca5f859ab0f0b704075871aa');
const redeemScript=template.prefix+'08e80300000000000020'+owner+'0100010020'+'0'.repeat(64)+'20'+'0'.repeat(64)+template.suffix;
// BLAKE2b-256 of the locally pinned template and fixed state above.
const scriptPublicKey='aa20855a2552d9b37d5da29c0ffa7de5c35d712440d66e77048bbb80e31ab2f769d187';
function request(count=1,compound=false) {
  return {sender,recipient:compound?sender:recipient,covenantId:'cc'.repeat(32),ticker:'WALLET',
    amount:compound?1000*count:500,decimals:0,feeRate:100,templateHash:'argent-kcc20-c8a0871',
    cells:Array.from({length:count},(_,i)=>({transactionId:(160+i).toString(16).repeat(32),index:0,
      valueSompi:100000000,blockDaaScore:123,scriptPublicKey,tokenAmount:1000,redeemScript})),
    fundingUtxosJson:JSON.stringify([{address:sender,outpoint:{transactionId:'bb'.repeat(32),index:0},
      utxoEntry:{amount:2000000000,scriptPublicKey:{version:0,scriptPublicKey:'20'+owner+'ac'},blockDaaScore:123,isCoinbase:false}}])};
}
function tenRequest(count) {
  const r=request(count);
  const redeem=template10.prefix+'08e80300000000000020'+owner+'0100010020'+'0'.repeat(64)+'20'+'0'.repeat(64)+template10.suffix;
  r.templateHash='argent-kcc20-c8a0871-10x10';r.amount=count*1000-1;
  for(const cell of r.cells) {
    cell.redeemScript=redeem;
    cell.scriptPublicKey='aa20f0e42e9ec8a417b1cfec8d650757c757f69689cf355d4bad5584dfd6ddea816787';
  }
  return r;
}
test('packaged WASM reuses a receiver cell without signing it for both pinned configurations',()=>{
  for(const [t,make] of [[template,request],[template10,tenRequest]]) {
    const r=make(1),recipientOwner=core.publicKey('private:'+'22'.repeat(32));
    const redeem=t.prefix+'08881300000000000020'+recipientOwner+'0100010120'+'0'.repeat(64)+'20'+'0'.repeat(64)+t.suffix;
    const script=payToScriptHashScript(redeem),scriptPublicKey=script.script;script.free();
    r.borrowedReceive={transactionId:'dd'.repeat(32),index:0,valueSompi:500000000,blockDaaScore:123,scriptPublicKey,tokenAmount:5000,redeemScript:redeem};
    const prepared=JSON.parse(core.prepareKronTransfer(JSON.stringify(r))),review=JSON.parse(core.preparePskt(JSON.stringify(prepared.psktRequest)));
    assert.equal(review.outputs[0].amountSompi,500000000);
    assert(prepared.psktRequest.scripts.every(s=>s.inputIndex!==0));
    const signed=JSON.parse(core.signPskt(secret,JSON.stringify(prepared.psktRequest),review.reviewHash));
    assert(!signed.signedInputIndexes.includes(0));
    const altered=structuredClone(r);altered.borrowedReceive.tokenAmount++;
    assert.throws(()=>core.prepareKronTransfer(JSON.stringify(altered)));
  }
});
test('actual WASM signs up to ten inputs directly, then compounds eleven without changing templates',()=>{
  for(const count of [4,7,10]){
    const r=tenRequest(count),prepared=JSON.parse(core.prepareKronTransfer(JSON.stringify(r)));
    assert.equal(prepared.covenantInputCount,count);
    assert.equal(prepared.templateHash,r.templateHash);
    const review=JSON.parse(core.preparePskt(JSON.stringify(prepared.psktRequest)));
    core.signPskt(secret,JSON.stringify(prepared.psktRequest),review.reviewHash);
    assert.equal(JSON.parse(core.prepareKcc20Plan(JSON.stringify(r))).transactionCount,1);
  }
  const r=tenRequest(11);
  assert.throws(()=>core.prepareKronTransfer(JSON.stringify(r)));
  const plan=JSON.parse(core.prepareKcc20Plan(JSON.stringify(r)));
  assert.equal(plan.transactionCount,2);assert.equal(plan.steps[0].covenantInputCount,10);
  const signed=JSON.parse(core.signKcc20Plan(secret,JSON.stringify(r),plan.reviewHash));
  assert.equal(signed.transactions.length,2);
  const changed=structuredClone(r);changed.templateHash='argent-kcc20-c8a0871';
  assert.throws(()=>core.signKcc20Plan(secret,JSON.stringify(changed),plan.reviewHash));
});
test('10/10 indexer reconstruction uses the same bytecode that the actual WASM verifies',async()=>{
  const r=tenRequest(10),cid=r.covenantId,spk=r.cells[0].scriptPublicKey;
  const envelope=data=>({data,meta:{network:'mainnet',reference_commit:template.referenceCommit}});
  const get=async url=>{
    const path=new URL(url).pathname,id=path.split('/').at(-1);
    if(path.endsWith('/balance'))return envelope({covenant_id:cid,owner_value:owner,owner_scheme:0,available:true,balance_raw:'10000',outputs:r.cells.map(c=>({txid:c.transactionId,output_index:0,balance_raw:'1000',amount_sompi:'100000000'}))});
    if(path.includes('/local-node/transactions/'))return {transaction_id:id,is_accepted:true,outputs:[{index:0,covenant_id:cid,amount:'100000000',script_public_key:spk,script_public_key_address:sender}]};
    if(path.endsWith('/utxos'))return r.cells.map(c=>({outpoint:{transactionId:c.transactionId,index:0},utxoEntry:{amount:'100000000',blockDaaScore:'123',isCoinbase:false,scriptPublicKey:{scriptPublicKey:spk}}}));
    if(path.includes('/transactions/'))return envelope({txid:id,outputs:[{io_index:0,actor:'KCC20',covenant_id:cid,token_amount:'1000',owner_scheme:0,owner_value:owner,state_hash_verified:true,template_hash:template10.templateHash,borrow_scheme:0,borrow_guard:'0'.repeat(64),extension_commitment:'0'.repeat(64)}]});
    throw Error('Unexpected '+url);
  };
  const batch=await standardKcc20TransferData(get,cid,owner,9999,{fullPlan:true});
  assert.equal(batch.inputLimit,10);assert.equal(batch.transactionCount,1);
  const prepared=JSON.parse(core.prepareKronTransfer(JSON.stringify({...r,cells:batch.cells,templateHash:batch.templateHash})));
  const review=JSON.parse(core.preparePskt(JSON.stringify(prepared.psktRequest)));
  core.signPskt(secret,JSON.stringify(prepared.psktRequest),review.reviewHash);
});
test('extension WASM routes standard KCC20 through review, signing and real local VM, including compounds',()=>{
  for(const count of [1,2,3])for(const compound of [false,true]) {
    const terms=request(count,compound);
    const prepared=JSON.parse(core.prepareKronTransfer(JSON.stringify(terms)));
    assert.equal(prepared.psktRequest.profile,'kcc20-standard-transfer-v1');
    assert.equal(prepared.covenantInputCount,count);
    assert.equal(prepared.covenantOutputCount,compound?1:2);
    const review=JSON.parse(core.preparePskt(JSON.stringify(prepared.psktRequest)));
    const signed=JSON.parse(core.signPskt(secret,JSON.stringify(prepared.psktRequest),review.reviewHash));
    assert.match(signed.transactionId,/^[0-9a-f]{64}$/);
    assert.equal(JSON.parse(signed.signedTxJson).outputs.length,compound?2:3);
  }
});
test('standard routing never bypasses ownership, live-script, template or input-limit validation',()=>{
  for(const change of [
    r=>{r.sender=recipient;},
    r=>{r.cells[0].scriptPublicKey='aa20'+'00'.repeat(32)+'87';},
    r=>{r.cells[0].redeemScript='00'+r.cells[0].redeemScript.slice(2);},
    r=>{r.cells[0].tokenAmount=999;},
    r=>{r.templateHash='unknown-template';},
  ]) {
    const terms=request();change(terms);
    assert.throws(()=>core.prepareKronTransfer(JSON.stringify(terms)));
  }
  assert.throws(()=>core.prepareKronTransfer(JSON.stringify(request(4))),/standard KCC20/);
});
test('one whole-plan approval binds every dependency, fee, amount and recipient and executes all covenant VMs',()=>{
  for(const count of [4,7]) {
    const terms=request(count);terms.amount=count*1000-1;
    const plan=JSON.parse(core.prepareKcc20Plan(JSON.stringify(terms)));
    assert.equal(plan.transactionCount,Math.ceil((count-1)/2));
    const signed=JSON.parse(core.signKcc20Plan(secret,JSON.stringify(terms),plan.reviewHash));
    assert.equal(signed.transactions.length,plan.transactionCount);
    assert.equal(signed.totalFeeSompi,plan.steps.reduce((sum,s)=>sum+s.feeSompi,0));
    signed.transactions.forEach((tx,i)=>assert.equal(tx.transactionId,plan.steps[i].transactionId));
    for(const mutate of [r=>r.amount--,r=>r.recipient=sender,r=>r.feeRate=101,r=>r.cells.reverse()]) {
      const other=structuredClone(terms);mutate(other);
      assert.throws(()=>core.signKcc20Plan(secret,JSON.stringify(other),plan.reviewHash));
    }
    assert.throws(()=>core.signKcc20Plan('private:'+'22'.repeat(32),JSON.stringify(terms),plan.reviewHash));
    const duplicate=structuredClone(terms);duplicate.cells[3]=duplicate.cells[0];
    assert.throws(()=>core.prepareKcc20Plan(JSON.stringify(duplicate)));
  }
});
test('full-plan discovery verifies seven original cells with shared origin and live proofs',async()=>{
  const terms=request(7);let detailReads=0,nodeReads=0;
  const envelope=data=>({data,meta:{network:'mainnet',reference_commit:template.referenceCommit}});
  // Use one accepted origin transaction with seven distinct output indices.
  const id='aa'.repeat(32), outputs=terms.cells.map((c,index)=>({...c,transactionId:id,index}));
  const get=async url=>{
    const path=new URL(url).pathname;
    if(path.endsWith('/balance'))return envelope({covenant_id:terms.covenantId,owner_value:owner,owner_scheme:0,available:true,balance_raw:'7000',outputs:outputs.map(c=>({txid:id,output_index:c.index,balance_raw:'1000',amount_sompi:'100000000'}))});
    if(path.includes('/local-node/transactions/')){nodeReads++;return {transaction_id:id,is_accepted:true,outputs:outputs.map(c=>({index:c.index,covenant_id:terms.covenantId,amount:'100000000',script_public_key:scriptPublicKey,script_public_key_address:sender}))};}
    if(path.endsWith('/utxos')){nodeReads++;return outputs.map(c=>({outpoint:{transactionId:id,index:c.index},utxoEntry:{amount:'100000000',blockDaaScore:'123',isCoinbase:false,scriptPublicKey:{scriptPublicKey}}}));}
    if(path.includes('/transactions/')){detailReads++;return envelope({txid:id,outputs:outputs.map(c=>({io_index:c.index,actor:'KCC20',covenant_id:terms.covenantId,token_amount:'1000',owner_scheme:0,owner_value:owner,state_hash_verified:true,template_hash:'9703112ee6e3555107cd168858992b77d3b74f655205b2b463b1f9ec2ec73cf7',borrow_scheme:0,borrow_guard:'0'.repeat(64),extension_commitment:'0'.repeat(64)}))});}
    throw Error('Unexpected '+url);
  };
  const batch=await standardKcc20TransferData(get,terms.covenantId,owner,6999,{fullPlan:true});
  assert.equal(batch.cells.length,7);assert.equal(batch.stepAmount,6999);assert.equal(batch.compound,false);
  assert.equal(batch.transactionCount,3);assert.equal(detailReads,1);assert.equal(nodeReads,2);
});
test('plan safety bound permits 65 cells / 32 transactions but rejects a larger plan before signing',()=>{
  const source=request(65);source.amount=65000;
  const plan=JSON.parse(core.prepareKcc20Plan(JSON.stringify(source)));
  assert.equal(plan.transactionCount,32);
  assert.equal(plan.steps.at(-1).psktRequest.tradeSummary.recipient,recipient);
  assert.equal(plan.steps.at(-1).psktRequest.tradeSummary.amount,65000);
  const signed=JSON.parse(core.signKcc20Plan(secret,JSON.stringify(source),plan.reviewHash));
  assert.equal(signed.transactions.length,32);
  const oversized=request(66);oversized.amount=66000;
  assert.throws(()=>core.prepareKcc20Plan(JSON.stringify(oversized)),/maximum 65/);
});
test('an ordinary payment consumes three owned cells without an extra consolidation or changing the recipient amount',async()=>{
  const terms=request(3),cid=terms.covenantId;
  const get=async url=>{
    const path=new URL(url).pathname,txid=path.split('/').at(-1);
    const envelope=data=>({data,meta:{network:'mainnet',reference_commit:template.referenceCommit}});
    if(path.endsWith('/balance'))return envelope({covenant_id:cid,owner_value:owner,owner_scheme:0,available:true,balance_raw:'3000',outputs:terms.cells.map(c=>({txid:c.transactionId,output_index:0,balance_raw:'1000',amount_sompi:'100000000'}))});
    if(path.includes('/local-node/transactions/'))return {transaction_id:txid,is_accepted:true,outputs:[{index:0,covenant_id:cid,amount:'100000000',script_public_key:scriptPublicKey,script_public_key_address:sender}]};
    if(path.endsWith('/utxos'))return terms.cells.map(c=>({outpoint:{transactionId:c.transactionId,index:0},utxoEntry:{amount:'100000000',blockDaaScore:'123',isCoinbase:false,scriptPublicKey:{scriptPublicKey}}}));
    if(path.includes('/transactions/'))return envelope({txid,outputs:[{io_index:0,actor:'KCC20',covenant_id:cid,token_amount:'1000',owner_scheme:0,owner_value:owner,state_hash_verified:true,template_hash:'9703112ee6e3555107cd168858992b77d3b74f655205b2b463b1f9ec2ec73cf7',borrow_scheme:0,borrow_guard:'0'.repeat(64),extension_commitment:'0'.repeat(64)}]});
    throw Error('Unexpected URL '+url);
  };
  const data=await standardKcc20TransferData(get,cid,owner,500);
  assert.equal(data.compound,false);assert.equal(data.cells.length,3);assert.equal(data.transactionCount,1);
  terms.cells=data.cells;terms.amount=data.stepAmount;
  const prepared=JSON.parse(core.prepareKronTransfer(JSON.stringify(terms)));
  assert.equal(prepared.psktRequest.tradeSummary.amount,500);
  assert.equal(prepared.psktRequest.tradeSummary.recipient,recipient);
  assert.equal(prepared.tokenChange,2500);
  const review=JSON.parse(core.preparePskt(JSON.stringify(prepared.psktRequest)));
  const signed=JSON.parse(core.signPskt(secret,JSON.stringify(prepared.psktRequest),review.reviewHash));
  assert.match(signed.transactionId,/^[0-9a-f]{64}$/);
});
