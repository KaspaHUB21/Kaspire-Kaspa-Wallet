// Isolated test directory. Wallets independently verify every offer on-chain.
// No private keys, signed transactions or operator-controlled escrow.
import http from 'node:http';
import {execFile} from 'node:child_process';
import {readFile,writeFile,rename,mkdir} from 'node:fs/promises';
import {join} from 'node:path';
import {discoverCompletion,marketAnalytics} from './dotk-market-analytics.mjs';
const state=process.env.MARKET_STATE_DIR, descriptor=process.env.MARKET_DESCRIPTOR;
if(!state||!descriptor) throw Error('Explicit state directory and descriptor required');
await mkdir(state,{recursive:true});
const file=join(state,'offers.json');
let offers=[];
try{offers=JSON.parse(await readFile(file,'utf8'));}catch(e){if(e.code!=='ENOENT')throw e;}
let busy=false;
const archiveFile=join(state,'history.json');
let archive={version:1,startedAt:Date.now(),updatedAt:Date.now(),records:{}};
try{archive=JSON.parse(await readFile(archiveFile,'utf8'));}catch(e){if(e.code!=='ENOENT')throw e;}
async function persistArchive(){
  archive.updatedAt=Date.now();
  await writeFile(archiveFile+'.pending',JSON.stringify(archive),{mode:0o600});
  await rename(archiveFile+'.pending',archiveFile);
}
async function json(url){
  const r=await fetch(url,{signal:AbortSignal.timeout(8000),redirect:'error'});
  if(!r.ok)throw Error('Node proof unavailable');
  const body=await r.text();if(body.length>4*1024*1024)throw Error('Oversized response');
  return JSON.parse(body);
}
function derive(terms,saleId){return new Promise((resolve,reject)=>{
  const child=execFile(descriptor,[],{timeout:10000,maxBuffer:65536},(error,stdout)=>{
    if(error)return reject(Error('Invalid marketplace terms'));
    try{resolve(JSON.parse(stdout));}catch(e){reject(e);}
  });
  child.stdin.on('error',reject);
  child.stdin.end(JSON.stringify({terms,saleId}));
});}
const node='https://kaspire.kaslab.space/api/local-node';
async function verify(record,{live=true}={}){
  if(!record||!/^[a-f0-9]{64}$/.test(record.listingTxId))throw Error('Invalid listing transaction');
  if(!Number.isSafeInteger(record.terms?.priceSompi)||record.terms.priceSompi<1000000000)throw Error('Minimum price is 10 KAS');
  if(process.env.MARKET_FEE_ADDRESS&&record.terms.feeAddress!==process.env.MARKET_FEE_ADDRESS)throw Error('Unrecognized marketplace fee recipient');
  const tx=await json(`${node}/transactions/${record.listingTxId}`);
  if(tx.transaction_id!==record.listingTxId||tx.is_accepted!==true)throw Error('Listing not yet accepted');
  const sale=tx.outputs.find(o=>o.index===1),deed=tx.outputs.find(o=>o.index===0);
  if(!sale||!deed||!/^[a-f0-9]{64}$/.test(sale.covenant_id))throw Error('Missing sale covenant');
  const d=await derive(record.terms,sale.covenant_id);
  for(const [out,address,script,amount,id] of [
    [sale,d.saleAddress,d.saleScriptPublicKey,d.saleReserveSompi,sale.covenant_id],
    [deed,d.deed.deedAddress,d.deed.scriptPublicKey,d.deed.bond,d.deed.registryCovenantId],
  ]){
    if(out.script_public_key!==script||out.script_public_key_address!==address||String(out.amount)!==String(amount)||out.covenant_id!==id)throw Error('Terms conflict with chain');
    if(live){
      const cells=await json(`${node}/addresses/${encodeURIComponent(address)}/utxos`);
      if(!cells.some(u=>u.outpoint.transactionId===record.listingTxId&&u.outpoint.index===out.index&&String(u.utxoEntry.amount)===String(amount)))throw Error('Listing no longer available');
    }
  }
  return {terms:record.terms,listingTxId:record.listingTxId,saleId:sale.covenant_id};
}
// Controlled public recovery hints, never trusted until the original covenant
// outputs have been reconstructed and matched against an accepted transaction.
let recovery=[];
try{recovery=JSON.parse(await readFile(new URL('./dotk-market-recovered.json',import.meta.url),'utf8'));}catch(e){if(e.code!=='ENOENT')throw e;}
for(const hint of [...offers,...recovery]){
  if(archive.records[hint.listingTxId])continue;
  const offer=await verify(hint,{live:false});
  archive.records[offer.listingTxId]={offer,recordedAt:Date.now(),completion:null};
}
await persistArchive();
http.createServer(async(req,res)=>{
  res.setHeader('Content-Type','application/json');res.setHeader('Cache-Control','no-store');
  res.setHeader('X-Content-Type-Options','nosniff');
  const send=(status,data)=>{res.writeHead(status);res.end(JSON.stringify(data));};
  try{
    const url=new URL(req.url,'http://localhost');
    if(req.method==='GET'&&url.pathname==='/health')return send(200,{status:'test-directory',offers:offers.length});
    if(req.method==='GET'&&url.pathname==='/analytics')return send(200,marketAnalytics(archive,(url.searchParams.get('q')||'').slice(0,64)));
    if(req.method==='GET'&&url.pathname==='/offers'){
      const q=(url.searchParams.get('q')||'').toLowerCase().slice(0,64),offset=Number(url.searchParams.get('offset')||0);
      if(!Number.isSafeInteger(offset)||offset<0)return send(400,{error:'Invalid offset'});
      const rows=offers.filter(o=>o.terms.name.includes(q)).sort((a,b)=>a.terms.name.localeCompare(b.terms.name)||a.listingTxId.localeCompare(b.listingTxId));
      return send(200,{offers:rows.slice(offset,offset+50),nextOffset:offset+50<rows.length?offset+50:null,verification:'discovery-hints-only'});
    }
    if(req.method==='POST'&&url.pathname==='/offers'){
      if(busy)return send(429,{error:'Directory busy; retry shortly'});
      if(offers.length>=1000)return send(503,{error:'Test capacity reached'});
      busy=true;
      try{
        let body='';req.setTimeout(10000,()=>req.destroy());
        for await(const chunk of req){body+=chunk;if(body.length>8192)throw Error('Offer too large');}
        const record=await verify(JSON.parse(body));
        if(!archive.records[record.listingTxId]){
          archive.records[record.listingTxId]={offer:record,recordedAt:Date.now(),completion:null};
          await persistArchive();
        }
        if(offers.some(o=>o.listingTxId===record.listingTxId))return send(200,record);
        const next=[...offers,record];await writeFile(file+'.pending',JSON.stringify(next),{mode:0o600});
        await rename(file+'.pending',file);offers=next;return send(201,record);
      }finally{busy=false;}
    }
    send(404,{error:'Not found'});
  }catch(e){if(!res.headersSent)send(400,{error:String(e.message||e).slice(0,300)});}
}).listen(Number(process.env.PORT||8138),'127.0.0.1');

// Retire spent listings. A timeout or unavailable node never removes an offer.
// No addresses or incoming request URLs are written to logs.
let sweepCursor=0;
async function sweep(){
  if(busy)return;
  const unresolved=Object.values(archive.records).filter(r=>!r.completion);
  if(!unresolved.length)return;
  busy=true;
  try{
    const checked=unresolved.slice(sweepCursor,sweepCursor+10);
    sweepCursor=(sweepCursor+10)%unresolved.length;
    const spent=new Set();
    for(const record of checked){
      const offer=record.offer;
      try{await verify(offer);}catch(e){
        if(e.message==='Listing no longer available'){
          spent.add(offer.listingTxId);
          try{record.completion=await discoverCompletion(offer,{json,derive,node});}
          catch{/* Retry later; never infer a sale from a spent or missing cell. */}
        }
      }
    }
    await persistArchive();
    if(spent.size){
      const next=offers.filter(o=>!spent.has(o.listingTxId));
      await writeFile(file+'.pending',JSON.stringify(next),{mode:0o600});
      await rename(file+'.pending',file);offers=next;
    }
  }finally{busy=false;}
}
setInterval(()=>sweep().catch(()=>{}),30000).unref();
void sweep().catch(()=>{});
