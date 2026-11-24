// The runtime journal is committed BEFORE signed bytes leave the signer. This
// adapter also recovers a crash between that commit and the Android receipt save.
type Row=Record<string,any>;
type Host={address:string;rootAddress:string;guard():Promise<void>;read(key:string):Promise<string|null>;write(key:string,value:string|null):Promise<void>;signed():Promise<Row>;check(id:string):Promise<{confirmed:boolean}>};
const idPattern=/^[a-f0-9]{64}$/;
const canonical=(value:any):string=>JSON.stringify(value,(_,v)=>v&&typeof v==='object'&&!Array.isArray(v)?Object.fromEntries(Object.keys(v).sort().map(k=>[k,v[k]])):v);
export function nativeSwapJournal(host:Host){
 const key='trestly.pending.v1.'+host.address;
 async function entries(){await host.guard();return Object.values(await host.signed()).filter((e:any)=>{if(e.operation!=='signTrestly'||e.walletAddress!==host.rootAddress)return false;try{return JSON.parse(e.request).sender===host.address;}catch{throw Error('Saved native swap is unreadable. Nothing was removed.');}}) as Row[];}
 function validate(record:Row,rows:Row[]){
  if(!record||!idPattern.test(record.transactionId)||typeof record.wrpcJson!=='string'||!record.wrpcJson.length||record.wrpcJson.length>524288)throw Error('Invalid saved native swap. Nothing was sent or removed.');
  const entry=rows.find(e=>e.result?.transactionId===record.transactionId);
  if(!entry||entry.result?.wrpcJson!==record.wrpcJson||entry.result?.feeSompi!==record.feeSompi||canonical(entry.result?.review)!==canonical(record.review)||entry.result?.review?.profile!=='trestly-mainnet-v2'||entry.reviewHash!==entry.result.review.reviewHash||canonical(JSON.parse(entry.request))!==canonical(record.request))throw Error('Native swap differs from the durable wallet signature. Nothing was sent or removed.');
  return entry;
 }
 async function read(requested:string):Promise<string|null>{
  if(requested!==key&&requested!==key+'.last')throw Error('Wrong native swap receipt key.');
  const rows=await entries(),raw=await host.read(requested);
  if(raw!==null){validate(JSON.parse(raw),rows);return raw;}
  if(requested!==key)return null;
  const unresolved=rows.filter(e=>e.confirmed!==true);
  if(unresolved.length>1)throw Error('Multiple saved native swaps need review. No new trade was created.');
  if(!unresolved.length)return null;
  const entry=unresolved[0]!,record={...entry.result,request:JSON.parse(entry.request),createdAt:entry.at};validate(record,rows);
  const recovered=JSON.stringify(record);await host.guard();await host.write(key,recovered);
  if(await host.read(key)!==recovered)throw Error('Could not recover the saved swap. Nothing was sent.');
  return recovered;
 }
 async function write(requested:string,value:string|null){
  if(requested!==key&&requested!==key+'.last')throw Error('Wrong native swap receipt key.');
  const rows=await entries();
  if(value!==null){
   const data=JSON.parse(value);validate(data,rows);
   const pending=await host.read(key);
   if(pending&&JSON.parse(pending).transactionId!==data.transactionId)throw Error('A different saved swap already exists.');
   if(requested.endsWith('.last')&&data.status!=='confirmed')throw Error('Invalid native swap confirmation receipt.');
   await host.guard();await host.write(requested,value);return;
  }
  if(requested!==key)throw Error('Native swap history cannot be erased here.');
  const raw=await host.read(key),last=await host.read(key+'.last');
  if(!raw||!last)throw Error('Keep the saved swap until confirmation.');
  const pending=JSON.parse(raw),receipt=JSON.parse(last);validate(pending,rows);validate(receipt,rows);
  if(receipt.status!=='confirmed'||receipt.transactionId!==pending.transactionId||!(await host.check(pending.transactionId)).confirmed)throw Error('Own-node confirmation is unavailable. The signed swap remains saved.');
  await host.guard();await host.write(key,null);
 }
 async function beforeSubmit(id:string,raw:string){
  const saved=await read(key);if(!saved)throw Error('The signed native swap was not saved.');
  const record=JSON.parse(saved);validate(record,await entries());
  if(record.transactionId!==id||record.wrpcJson!==raw)throw Error('Only the exact durably saved native swap may be submitted.');
  await host.guard();
 }
 return {read,write,beforeSubmit};
}
