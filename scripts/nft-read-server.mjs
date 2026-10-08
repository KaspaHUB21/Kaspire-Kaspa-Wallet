// Strictly read-only display gateway. No signing, broadcasting or admin routes.
import http from 'node:http';
import {readFile} from 'node:fs/promises';
import {join} from 'node:path';
const local='http://127.0.0.1:18801';
const rankDir=process.env.KRC721_RARITY_DIR;
if (!rankDir) throw Error('Explicit local rarity directory required');
const headers=process.env.KRC721_API_KEY?{'X-KRC721-Key':process.env.KRC721_API_KEY}:{};
const tickPattern=/^[A-Za-z0-9]{1,10}$/,idPattern=/^\d{1,20}$/,addressPattern=/^kaspa:[a-z0-9]{40,100}$/;
const imageCache=new Map(), rankCache=new Map();
let imageBusy=false,imageCacheBytes=0;const imageWaiters=[];
async function acquireImage(){
  if(!imageBusy){imageBusy=true;return;}
  if(imageWaiters.length>=32)throw Error('Image processing queue full');
  await new Promise(resolve=>imageWaiters.push(resolve));
}
function releaseImage(){const next=imageWaiters.shift();if(next)next();else imageBusy=false;}
async function boundedImageBody(response){
  if(Number(response.headers.get('content-length'))>2*1024*1024){await response.body?.cancel();throw Error('Image too large');}
  const pieces=[];let size=0;
  for await(const chunk of response.body){size+=chunk.length;if(size>2*1024*1024)throw Error('Image too large');pieces.push(chunk);}
  return Buffer.concat(pieces,size);
}
function cacheImage(key,image){
  if(image.body.length>16*1024*1024)return;
  while(imageCache.size>=64||imageCacheBytes+image.body.length>16*1024*1024){const oldest=imageCache.keys().next().value;imageCacheBytes-=imageCache.get(oldest).body.length;imageCache.delete(oldest);}
  imageCache.set(key,image);imageCacheBytes+=image.body.length;
}
let active=0;
async function fetchLocal(path) { return fetch(local+path,{headers,redirect:'error',signal:AbortSignal.timeout(5000)}); }
async function localJson(path) {
  const r=await fetchLocal(path);
  if (!r.ok) { const error=Error('Local display source unavailable'); error.status=r.status>=500||r.status===401?503:r.status; throw error; }
  const text=await r.text(); if(text.length>4*1024*1024)throw Error('Local display response too large');
  return JSON.parse(text);
}
async function ranks(tick) {
  const hit=rankCache.get(tick);if(hit&&hit.until>Date.now())return hit.value;
  try {
    const value=JSON.parse(await readFile(join(rankDir,tick+'.json'),'utf8')).ranks;
    if(rankCache.size>=128)rankCache.delete(rankCache.keys().next().value);
    rankCache.set(tick,{until:Date.now()+30000,value});return value;
  } catch { return null; }
}
http.createServer(async(req,res)=>{
  const send=(status,value)=>{res.writeHead(status,{'content-type':'application/json','cache-control':'no-store','x-content-type-options':'nosniff'});res.end(JSON.stringify(value));};
  if(req.method!=='GET')return send(405,{error:'Read-only endpoint'});
  const imageRequest=req.url.startsWith('/images/');
  if(!imageRequest&&active>=16)return send(503,{error:'Local display source busy'});
  if(!imageRequest)active++;
  try {
    if(req.url.length>4096)return send(400,{error:'URL too long'});
    const url=new URL(req.url,'http://localhost');
    const parts=url.pathname.split('/').filter(Boolean).map(decodeURIComponent);
    if(parts.length===1&&parts[0]==='health')return send(200,{mode:'read-only'});
    if(parts[0]==='nfts'&&parts.length===3&&tickPattern.test(parts[1])&&idPattern.test(parts[2])) {
      const data=await localJson('/v1/nfts/'+parts[1].toUpperCase()+'/'+parts[2]);
      if(data.result)data.result.imageUrl='https://kaspire.kaslab.space/krc721-read-v1/images/'+parts[1].toUpperCase()+'/'+parts[2];
      return send(200,data);
    }
    if(parts[0]==='address'&&(parts.length===2||parts.length===3)&&addressPattern.test(parts[1])&&(!parts[2]||tickPattern.test(parts[2]))) {
      const q=new URLSearchParams();
      for(const[k,v]of url.searchParams) {
        if(!['limit','offset','direction'].includes(k)||v.length>160||url.searchParams.getAll(k).length!==1)return send(400,{error:'Invalid pagination'});
        q.set(k,v);
      }
      const data=await localJson('/v1/wallets/'+parts.slice(1).map(encodeURIComponent).join('/')+'?'+q);
      for(const item of data.result||[])item.imageUrl='https://kaspire.kaslab.space/krc721-read-v1/images/'+item.tick.toUpperCase()+'/'+item.tokenId;
      return send(200,data);
    }
    if(parts[0]==='metadata'&&parts.length===2&&tickPattern.test(parts[1])) {
      const tick=parts[1].toUpperCase(),ids=(url.searchParams.get('ids')||'').split(',');
      if(ids.length>100||ids.some(id=>!idPattern.test(id)||BigInt(id)>=2n**64n))return send(400,{error:'Invalid token IDs'});
      // Rank files remain readable even if ownership synchronization is down.
      const known=await ranks(tick);
      let data;try{data=await localJson('/v1/metadata/'+tick+'?ids='+ids.join(','));}catch(error){if(!known)throw error;data={items:[]};}
      const byId=new Map((data.items||[]).map(item=>[String(item.tokenId),item]));
      return send(200,{items:ids.map(id=>({...byId.get(id),ticker:tick,tokenId:id,rarityRank:known?.[id]??null,
        imageUrl:'https://kaspire.kaslab.space/krc721-read-v1/images/'+tick+'/'+id})),ranksAvailable:known!==null});
    }
    if(parts[0]==='images'&&parts.length===3&&tickPattern.test(parts[1])&&idPattern.test(parts[2])) {
      const tick=parts[1].toUpperCase(),id=parts[2],key=tick+'/'+id;
      let image=imageCache.get(key);
      if(!image) {
        await acquireImage();
        try {
          image=imageCache.get(key);
          if(!image) {
            const response=await fetchLocal('/v1/token-images/'+tick+'/'+id+'?size=512');
            if(!response.ok) {
              await response.body?.cancel();
              return send(response.status===404?404:503,{error:'Local image unavailable'});
            }
            const raw=await boundedImageBody(response);
            image={body:raw,type:response.headers.get('content-type')};
            if(!image.type?.startsWith('image/')||image.type.includes('svg'))throw Error('Unsupported display image');
            cacheImage(key,image);
          }
        } finally {releaseImage();}
      }
      res.writeHead(200,{'content-type':image.type,'cache-control':'public,max-age=300','x-content-type-options':'nosniff'});return res.end(image.body);
    }
    return send(404,{error:'Unknown read route'});
  } catch(error) {
    send(error.status||503,{error:'Local display source unavailable'});
  } finally { if(!imageRequest)active--; }
}).listen(Number(process.env.PORT||8150),'127.0.0.1');
