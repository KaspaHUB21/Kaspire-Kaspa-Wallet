import {core} from "./core";
import {broadcast, resolveWalletInput, spendingData} from "./api";
import {nftWalletPage, nftMetadata, nftImage, officialNft, requireUnlistedNft} from "./krc721Reads";

export const NFT_DIRECTORY = "https://kaspire.kaslab.space/nft-market-test-v1";
const NODE = "https://kaspire.kaslab.space/api/local-node";
const key = (address: string) => `nftMarketRecoveryV1:${address}`;
const pendingKey = (address: string) => `nftMarketBroadcastV1:${address}`;
const publishing = new Map<string, Promise<void>>();
const busy = new Set<string>();
const pause = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));
type RecordData = Record<string, any>;
export type NftContext = {
  address: string;
  guard(): Promise<void>;
  approve(title: string, details: string[], rawJson: unknown): Promise<boolean>;
  sign(kind: "Transaction" | "Reveal" | "Pskt", request: any, hash: string): Promise<any>;
};
async function read(url: string) {
  const response = await fetch(url, {signal:AbortSignal.timeout(12000)});
  if (!response.ok) throw new Error(`NFT source unavailable (${response.status}).`);
  const text = await response.text();
  if (text.length > 4 * 1024 * 1024) throw new Error("NFT response too large.");
  return JSON.parse(text);
}
export async function nftSaved(address: string): Promise<RecordData[]> {
  const data = await chrome.storage.local.get(key(address));
  return Array.isArray(data[key(address)]) ? data[key(address)] : [];
}
async function save(record: RecordData) {
  const rows = await nftSaved(record.seller);
  await chrome.storage.local.set({[key(record.seller)]: [...rows.filter(row => row.localId !== record.localId), record]});
}
export async function nftBrowse(params: RecordData = {}) {
  const query = new URLSearchParams({q:String(params.q ?? ""),offset:String(params.offset ?? 0),sort:String(params.sort ?? (params.high ? "high" : "low"))});
  if (params.collection) query.set("collection",String(params.collection));
  if (params.traits && Object.keys(params.traits).length) query.set("traits",JSON.stringify(params.traits));
  if (params.seller) query.set("seller",String(params.seller));
  if (params.refresh) query.set("refresh","1");
  return read(`${NFT_DIRECTORY}/offers?${query}`);
}
export async function nftOwnedCollections(address: string) {
  const ticks = new Set<string>(), seen = new Set<string>();
  let cursor = "";
  for (let i=0; i<1000; i++) {
    const page = await nftWalletPage(address,cursor);
    page.result.forEach((row:any)=>ticks.add(String(row.tick).toUpperCase()));
    cursor = String(page.next ?? "");
    if (!cursor) return [...ticks].sort();
    if (seen.has(cursor)) throw new Error("NFT indexer repeated a page. Please reload.");
    seen.add(cursor);
  }
  throw new Error("NFT collection pagination exceeded the safe limit.");
}
export async function nftOwned(address:string, cursor="", collection="") {
  const seen = new Set<string>(); let rows:any[] = [], next=cursor;
  do {
    const page = await nftWalletPage(address,next,collection,10-rows.length);
    rows.push(...page.result.filter((row:any)=>!collection || String(row.tick).toUpperCase()===collection));
    next = String(page.next ?? "");
    if (next && seen.has(next)) throw new Error("NFT indexer repeated a page. Please reload.");
    seen.add(next);
  } while (rows.length<10 && next);
  if(next) {
    let probe=next;
    while(probe) {
      const page=await nftWalletPage(address,probe,collection,1);
      if(page.result.some((row:any)=>!collection||String(row.tick).toUpperCase()===collection))break;
      probe=String(page.next??'');
      if(probe&&seen.has(probe))throw new Error('NFT indexer repeated a page. Please reload.');
      seen.add(probe);
    }
    if(!probe)next='';
  }
  rows = rows.map((row:any)=>({...row,ticker:String(row.tick).toUpperCase(),tokenId:String(row.tokenId)}));
  await Promise.all([...new Set<string>(rows.map(row=>row.ticker))].map(async tick=>{
    let metadata:any[] = [];
    try { metadata = await nftMetadata(tick,rows.filter(row=>row.ticker===tick).map(row=>row.tokenId)); } catch { /* Inventory remains visible. */ }
    for (const row of rows.filter(row=>row.ticker===tick)) {
      row.imageUrl = nftImage(tick,row.tokenId);
      row.rarityRank = metadata.find(item=>String(item.tokenId)===row.tokenId)?.rarityRank ?? null;
    }
  }));
  return {nfts:rows,next:next||null};
}
const amount = (value:unknown) => `${Number(value)/100_000_000} KAS`;
function args(record:RecordData,sender:string,action:string,cells="") {
  return {action,sender,seller:record.seller,ticker:record.ticker,tokenId:record.tokenId,
    listingTransactionId:record.listingTransactionId ?? "",listingUtxosJson:cells,
    priceSompi:record.priceSompi,feeAddress:record.feeAddress,
    ...(action==="buy"?{sellerPskt:record.sellerPskt}:{})};
}
async function descriptor(record:RecordData) {
  return JSON.parse((await core()).prepareNftMarket(JSON.stringify({action:"describe",sender:record.seller,seller:record.seller,ticker:record.ticker,tokenId:record.tokenId})));
}
async function live(record:RecordData) {
  const nft = await officialNft(record.ticker,record.tokenId);
  if (nft.owner!==record.seller || nft.status?.state!=="listed" || nft.status?.listingTxId!==record.listingTransactionId)
    throw new Error("This NFT is not currently listed by this seller. Refresh the market.");
  const proof = await read(`${NODE}/transactions/${record.listingTransactionId}`);
  if (proof.is_accepted!==true || proof.transaction_id!==record.listingTransactionId) throw new Error("The NFT listing has not been accepted yet.");
  const d = await descriptor(record);
  const cells = (await spendingData(d.listingAddress,"mainnet")).utxosJson;
  if (!JSON.parse(cells).some((row:any)=>row.outpoint.transactionId===record.listingTransactionId && row.outpoint.index===0))
    throw new Error("The NFT listing is pending, sold or cancelled. Refresh and retry.");
  return cells;
}
async function waitCells(context:NftContext,address:string,id:string) {
  for(let i=0;i<12;i++) {
    await context.guard();
    const cells = (await spendingData(address,"mainnet")).utxosJson;
    if(JSON.parse(cells).some((row:any)=>row.outpoint.transactionId===id && row.outpoint.index===0)) return cells;
    await pause(2000);
  }
  throw new Error("Transaction saved but not spendable yet. Open My listings and tap Resume listing.");
}
async function acceptedOrBroadcast(context:NftContext,id:string,submit:string) {
  await context.guard();
  try { const proof=await read(`${NODE}/transactions/${id}`); if(proof.transaction_id===id && proof.is_accepted===true) return; } catch { /* Exact transaction only. */ }
  await context.guard();
  const result = await broadcast(submit,"mainnet");
  if(result && result!==id) throw new Error("Node returned a mismatching transaction ID.");
}
async function authorization(context:NftContext,title:string,details:string[],request:any,review:any,kind:"Transaction"|"Reveal"|"Pskt") {
  await context.guard();
  if(!await context.approve(title,details,{request,review})) throw new Error("Transaction cancelled. Any saved listing remains recoverable.");
  await context.guard();
  return context.sign(kind,request,review.reviewHash);
}
export async function nftPublish(record:RecordData) {
  const id=record.localId;
  if(publishing.has(id)) return publishing.get(id)!;
  const task=(async()=>{
    for(let i=0;i<12;i++) {
      try {
        const response=await fetch(`${NFT_DIRECTORY}/offers`,{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify(record),signal:AbortSignal.timeout(30000)});
        if(response.ok) {
          const latest=(await nftSaved(record.seller)).find(row=>row.localId===id);
          if(latest && !["sold","cancelled"].includes(latest.status)) {
            latest.published=true; latest.status="active"; delete latest.publicationError; delete latest.publicationBlocked; await save(latest);
          }
          return;
        }
        const data=await response.json().catch(()=>({})); const message=String(data.error ?? "Publication temporarily unavailable.");
        if(!(response.status===429 || response.status>=500 || /Indexer has not confirmed|Verification source unavailable/.test(message))) {
          record.publicationBlocked=true;record.publicationError=message;await save(record);throw new Error(message);
        }
      } catch(error) { if(record.publicationBlocked || i===11) throw error; }
      await pause(i<3?2000:5000);
    }
    throw new Error("Listing saved. Publication will retry automatically when NFT Market is open.");
  })().finally(()=>{publishing.delete(id);});
  publishing.set(id,task); return task;
}
export async function nftPublishPending(address:string) {
  for(const record of await nftSaved(address))
    if(record.stage==="complete" && !record.published && !record.publicationBlocked && !["sold","cancelled"].includes(record.status))
      void nftPublish(record).catch(()=>undefined);
}
async function resume(context:NftContext,record:RecordData) {
  const wasm=await core();
  if(record.stage==="commit") {
    await acceptedOrBroadcast(context,record.commitTransactionId,record.commitSubmitJson);
    const cells=await waitCells(context,record.plan.commitAddress,record.commitTransactionId);
    const request={operation:record.operation,commitTransactionId:record.commitTransactionId,commitUtxosJson:cells,feeRate:(await spendingData(context.address,"mainnet")).feeRate};
    const review=JSON.parse(wasm.prepareReveal(JSON.stringify(request)));
    const signed=await authorization(context,"Confirm NFT listing reveal",[`${record.ticker} #${record.tokenId}`,`Seller: ${context.address}`,`Network fee: ${amount(review.feeSompi)}`,`Listing reserve: ${amount(review.returnSompi)}`],request,review,"Reveal");
    Object.assign(record,{listingTransactionId:signed.transactionId,revealSubmitJson:signed.submitJson,stage:"reveal"});await save(record);
  }
  if(record.stage==="reveal") {
    await acceptedOrBroadcast(context,record.listingTransactionId,record.revealSubmitJson);record.stage="offer";await save(record);
  }
  if(record.stage==="offer") {
    const d=await descriptor(record),cells=await waitCells(context,d.listingAddress,record.listingTransactionId);
    const built=JSON.parse(wasm.prepareNftMarket(JSON.stringify(args(record,context.address,"offer",cells))));
    // Bind the review to the exact JS-round-tripped request sent for signing,
    // just like Android's separate preparePskt call (JSON 1.0 becomes 1).
    built.review=JSON.parse(wasm.preparePskt(JSON.stringify(built.request)));
    const signed=await authorization(context,"Authorize seller PSKT",[`${record.ticker} #${record.tokenId}`,`Price: ${amount(record.priceSompi)}`,`Seller payout including reserve: ${amount(built.review.outputs[0].amountSompi)}`,`Marketplace fee (2.1%): ${amount(built.feeSompi)}`,`Fee recipient: ${record.feeAddress}`,"SINGLE|ANYONECANPAY · buyer adds funding · no escrow","Kaspire enforces the marketplace fee on purchases. An external PSKT consumer could omit this fee."],built.request,built.review,"Pskt");
    Object.assign(record,{sellerPskt:signed.signedTxJson,status:"active",stage:"complete",published:false});await save(record);
  }
  if(record.stage==="complete" && !record.published) await nftPublish(record);
  return {action:"list",transactionId:record.listingTransactionId,published:record.published};
}
export async function nftOperation(context:NftContext,input:RecordData) {
  if(busy.has(context.address)) throw new Error("An NFT marketplace operation is already in progress.");
  busy.add(context.address);
  try {
    await context.guard();
    const stored=await chrome.storage.local.get(pendingKey(context.address));
    if(input.action==="resumeBroadcast") {
      const signed=stored[pendingKey(context.address)]; if(!signed) return {action:"resumeBroadcast"};
      await acceptedOrBroadcast(context,signed.transactionId,signed.submitJson);
      await completion(signed.listingTransactionId,signed.transactionId);
      await chrome.storage.local.remove(pendingKey(context.address));
      return {action:"resumeBroadcast",transactionId:signed.transactionId};
    }
    if(stored[pendingKey(context.address)]) throw new Error("A signed marketplace transaction is awaiting submission. Open My listings → Resume saved transaction first.");
    if(input.action==="resume") {
      const record=(await nftSaved(context.address)).find(row=>row.localId===input.localId);
      if(!record || ["sold","cancelled"].includes(record.status)) throw new Error("No recoverable listing found.");
      return resume(context,record);
    }
    if(input.action==="list") {
      const nft=input.nft,price=Number(input.priceSompi);
      if(!nft || !Number.isSafeInteger(price) || price<1_000_000_000 || price>9_000_000_000_000_000) throw new Error("Marketplace minimum: 10 KAS; maximum: 90,000,000 KAS.");
      const previous=await nftSaved(context.address);
      if(previous.some(row=>row.ticker===nft.ticker && row.tokenId===nft.tokenId && !["sold","cancelled"].includes(row.status))) throw new Error("This NFT already has a saved listing. Use My listings to resume or cancel it.");
      const pending=await chrome.storage.local.get("pendingInscription");
      if(pending.pendingInscription) throw new Error("Complete your pending asset reveal in Send → Assets first.");
      await requireUnlistedNft(context.address,nft.ticker,nft.tokenId);
      const feeAddress=await resolveWalletInput("hub21.kas","mainnet"),wasm=await core();
      const operation={kind:"krc721-list",sender:context.address,recipient:context.address,ticker:nft.ticker,tokenId:nft.tokenId};
      const plan=JSON.parse(wasm.prepareInscription(JSON.stringify(operation))),spend=await spendingData(context.address,"mainnet");
      const request={sender:context.address,recipient:plan.commitAddress,amountSompi:plan.commitAmountSompi,feeRate:spend.feeRate,utxosJson:spend.utxosJson,sendAll:false};
      const review=JSON.parse(wasm.prepareTransaction(JSON.stringify(request)));
      const signed=await authorization(context,"List NFT",[`${nft.ticker} #${nft.tokenId}`,`Seller: ${context.address}`,`Price: ${amount(price)}`,`Marketplace fee (2.1%): ${amount(((BigInt(price)*21n+999n)/1000n).toString())}`,`Fee recipient: ${feeAddress}`,`Listing reserve: ${amount(plan.commitAmountSompi)}`,`Commit network fee: ${amount(review.feeSompi)}`,"PSKT · SINGLE|ANYONECANPAY · no escrow. Reveal requires a separate authorization."],request,review,"Transaction");
      const record={ticker:nft.ticker,tokenId:nft.tokenId,imageUrl:nft.imageUrl,rarityRank:nft.rarityRank,localId:signed.transactionId,seller:context.address,priceSompi:price,feeAddress,operation,plan,commitTransactionId:signed.transactionId,commitSubmitJson:signed.submitJson,status:"pending",stage:"commit",createdAt:Date.now()};
      await save(record);return resume(context,record);
    }
    if(!["buy","cancel"].includes(input.action)) throw new Error("Invalid NFT marketplace action.");
    const offer=input.offer;
    if(!offer || (input.action==="cancel" && offer.seller!==context.address)) throw new Error("Select the selling wallet first.");
    const cells=await live(offer),wasm=await core(),spend=await spendingData(context.address,"mainnet");
    const requestArgs={...args(offer,context.address,input.action,cells),feeRate:spend.feeRate,...(input.action==="buy"?{walletUtxosJson:spend.utxosJson}:{})};
    const built=JSON.parse(wasm.prepareNftMarket(JSON.stringify(requestArgs)));
    built.review=JSON.parse(wasm.preparePskt(JSON.stringify(built.request)));
    await context.guard();
    if(!await context.approve(input.action==="buy"?"Buy NFT":"Cancel NFT listing",[`${offer.ticker} #${offer.tokenId}`,`Seller: ${offer.seller}`,`Signing account: ${context.address}`,`Price: ${amount(input.action==="buy"?offer.priceSompi:0)}`,`Marketplace fee: ${amount(built.feeSompi)}`,`Fee recipient: ${offer.feeAddress}`,`Network fee: ${amount(built.networkFeeSompi)}`,
      ...built.review.outputs.map((output:any,index:number)=>`Output ${index}: ${amount(output.amountSompi)} → ${output.address ?? output.scriptPublicKey}`),
      `Transaction ID: ${built.review.transactionId}`,
    ],{request:built.request,review:built.review})) throw new Error("Transaction cancelled.");
    await context.guard();await live(offer);
    const signed=await context.sign("Pskt",built.request,built.review.reviewHash);
    if(!signed.submitJson) throw new Error("NFT transaction is not fully funded. Nothing was broadcast.");
    await chrome.storage.local.set({[pendingKey(context.address)]:{...signed,listingTransactionId:offer.listingTransactionId}});
    await acceptedOrBroadcast(context,signed.transactionId,signed.submitJson);await completion(offer.listingTransactionId,signed.transactionId);
    await chrome.storage.local.remove(pendingKey(context.address));
    if(input.action==="cancel") {
      const own=(await nftSaved(context.address)).find(row=>row.listingTransactionId===offer.listingTransactionId);
      if(own) {own.status="cancelled";await save(own);}
    }
    return {action:input.action,transactionId:signed.transactionId};
  } finally {busy.delete(context.address);}
}
async function completion(listingTransactionId:string,transactionId:string) {
  for(let i=0;i<3;i++) try {
    const response=await fetch(`${NFT_DIRECTORY}/completion`,{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({listingTransactionId,transactionId}),signal:AbortSignal.timeout(5000)});
    if(response.ok) return;
    await pause(1000);
  } catch { /* Discovery is not transaction success. */ }
}
export async function nftMyListings(address:string) {
  const remote:any[]=[];let offset=0;
  for(let i=0;i<1000;i++) {
    const page=await nftBrowse({seller:address,offset});remote.push(...page.offers);
    if(page.nextOffset==null) break;
    if(!Number.isSafeInteger(page.nextOffset)||page.nextOffset<=offset) throw new Error("Invalid NFT directory pagination.");
    offset=page.nextOffset;
  }
  const own=await nftSaved(address);
  for(const row of own) {
    const match=remote.find(item=>item.listingTransactionId===row.listingTransactionId);
    if(match) {
      if(!["sold","cancelled"].includes(row.status) || ["sold","cancelled"].includes(match.status)) row.status=match.status;
      if(match.rarityRank!=null) row.rarityRank=match.rarityRank;
      row.published=true;await save(row);
    }
  }
  return {records:[...own,...remote.filter(row=>!own.some(item=>item.listingTransactionId===row.listingTransactionId))].sort((a,b)=>Number(["sold","cancelled"].includes(a.status))-Number(["sold","cancelled"].includes(b.status)) || Number(b.createdAt??0)-Number(a.createdAt??0)),pendingBroadcast:!!(await chrome.storage.local.get(pendingKey(address)))[pendingKey(address)]};
}
