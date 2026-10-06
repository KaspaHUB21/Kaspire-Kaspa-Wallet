// Discovery directory only. Seller-signed PSKTs, no custody or private keys.
import http from 'node:http';
import {readFile,writeFile,rename,mkdir} from 'node:fs/promises';
import {execFile} from 'node:child_process';
import {join} from 'node:path';
const state=process.env.MARKET_STATE_DIR, helper=process.env.MARKET_DESCRIPTOR, feeAddress=process.env.MARKET_FEE_ADDRESS;
if(!state||!helper||!/^kaspa:[a-z0-9]{40,80}$/.test(feeAddress||''))throw Error('Explicit state, native verifier and fee recipient required');
const node='https://kaspire.kaslab.space/api/local-node', indexer='https://krc721-indexer.kaspa.com/api/v1/krc721/mainnet';
await mkdir(state,{recursive:true});const file=join(state,'offers.json');let records=[];
try{records=JSON.parse(await readFile(file,'utf8'));}catch(e){if(e.code!=='ENOENT')throw e;}
let writing=false;const cache=new Map();
const displayCache=new Map();
async function enrichDisplay(rows) {
  const groups=new Map();
  for(const r of rows){const key=r.ticker+'/'+r.tokenId;const hit=displayCache.get(key);
    if(hit&&hit.until>Date.now()){Object.assign(r,hit.value);continue;}
    if(!groups.has(r.ticker))groups.set(r.ticker,[]);groups.get(r.ticker).push(r);}
  for(const[tick,group]of groups)for(let start=0;start<group.length;start+=100){
    const batch=group.slice(start,start+100),ids=batch.map(r=>r.tokenId);
    let items=[],fallback=false;
    try {const response=await fetch('http://127.0.0.1:8150/metadata/'+tick+'?ids='+ids.join(','),{signal:AbortSignal.timeout(6000)});
      if(response.ok){const data=await response.json();items=data.items||[];fallback=data.ranksAvailable===false;}else fallback=response.status>=500||response.status===404;
    }catch{fallback=true;}
    if(fallback)try{const response=await fetch('https://api.kaspa.com/krc721/tokens',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({ticker:tick,tokenIds:ids,limit:ids.length,offset:0,sortField:'tokenId',sortDirection:'asc',traits:{}}),signal:AbortSignal.timeout(5000)});if(response.ok){const remote=(await response.json()).items||[];for(const row of remote){const local=items.find(i=>String(i.tokenId)===String(row.tokenId));if(local){local.rarityRank??=row.rarityRank;}else items.push(row);}}}catch{}
    for(const r of batch){const row=items.find(i=>String(i.tokenId)===r.tokenId),traits={};
      for(const entry of row?.attributes||[]){if(entry?.trait_type&&entry.value!=null)traits[String(entry.trait_type).slice(0,80)]=String(entry.value).slice(0,160);}
      for(const[k,v]of Object.entries(row?.traits||{})){const value=v&&typeof v==='object'?v.value:v;if(k.length<=80&&value!=null)traits[k]=String(value).slice(0,160);}
      const rank=row?.rarityRank;
      const value={imageUrl:`https://kaspire.kaslab.space/krc721-read-v1/images/${r.ticker}/${r.tokenId}`,
        rarityRank:Number.isSafeInteger(rank)&&(rank>0||rank===-1)?rank:r.rarityRank??null,
        traits:Object.keys(traits).length?traits:r.traits||{}};
      Object.assign(r,value);if(displayCache.size>=2048)displayCache.delete(displayCache.keys().next().value);displayCache.set(r.ticker+'/'+r.tokenId,{until:Date.now()+60000,value});
    }
  }
}
async function get(url){const r=await fetch(url,{redirect:'error',signal:AbortSignal.timeout(8000)});if(!r.ok)throw Error('Verification source unavailable');const text=await r.text();if(text.length>4*1024*1024)throw Error('Verification response too large');return JSON.parse(text);}
function native(request){return new Promise((resolve,reject)=>{const p=execFile(helper,[],{timeout:8000,maxBuffer:256*1024},(e,out)=>{if(e)return reject(Error('NFT listing or seller signature is invalid'));try{resolve(JSON.parse(out));}catch(e){reject(e);}});p.stdin.on('error',reject);p.stdin.end(JSON.stringify(request));});}
const nftUrl=r=>`${indexer}/nfts/${r.ticker.toLowerCase()}/${r.tokenId}`;
async function displayNft(r) {
  let response;
  try{response=await fetch('http://127.0.0.1:8150/nfts/'+r.ticker+'/'+r.tokenId,{signal:AbortSignal.timeout(6000)});}catch{return (await get(nftUrl(r))).result;}
  if(response.status>=500||response.status===429)return (await get(nftUrl(r))).result;
  if(!response.ok)throw Error('Local NFT lookup rejected');
  return (await response.json()).result;
}
async function status(r,force=false){
  if(r.completion){
    if(force){const proof=await get(`${node}/transactions/${r.completion.transactionId}`);if(proof.is_accepted!==true)throw Error('Completion proof unavailable');}
    return r.completion.status;
  }
  const saved=cache.get(r.listingTransactionId);if(!force&&saved&&Date.now()-saved.time<15000)return saved.status;
  // Node failures never become sold/cancelled.
  const nft=await displayNft(r);
  let result='unavailable';
  if(nft?.owner===r.seller&&nft.status?.state==='listed'&&nft.status.listingTxId===r.listingTransactionId){
    const d=await native({action:'describe',sender:r.seller,seller:r.seller,ticker:r.ticker,tokenId:r.tokenId});
    const cells=await get(`${node}/addresses/${encodeURIComponent(d.listingAddress)}/utxos`);
    result=cells.some(c=>c.outpoint?.transactionId===r.listingTransactionId&&c.outpoint.index===0)?'active':'pending';
  }else if(nft?.owner){result=nft.owner===r.seller?'cancelled':'sold';}
  cache.set(r.listingTransactionId,{time:Date.now(),status:result});return result;
}
async function verify(r){
  if(!r||!/^[a-f0-9]{64}$/.test(r.listingTransactionId)||!/^[A-Z0-9]{1,10}$/.test(r.ticker)||!/^\d{1,20}$/.test(r.tokenId)||!Number.isSafeInteger(r.priceSompi)||r.priceSompi<476191||r.feeAddress!==feeAddress||typeof r.sellerPskt!=='string'||r.sellerPskt.length>128*1024)throw Error('Invalid NFT offer terms');
  const nft=(await get(nftUrl(r))).result;
  if(nft?.owner!==r.seller||nft.status?.state!=='listed'||nft.status.listingTxId!==r.listingTransactionId)throw Error('Indexer has not confirmed this NFT listing yet; retry Publish');
  const d=await native({action:'describe',sender:r.seller,seller:r.seller,ticker:r.ticker,tokenId:r.tokenId});
  const cells=await get(`${node}/addresses/${encodeURIComponent(d.listingAddress)}/utxos`);
  const tx=await get(`${node}/transactions/${r.listingTransactionId}`);
  if(tx.transaction_id!==r.listingTransactionId||tx.is_accepted!==true||!tx.outputs?.some(o=>o.index===0&&o.script_public_key_address===d.listingAddress))throw Error('NFT listing is not accepted on-chain');
  await native({action:'verify-offer',sender:r.seller,seller:r.seller,ticker:r.ticker,tokenId:r.tokenId,listingTransactionId:r.listingTransactionId,listingUtxosJson:JSON.stringify(cells),priceSompi:r.priceSompi,feeAddress:r.feeAddress,sellerPskt:r.sellerPskt});
  const record={ticker:r.ticker,tokenId:r.tokenId,seller:r.seller,listingTransactionId:r.listingTransactionId,priceSompi:r.priceSompi,feeAddress:r.feeAddress,sellerPskt:r.sellerPskt,rarityRank:null,traits:{},createdAt:Date.now(),status:'active'};
  await enrichDisplay([record]);return record;
}
// Repair display metadata for existing offers without changing signed terms.
await enrichDisplay(records);
http.createServer(async(req,res)=>{
  res.setHeader('Content-Type','application/json');res.setHeader('Cache-Control','no-store');res.setHeader('X-Content-Type-Options','nosniff');
  const send=(code,body)=>{res.writeHead(code);res.end(JSON.stringify(body));};
  try{
    const url=new URL(req.url,'http://localhost');
    if(req.method==='GET'&&url.pathname==='/health')return send(200,{status:'internal-test-directory',offers:records.length});
    if(req.method==='GET'&&url.pathname==='/offers'){
      const offset=Number(url.searchParams.get('offset')||0);if(!Number.isSafeInteger(offset)||offset<0)throw Error('Invalid page offset');
      const seller=url.searchParams.get('seller'),q=(url.searchParams.get('q')||'').toUpperCase().slice(0,80),collection=url.searchParams.get('collection');
      let traits={};try{traits=JSON.parse(url.searchParams.get('traits')||'{}');}catch{throw Error('Invalid trait filter');}
      if(!traits||Array.isArray(traits)||typeof traits!=='object'||Object.keys(traits).length>32)throw Error('Invalid trait filter');
      const relevant=records.filter(r=>!seller||r.seller===seller);
      const collections=[...new Set(records.filter(r=>!['sold','cancelled'].includes(cache.get(r.listingTransactionId)?.status)).map(r=>r.ticker))].sort();
      const traitOptions={};for(const r of relevant.filter(r=>r.ticker===collection&&!['sold','cancelled'].includes(cache.get(r.listingTransactionId)?.status))){for(const[k,v]of Object.entries(r.traits)){(traitOptions[k]??=new Set()).add(v);}}
      let rows=relevant.filter(r=>(!collection||r.ticker===collection)&&`${r.ticker} #${r.tokenId}`.includes(q)&&Object.entries(traits).every(([k,v])=>r.traits[k]===v));
      rows.sort((a,b)=>seller?(Number(['sold','cancelled'].includes(cache.get(a.listingTransactionId)?.status))-Number(['sold','cancelled'].includes(cache.get(b.listingTransactionId)?.status))||b.createdAt-a.createdAt):url.searchParams.get('sort')==='high'?b.priceSompi-a.priceSompi:a.priceSompi-b.priceSompi);
      const page=[];let cursor=offset;
      const scanEnd=Math.min(rows.length,offset+30);
      while(cursor<scanEnd&&page.length<10){const batch=rows.slice(cursor,Math.min(scanEnd,cursor+10-page.length));cursor+=batch.length;await enrichDisplay(batch);const verified=await Promise.all(batch.map(async r=>{try{return {...r,status:await status(r,url.searchParams.get('refresh')==='1')};}catch{return {...r,status:'unavailable'};}}));page.push(...verified.filter(r=>seller||r.status==='active'));}
      return send(200,{offers:page,nextOffset:cursor<rows.length?cursor:null,collections,traitOptions:Object.fromEntries(Object.entries(traitOptions).map(([k,v])=>[k,[...v].sort()])),verification:'discovery-only'});
    }
    if(req.method==='POST'&&url.pathname==='/offers'){
      if(writing)return send(429,{error:'Publication busy; retry shortly'});writing=true;
      try{let body='';req.setTimeout(10000,()=>req.destroy());for await(const c of req){body+=c;if(body.length>160*1024)throw Error('Offer too large');}
        const record=await verify(JSON.parse(body));const existing=records.find(r=>r.listingTransactionId===record.listingTransactionId);
        if(existing){if(existing.priceSompi!==record.priceSompi||existing.sellerPskt!==record.sellerPskt)throw Error('Cancel the existing listing before changing its price');cache.delete(record.listingTransactionId);return send(200,existing);}
        if(records.length>=10000)return send(503,{error:'Test directory capacity reached'});
        const next=[...records,record];await writeFile(file+'.pending',JSON.stringify(next),{mode:0o600});await rename(file+'.pending',file);records=next;return send(201,record);
      }finally{writing=false;}
    }
    if(req.method==='POST'&&url.pathname==='/completion'){
      if(writing)return send(429,{error:'Directory busy; retry shortly'});writing=true;
      try{
        let body='';for await(const c of req){body+=c;if(body.length>512)throw Error('Completion proof too large');}
        const data=JSON.parse(body);if(!/^[a-f0-9]{64}$/.test(data.transactionId)||!/^[a-f0-9]{64}$/.test(data.listingTransactionId))throw Error('Invalid completion IDs');
        const record=records.find(r=>r.listingTransactionId===data.listingTransactionId);if(!record)throw Error('Listing not in this directory');
        const tx=await get(`${node}/transactions/${data.transactionId}`);
        if(tx.transaction_id!==data.transactionId||tx.is_accepted!==true||tx.inputs?.[0]?.previous_outpoint_hash!==record.listingTransactionId||tx.inputs[0].previous_outpoint_index!==0)throw Error('Transaction does not consume this listing');
        const completion={transactionId:data.transactionId,status:tx.outputs?.some(o=>o.index===1)?'sold':'cancelled'};
        const next=records.map(r=>r.listingTransactionId===record.listingTransactionId?{...r,completion}:r);
        await writeFile(file+'.pending',JSON.stringify(next),{mode:0o600});await rename(file+'.pending',file);records=next;cache.delete(record.listingTransactionId);
        return send(200,completion);
      }finally{writing=false;}
    }
    return send(404,{error:'Not found'});
  }catch(e){if(!res.headersSent)send(400,{error:String(e.message||e).slice(0,250)});}
}).listen(Number(process.env.PORT||8149),'127.0.0.1');
