// Standalone Kaspire offer service. Imported logic is owned in services/nft-nexus;
// no runtime files, environment or database belong to the former website.
import http from 'node:http';
import {randomBytes} from 'node:crypto';
import {prisma} from '@/lib/db/prisma';
import {env} from '@/lib/validation/env';
import {verifyWalletSignatureDetailed} from '@/lib/auth/wallet-verifier';
import {getDisplayNftSnapshot,refreshNftSnapshot} from '@/server/services/nft-service';
import {createOffer,cancelOffer,acceptCounterOffer,sellerTransition} from '@/server/services/offer-service';
import {getActiveOffersBatch} from '@/lib/offers/active-offers';
import {fetchCollectionTokenPage,fetchCollectionTraitCatalog,resolveExistingCollection} from '@/lib/market-provider/kaspacom-tokens';
import {fetchWalletCollectionSummaries,resolveWalletQuery} from '@/lib/market-provider/wallet-holdings';
import {privateToken,privateCollectionSnapshot,privateWallet} from '@/lib/market-provider/private-indexer';
import {getCollectionInfo} from '@/lib/market-provider/collections';
import {storedCollectionRanks} from '@/lib/market-provider/stored-rarity';
import {rateLimit} from '@/lib/security/rate-limit';
import {startExpiryWorker} from '@/worker/expiry-worker';
import {validateOffer,createNexusToken,readNexusToken,buildInternalNexusChallenge} from './nexus-protocol.mjs';

