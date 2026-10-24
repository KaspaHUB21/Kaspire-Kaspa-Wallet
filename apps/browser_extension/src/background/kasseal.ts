// Kasseal supplies unsigned plans only. The pinned Rust core rebuilds and
// simulates them; independent live node entries are checked before review/sign.
import {parseKronAmount, type KronContext} from './kronDex';
import {rocketAccepted, confirmedRocketConflict, RocketConflictUnknown} from './rocketSwaps';
import {formatRawTokenAmount} from '../shared/tokenAmount';
export const KASSEAL_API='https://app.kasseal.com/v1';
export const KASSEAL_PLANNER='https://kaspire.kaslab.space/dex-test-v1/kasseal-mainnet';
const hex=/^[a-f0-9]{64}$/, uint=/^\d{1,20}$/;
export type KassealState={pending?:any;history?:any[];preparations?:any[];obsolete?:any};
export type KassealContext=Omit<KronContext,'broadcast'> & {load():KassealState;save(value:KassealState):Promise<void>};
const quotes=new Map<string,any>(), reviews=new Map<string,any>(), inFlight=new Set<string>();
const assetCache=new Map<string,{at:number;assets:any[]}>();
export function cachedKassealAsset(address:string,cid:string){const v=assetCache.get(address);return v&&Date.now()-v.at<300000?v.assets.find(a=>a.covenantId===cid):undefined;}
export function clearKassealReviews(){quotes.clear();reviews.clear();}
export async function kassealJson(url:string,body?:any,signal?:AbortSignal):Promise<any>{
  const allowed=[KASSEAL_API+'/',KASSEAL_PLANNER+'/'];
  if(!allowed.some(prefix=>url.startsWith(prefix)))throw Error('Invalid Kasseal endpoint.');
  const response=await fetch(url,{method:body===undefined?'GET':'POST',redirect:'error',
    headers:{accept:'application/json',...(body===undefined?{}:{'content-type':'application/json'})},
    ...(body===undefined?{}:{body:JSON.stringify(body)}),
    signal:signal?AbortSignal.any([signal,AbortSignal.timeout(55000)]):AbortSignal.timeout(55000)});
  const text=await response.text();if(text.length>4*1024*1024)throw Error('Kasseal response is too large.');
  let data:any;try{data=JSON.parse(text);}catch{throw Error(`Kasseal returned an unreadable response (${response.status}).`);}
  if(!response.ok)throw Error(String(data?.detail??data?.error??data?.title??`Kasseal unavailable (${response.status}).`));
  return data;
}
export function kassealImage(token:any){
  const path=String(token?.meta?.imageUrl??'');
  return token?.meta?.imageSource==='verified'&&/^\/v1\/images\/[a-f0-9]{64}$/.test(path)?'https://app.kasseal.com'+path:'';
}
function validToken(token:any){return hex.test(token?.meta?.covenantId??'')&&token.verification==='verified'&&token.meta.decimals===0&&typeof token.meta.ticker==='string';}
export async function kassealTokens(search='',cursor='',signal?:AbortSignal){
  search=search.trim();if(search.length>64||cursor.length>1024)throw Error('Search is too long.');
  const data=await kassealJson(`${KASSEAL_PLANNER}/tokens?${new URLSearchParams({search,cursor})}`,undefined,signal);
  if(!Array.isArray(data?.tokens)||data.tokens.length>100||
    (data.nextCursor!=null&&typeof data.nextCursor!=='string'))throw Error('Invalid Kasseal catalogue.');
  return {...data,tokens:data.tokens.filter(validToken)};
}
export async function kassealHoldings(address:string,signal?:AbortSignal){
  const data=await kassealJson(`${KASSEAL_API}/address/${encodeURIComponent(address)}/tokens`,undefined,signal);
  if(data?.address!==address||!Array.isArray(data.tokens)||!Array.isArray(data.holdings)||data.holdings.length>10000)throw Error('Invalid Kasseal wallet response.');
  const tokens=new Map<string,any>(data.tokens.filter(validToken).map((t:any)=>[t.meta.covenantId,t]));
  const seen=new Set<string>();const assets=[];
  for(const h of data.holdings){
    const token=tokens.get(h.tokenId),raw=String(h.balance);
    if(!hex.test(h.tokenId??'')||!uint.test(raw)||seen.has(h.tokenId))throw Error('Invalid Kasseal holding.');
    seen.add(h.tokenId);if(!token||BigInt(raw)===0n)continue;
    assets.push({covenantId:h.tokenId,tokenId:h.tokenId,symbol:token.meta.ticker,name:token.meta.name,
      rawBalance:raw,decimals:0,image_url:kassealImage(token),standard:'kasseal-kcc20',
      validationStatus:'kasseal-indexed',discoveryComplete:false,
      explorerUrl:`https://kaspatoken.kaslab.space/kcc20/${h.tokenId}`});
  }
  if(assetCache.size>=100)assetCache.delete(assetCache.keys().next().value!);
  assetCache.set(address,{at:Date.now(),assets});return assets;
}
export async function verifyKassealInputs(request:any,review?:any,signal?:AbortSignal,get=kassealJson){
  const tx=JSON.parse(request.txJsonString),inputs=tx.inputs;
  if(!Array.isArray(inputs)||!inputs.length||inputs.length>100||review&&review.inputs?.length!==inputs.length)throw Error('Incomplete Kasseal input review.');
  const lookups=new Map<string,any[]>();
  for(let i=0;i<inputs.length;i++){
    signal?.throwIfAborted();
    const input=inputs[i],embedded=input.utxo,hint=review?review.inputs[i]?.address:embedded?.address;
    if(typeof hint!=='string'||!/^kaspa:[a-z0-9]{61,63}$/.test(hint)||!hex.test(input.transactionId??'')||!Number.isInteger(input.index)||input.index<0)throw Error('Invalid Kasseal input identity.');
    if(!lookups.has(hint)){
      const state=await get(`${KASSEAL_PLANNER}/utxos?address=${encodeURIComponent(hint)}`,undefined,signal);
      if(state?.network!=='mainnet'||state.covenantIdsIncluded!==true||!Array.isArray(state.entries))throw Error('Independent Kasseal UTXO verification unavailable. Nothing was signed.');
      lookups.set(hint,state.entries);
    }
    const matches=lookups.get(hint)!.filter(r=>r.outpoint?.transactionId===input.transactionId&&r.outpoint?.index===input.index);
    if(matches.length!==1)throw Error('The pool or wallet balance changed. Refresh the quote. Nothing was signed.');
    const live=matches[0].utxoEntry,spk=live?.scriptPublicKey,version=spk?.version??0;
    if(!Number.isInteger(version)||version<0||version>65535)throw Error('Invalid node script version.');
    const script=version.toString(16).padStart(4,'0')+String(spk?.script??spk?.scriptPublicKey);
    if(!embedded||String(live.amount)!==String(embedded.amount)||script!==embedded.scriptPublicKey||live.isCoinbase!==false||
      !Object.hasOwn(live,'covenantId')||live.covenantId!==(embedded.covenantId??null)||!uint.test(String(live.blockDaaScore)))throw Error('Kasseal input differs from the independent node.');
    if(review){if(String(live.blockDaaScore)!==String(embedded.blockDaaScore)||embedded.isCoinbase!==false)throw Error('Kasseal input changed after review.');}
    else{embedded.blockDaaScore=String(live.blockDaaScore);embedded.isCoinbase=false;}
  }
  if(!review)request.txJsonString=JSON.stringify(tx);
}
export function validateKassealPlan(data:any,address:string,body:any){
  const request=data?.request,terms=request?.tradeSummary;
  if(data?.proofStatus!=='bound'||data.sdkVersion!=='0.1.1'||request?.sender!==address||request.tokenId!==body.tokenId||request.side!==body.side||
    !['kasseal-mainnet-swap-v1','kasseal-mainnet-prepare-v1'].includes(request.profile))throw Error('Kasseal plan identity verification failed.');
  if(request.profile==='kasseal-mainnet-prepare-v1'){
    if(body.side!=='sell'||terms?.stage!=='preparation'||!['split','merge'].includes(terms.operation)||terms.maxPreparationDebitSompi!=='700000000')throw Error('Invalid Kasseal self-owned token preparation.');
  }else if(terms?.stage!=='swap')throw Error('Invalid Kasseal swap stage.');
  for(const key of ['network','tokenId','side','rawAmount','minimumReceive','maxSpendSompi'])
    if(String(terms?.[key])!==String(body[key]))throw Error('Kasseal changed the reviewed trade limits.');
  return request;
}
const prune=(map:Map<string,any>)=>{for(const [id,v]of map)if(v.expires<Date.now())map.delete(id);if(map.size>=100)map.delete(map.keys().next().value!);};
function saved(context:KassealContext){
  const p=context.load().pending;
  if(p&&(p.address!==context.address||p.network!=='mainnet'||!hex.test(p.transactionId??'')||typeof p.signedTxJson!=='string'))throw Error('Invalid saved Kasseal swap.');
  return p;
}
export async function retireKasseal(context:KassealContext){
  const p=saved(context);if(!p||await rocketAccepted(p.transactionId,context.signal))return false;
  const competing=await confirmedRocketConflict(JSON.parse(p.signedTxJson),new Set([p.transactionId]),undefined,context.signal);
  if(!competing||await rocketAccepted(p.transactionId,context.signal))return false;
  await context.guard();const state=context.load();delete state.pending;
  await context.save({...state,obsolete:{...p,conflictingTransactionId:competing}});return true;
}
async function fresh(context:KassealContext){await context.guard();if(saved(context)&&!await retireKasseal(context))throw Error('Check the saved swap first. Its signed transaction cannot be replaced while confirmation is uncertain.');}
export async function kassealQuote(context:KassealContext,id:string,side:string,amount:string){
  await fresh(context);if(!hex.test(id)||!['buy','sell'].includes(side))throw Error('Invalid Kasseal trade.');
  const raw=parseKronAmount(amount,side==='buy'?8:0).toString();
  const body={network:'mainnet',address:context.address,tokenId:id,side,rawAmount:raw};
  const quote=await kassealJson(KASSEAL_PLANNER+'/quote',body,context.signal);
  for(const key of ['network','tokenId','side','rawAmount'])if(quote?.[key]!==body[key as keyof typeof body])throw Error('Kasseal quote differs from the requested trade.');
  if(!['tokenAmount','kasSompi','protocolFeeSompi','maxSpendSompi'].every(k=>uint.test(String(quote[k])))||
    !Number.isFinite(quote.quoteExpiresAt)||quote.quoteExpiresAt<=Date.now()||quote.quoteExpiresAt>Date.now()+180000)throw Error('Invalid or expired Kasseal quote.');
  await context.guard();prune(quotes);const quoteId=crypto.randomUUID();
  quotes.set(quoteId,{body,quote,binding:context.binding,expires:quote.quoteExpiresAt});return {...quote,quoteId};
}
export async function prepareKasseal(context:KassealContext,quoteId:string){
  await fresh(context);const q=quotes.get(quoteId);
  if(!q||q.binding!==context.binding||q.body.address!==context.address||q.expires<=Date.now())throw Error('Quote expired. Refresh the quote.');quotes.delete(quoteId);
  const expected=BigInt(q.quote[q.body.side==='buy'?'tokenAmount':'kasSompi']);
  const body={...q.body,minimumReceive:String(expected*99n/100n),maxSpendSompi:q.quote.maxSpendSompi,allowPreparation:true};
  const data=await kassealJson(KASSEAL_PLANNER+'/plan',body,context.signal),request=validateKassealPlan(data,context.address,body);
  await verifyKassealInputs(request,undefined,context.signal);await context.guard();
  const review=await context.prepare(request);await context.guard();
  const row=(await kassealTokens(q.body.tokenId,'',context.signal)).tokens.find((t:any)=>t.meta.covenantId===q.body.tokenId);
  if(!row)throw Error('Verified Kasseal token metadata unavailable.');
  const id=crypto.randomUUID();prune(reviews);
  const value={id,request,review,token:row,summary:request.tradeSummary,binding:context.binding,address:context.address,expires:Date.now()+120000};
  reviews.set(id,value);return {id,token:row,summary:value.summary,review,rawPlan:request};
}
export function kassealDetails(summary:any){
  const kas=(v:any)=>kassealDisplay(v,8)+' KAS';
  if(summary.stage==='preparation')return [`Token preparation: ${summary.operation==='split'?'Split token cell':'Merge token cells'}`,'Self-owned tokens only. No sale has been sent.',`Maximum preparation debit: ${kas(summary.maxPreparationDebitSompi)}`,`Network fee: ${kas(summary.networkFeeSompi)}`];
  return [`Token amount: ${kassealDisplay(summary.tokenAmount,0)}`,
    `${summary.side==='buy'?'KAS into market':'KAS returned by market (after protocol fee)'}: ${kas(summary.kasSompi)}`,
    `Protocol fee (included): ${kas(summary.protocolFeeSompi)}`,
    ...(summary.depositSompi?[`Refundable token-cell deposit: ${kas(summary.depositSompi)}`]:[]),
    ...(summary.depositRefundSompi?[`Token-cell deposit refunded: ${kas(summary.depositRefundSompi)}`]:[]),
    ...(summary.networkFeeSompi==null?[]:[`Network fee: ${kas(summary.networkFeeSompi)}`]),
    ...(summary.walletNetSompi==null?[]:[`Net wallet KAS change: ${kas(summary.walletNetSompi)}`])];
}
export function kassealDisplay(value:any,decimals:number){
  const n=BigInt(value??0),text=formatRawTokenAmount(String(n<0n?-n:n),decimals),[whole,fraction]=text.split('.');
  return (n<0n?'-':'')+whole!.replace(/\B(?=(\d{3})+(?!\d))/g,',')+(fraction?'.'+fraction:'');
}
async function exclusive<T>(context:KassealContext,run:()=>Promise<T>){
  if(inFlight.has(context.address))throw Error('A Kasseal operation is still in progress.');
  inFlight.add(context.address);try{return await run();}finally{inFlight.delete(context.address);}
}
const delay=(ms:number)=>new Promise<void>(resolve=>setTimeout(resolve,ms));
export async function resumeKasseal(context:KassealContext){return exclusive(context,()=>resume(context));}
async function resume(context:KassealContext,checkConflict=true){
  await context.guard();const p=saved(context);if(!p)throw Error('No saved Kasseal transaction.');
  if(!await rocketAccepted(p.transactionId,context.signal)){
    const retire=async()=>{try{return await retireKasseal(context);}catch(e){if(e instanceof RocketConflictUnknown)return false;throw e;}};
    if(checkConflict&&await retire())throw Error('The pool changed. The obsolete swap was archived. Refresh the quote.');
    try{await kassealJson(KASSEAL_API+'/tx',{txJson:p.signedTxJson},context.signal);}catch(e){if(await retire())throw Error('The pool changed. Refresh the quote to try again.');throw e;}
    let confirmed=false;
    for(let i=0;i<12;i++){await context.guard();if(await rocketAccepted(p.transactionId,context.signal)){confirmed=true;break;}await delay(1500);}
    if(!confirmed)throw Error('Confirmation is pending. The signed transaction is safely saved. Check its status; do not create another trade.');
  }
  const preparation=p.summary.stage==='preparation';
  if(preparation){
    let ready=false;
    for(let i=0;i<20;i++){
      await context.guard();const data=await kassealJson(`${KASSEAL_PLANNER}/prepared?${new URLSearchParams({address:context.address,tokenId:p.summary.tokenId,transactionId:p.transactionId})}`,undefined,context.signal);
      if(data.network!=='mainnet'||data.tokenId!==p.summary.tokenId||data.transactionId!==p.transactionId)throw Error('Preparation indexer response differs. The saved transaction is preserved.');
      if(data.ready===true){ready=true;break;}await delay(1500);
    }
    if(!ready)throw Error('Token preparation is confirmed but not indexed yet. Check saved preparation to continue. No sale has been sent.');
  }else{
    await context.record(context.address,{transactionId:p.transactionId,blockTime:p.timestamp,incoming:p.summary.side==='buy',assetKind:'KCC20',
      assetSymbol:p.token.meta.ticker,displayAmount:kassealDisplay(p.summary.tokenAmount,0),covenantId:p.summary.tokenId,tokenId:p.summary.tokenId,
      type:'kasseal-swap',standard:'kasseal-kcc20',operationLabel:p.summary.side==='buy'?'Kasseal Buy':'Kasseal Sell',rawJson:p});
  }
  await context.guard();const state=context.load();delete state.pending;const key=preparation?'preparations':'history';
  state[key]=[p,...(state[key]??[]).filter(r=>r.transactionId!==p.transactionId)].slice(0,1000);await context.save(state);return p;
}
export async function submitKasseal(context:KassealContext,id:string){return exclusive(context,async()=>{
  await fresh(context);const p=reviews.get(id);reviews.delete(id);
  if(!p||p.binding!==context.binding||p.address!==context.address||p.expires<=Date.now())throw Error('Secure Kasseal review expired. Refresh the quote.');
  const title=p.summary.stage==='preparation'?'Prepare Kasseal token cells':`${p.summary.side==='buy'?'Buy':'Sell'} ${p.token.meta.ticker}`;
  if(!await context.approve(title,[...kassealDetails(p.summary),`Token covenant: ${p.summary.tokenId}`,'Slippage limit: 1%.'],p.request))throw Error('Transaction rejected.');
  await context.guard();await verifyKassealInputs(p.request,p.review,context.signal);await context.guard();
  const signed=await context.sign(p.request,p.review.reviewHash);
  if(signed.transactionId!==p.review.transactionId||typeof signed.wrpcJson!=='string')throw Error('Signed Kasseal transaction differs from review.');
  const receipt={network:'mainnet',address:context.address,token:p.token,summary:p.summary,transactionId:signed.transactionId,signedTxJson:signed.wrpcJson,timestamp:Date.now()};
  // Persist inside the encrypted wallet before the first external submit.
  // Inputs have just been re-verified and signed locally. Submit the first
  // attempt directly; conflict history is for recovery/provider rejection.
  await context.save({...context.load(),pending:receipt});return resume(context,false);
});}
