import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import init,* as raw from './generated/wasm/kaspa_secure_core.mjs';
import {secureCore} from './generated/secretInputs.mjs';
import {ownerAddress} from './generated/publicCrypto.mjs';
import poolInit,* as native from './generated/trestly/trestly_web_core.js';
const memory=(await init({module_or_path:await readFile(new URL('./generated/wasm/kaspa_secure_core_bg.wasm',import.meta.url))})).memory,core=secureCore(raw,memory);
const poolExports=await poolInit({module_or_path:await readFile(new URL('./generated/trestly/trestly_web_core_bg.wasm',import.meta.url))});
const fixture=JSON.parse(await readFile(new URL('../../../crates/kaspa_secure_core/src/trestly_mainnet_pool_fixture.json',import.meta.url))),phrase='abandon '.repeat(11)+'about';
async function plan(secret,side){
 const owner=core.publicKey(secret),address=await ownerAddress(owner,'mainnet'),poolState=fixture.pool.state,payerState={amount:1234567,owner,ownerScheme:0,borrowScheme:0,borrowGuard:'00'.repeat(32),extensionCommitment:'00'.repeat(32)};
 const d=JSON.parse(native.describeTrestly(JSON.stringify({poolState,payerState}))),coin=(id,amount,scriptPublicKey,covenantId)=>({transactionId:id.repeat(32),index:0,amount,scriptPublicKey,blockDaaScore:1000,isCoinbase:false,covenantId});
 return {sender:address,side,amountIn:side==='buy'?'100000000':'1234567',minOut:'1',maxFeeSompi:'100000000',feerate:100,nowDaa:'2010',pool:{state:poolState,utxo:coin('11',Number(d.poolAmount),d.poolScript,d.poolId)},reserve:{state:d.reserveState,utxo:coin('22',150000000,d.reserveScript,d.tokenId)},payer:side==='buy'?null:{state:payerState,utxo:coin('33',150000000,d.payerScript,d.tokenId)},funding:[coin('44',200000000000,'000020'+owner+'ac',null)]};
}
const sign=(secret,request,hash)=>{const b=new TextEncoder().encode(secret);try{return JSON.parse(native.signTrestly(b,JSON.stringify(request),hash));}finally{b.fill(0);}};
test('isolated pinned signer supports the same mnemonic, HD, Unicode passphrase and private keys',async()=>{
 const unicode='päss 🔑',passphrase='mnemonic-passphrase:'+Buffer.from(unicode).toString('hex')+':'+phrase;
 for(const secret of ['mnemonic:'+phrase,"hd-path:m/44'/111111'/1'/0/2:mnemonic:"+phrase,passphrase,'private:'+'01'.repeat(32)]){
  for(const side of ['buy','sell']){const req=await plan(secret,side),review=JSON.parse(native.prepareTrestly(JSON.stringify(req))),signed=sign(secret,req,review.reviewHash),tx=JSON.parse(signed.wrpcJson);assert.equal(signed.review.sender,req.sender);assert.equal(signed.review.side,side);assert(tx.inputs.every(i=>i.computeBudget>0));assert.match(signed.transactionId,/^[a-f0-9]{64}$/);assert(BigInt(signed.feeSompi)<=100000000n);assert(tx.inputs.every(i=>typeof i.signatureScript==='string'&&i.signatureScript.length>0));assert.throws(()=>sign(secret,{...req,maxFeeSompi:'99999999'},review.reviewHash),/review/);}
 }
});
test('native core rejects incorrect keys, changed covenant scripts and malformed UTF8 without leaking sentinels',async()=>{
 const req=await plan('mnemonic:'+phrase,'buy'),review=JSON.parse(native.prepareTrestly(JSON.stringify(req)));
 assert.throws(()=>sign('private:'+'02'.repeat(32),req,review.reviewHash),/control/);
 assert.throws(()=>native.prepareTrestly(JSON.stringify({...req,reserve:{...req.reserve,utxo:{...req.reserve.utxo,scriptPublicKey:'000051'}}})),/mismatch/);
 const marker=new TextEncoder().encode('NATIVE-SECRET-ERASURE-CHECK-'.repeat(12)),bytes=new Uint8Array(marker.length+1);bytes.set(marker);bytes[bytes.length-1]=255;try{assert.throws(()=>native.signTrestly(bytes,'{','invalid'));}finally{bytes.fill(0);}assert.equal(Buffer.from(poolExports.memory.buffer).indexOf(marker),-1);
});
