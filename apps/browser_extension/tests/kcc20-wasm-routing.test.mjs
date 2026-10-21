import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import init, * as rawCore from './generated/wasm/kaspa_secure_core.mjs';
import {secureCore} from './generated/secretInputs.mjs';
import {standardKcc20TransferData} from './generated/standardKcc20.mjs';

const exports=await init({module_or_path:await readFile(new URL('./generated/wasm/kaspa_secure_core_bg.wasm',import.meta.url))});
const core=secureCore(rawCore,exports.memory);
const template=JSON.parse(await readFile(new URL('../../../crates/kaspa_secure_core/src/kcc20_standard_template.json',import.meta.url),'utf8'));
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
