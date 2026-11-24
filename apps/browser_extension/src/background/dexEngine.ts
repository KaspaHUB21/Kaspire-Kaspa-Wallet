import {nativeSwapResponse} from './nativeSwapResponse';
import {KCC20_PROGRAMS} from '../shared/kcc20Programs';
export type DexVenue='braid'|'kforge'|'kasforge'|'trestly';
export type DexContext={address:string;network:'mainnet'|'testnet-10';signal?:AbortSignal;
  guard():Promise<void>;ensure():Promise<void>;progress(stage:string):void;
  prepare(request:any):Promise<any>;sign(request:any,hash:string):Promise<any>;
  read(key:string):Promise<string|null>;write(key:string,value:string|null):Promise<void>;
  broadcast(raw:string,id:string):Promise<string>;
  trestly?:{describe(request:any):Promise<any>;prepare(request:any):Promise<any>;sign(request:any,hash:string):Promise<any>;canSign():Promise<boolean>;beforeSubmit(id:string,raw:string):Promise<void>};
};
const jobs=new Map<string,{context:DexContext;venue:DexVenue;action:string;readonly:boolean}>();
type AssetJob={context:DexContext;rows:any[];at:number;task?:Promise<any[]>;value?:any[]};
const assetJobs=new Map<string,AssetJob>();
const assetKey=(c:DexContext,v:DexVenue)=>`${c.network}:${c.address}:${v}`;
function publishAssets(c:DexContext,venue:DexVenue,items:any[]){
  if(!Array.isArray(items)||items.length>1000)throw Error('Invalid DEX holdings progress.');
  const job=assetJobs.get(assetKey(c,venue));if(job?.context===c)job.rows=items;
  void chrome.runtime.sendMessage({kind:'wallet-dex-assets-progress',address:c.address,network:c.network,venue,items}).catch(()=>{});
}
export async function sharedDexAssets(context:DexContext,venue:DexVenue){
  const key=assetKey(context,venue);let previous=assetJobs.get(key);
  await context.guard();
  if(previous){try{await previous.context.guard();}catch{assetJobs.delete(key);previous=undefined;}}
  if(previous?.rows.length)publishAssets(context,venue,previous.rows);
  if(previous?.task)return previous.task.then(async rows=>{await context.guard();return rows;});
  if(previous?.value&&Date.now()-previous.at<15000)return previous.value;
  if(assetJobs.size>64)assetJobs.delete(assetJobs.keys().next().value!);
  const job:AssetJob={context,rows:previous?.rows??[],at:Date.now()};assetJobs.set(key,job);
  const task=runDexEngine(context,venue,'assets').then(rows=>{publishAssets(context,venue,rows);job.value=rows;job.at=Date.now();return rows;}).finally(()=>{job.task=undefined;});
  job.task=task;return task;
}
const readonlyActions=new Set(['tokens','assets','portfolio','saved','info','notes','context','balance']);
const assets=new Map([['assets/kcc20_standard_template.json',JSON.stringify(KCC20_PROGRAMS[0]!.template)]]);
function allowedUrl(url:string,network:string){
  const u=new URL(url);if(u.protocol!=='https:'||u.username||u.password||u.hash)throw Error('Invalid DEX read endpoint.');
  const hosts=network==='mainnet'?['api.kforge.xyz','kaspa.pumpforge.tech','app.braidswap.com','api.kaspa.org']:['api-test.kforge.xyz','kaspa.testnet.pumpforge.tech','tn10-aggregator.braidswap.com','api-tn10.kaspa.org'];
  if(u.hostname==='kaspire.kaslab.space')return u.pathname.startsWith(network==='mainnet'?'/api/local-node/':'/dex-test-v1/kasseal/utxos')||network==='mainnet'&&u.pathname.startsWith('/dex-test-v1/kasseal-mainnet/utxos')||u.pathname==='/api/kcc20/broadcast';
  return hosts.includes(u.hostname);
}
function validKey(context:DexContext,venue:DexVenue,key:string){
  if(venue==='trestly'){
    const expected=`trestly.pending.v1.${context.address}`;
    if(context.network!=='mainnet'||![expected,expected+'.last'].includes(key))throw Error('Wrong native swap storage wallet/network.');
    return key;
  }
  const network=context.network==='mainnet'?'mainnet':'tn10';
  const expected=venue==='braid'?`braid_${network}_receipts_v1_${context.address}`:venue==='kforge'?`kforge_${network}_atomic_v1_${context.address}`:`kasforge_${network}_orders_v1_${context.address}`;
  // The exact Android KasForge key is verified by the build-time parity test.
  if(key!==expected)throw Error('Wrong DEX storage wallet/network.');return key;
}
const bytes64=(b:Uint8Array)=>btoa(Array.from(b,x=>String.fromCharCode(x)).join(''));
const unbase64=(s:string)=>Uint8Array.from(atob(s),c=>c.charCodeAt(0));
async function host(capability:string,message:any){
  const job=jobs.get(capability);if(!job)throw Error('DEX operation expired.');const c=job.context;
  await c.guard();const {operation,body}=message;
  if(operation==='guard')return true;
  if(operation==='progress'){c.progress(String(body.value??''));return true;}
  if(operation==='assets'){publishAssets(c,job.venue,body.items);return true;}
  if(operation==='asset'){const value=assets.get(body.path);if(value===undefined)throw Error('Unsupported DEX asset.');return value;}
  if(operation==='storeRead')return c.read(validKey(c,job.venue,String(body.key)));
  if(['storeWrite','storeDelete'].includes(operation)){
    if(job.readonly)throw Error('Read-only DEX operation cannot change recovery.');
    const key=validKey(c,job.venue,String(body.key)),value=operation==='storeDelete'?null:String(body.value);
    if(value!==null){const data=JSON.parse(value);if(value.length>16000000||(job.venue==='trestly'?!data||typeof data!=='object'||Array.isArray(data):!Array.isArray(data)))throw Error('Invalid DEX recovery data.');}
    await c.write(key,value);return true;
  }
  if(operation==='http'){
    const url=String(body.url),method=String(body.method),u=new URL(url),native=job.venue==='trestly';
    const nativeRead=c.network==='mainnet'&&u.protocol==='https:'&&!u.username&&!u.password&&!u.hash&&(
      u.origin==='https://api.trestly.io'&&['/api/v1/status','/api/v1/pool','/api/v1/tokens'].includes(u.pathname)||
      u.origin==='https://kaspire.kaslab.space'&&(/^\/api\/local-node\/(addresses\/kaspa%3A[a-z0-9]+\/utxos|transactions\/[a-f0-9]{64}|info\/(blockdag|fee-estimate))$/i.test(u.pathname)||/^\/api\/native-kusdt\/transactions\/[a-f0-9]{64}$/.test(u.pathname)));
    const nativeSubmit=native&&c.network==='mainnet'&&url==='https://kaspire.kaslab.space/api/native-kusdt/submit'&&method==='POST'&&['submit','resume'].includes(job.action);
    if((native?!(nativeRead&&method==='GET'||nativeSubmit):!allowedUrl(url,c.network))||!['GET','HEAD','POST'].includes(method))throw Error('Untrusted DEX endpoint.');
    if(job.readonly&&method==='POST'&&!(job.action==='notes'&&new URL(url).pathname.endsWith('/notes')))throw Error('Read-only DEX operation cannot submit a trade.');
    const encoded=String(body.body??'');if(encoded.length>4000000)throw Error('DEX request too large.');
    if(nativeSubmit){const data=JSON.parse(new TextDecoder().decode(unbase64(encoded)));if(!c.trestly||Object.keys(data).sort().join(',')!=='transactionId,transactionJson')throw Error('Invalid native swap submission.');await c.trestly.beforeSubmit(data.transactionId,data.transactionJson);}
    const target=url;
    const response=await fetch(target,{method,redirect:'error',credentials:'omit',cache:'no-store',headers:{accept:'application/json',...(method==='POST'?{'content-type':'application/json'}:{})},...(method==='POST'?{body:unbase64(encoded)}:{}),signal:AbortSignal.any([AbortSignal.timeout(45000),...(c.signal?[c.signal]:[])])});
    let bytes=new Uint8Array(await response.arrayBuffer());if(bytes.length>4000000)throw Error('DEX response too large.');await c.guard();
    if(native&&response.ok)bytes=nativeSwapResponse(url,bytes);
    const headers:Record<string,string>={};response.headers.forEach((value,key)=>{headers[key]=value;});
    return {status:response.status,body:bytes64(bytes),headers};
  }
  if(operation.startsWith('trestly')){
    if(job.venue!=='trestly'||c.network!=='mainnet'||!c.trestly)throw Error('Unsupported native swap profile.');
    if(operation==='trestlyCanSign'){if(body.address!==c.address)throw Error('Wrong native swap wallet.');return c.trestly.canSign();}
    if(operation==='trestlyDescribe')return c.trestly.describe(body.request);
    if(body.request?.sender!==c.address)throw Error('Wrong native swap sender.');
    if(operation==='trestlyPrepare'&&!job.readonly)return c.trestly.prepare(body.request);
    if(operation==='trestlySign'&&job.action==='submit')return c.trestly.sign(body.request,String(body.hash));
    throw Error('This native swap action cannot sign.');
  }
  if(operation==='prepare'||operation==='sign'){
    if(job.venue==='trestly')throw Error('Native swap cannot use generic PSKT signing.');
    if(job.readonly)throw Error('Read-only DEX operation cannot prepare a signature.');
    if(operation==='sign'&&!['submit','resume','recover'].includes(job.action))throw Error('This DEX action cannot authorize a signature.');
    const r=body.request,net=c.network==='mainnet'?'mainnet':'tn10';
    const profiles=job.venue==='braid'?[`braid-${net}-deposit-v1`,`braid-${net}-reclaim-v1`]:job.venue==='kforge'?[`kforge-${net}-swap-v1`]:[`kasforge-${net}-order-v1`];
    const fundingReturn=job.venue==='kasforge'&&r?.profile==null&&r?.tradeSummary?.kind==='forge-funding-return';
    if(r?.sender!==c.address||!profiles.includes(r.profile)&&!fundingReturn)throw Error('Wrong DEX signing profile or sender.');
    return operation==='prepare'?c.prepare(r):c.sign(r,String(body.hash));
  }
  if(operation==='broadcast'){
    if(job.venue==='trestly')throw Error('Native swap requires its exact-wire relay.');
    if(!['submit','resume','recover'].includes(job.action)||c.network!=='mainnet')throw Error('Unsupported independent broadcast.');
    return c.broadcast(String(body.raw),String(body.id));
  }
  if(operation==='socketFrame'){
    if(job.venue==='trestly')throw Error('Native swap cannot use an independent DEX relay.');
    if(job.readonly||c.network!=='testnet-10'||!['wss://vector-10.kaspa.green/kaspa/testnet-10/wrpc/borsh','wss://muon-10.kaspa.blue/kaspa/testnet-10/wrpc/borsh'].includes(body.url))throw Error('Unsupported independent node.');
    const frame=unbase64(String(body.frame));if(frame.length>2000000)throw Error('Node frame too large.');
    return new Promise<string>((resolve,reject)=>{
      const socket=new WebSocket(body.url);socket.binaryType='arraybuffer';
      let settled=false;
      const finish=(error?:Error,value?:string)=>{if(settled)return;settled=true;clearTimeout(timer);c.signal?.removeEventListener('abort',abort);socket.close();error?reject(error):resolve(value!);};
      const abort=()=>finish(Error('DEX operation cancelled.'));
      const timer=setTimeout(()=>finish(Error('Independent public node timed out.')),12000);c.signal?.addEventListener('abort',abort,{once:true});
      socket.onopen=()=>socket.send(frame);socket.onerror=()=>finish(Error('Independent public node unavailable.'));
      socket.onclose=()=>finish(Error('Independent public node disconnected.'));
      socket.onmessage=e=>{if(e.data instanceof ArrayBuffer&&e.data.byteLength>12&&e.data.byteLength<2000000&&new Uint8Array(e.data)[0]===1)void c.guard().then(()=>finish(undefined,bytes64(new Uint8Array(e.data)))).catch(e=>finish(e));};
    });
  }
  throw Error('Unsupported DEX host operation.');
}
chrome.runtime.onMessage.addListener((message,sender,respond)=>{
  if(message?.kind!=='dex-engine-host')return false;
  void (async()=>{
    if(sender.id!==chrome.runtime.id||sender.url!==chrome.runtime.getURL('session.html'))throw Error('DEX host requires the offscreen document.');
    // Chromium omits MessageSender.documentId for offscreen extension pages.
    // Require the URL to exist ONLY as our single offscreen context (never a
    // tab/popup/iframe), plus the unguessable per-job capability below.
    const contexts=await chrome.runtime.getContexts({documentUrls:[sender.url]});
    if(sender.tab||contexts.length!==1||contexts[0]?.contextType!==chrome.runtime.ContextType.OFFSCREEN_DOCUMENT||
      sender.documentId!==undefined&&contexts[0]?.documentId!==sender.documentId)throw Error('Untrusted DEX host surface.');
    const raw=String(message.request);if(raw.length>18000000)throw Error('DEX request too large.');
    return host(String(message.capability),JSON.parse(raw));
  })().then(value=>respond({ok:true,value})).catch(e=>respond({ok:false,error:String(e?.message??e)}));return true;
});
export async function runDexEngine(context:DexContext,venue:DexVenue,action:string,args:any={}){
  if(!['braid','kforge','kasforge','trestly'].includes(venue)||!/^([a-zA-Z]{1,30})$/.test(action))throw Error('Invalid DEX command.');
  await context.guard();await context.ensure();
  const capability=Array.from(crypto.getRandomValues(new Uint8Array(32)),b=>b.toString(16).padStart(2,'0')).join('');
  jobs.set(capability,{context,venue,action,readonly:readonlyActions.has(action)});
  try{
    const response=await chrome.runtime.sendMessage({kind:'dex-engine-invoke',capability,payload:JSON.stringify({venue,action,args,address:context.address,network:context.network})});
    if(response?.error)throw Error(response.error);if(typeof response?.result!=='string')throw Error('DEX engine returned no result.');
    const result=JSON.parse(response.result);if(result.ok!==true)throw Error(String(result.error??'DEX failed.'));await context.guard();return result.value;
  }finally{jobs.delete(capability);}
}
