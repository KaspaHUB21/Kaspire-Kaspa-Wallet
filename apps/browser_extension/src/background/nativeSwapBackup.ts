import {nativeSwapJournal} from './nativeSwapJournal';
type Row=Record<string,any>;
const object=(v:any)=>v&&typeof v==='object'&&!Array.isArray(v);
export function nativeSwapBackup(signatures:Row|undefined,store:Record<string,string>|undefined){
 if(!signatures||!Object.keys(signatures).length)return undefined;
 return {format:'kaspire-native-swaps-v1',signatures,receipts:Object.fromEntries(Object.entries(store??{}).filter(([key])=>key.startsWith('trestly.pending.v1.')))};
}
export async function restoreNativeSwapBackup(value:unknown,addresses:string[],verify:(request:string)=>Promise<Row>){
 const v=value as Row;
 if(!object(v)||v.format!=='kaspire-native-swaps-v1'||!object(v.signatures)||!object(v.receipts)||Object.keys(v.signatures).length>128||Object.keys(v.receipts).length>256||new TextEncoder().encode(JSON.stringify(v)).length>2_000_000)throw Error('Invalid native swap recovery backup. Nothing was removed.');
 const own=new Set(addresses),signatures:Row=Object.create(null),receipts:Record<string,string>=Object.create(null);
 for(const [id,raw]of Object.entries(v.signatures)){
  const e=raw as Row;
  if(!/^[a-f0-9]{64}$/.test(id)||!object(e)||e.operation!=='signTrestly'||!own.has(e.walletAddress)||typeof e.request!=='string'||e.request.length>524288||!object(e.result)||e.result.transactionId!==id||typeof e.result.wrpcJson!=='string'||e.result.wrpcJson.length>524288)throw Error('Invalid native swap signature backup.');
  const request=JSON.parse(e.request),review=await verify(e.request),tx=JSON.parse(e.result.wrpcJson);
  if(request.sender!==e.walletAddress||e.reviewHash!==review.reviewHash||e.result.review?.reviewHash!==review.reviewHash||!Array.isArray(tx.inputs)||tx.inputs.length<1||tx.inputs.length>8||!Array.isArray(tx.outputs)||typeof tx.id==='string'&&tx.id!==id)throw Error('Native recovery identity or approved review differs.');
  signatures[id]=e;
 }
 for(const [key,raw]of Object.entries(v.receipts)){
  const address=key.replace(/^trestly\.pending\.v1\./,'').replace(/\.last$/,'');
  if(!own.has(address)||![`trestly.pending.v1.${address}`,`trestly.pending.v1.${address}.last`].includes(key)||typeof raw!=='string'||raw.length>1_000_000)throw Error('Native receipt belongs to another wallet.');
  receipts[key]=raw;
 }
 for(const [key]of Object.entries(receipts)){
  const address=key.slice('trestly.pending.v1.'.length).replace(/\.last$/,'');
  const journal=nativeSwapJournal({address,rootAddress:address,guard:async()=>{},read:async name=>receipts[name]??null,write:async()=>{throw Error('Recovery validation cannot write.');},signed:async()=>signatures,check:async()=>({confirmed:false})});await journal.read(key);
 }
 return {signatures,receipts};
}
