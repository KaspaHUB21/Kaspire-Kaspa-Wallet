// Read-only Rocket hints -> locally pinned reference program -> own-node live cells.
// No remote transaction plan is trusted, no keys/signatures/broadcasts are accepted.
import * as sdk from '@kassealhq/sdk/node';
import {readFileSync} from 'node:fs';
import {NETWORK} from './network.mjs';
import {utxos,checkAddress} from './node.mjs';
const template=JSON.parse(readFileSync(new URL('../../apps/mobile_flutter/assets/kcc20_reference_10_template.json',import.meta.url)));
const hex64=/^[a-f0-9]{64}$/,positive=/^[1-9][0-9]{0,18}$/,unsigned=/^(0|[1-9][0-9]{0,18})$/;
async function holding(address,tokenId){
 const response=await fetch(`https://kaspire.kaslab.space/api/kasparocket/pro-api/tokens/${encodeURIComponent(address)}/${tokenId}`,{redirect:'error',signal:AbortSignal.timeout(20000)});
 if(!response.ok)throw Error(`Rocket token cells unavailable (${response.status}).`);
 return response.json();
}
export async function rocketCells(address,tokenId,amountText,fullPlan,sources={}) {
 if(NETWORK!=='mainnet')throw Error('Rocket transfers require Mainnet.');
 checkAddress(address);
 if(!hex64.test(tokenId??'')||!positive.test(amountText??'')||!['0','1'].includes(fullPlan))throw Error('Invalid Rocket transfer identity.');
 const wanted=BigInt(amountText);if(wanted>0x7fffffffffffffffn)throw Error('Token amount overflow.');
 const data=await (sources.holding??holding)(address,tokenId);
 if(data.address!==address||data.kcc20_covenant_id!==tokenId||!Array.isArray(data.utxos)||data.utxos.length>1000)throw Error('Rocket holding identity differs.');
 const rows=[],seen=new Map();let total=0n;
 for(const c of data.utxos){
   if(!c||!hex64.test(c.transactionId??'')||!Number.isInteger(c.index)||c.index<0||c.index>0xffffffff||(typeof c.amount==='number'&&!Number.isSafeInteger(c.amount))||!unsigned.test(String(c.amount))||BigInt(c.amount)>0x7fffffffffffffffn)throw Error('Rocket returned a malformed token-cell hint. Refresh the token before trying again.');
   const key=`${c.transactionId}:${c.index}`,amount=String(c.amount);
   // Hints may repeat an outpoint or include an empty token cell. Neither is
   // an additional token balance. Conflicting duplicates remain an error.
   if(seen.has(key)){if(seen.get(key)!==amount)throw Error('Rocket returned conflicting amounts for one token cell. Refresh before sending.');continue;}
   seen.set(key,amount);
   if(BigInt(amount)===0n)continue;
   rows.push({...c,amount});total+=BigInt(amount);
 }
 if((typeof data.balance_tokens==='number'&&!Number.isSafeInteger(data.balance_tokens))||!unsigned.test(String(data.balance_tokens))||total!==BigInt(data.balance_tokens)||total<wanted||total>0x7fffffffffffffffn)throw Error('Rocket balance changed or its cell list is incomplete. Refresh the token.');
 rows.sort((a,b)=>BigInt(a.amount)!==BigInt(b.amount)?(BigInt(a.amount)>BigInt(b.amount)?-1:1):a.transactionId.localeCompare(b.transactionId)||a.index-b.index);
 let covered=0n,required=0;for(const c of rows){covered+=BigInt(c.amount);required++;if(covered>=wanted)break;}
 if(fullPlan==='1'&&required>65)throw Error('This transfer needs more than 65 cells. Choose a smaller amount.');
 const mandatory=fullPlan==='1'?required:Math.min(10,required),selected=rows.slice(0,mandatory);
 for(const c of [...rows].reverse()){if(selected.length>=10)break;if(!selected.includes(c))selected.push(c);}
 const owner=Buffer.from(sdk.xOnlyKeyOfAddress(address)).toString('hex');
 const reads=new Map();
 async function verify(c,position){
   const n=BigInt(c.amount),amount=Buffer.alloc(8);amount.writeBigUInt64LE(n);
   // Both are already supported by the pinned local signing core: original
   // receive and Kaspire's increase-only Borrowed Receive (threshold zero).
   // Never infer a policy from an indexer's label: require the exact live hash.
   for(const borrow of ['00','01']){
     const redeem=template.prefix+'08'+amount.toString('hex')+'20'+owner+'010001'+borrow+'20'+'0'.repeat(64)+'20'+'0'.repeat(64)+template.suffix;
     const script=Buffer.from(sdk.p2shScript(Buffer.from(redeem,'hex'))).toString('hex');
     const cellAddress=sdk.addressOfSpk(Buffer.from(script,'hex'),'mainnet');
     if(!reads.has(cellAddress))reads.set(cellAddress,(sources.utxos??utxos)(cellAddress));
     const live=await reads.get(cellAddress);
     if(live.network!=='mainnet'||live.covenantIdsIncluded!==true)throw Error('Own-node network or covenant data is unavailable.');
     const matches=live.entries.filter(e=>e.outpoint.transactionId===c.transactionId&&e.outpoint.index===c.index&&e.utxoEntry.scriptPublicKey.script===script);
     if(matches.length===0)continue;
     if(matches.length!==1)throw Error('Own node returned a duplicate Rocket outpoint.');
     const e=matches[0].utxoEntry;
     if(e.covenantId!==tokenId||e.isCoinbase!==false||e.scriptPublicKey.version!==0||!positive.test(e.amount)||!/^\d+$/.test(e.blockDaaScore))throw Error('Own node rejected the Rocket cell identity, owner or program.');
     return {transactionId:c.transactionId,index:c.index,valueSompi:e.amount,blockDaaScore:e.blockDaaScore,scriptPublicKey:script,tokenAmount:String(n),redeemScript:redeem};
   }
   if(position>=mandatory)return null;
   throw Error('Rocket token cell changed or does not match a supported 10x10 receiving policy. Refresh the token.');
 }
 const cells=[];
 for(let offset=0;offset<selected.length;offset+=3)for(const cell of await Promise.all(selected.slice(offset,offset+3).map((c,i)=>verify(c,offset+i))))if(cell)cells.push(cell);
 return {network:NETWORK,address,tokenId,requestedAmount:amountText,templateId:'argent-kcc20-c8a0871-10x10',inputLimit:10,requiredCells:required,cells};
}
