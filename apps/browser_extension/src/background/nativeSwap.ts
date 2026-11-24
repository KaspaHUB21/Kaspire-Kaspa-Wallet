import {nativePoolCore} from './nativePoolCore';
import {nativeSwapJournal} from './nativeSwapJournal';
import {formatRawTokenAmount} from '../shared/tokenAmount';
type Row=Record<string,any>;
export type NativeSignature=Row;
// Multiple extension surfaces must not authorize independent replacements.
const signing=new Set<string>();
type Host={address:string;guard():Promise<void>;read(key:string):Promise<string|null>;write(key:string,value:string|null):Promise<void>;signatures():Record<string,NativeSignature>;saveSignature(id:string,entry:NativeSignature):Promise<void>;approve(review:Row,request:Row):Promise<boolean>;secret():string;canSign():boolean};
export async function nativeSwapConfirmed(id:string){
 if(!/^[a-f0-9]{64}$/.test(id))throw Error('Invalid native swap transaction ID.');
 const response=await fetch('https://kaspire.kaslab.space/api/native-kusdt/transactions/'+id,{method:'GET',credentials:'omit',redirect:'error',cache:'no-store',signal:AbortSignal.timeout(15000)});
 if(!response.ok)throw Error('Native swap confirmation is unavailable. The exact signed swap remains saved.');
 const raw=await response.text();if(raw.length>16384)throw Error('Native swap status is too large. Keep the saved swap.');
 const value=JSON.parse(raw);if(value?.transactionId!==id||!['confirmed','mempool','not_seen','unknown'].includes(value.status))throw Error('Native swap status could not be independently verified. Keep the saved swap.');
 return {confirmed:value.status==='confirmed'};
}
export function nativeReviewDetails(review:Row){
 if(review.profile!=='trestly-mainnet-v2'||!['buy','sell'].includes(review.side))throw Error('Invalid native swap review.');
 const buy=review.side==='buy',amount=(raw:unknown,d:number,unit:string)=>{
  if(typeof raw!=='string'||!/^\d+$/.test(raw))throw Error('Invalid exact native swap amount.');
  return formatRawTokenAmount(raw,d)+' '+unit;
 };
 return [`You pay: ${amount(review.amountIn,buy?8:6,buy?'KAS':'kUSDT')}`,`You receive: ${amount(review.amountOut,buy?6:8,buy?'kUSDT':'KAS')}`,
  'Pool fee: 0.50% · included',`Network fee: up to ${amount(review.maxFeeSompi,8,'KAS')}`,
  ...(buy?[`Your token storage: ${amount(review.tokenValueSompi,8,'KAS')} · not a fee`]:[]),
  `Pool covenant: ${review.poolId}`,`Token covenant: ${review.tokenId}`,`Exact pool transaction: ${review.poolTransactionId}`];
}
export function nativeSwapContext(host:Host){
 const journal=nativeSwapJournal({address:host.address,rootAddress:host.address,guard:host.guard,read:host.read,write:host.write,signed:async()=>host.signatures(),check:nativeSwapConfirmed});
 return {read:journal.read,write:journal.write,trestly:{
  describe:async(request:Row)=>{await host.guard();const result=(await nativePoolCore()).describe(JSON.stringify(request));await host.guard();return result;},
  prepare:async(request:Row)=>{await host.guard();if(request.sender!==host.address)throw Error('Wrong native swap sender.');const result=(await nativePoolCore()).prepare(JSON.stringify(request));await host.guard();return result;},
  canSign:async()=>{await host.guard();return host.canSign();},
  beforeSubmit:journal.beforeSubmit,
  sign:async(request:Row,hash:string)=>{
   if(signing.has(host.address))throw Error('A native swap is already being authorized.');
   signing.add(host.address);try{
   await host.guard();if(!host.canSign())throw Error('Watch-only wallets cannot sign native swaps.');
   if(request.sender!==host.address)throw Error('Wrong native swap sender.');
   if(Object.values(host.signatures()).some(e=>e.walletAddress===host.address&&e.operation==='signTrestly'&&e.confirmed!==true))throw Error('A native swap is already saved. Resume the same transaction first.');
   const core=await nativePoolCore(),raw=JSON.stringify(request),review=core.prepare(raw);
   if(review.reviewHash!==hash)throw Error('Native swap review changed. Nothing was signed.');
   if(!await host.approve(review,request))throw Error('Transaction rejected.');
   await host.guard();if(core.prepare(raw).reviewHash!==hash)throw Error('Native swap review changed.');
   const result=core.sign(host.secret(),raw,hash);
   if(result.review?.reviewHash!==hash||!/^([a-f0-9]{64})$/.test(result.transactionId)||typeof result.wrpcJson!=='string')throw Error('The native signer returned an invalid result. Nothing was submitted.');
   await host.guard();await host.saveSignature(result.transactionId,{operation:'signTrestly',walletAddress:host.address,request:raw,reviewHash:hash,result,at:Date.now()});
   await host.guard();return result;
   }finally{signing.delete(host.address);}
  }
 }};
}
