import * as kron from '@kronsdk/kron-sdk';
import {loadKaspa} from '@kronsdk/kron-sdk/wasm';
export const REF='kaspirewallet';
const API='https://api.kron.technology',IDX='https://idx.kron.technology/v1/kcc20';
const SEQ=new kron.client.SequencerClient('https://seq.kron.technology');
const hex=x=>Buffer.from(x).toString('hex'),bytes=x=>Uint8Array.from(Buffer.from(x,'hex'));
const stringify=x=>JSON.stringify(x,(_,v)=>typeof v==='bigint'?v.toString():v);
const point=u=>({transactionId:u.outpoint.transactionId,index:u.outpoint.index});
let catalogueCache, rpcPromise;
const templates=new Map();
async function get(url){const r=await fetch(url,{signal:AbortSignal.timeout(20000)});if(!r.ok)throw Error(`KRON data unavailable (${r.status}); retry later.`);return r.json();}
async function rpc(){if(!rpcPromise)rpcPromise=(async()=>{const k=await loadKaspa(),r=new k.RpcClient({url:process.env.KASPIRE_DEX_NODE_URL??'ws://172.30.0.1:17110',encoding:k.Encoding.Borsh,networkId:'mainnet'});await r.connect();const info=await r.getInfo();if(!info.isSynced||!info.isUtxoIndexed||(await r.getBlockDagInfo()).network!=='mainnet')throw Error('Mainnet node is not ready');return{k,r};})().catch(e=>{rpcPromise=null;throw e});return rpcPromise;}
export async function catalogue(){
 if(catalogueCache&&Date.now()-catalogueCache.time<60000)return catalogueCache.tokens;
 const [list,markets,kasvio]=await Promise.all([get(`${API}/api/registry/tokenlist?all=1`),get(`${IDX}/markets`),get('https://kasvio.network/api/kron/v2/tokens?limit=100').catch(()=>null)]);
 const k=await loadKaspa();
 const verdict=kron.verify.verifyTokenListSignature(k,list,{requireFresh:true,expectedVariant:{all:true}});
 if(!verdict.ok)throw Error(`KRON token metadata signature could not be verified: ${verdict.reason}`);
 const rows=Array.isArray(markets.result)?markets.result:[];
 const extra=new Map((kasvio?.data??[]).map(t=>[t.token_id,t]));
 const tokens=list.tokens.filter(t=>t.network==='mainnet'&&t.extensions?.curveParams&&t.extensions?.chainVerified===true).map(t=>{
  const market=rows.find(m=>m.covenantId===t.covenantId)??{},v=extra.get(t.covenantId);
  return {...t,ticker:t.symbol.toUpperCase(),image:t.logoURI??v?.logo_uri??'',priceKas:market.price??v?.last_price_kas_per_raw_unit??null,volume24hKas:market.volume24h??v?.observed_volume_24h_kas??null,poolKas:market.tvl??null,phase:market.graduated?'pool':'curve',description:'KRON native covenant token'};
 });
 tokens.sort((a,b)=>Number(b.volume24hKas??0)-Number(a.volume24hKas??0)||a.ticker.localeCompare(b.ticker));
 catalogueCache={time:Date.now(),tokens};return tokens;
}
async function context(tokenId){
 const record=(await catalogue()).find(t=>t.covenantId===tokenId);if(!record)throw Error('Unknown KRON covenant ID');
 const data=(await get(`${IDX}/token/${encodeURIComponent(record.symbol)}`)).result;
 const token=Array.isArray(data)?data.find(t=>t.covenantId===tokenId):data;
 if(!token||token.covenantId!==tokenId||Number(token.dec)!==record.decimals)throw Error('KRON ticker resolved to a different covenant');
 return {record,token,p:record.extensions.curveParams};
}
function poolParams(p){return {creatorFeeOwner:bytes(p.creatorFeeOwner),platformFeeOwner:bytes(p.platformFeeOwner),creatorFeeBps:BigInt(p.dexCreatorFeeBps),platformFeeBps:BigInt(p.dexPlatformFeeBps),lpFeeBps:BigInt(p.dexLpFeeBps??0),lockedShares:BigInt(p.poolLockedShares)};}
function curveMath(token,p){return {realKas:BigInt(token.cpState.realKas),tokenReserve:BigInt(token.cpState.tokenReserve),vKas:BigInt(p.vKas),graduationKas:BigInt(p.graduationKas),creatorFeeBps:BigInt(p.creatorFeeBps),platformFeeBps:BigInt(p.platformFeeBps),devFundBps:BigInt(p.devFundBps??0)};}
function poolState(token){const s=token.cpState;return {kasReserve:BigInt(s.poolKas),tokenReserve:BigInt(s.poolTokenReserve),totalShares:BigInt(s.poolTotalShares),lpCovid:bytes(s.poolLpCovid??'0'.repeat(64)),tokenCovid:bytes(token.covenantId)};}
export function quoteFor(token,p,side,amount){
 if(!['buy','sell'].includes(side)||!/^[1-9][0-9]{0,18}$/.test(String(amount)))throw Error('Enter a positive amount without more decimals than supported');
 const raw=BigInt(amount);if(side==='buy'&&raw%1_000_000n!==0n)throw Error('KRON KAS trade amounts use steps of 0.01 KAS');
 const q=token.graduated?(side==='buy'?kron.poolCpV3.quotePoolV3Buy(poolState(token),poolParams(p),raw):kron.poolCpV3.quotePoolV3Sell(poolState(token),poolParams(p),raw)):(side==='buy'?kron.curve.quoteCpBuy(curveMath(token,p),raw):kron.curve.quoteCpSell(curveMath(token,p),raw));
 if(!q)throw Error('This amount cannot be traded economically after KRON fees. Increase the amount.');return q;
}
function summary(q,record,side){return {tokenId:record.covenantId,ticker:record.ticker,decimals:record.decimals,side,tokenAmount:String(side==='buy'?q.tokenOut:q.tokenIn),grossKasSompi:String(side==='buy'?q.kasIn:q.kasOut),netKasSompi:String(side==='buy'?q.total:q.net),creatorFeeSompi:String(q.creatorOut??q.creatorFee),platformFeeSompi:String(q.platformOut??q.platformFee),devFundFeeSompi:String(q.devFundFee??0),lpFeeSompi:String(q.lpFee??0),quoteExpiresAt:Date.now()+120000,ref:REF};}
export async function quote(body){const{record,token,p}=await context(body.tokenId);return summary(quoteFor(token,p,body.side,body.rawAmount),record,body.side);}
async function live(spk,outpoint,cid){
 const{k,r}=await rpc(),address=k.addressFromScriptPublicKey(spk,'mainnet').toString();
 const found=(await r.getUtxosByAddresses([address])).entries.filter(u=>(!outpoint||(u.outpoint.transactionId===outpoint.transactionId&&u.outpoint.index===outpoint.index))&&String(u.entry?.covenantId)===cid);
 if(found.length!==1)throw Error('The market output is pending or changed. Refresh the quote and retry.');return found[0];
}
async function tpls(record){const key=record.covenantId;if(!templates.has(key)){const promise=kron.client.fetchCpTemplates({baseUrl:API,tokenCovid:key,curveParams:record.extensions.curveParams,templateVersion:record.extensions.templateVersion??null}).catch(e=>{templates.delete(key);throw e});templates.set(key,promise);}return templates.get(key);}
async function traderTokens(k,record,address,amount){
 const rows=(await get(`${IDX}/token/${encodeURIComponent(record.symbol)}/address/${encodeURIComponent(address)}/utxos`)).result;
 if(!Array.isArray(rows)||rows.length>1000)throw Error('Invalid token balance response');
 const owner=k.payToAddressScript(new k.Address(address)).script.slice(2,-2);
 const selected=[];let total=0n;
 for(const row of rows.sort((a,b)=>BigInt(a.amount)>BigInt(b.amount)?-1:1)){
  const redeem=bytes(row.redeemScriptHex),decoded=kron.kcc20.decodeKcc20Redeem(redeem);
  if(row.ownerAddress!==address||decoded.state.isMinter||decoded.state.identifierType!==3||hex(decoded.state.ownerIdentifier)!==owner||String(decoded.state.amount)!==String(row.amount))throw Error('Token ownership verification failed');
  const entry=await live(k.payToScriptHashScript(redeem),row.outpoint,record.covenantId);
  selected.push({...row.outpoint,value:entry.amount,state:decoded.state,entry,redeem:hex(redeem)});total+=decoded.state.amount;
  if(total>=amount)return selected;
  if(selected.length===3)break;
 }
 throw Error('Insufficient spendable tokens in three outputs. Reduce the amount or consolidate in KRON.');
}
export async function plan(body){
 const{k,r}=await rpc();if(!/^kaspa:/.test(body.address)||!kron.partnerTag.REF_RE.test(REF))throw Error('Invalid wallet or partner configuration');
 const address=new k.Address(body.address),fundingSpk=k.payToAddressScript(address);
 if(!/^20[0-9a-f]{64}ac$/.test(fundingSpk.script))throw Error('KRON swaps currently require a Schnorr P2PK wallet');
 const pubkey=bytes(fundingSpk.script.slice(2,-2));
 const{record,token,p}=await context(body.tokenId),tpl=await tpls(record),side=body.side,amount=BigInt(body.rawAmount);
 const q=quoteFor(token,p,side,body.rawAmount);
 if(BigInt(side==='buy'?q.tokenOut:q.net)<BigInt(body.minimumReceive??0))throw Error('Price moved beyond your slippage limit. Get a new quote.');
 const owned=side==='sell'?await traderTokens(k,record,body.address,amount):[];
 const witness=2+owned.length;let spend,marketId;
 if(token.graduated){
  const headResult=await SEQ.head(record.symbol).catch(()=>null);
  const head=headResult?.head??(await get(`${IDX}/token/${encodeURIComponent(record.symbol)}/poolhead`)).result;
  const reserves=head.reserves;const state={kasReserve:BigInt(reserves.kasReserve),tokenReserve:BigInt(reserves.tokenReserve),totalShares:BigInt(reserves.totalShares),lpCovid:bytes(reserves.lpCovid??'0'.repeat(64)),tokenCovid:bytes(record.covenantId)};
  // Never mix a head's outpoints with reserves from another indexer snapshot.
  const headToken={...token,cpState:{...token.cpState,poolKas:String(state.kasReserve),poolTokenReserve:String(state.tokenReserve),poolTotalShares:String(state.totalShares),poolLpCovid:hex(state.lpCovid)}};
  const fresh=quoteFor(headToken,p,side,body.rawAmount);
  if(BigInt(side==='buy'?fresh.tokenOut:fresh.net)<BigInt(body.minimumReceive??0))throw Error('Pool price changed beyond slippage; refresh quote');
  Object.assign(q,fresh);marketId=token.poolCovenantId;
  const outpoint=head.poolOutpoint??head.pool,tokenOutpoint=head.poolTokenOutpoint??head.poolToken;
  const entry=await live(kron.poolCpV3.poolCpV3SpkForState(k,tpl.pool,state),outpoint,marketId);
  const inv=await live(kron.kcc20.kcc20Spk(k,kron.kcc20.materializeKcc20Script(tpl.token,kron.kcc20.covenantIdOwned(bytes(marketId),state.tokenReserve,false))),tokenOutpoint,record.covenantId);
  const utxo={...point(entry),state,tokenUtxo:{...point(inv),value:inv.amount}};
  spend=side==='buy'?kron.poolCpV3.buildPoolV3SwapKasForToken(k,tpl.pool,tpl.token,poolParams(p),utxo,bytes(marketId),pubkey,q,[],witness):kron.poolCpV3.buildPoolV3SwapTokenForKas(k,tpl.pool,tpl.token,poolParams(p),utxo,bytes(marketId),pubkey,owned,q,witness);
 }else{
  marketId=token.curveCovenantId;
  const sequenced=await SEQ.curveHead(marketId).catch(()=>null),head=sequenced?.ok?sequenced.head:null;
  const realKas=BigInt(head?.reserves.realKas??token.cpState.realKas),reserve=BigInt(head?.reserves.tokenReserve??token.cpState.tokenReserve);
  const fresh=quoteFor({...token,cpState:{...token.cpState,realKas:String(realKas),tokenReserve:String(reserve)}},p,side,body.rawAmount);
  if(BigInt(side==='buy'?fresh.tokenOut:fresh.net)<BigInt(body.minimumReceive??0))throw Error('Curve price changed beyond slippage; refresh quote');Object.assign(q,fresh);
  const state={graduated:false,tokenCovid:bytes(record.covenantId),tokenReserve:reserve};
  const entry=await live(kron.curveCp.cpSpkForState(k,tpl.curve,state),head?.poolOutpoint,marketId);
  if(entry.amount!==realKas)throw Error('Curve balance changed; refresh quote');
  const inv=await live(kron.kcc20.kcc20Spk(k,kron.kcc20.materializeKcc20Script(tpl.token,kron.kcc20.covenantIdOwned(bytes(marketId),reserve,false))),head?.poolTokenOutpoint,record.covenantId);
  const utxo={...point(entry),realKas:entry.amount,state},inventory={...point(inv),value:inv.amount,amount:reserve};
  spend=side==='buy'?kron.curveCp.buildCpBuy(k,tpl.curve,tpl.token,utxo,inventory,bytes(marketId),pubkey,q.kasIn,q.tokenOut,[],witness):kron.curveCp.buildCpSell(k,tpl.curve,tpl.token,utxo,owned,inventory,bytes(marketId),pubkey,q.tokenIn,q.kasOut,witness);
 }
 const entries=await Promise.all(spend.inputs.map(async ci=>{try{return await live(ci.scriptPublicKey,{transactionId:ci.transactionId,index:ci.index},ci.role==='curve'||ci.role==='pool'?marketId:record.covenantId);}catch(e){throw Error(`${ci.role}: ${e.message} (${ci.transactionId}:${ci.index})`);}}));
 entries.forEach((entry,i)=>{if(entry.amount!==spend.inputs[i].value)throw Error('Market deposit changed; refresh quote');});
 const available=(await r.getUtxosByAddresses([body.address])).entries.filter(u=>!u.isCoinbase&&!u.entry?.covenantId).sort((a,b)=>a.amount>b.amount?-1:1);
 const feeRate=Math.max(100,(await r.getFeeEstimate()).estimate.priorityBucket.feerate),picked=[];let asm,fee;
 for(const entry of available){
  picked.push(entry);
  if(asm){asm.transaction.free();asm=null;}
  try{
   asm=kron.spend.assembleNativeTx(k,{spend,fundingEntries:picked,changeAddress:address,networkFee:10000n,ref:REF});
   fee=kron.spend.estimateNativeFee(k,'mainnet',asm,feeRate);asm.transaction.free();asm=null;
   asm=kron.spend.assembleNativeTx(k,{spend,fundingEntries:picked,changeAddress:address,networkFee:fee,ref:REF});if(asm.change>=10000n)break;
  }catch(e){if(picked.length===available.length)throw Error(`Insufficient KAS for trade, token deposits and network fee: ${e.message}`);}
 }
 if(!asm||asm.change<10000n)throw Error('Insufficient spendable KAS. Leave room for fees and token deposits.');
 const pskt=kron.spend.toPsktJson(asm),tx=JSON.parse(pskt.txJsonString);
 // Supply the actual confirmed node entries; no indexer-provided native amounts are signed.
 tx.inputs.forEach((input,i)=>{const entry=i<entries.length?entries[i]:picked[i-entries.length];input.utxo.blockDaaScore=String(entry.blockDaaScore);input.utxo.covenantId=entry.entry?.covenantId?String(entry.entry.covenantId):null;});
 const received=side==='buy'?q.tokenOut:0n,ownRemaining=side==='buy'?received:owned.reduce((s,t)=>s+t.state.amount,0n)-amount;
 const traderRedeem=ownRemaining>0n?hex(kron.kcc20.materializeKcc20Script(tpl.token,kron.kcc20.addressPresenceOwned(pubkey,ownRemaining))):null;
 const terms={...summary(q,record,side),phase:token.graduated?'pool':'curve',marketId,rawAmount:String(amount),minimumReceive:String(body.minimumReceive??0),networkFeeSompi:String(fee),traderInputs:owned.map(t=>({index:spend.inputs.findIndex(i=>i.transactionId===t.transactionId&&i.index===t.index),redeem:t.redeem})),traderOutputRedeem:traderRedeem,creatorOwner:p.creatorFeeOwner,platformOwner:p.platformFeeOwner,devFundOwner:p.devFundOwner??null,inputAddresses:[...entries,...picked].map(e=>k.addressFromScriptPublicKey(e.scriptPublicKey,'mainnet').toString()),outputRoles:spend.outputs.map((o,index)=>({index,role:o.role,value:String(o.value),script:typeof o.scriptPublicKey.script==='string'?o.scriptPublicKey.script:hex(o.scriptPublicKey.script)}))};
 const request={sender:body.address,profile:'kron-swap-v1',tokenId:record.covenantId,lpCovenantId:marketId,ticker:record.ticker,side,tradeSummary:terms,txJsonString:JSON.stringify(tx),signInputs:pskt.signInputs,scripts:[]};
 asm.transaction.free();return JSON.parse(stringify({request,summary:terms}));
}