const market='https://kaspire.kaslab.space/nft-market-test-v1';
const image=(ticker:string,id:string)=>`https://kaspire.kaslab.space/krc721-read-v1/images/${encodeURIComponent(ticker)}/${encodeURIComponent(id)}`;
const mainnet=(v:unknown)=>{if(typeof v!=='string'||!/^kaspa:[a-z0-9]{40,80}$/.test(v))throw Error('A Kaspa mainnet wallet is required.');return v;};
const ref=(ticker:string,id:string)=>{if(!/^[a-zA-Z0-9_-]{1,32}$/.test(ticker)||!/^\d{1,20}$/.test(id))throw Error('Invalid NFT reference.');return {collectionId:ticker,tokenId:id};};
const nonnegative=(v:string|null)=>{const n=Number(v??0);if(!Number.isSafeInteger(n)||n<0||n>1000000)throw Error('Invalid page offset.');return n;};
function traitsParam(value:string|null):Record<string,string[]> {
  const parsed=JSON.parse(value||'{}');
  if(!parsed||Array.isArray(parsed)||typeof parsed!=='object'||Object.keys(parsed).length>32)throw Error('Invalid trait filters.');
  for(const [name,values]of Object.entries(parsed))if(name.length>120||!Array.isArray(values)||values.length>64||values.some(v=>typeof v!=='string'||v.length>320))throw Error('Invalid trait filters.');
  return parsed;
}
const listingCache=new Map<string,{until:number,value:any}>(),listingPending=new Map<string,Promise<any>>();
async function ownListing(ticker:string,id:string,owner:string|null) {
  const key=ticker.toUpperCase()+':'+id+':'+owner,hit=listingCache.get(key);
  if(hit&&hit.until>Date.now())return hit.value;
  if(listingPending.has(key))return listingPending.get(key);
  const work=loadOwnListing(ticker,id,owner).then(value=>{if(listingCache.size>2048)listingCache.delete(listingCache.keys().next().value!);listingCache.set(key,{until:Date.now()+25000,value});return value;}).finally(()=>listingPending.delete(key));
  listingPending.set(key,work);return work;
}
async function loadOwnListing(ticker:string,id:string,owner:string|null) {
  const response=await fetch(market+'/offers?'+new URLSearchParams({tokenId:id,collection:ticker.toUpperCase(),refresh:'1'}),{signal:AbortSignal.timeout(12000)});
  if(!response.ok)throw Error('Kaspire listing status is currently unavailable.');
  const data=await response.json();
  return data.offers?.find((r:any)=>r.ticker===ticker.toUpperCase()&&String(r.tokenId)===id&&r.seller===owner&&r.status==='active')??null;
}
async function reconcile(wallet:string) {
  const candidates=await prisma.offerThread.findMany({where:{status:{in:['OPEN','COUNTERED','AGREED_WAITING_RELIST','RELIST_DETECTED']},OR:[{buyerWalletAccount:{walletAddress:wallet}},{currentSellerWallet:wallet}]},include:{nftCache:true},orderBy:{updatedAt:'desc'},take:50});
  for(const offer of candidates) {
    try {
      const snapshot=await refreshNftSnapshot({collectionId:offer.nftCache.collectionId,tokenId:offer.nftCache.tokenId});
      if(!snapshot.currentOwnerWallet)continue;
      if(snapshot.currentOwnerWallet!==offer.currentSellerWallet) {
        await prisma.$transaction(async tx=>{
          const changed=await tx.offerThread.updateMany({where:{id:offer.id,status:offer.status,currentSellerWallet:offer.currentSellerWallet},data:{status:'INVALIDATED_OWNER_CHANGED',currentSellerWallet:snapshot.currentOwnerWallet}});
          if(!changed.count)return;
          await tx.notification.upsert({where:{dedupeKey:`owner-changed:${offer.id}`},update:{},create:{walletAccountId:offer.buyerWalletAccountId,type:'INVALIDATED_OWNER_CHANGED',channel:'IN_APP',dedupeKey:`owner-changed:${offer.id}`,payloadJson:{title:'Offer invalidated',message:`${offer.nftCache.name} has changed owner.`,offerId:offer.id,collectionId:offer.nftCache.collectionId,tokenId:offer.nftCache.tokenId}}});
        });
        continue;
      }
      if(snapshot.listingStatus!=='LISTED')continue;
      const listing=await ownListing(offer.nftCache.collectionId,offer.nftCache.tokenId,snapshot.currentOwnerWallet);
      if(!listing)continue;
      await prisma.notification.upsert({where:{dedupeKey:`nexus-listing:${offer.id}:${listing.listingTransactionId}`},update:{},create:{walletAccountId:offer.buyerWalletAccountId,type:'NFT_LISTED',channel:'IN_APP',dedupeKey:`nexus-listing:${offer.id}:${listing.listingTransactionId}`,payloadJson:{title:'NFT listed on Kaspire',message:`${offer.nftCache.name} now has an active Kaspire listing.`,offerId:offer.id,collectionId:offer.nftCache.collectionId,tokenId:offer.nftCache.tokenId}}});
      if(BigInt(listing.priceSompi)!==offer.currentAmountSompi||offer.status!=='AGREED_WAITING_RELIST')continue;
      await prisma.$transaction(async tx=>{
        const updated=await tx.offerThread.updateMany({where:{id:offer.id,status:'AGREED_WAITING_RELIST'},data:{status:'RELIST_DETECTED'}});
        if(!updated.count)return;
        await tx.offerRevision.create({data:{offerThreadId:offer.id,actorWalletAddress:'system',type:'RELIST_DETECTED',amountSompi:BigInt(listing.priceSompi)}});
        await tx.notification.upsert({where:{dedupeKey:`relist-detected:${offer.id}`},update:{},create:{walletAccountId:offer.buyerWalletAccountId,type:'RELIST_DETECTED',channel:'IN_APP',dedupeKey:`relist-detected:${offer.id}`,payloadJson:{title:'NFT relisted at your agreed price',message:`${offer.nftCache.name} is listed on Kaspire at your agreed price. Another buyer may buy it first.`,offerId:offer.id,collectionId:offer.nftCache.collectionId,tokenId:offer.nftCache.tokenId}}});
      });
    }catch{/* A failed listing check must not become a false relist alert. */}
  }
}
const refreshJobs=new Map<string,number>();
function scheduleReconcile(wallet:string) {
  if((refreshJobs.get(wallet)??0)>Date.now())return;
  refreshJobs.set(wallet,Date.now()+30000);
  void reconcile(wallet).catch(()=>{}).finally(()=>{
    if(refreshJobs.size>4096)for(const [key,until]of refreshJobs)if(until<Date.now())refreshJobs.delete(key);
  });
}
async function handler(req:http.IncomingMessage,res:http.ServerResponse) {
  const send=(status:number,data:unknown)=>{res.writeHead(status,{'content-type':'application/json','cache-control':'no-store','x-content-type-options':'nosniff'});res.end(JSON.stringify(data,(_,v)=>typeof v==='bigint'?v.toString():v));};
  try {
    const url=new URL(req.url??'/', 'http://127.0.0.1'),path=url.pathname.split('/').filter(Boolean),method=req.method;
    if(!rateLimit('native-api:'+req.socket.remoteAddress,300,60000).ok)return send(429,{error:'Too many requests. Please try again shortly.'});
    let body:any={};
    if(method==='POST') {let raw='';for await(const chunk of req){raw+=chunk;if(Buffer.byteLength(raw)>16384)return send(413,{error:'Request too large.'});}body=JSON.parse(raw||'{}');}
    const bearer=req.headers.authorization?.match(/^Bearer ([A-Za-z0-9_.-]+)$/)?.[1];
    const wallet=readNexusToken(bearer,env.SESSION_SECRET);
    const authenticated=()=>{if(!wallet)throw Error('Wallet session required.');return mainnet(wallet);};
    if(method==='GET'&&path[0]==='health')return send(200,{service:'Kaspire standalone NFT offers',custody:false});
    if(method==='POST'&&path.join('/')==='auth/internal-challenge') {
      const address=mainnet(body.walletAddress);
      if(!rateLimit('native-challenge:'+address,10,60000).ok)return send(429,{error:'Too many login challenges. Try again in a minute.'});
      const now=new Date(),expiresAt=new Date(now.getTime()+300000),nonce=randomBytes(32).toString('base64url');
      await prisma.walletAccount.upsert({where:{walletAddress:address},update:{},create:{walletAddress:address}});
      return send(200,await prisma.authChallenge.create({data:{walletAddress:address,nonce,expiresAt,message:buildInternalNexusChallenge(address,nonce,now.toISOString(),expiresAt.toISOString())}}));
    }
    if(method==='POST'&&path.join('/')==='auth/internal-verify') {
      const address=mainnet(body.walletAddress);
      if(typeof body.nonce!=='string'||body.nonce.length>128||typeof body.signature!=='string'||body.signature.length>512||typeof body.publicKey!=='string'||body.publicKey.length>130)throw Error('Invalid login signature.');
      const challenge=await prisma.authChallenge.findUnique({where:{nonce:body.nonce}});
      if(!challenge||challenge.walletAddress!==address||challenge.usedAt||challenge.expiresAt<=new Date())return send(401,{error:'Login challenge expired or already used.'});
      if(!challenge.message.startsWith('Kaspire Internal NFT Offers\n'))return send(401,{error:'Wallet authentication purpose mismatch.'});
      const verification=await verifyWalletSignatureDetailed({walletAddress:address,message:challenge.message,signature:body.signature,publicKey:body.publicKey});
      if(!verification.valid)return send(401,{error:verification.reason});
      const consumed=await prisma.authChallenge.updateMany({where:{id:challenge.id,usedAt:null,expiresAt:{gt:new Date()}},data:{usedAt:new Date()}});
      if(!consumed.count)return send(401,{error:'Login challenge already used.'});
      await prisma.walletAccount.update({where:{walletAddress:address},data:{publicKey:body.publicKey,verifiedAt:new Date()}});
      return send(200,{walletAddress:address,token:createNexusToken(address,env.SESSION_SECRET)});
    }
    if(method==='GET'&&path[0]==='search') {
      const q=(url.searchParams.get('q')||'').trim();if(!q||q.length>160)throw Error('Enter a ticker, ticker + token ID, or wallet.');
      if(/^kaspa:/.test(q)||/\.kas$/i.test(q)){const resolved=await resolveWalletQuery(q);if(!resolved)return send(404,{error:'Wallet or KNS name not found.'});return send(200,{kind:'wallet',walletAddress:resolved.walletAddress,collections:await fetchWalletCollectionSummaries(resolved.walletAddress)});}
      const parts=q.replace('#',' ').split(/\s+/),id=parts.find(v=>/^\d+$/.test(v)),ticker=parts.filter(v=>!/^\d+$/.test(v)).join('');
      const collection=await resolveExistingCollection(ticker);if(!collection)return send(404,{error:'Collection not found.'});
      return send(200,{kind:id?'nft':'collection',...collection,tokenId:id});
    }
    if(method==='GET'&&path[0]==='collection'&&path[1]) {
      const collectionId=path[1];if(!/^[a-zA-Z0-9_-]{1,32}$/.test(collectionId))throw Error('Invalid collection.');
      const offset=nonnegative(url.searchParams.get('offset')),sort=url.searchParams.get('sort')==='rarityRank'?'rarityRank':'tokenId',filters=traitsParam(url.searchParams.get('traits')),owner=url.searchParams.get('wallet');
      let page:any;
      if(owner) {
        mainnet(owner);const c=getCollectionInfo(collectionId);if(!c)throw Error('Collection not found.');
        const [all,holdings,ranks]=await Promise.all([privateCollectionSnapshot(c.ticker),privateWallet(owner,c.ticker),storedCollectionRanks(c.collectionId)]);
        const ids=new Set(holdings.map(r=>String(r.tokenId)));
        let rows=all.items.filter(r=>ids.has(String(r.tokenId))&&Object.entries(filters).every(([name,values])=>{const v=r.traits?.[name];const value=v&&typeof v==='object'?v.value:v??r.attributes?.find(a=>a.trait_type===name)?.value;return values.includes(String(value??''));})).map(r=>({...r,rarityRank:ranks.get(String(r.tokenId))??r.rarityRank??null}));
        rows.sort((a,b)=>sort==='rarityRank'?(a.rarityRank??Infinity)-(b.rarityRank??Infinity)||Number(a.tokenId)-Number(b.tokenId):Number(a.tokenId)-Number(b.tokenId));
        page={tokens:rows.slice(offset,offset+24).map(r=>({ticker:c.ticker,tokenId:String(r.tokenId),rarityRank:r.rarityRank??null,imageUrl:image(c.ticker,String(r.tokenId))})),totalCount:rows.length};
      } else page=await fetchCollectionTokenPage(collectionId,24,offset,sort,filters);
      return send(200,{...page,tokens:page.tokens.map((r:any)=>({...r,imageUrl:image(r.ticker,r.tokenId)})),catalog:await fetchCollectionTraitCatalog(collectionId),nextOffset:offset+24<page.totalCount?offset+24:null});
    }
    if(method==='GET'&&path.join('/')==='offers/active'){
      const page=await getActiveOffersBatch(nonnegative(url.searchParams.get('offset')),10);
      return send(200,{...page,offers:page.offers.map(r=>({...r,imageUrl:image(r.ticker,r.tokenId)}))});
    }
    if(method==='GET'&&path[0]==='nft'&&path.length===3) {
      const nft=await getDisplayNftSnapshot(ref(path[1],path[2]));if(!nft)return send(404,{error:'NFT not found.'});
      let listing=null,listingError=false;try{listing=await ownListing(path[1],path[2],nft.currentOwnerWallet);}catch{listingError=true;}
      const best=await prisma.offerThread.findMany({where:{nftCache:{collectionId:nft.collectionId,tokenId:nft.tokenId},status:{in:['OPEN','COUNTERED']},expiresAt:{gt:new Date()}},orderBy:{currentAmountSompi:'desc'},take:3});
      const token=await privateToken(path[1].toUpperCase(),path[2]);
      return send(200,{...nft,imageUrl:image(path[1].toUpperCase(),path[2]),listingPriceSompi:listing?.priceSompi??null,kaspireListing:listing,listingPriceUnavailable:listingError,attributes:token?.metadata?.attributes??[],bestOffers:best.map(r=>({id:r.id,status:r.status,currentAmountSompi:r.currentAmountSompi,expiresAt:r.expiresAt}))});
    }
    if(method==='GET'&&path[0]==='dashboard') {
      const address=authenticated();scheduleReconcile(address);
      if(path[1]==='notifications')return send(200,await prisma.notification.findMany({where:{walletAccount:{walletAddress:address}},orderBy:{createdAt:'desc'},take:50}));
      const where=path[1]==='sent'?{buyerWalletAccount:{walletAddress:address}}:{OR:[{currentSellerWallet:address},{nftCache:{currentOwnerWallet:address}}]};
      return send(200,await prisma.offerThread.findMany({where,include:{nftCache:true,buyerWalletAccount:{select:{walletAddress:true}},revisions:{orderBy:{createdAt:'asc'}}},orderBy:{updatedAt:'desc'},take:100}));
    }
    if(method==='POST'&&path.join('/')==='notifications/read') {
      const address=authenticated();await prisma.notification.updateMany({where:{walletAccount:{walletAddress:address},readAt:null},data:{readAt:new Date()}});return send(200,{ok:true});
    }
    if(method==='POST'&&path[0]==='offers') {
      const address=authenticated();if(!rateLimit('native-offer-action:'+address,30,3600000).ok)return send(429,{error:'Too many offer actions. Please try again later.'});
      if(path.length===1)return send(201,await createOffer({buyerWalletAddress:address,...validateOffer(body)}));
      if(path.length!==3||!/^c[a-z0-9]{10,64}$/.test(path[1]))throw Error('Invalid offer.');
      const offer=await prisma.offerThread.findUnique({where:{id:path[1]},include:{buyerWalletAccount:true,nftCache:true}});if(!offer)throw Error('Offer not found.');
      if(!['OPEN','COUNTERED'].includes(offer.status)||offer.expiresAt<=new Date())throw Error('This offer is no longer actionable. Refresh to see its current status.');
      const action=path[2];
      if(['cancel','accept-counter'].includes(action)) {
        if(offer.buyerWalletAccount.walletAddress!==address)return send(403,{error:'Only the offer buyer can perform this action.'});
        return send(200,action==='cancel'?await cancelOffer(offer.id,address):await acceptCounterOffer(offer.id,address));
      }
      const actions={counter:{nextStatus:'COUNTERED',revisionType:'COUNTERED'},decline:{nextStatus:'DECLINED',revisionType:'DECLINED'},'agree-to-relist':{nextStatus:'AGREED_WAITING_RELIST',revisionType:'AGREED_TO_RELIST'}} as const;
      const mapped=actions[action as keyof typeof actions];if(!mapped)throw Error('Unsupported offer action.');
      const snapshot=await getDisplayNftSnapshot({collectionId:offer.nftCache.collectionId,tokenId:offer.nftCache.tokenId});
      if(snapshot?.currentOwnerWallet!==address)return send(403,{error:'Only the current NFT owner can perform this action.'});
      if(action==='counter')validateOffer({collectionId:'CHECK',tokenId:'0',amountKas:body.amountKas,durationDays:30,acknowledgedNonBinding:true});
      return send(200,await sellerTransition({offerId:offer.id,actorWalletAddress:address,...mapped,...(action==='counter'?{amountKas:body.amountKas}:{})}));
    }
    return send(404,{error:'Nexus route not found.'});
  }catch(error){const message=error instanceof Error?error.message:'Nexus request failed.';send(message==='Wallet session required.'?401:400,{error:message.includes('prisma')?'Offer service is temporarily unavailable. Please retry.':message});}
}
startExpiryWorker();
http.createServer((req,res)=>void handler(req,res)).listen(Number(process.env.NEXUS_NATIVE_PORT||8160),'127.0.0.1');
