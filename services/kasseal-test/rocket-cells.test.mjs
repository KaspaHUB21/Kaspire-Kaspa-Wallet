import test from 'node:test';
import assert from 'node:assert/strict';
import{readFileSync}from'node:fs';
import * as sdk from '@kassealhq/sdk/node';
process.env.KASPIRE_KASSEAL_NETWORK='mainnet';
const {rocketCells}=await import('./rocket-cells.mjs');
const template=JSON.parse(readFileSync(new URL('../../apps/mobile_flutter/assets/kcc20_reference_10_template.json',import.meta.url)));
const address=new (sdk.sdk().PrivateKey)('1'.padStart(64,'0')).toAddress('mainnet').toString(),cid='c'.repeat(64),owner=Buffer.from(sdk.xOnlyKeyOfAddress(address)).toString('hex');
function fixture(count=1){
 const rows=Array.from({length:count},(_,i)=>({transactionId:i.toString(16).padStart(64,'0'),index:0,amount:'10000'}));
 const bytes=Buffer.alloc(8);bytes.writeBigUInt64LE(10000n);
 const redeem=template.prefix+'08'+bytes.toString('hex')+'20'+owner+'0100010020'+'0'.repeat(64)+'20'+'0'.repeat(64)+template.suffix;
 const script=Buffer.from(sdk.p2shScript(Buffer.from(redeem,'hex'))).toString('hex');
 const data={address,kcc20_covenant_id:cid,balance_tokens:String(10000*count),utxos:rows};
 const live={network:'mainnet',covenantIdsIncluded:true,entries:rows.map(r=>({outpoint:{transactionId:r.transactionId,index:0},utxoEntry:{amount:'200000000',blockDaaScore:'123',isCoinbase:false,covenantId:cid,scriptPublicKey:{version:0,script}}}))};
 return{data,live,sources:{holding:async()=>data,utxos:async()=>live}};
}
test('Rocket hints become pinned, own-node-verified cells without Kasvio',async()=>{
 const f=fixture();const r=await rocketCells(address,cid,'1000','1',f.sources);
 assert.equal(r.inputLimit,10);assert.equal(r.templateId,'argent-kcc20-c8a0871-10x10');assert.equal(r.cells[0].valueSompi,'200000000');assert.equal(r.cells[0].blockDaaScore,'123');
 assert(r.cells[0].redeemScript.startsWith(template.prefix));
});
test('Wrong owner identity, missing cells and contradictory live commitments fail closed',async()=>{
 for(const mutate of [f=>f.data.address='kaspa:foreign',f=>f.data.kcc20_covenant_id='e'.repeat(64),f=>f.data.balance_tokens='1',f=>f.data.utxos.push(f.data.utxos[0]),f=>f.live.network='testnet-10',f=>f.live.entries=[],f=>f.live.entries[0].utxoEntry.covenantId='e'.repeat(64),f=>f.live.entries[0].utxoEntry.isCoinbase=true,f=>f.live.entries[0].utxoEntry.scriptPublicKey.script='aa20'+'0'.repeat(64)+'87',f=>f.data.utxos[0].amount=Number.MAX_SAFE_INTEGER+1]){
  const f=fixture();mutate(f);await assert.rejects(rocketCells(address,cid,'1000','1',f.sources));
 }
});
test('Ten token inputs stay one payment; eleven use the native consolidation plan',async()=>{
 for(const n of [10,11]){const f=fixture(n);const r=await rocketCells(address,cid,String(10000*n),'1',f.sources);assert.equal(r.requiredCells,n);assert.equal(r.cells.length,n);}
 const f=fixture(11);const r=await rocketCells(address,cid,'110000','0',f.sources);assert.equal(r.cells.length,10);assert.equal(r.requiredCells,11);
});
