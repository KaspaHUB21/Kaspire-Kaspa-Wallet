// Restricted mainnet partner relay: credentials and upstream cookies stay here.
import http from 'node:http';
import {readFile} from 'node:fs/promises';
import {randomBytes} from 'node:crypto';
import {spawn} from 'node:child_process';
import {family,wallet,page,orderId,browseBody,issueToken,readToken,writeBody,purchaseOutcome,rankedKrc20,rankedKrc721,historyFilters,sellerTransportMetadata} from './kaspacom-market-protocol.mjs';
const upstream='https://api.kaspa.com',keyFile=process.env.KASPACOM_KEY_FILE??'/srv/kaspire/private/kaspacom/api-key';
const binary=process.env.KASPACOM_NATIVE_BINARY??'/srv/kaspire/source/target/release/kaspacom_market_descriptor';
const secret=randomBytes(32),challenges=new Map(),rates=new Map();let cookie='',cookieUntil=0,login;
const publications=new Map();
const displayCache=new Map();
async function display(key,load){const hit=displayCache.get(key);if(hit&&hit.until>Date.now())return hit.value;const value=await load();if(displayCache.size>=128)displayCache.delete(displayCache.keys().next().value);displayCache.set(key,{until:Date.now()+60000,value});return value;}
function ticker(q){const t=(q.get('ticker')??'').trim().toUpperCase();if(!/^[A-Z0-9]{1,10}$/.test(t))throw Error('Invalid ticker');return t;}
async function rankedCatalog(offset){return display('ranked-catalog:'+offset,async()=>{
  const ranked=await display('explorer-ranking',async()=>{const r=await fetch('https://kaspatoken.kaslab.space/api/tokens?layer=KRC20',{redirect:'error',signal:AbortSignal.timeout(10000)});if(!r.ok)throw Error('Token Explorer ranking temporarily unavailable');const d=await r.json();return rankedKrc20(d.data.tokens);});
  const items=[];let cursor=offset;
  // Bounded work and a real source cursor: non-tradable tokens do not consume
  // a visible slot or make subsequent pages repeat/skip ranked candidates.
  while(items.length<20&&cursor<ranked.length&&cursor<offset+100){
    const batch=ranked.slice(cursor,Math.min(cursor+5,ranked.length));
    const checked=await Promise.all(batch.map(async(t,i)=>{const d=await display('active:'+t.symbol,()=>api('/p2p-v2/sell-orders?ticker='+t.symbol,{sort:{field:'totalPrice',direction:'asc'},pagination:{limit:1,offset:0},completedOrders:false,onlyDecentralize:true}));return d.orders?.length?{ticker:t.symbol,imageUrl:t.image_url,rank:cursor+i+1,price:t.price_kas,totalHolders:t.holders}:null;}));
    for(const item of checked){cursor++;if(item)items.push(item);if(items.length===20)break;}
  }
  return {items,nextOffset:cursor<ranked.length?cursor:null};
});}
async function nftCatalog(offset){
  const ranked=await display('nft-explorer-ranking',async()=>{
    const r=await fetch('https://kaspatoken.kaslab.space/api/tokens?layer=KRC721',{redirect:'error',signal:AbortSignal.timeout(10000)});
    if(!r.ok)throw Error('NFT Explorer ranking temporarily unavailable');
    const d=await r.json();return rankedKrc721(d.data.tokens);
  });
  let floors=[];
  try { floors=await display('nft-floor-prices',()=>api('/api/krc721/floor-price')); }
  catch { /* Missing optional prices never hide the ranked collections. */ }
  const floorByTicker=new Map((Array.isArray(floors)?floors:[]).map(f=>[f.ticker,f.floor_price]));
  const items=ranked.slice(offset,offset+20).map((t,i)=>({ticker:t.symbol,rank:offset+i+1,
    price:floorByTicker.get(t.symbol)??null,totalHolders:t.holders,
    imageUrl:t.image_url?new URL(t.image_url,'https://kaspatoken.kaslab.space').href:
      'https://kaspire.kaslab.space/krc721-read-v1/images/'+t.symbol+'/1'}));
  return {items,nextOffset:offset+items.length<ranked.length?offset+items.length:null};
}
async function traitOptions(t){return display('traits:'+t,async()=>{
  const options=new Map();let offset=0,total=1;
  while(offset<total){
    const page=await api('/krc721-orders-v2/sell-orders?ticker='+t,{sort:{direction:'desc',field:'createdAt'},pagination:{limit:50,offset},completedOrders:false,onlyDecentralize:true});
    const orders=page.orders??[];total=Number(page.totalCount??0);if(total>10000)throw Error('Trait catalog is too large; please try later');if(!orders.length)break;
    const data=await api('/api/krc721/tokens',{ticker:t,tokenIds:orders.map(o=>String(o.tokenId)),limit:50,offset:0});
    for(const item of data.items??[])for(const [key,trait]of Object.entries(item.traits??{})){const v=typeof trait==='object'?trait?.value:trait;if(typeof v!=='string')continue;if(!options.has(key))options.set(key,new Set());options.get(key).add(v);}
    offset+=orders.length;
  }
  return {traitOptions:Object.fromEntries([...options].sort(([a],[b])=>a.localeCompare(b)).map(([k,v])=>[k,[...v].sort()]))};
});}
async function krc20Proof(id){
  const order=await api('/p2p-v2/'+orderId(id));const t=ticker(new URLSearchParams({ticker:order.ticker}));const a=wallet(order.sellerWalletAddress),tx=order.psktTransactionId;
  if(!/^[a-f0-9]{64}$/.test(tx??''))throw Error('This order has no valid decentralized listing transaction');
  const url=new URL('https://api.kasplex.org/v1/krc20/market/'+t);url.searchParams.set('address',a);url.searchParams.set('txid',tx);
  const r=await fetch(url,{redirect:'error',signal:AbortSignal.timeout(15000)});if(!r.ok)throw Error(`Official KRC20 listing verification unavailable (${r.status}); no transaction was sent`);const raw=await r.text();if(raw.length>4*1024*1024)throw Error('KRC20 proof exceeds size limit');return JSON.parse(raw);
}
async function publish(kind,b,address){
  const tx=JSON.parse(b.psktSeller),listing=tx.inputs[0].transactionId;
  if(!/^[a-f0-9]{64}$/.test(listing??''))throw Error('Invalid listing transaction');
  const key=kind+':'+address+':'+listing;
  if(publications.has(key))return publications.get(key);
  const pending=(async()=>{
    const f=family(kind);
    // Recover an ambiguous prior response without creating a second order.
    for(let offset=0;offset<500;offset+=50){
      const history=await api('/'+f+'/user-orders',{sort:{direction:'desc',field:'createdAt'},pagination:{limit:50,offset},filters:{isSeller:true,isBuyer:false}},address);
      const rows=history.orders??[];
      const old=rows.find(o=>o.psktTransactionId===listing);
      if(old){
        if(Number(old.totalPrice)!==b.totalPrice||(kind==='kns'?old.assetId!==b.assetId:old.ticker?.toUpperCase()!==b.ticker)||(kind==='krc721'&&String(old.tokenId)!==b.tokenId)||(kind==='krc20'&&Number(old.quantity)!==b.quantity))throw Error('An order already exists for this listing with different terms');
        return {id:old.orderId??old.id,status:old.status};
      }
      if(rows.length<50)break;
    }
    return api('/'+f,b,address);
  })();
  publications.set(key,pending);
  try{return await pending;}finally{publications.delete(key);}
}
async function auth(){if(cookieUntil>Date.now())return cookie;if(login)return login;login=(async()=>{const key=(await readFile(keyFile,'utf8')).trim();const r=await fetch(upstream+'/auth/api-key-sign-in',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({apiKey:key}),signal:AbortSignal.timeout(15000),redirect:'error'});if(!r.ok)throw Error('KaspaCom authentication is temporarily unavailable');cookie=r.headers.getSetCookie().map(c=>c.split(';')[0]).join('; ');if(!cookie)throw Error('KaspaCom did not return an authentication cookie');cookieUntil=Date.now()+300000;return cookie;})().finally(()=>login=null);return login;}
// Live countercheck: X-Wallet-Address returns the API account's own orders even
// for another wallet. It is ignored upstream and MUST NOT be used for delegation.
// Keep the documented Wallet-Address and fail closed on misattributed history.
async function api(path,body,address,retry=true){const r=await fetch(upstream+path,{method:body===undefined?'GET':'POST',headers:{cookie:await auth(),'content-type':'application/json',...(address?{'Wallet-Address':address}:{})},...(body===undefined?{}:{body:JSON.stringify(body)}),signal:AbortSignal.timeout(30000),redirect:'error'});if(r.status===401&&retry){cookieUntil=0;return api(path,body,address,false);}if(!r.ok){const e=new Error(`KaspaCom request failed (${r.status}). Please refresh and retry.`);e.status=r.status;throw e;}const raw=await r.text();if(raw.length>3*1024*1024)throw Error('KaspaCom response exceeds size limit');const data=JSON.parse(raw);if(address&&path.endsWith('/user-orders')&&(data.orders??[]).some(o=>o.sellerWalletAddress!==address&&o.buyerWalletAddress!==address))throw Error('KaspaCom returned orders for another wallet; wallet history is unavailable');return data;}
function native(args){return new Promise((resolve,reject)=>{const p=spawn(binary,[],{stdio:['pipe','pipe','pipe']});let out='',err='';const timer=setTimeout(()=>p.kill(),15000);p.on('error',reject);p.stdout.on('data',d=>out+=d);p.stderr.on('data',d=>err+=d);p.on('close',code=>{clearTimeout(timer);if(code)return reject(Error('Wallet authentication failed'));try{resolve(JSON.parse(out));}catch{reject(Error('Invalid authentication response'));}});p.stdin.on('error',reject);p.stdin.end(JSON.stringify(args));});}
async function body(req){let data='';for await(const c of req){data+=c;if(data.length>550*1024){const e=Error('Request too large');e.status=413;throw e;}}return JSON.parse(data||'{}');}
function session(req){const a=readToken(req.headers.authorization?.replace(/^Bearer /,''),secret);if(!a){const e=Error('Unlock and authenticate this wallet first');e.status=401;throw e;}return a;}
const server=http.createServer(async(req,res)=>{res.setHeader('Content-Type','application/json');res.setHeader('Cache-Control','no-store');res.setHeader('X-Content-Type-Options','nosniff');const send=(status,data)=>{res.writeHead(status);res.end(JSON.stringify(data));};try{
  const now=Date.now(),ip=req.headers['x-real-ip']??req.socket.remoteAddress;const r=rates.get(ip)??{at:now,count:0};if(now-r.at>60000){r.at=now;r.count=0;}if(++r.count>120){send(429,{error:'Too many requests. Wait a minute.'});return;}rates.set(ip,r);if(rates.size>4096)for(const [key,v]of rates)if(now-v.at>60000)rates.delete(key);
  const url=new URL(req.url,'http://localhost'),parts=url.pathname.split('/').filter(Boolean);let value;
  if(req.method==='GET'&&url.pathname==='/health'){value={ok:true,network:'mainnet',marketplace:'KaspaCom'};}
  else if(req.method==='POST'&&url.pathname==='/challenge'){const b=await body(req),a=wallet(b.address);if(challenges.size>4096)for(const [id,c]of challenges)if(c.expires<now)challenges.delete(id);if(challenges.size>=4096)throw Error('Authentication busy, retry later');const nonce=randomBytes(32).toString('base64url'),message=`Kaspire KaspaCom Marketplace\nDomain: kaspire.kaslab.space\nWallet: ${a}\nNonce: ${nonce}\nExpires at: ${new Date(now+180000).toISOString()}\nAuthenticate this wallet for KaspaCom orders only. No funds are spent.`;challenges.set(nonce,{a,message,expires:now+180000});value={nonce,message};}
  else if(req.method==='POST'&&url.pathname==='/authenticate'){const b=await body(req),c=challenges.get(b.nonce);challenges.delete(b.nonce);if(!c||c.expires<now||c.a!==b.address)throw Error('Login challenge expired; retry');await native({action:'authenticate',address:c.a,message:c.message,signature:b.signature});value={token:issueToken(c.a,secret),expiresAt:now+3600000};}
  else if(req.method==='GET'&&url.pathname==='/catalog'){const kind=url.searchParams.get('kind');family(kind);value=kind==='krc20'?await rankedCatalog(page(url.searchParams.get('offset'))):kind==='krc721'?await nftCatalog(page(url.searchParams.get('offset'))):await api('/api/kns/trade-stats?timeFrame=1d');}
  else if(req.method==='GET'&&url.pathname==='/krc20/summary'){const t=ticker(url.searchParams);value=await display('token:'+t,async()=>{const [logos,floor]=await Promise.all([api('/api/tokens-logos?ticker='+t),api('/p2p-v2/floor-price/'+t)]);return {ticker:t,imageUrl:logos.find(l=>l.ticker===t)?.logo??null,floorPrice:floor.floorPrice};});}
  else if(req.method==='GET'&&url.pathname==='/krc721/traits'){value=await traitOptions(ticker(url.searchParams));}
  else if(parts.length===4&&req.method==='GET'&&parts[0]==='krc20'&&parts[1]==='orders'&&parts[3]==='proof'){value=await krc20Proof(parts[2]);}
  else if(parts.length===2&&req.method==='GET'&&parts[1]==='browse'){const kind=parts[0],f=family(kind),b=browseBody(kind,url.searchParams),ticker=(url.searchParams.get('search')??'').trim().toUpperCase();if(kind!=='kns'&&!/^[A-Z0-9]{1,10}$/.test(ticker))throw Error('Select a ticker or NFT collection first');value=await api('/'+f+'/sell-orders'+(kind==='kns'?'':'?ticker='+ticker),b);}
  else if(parts.length===2&&req.method==='GET'&&parts[1]==='history'){const a=session(req),f=family(parts[0]);value=await api('/'+f+'/user-orders',{sort:{direction:'desc',field:'createdAt'},pagination:{limit:10,offset:page(url.searchParams.get('offset'))},filters:historyFilters(url.searchParams.get('role')??'all')},a);}
  else if(parts.length===3&&parts[1]==='orders'&&req.method==='GET'){const quote=url.searchParams.get('quote')==='1';value=await api('/'+family(parts[0])+'/'+orderId(parts[2]),undefined,quote?session(req):undefined);if(quote)value={...value,exchangeQuote:true};}
  else if(parts.length===2&&parts[1]==='orders'&&req.method==='POST'){const a=session(req);value=await publish(parts[0],writeBody(parts[0],'create',await body(req)),a);}
  else if(parts.length===4&&parts[1]==='orders'&&req.method==='POST'){const a=session(req),kind=parts[0],f=family(kind),id=orderId(parts[2]),action=parts[3];if(!['buy','verify'].includes(action))throw Error('Unsupported action');let payload=writeBody(kind,action,await body(req));if(action==='buy'){
    payload=await native({action:'normalize-transport',address:a,signedBuyerPskt:payload.signedBuyerPskt});
    const original=await api('/'+f+'/'+id,undefined,a);
    payload.signedBuyerPskt=sellerTransportMetadata(payload.signedBuyerPskt,original.psktSeller);
  }value=await api('/'+f+'/'+(action==='verify'&&kind==='kns'?'verify-sold-order':action)+'/'+id,payload,a);if(action==='buy')purchaseOutcome(value);}
  else{send(404,{error:'Unknown marketplace route'});return;}
  if(url.pathname==='/catalog'&&Array.isArray(value))value={items:value,nextOffset:value.length===50?page(url.searchParams.get('offset'))+50:null};
  send(200,value);
 }catch(e){send(e.status>=400&&e.status<500?e.status:400,{error:e.message??'Marketplace temporarily unavailable'});}});
server.listen(Number(process.env.KASPACOM_PORT??8161),'127.0.0.1');
