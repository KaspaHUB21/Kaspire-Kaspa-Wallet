import http from 'node:http';
import {pathToFileURL} from 'node:url';
const aliases={hash:'HASH',kasgoths:'KASGOTHS',yonatoshi:'YONATOSHI',pixelkrex:'PIXELKREX',jeetslife:'JEETSLIFE',bitcoin:'BITCOIN',kaspunks:'KASPUNKS',kaszombies:'KASZOMBIES',kdc:'KDC'};
// Same merge, value conversion, rarity averaging and sorting as Nexus's
// fetchCollectionTraitCatalog. Never return owners, source credentials or scripts.
export function addTraits(counts,item){
 const traits={...item.traits,...Object.fromEntries((item.attributes??[]).map(a=>[a.trait_type,{value:a.value}]))};
 for(const [type,trait] of Object.entries(traits)){
  if(type.length>120)continue;const value=trait&&typeof trait==='object'?trait.value:trait;
  if(value===null||value===undefined||String(value)===''||String(value).length>320)continue;
  const rarity=trait&&typeof trait==='object'&&typeof trait.rarity==='number'?trait.rarity:null;
  let values=counts.get(type);if(!values){values=new Map();counts.set(type,values);}if(values.size>=4096&&!values.has(String(value)))throw Error('Trait catalog exceeds supported bounds.');
  const old=values.get(String(value))??{count:0,total:0,n:0};old.count++;if(rarity!==null&&Number.isFinite(rarity)){old.total+=rarity;old.n++;}values.set(String(value),old);
 }
}
export function traitResult(counts){return [...counts.entries()].sort(([a],[b])=>a.localeCompare(b)).map(([traitType,values])=>({traitType,values:[...values.entries()].map(([value,s])=>({value,count:s.count,rarity:s.n?s.total/s.n:null})).sort((a,b)=>b.count-a.count||a.value.localeCompare(b.value))}));}
export function createTraitsServer({request=fetch,base=process.env.KRC721_PRIVATE_BASE_URL??'http://127.0.0.1:18801',key=process.env.KRC721_PRIVATE_API_KEY??''}={}){
 const u=new URL(base);if(u.protocol!=='http:'||u.hostname!=='127.0.0.1'||u.pathname!=='/'||u.username||u.password)throw Error('Only the fixed loopback metadata reader is allowed.');
 const cache=new Map(),pending=new Map();let active=0;
 async function catalog(id){const hit=cache.get(id);if(hit&&hit.until>Date.now())return hit.value;if(pending.has(id))return pending.get(id);const task=(async()=>{
  const ticker=aliases[id]??id.toUpperCase(),counts=new Map(),seen=new Set();let offset=0,count=0,total=0,ready=0;const signal=AbortSignal.timeout(35000);
  for(let page=0;page<200;page++){
   const r=await request(base.replace(/\/$/,'')+'/v1/catalog/'+encodeURIComponent(ticker)+'?limit=500&offset='+offset,{redirect:'error',signal,headers:key?{'X-KRC721-Key':key}:{}});if(!r.ok)throw Error('Metadata temporarily unavailable.');
   const text=await r.text();if(text.length>16*1024*1024)throw Error('Metadata page too large.');const d=JSON.parse(text);if(d.message!=='success'||!Array.isArray(d.result)||!Number.isSafeInteger(d.totalCount)||d.totalCount<0||d.totalCount>100000)throw Error('Invalid metadata page.');
   total=d.totalCount;ready=d.metadataReady;for(const item of d.result){addTraits(counts,item);count++;}if(d.next===null){if(count!==total)throw Error('Collection inventory changed. Retry.');const value={collectionId:id,ticker,traits:traitResult(counts),metadataReady:ready,totalCount:total};if(cache.size>=64)cache.delete(cache.keys().next().value);cache.set(id,{until:Date.now()+30000,value});return value;}
   if(!Number.isSafeInteger(d.next)||d.next<=offset||seen.has(d.next)||d.result.length===0)throw Error('Metadata paging did not advance.');seen.add(d.next);offset=d.next;
  }throw Error('Metadata scan incomplete.');
 })().finally(()=>pending.delete(id));pending.set(id,task);return task;}
 return http.createServer(async(req,res)=>{
  const send=(status,data)=>{res.writeHead(status,{'content-type':'application/json','cache-control':'public,max-age=30','x-content-type-options':'nosniff'});res.end(JSON.stringify(data));};
  const u=new URL(req.url,'http://localhost'),match=/^\/api\/collections\/([a-z0-9]{1,64})\/traits$/.exec(u.pathname);
  if(req.method==='GET'&&u.pathname==='/health'){send(200,{ok:true,readOnly:true});return;}
  if(req.method!=='GET'||!match||u.search){req.resume();send(404,{error:'Unsupported explorer read.'});return;}
  if(active>=4){send(503,{error:'Trait catalog busy. Please retry.'});return;}active++;
  try{send(200,await catalog(match[1]));}catch{send(503,{error:'NFT trait catalog temporarily unavailable. Please retry.'});}finally{active--;}
 });
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)createTraitsServer().listen(3022,'127.0.0.1');
