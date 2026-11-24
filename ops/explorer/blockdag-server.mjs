// Fixed own-node, public header-only observation feed. No wallet SDK, keys,
// transaction submission, arbitrary RPC proxy, persistence or upstream fallback.
import http from 'node:http';
import {randomUUID} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';
import {pathToFileURL} from 'node:url';

export const LIMIT=240, RPC_URL='ws://127.0.0.1:18110';
const HASH=/^[a-f0-9]{64}$/, U64=(1n<<64n)-1n;
const integer=v=>{
  if(typeof v==='number'&&!Number.isSafeInteger(v))throw Error('Unsafe integer');
  if(!/^\d{1,20}$/.test(String(v))||BigInt(v)>U64)throw Error('Invalid integer');
  return String(v);
};
export function headerBlock(block,observedAt){
  const h=block?.header,v=block?.verboseData;
  if(!h||!HASH.test(h.hash??'')||v?.hash&&v.hash!==h.hash)throw Error('Invalid block identity');
  const parents=h.parentsByLevel?.[0];
  if(!Array.isArray(parents)||parents.length>256||parents.some(p=>!HASH.test(p)||p===h.hash)||new Set(parents).size!==parents.length)throw Error('Invalid parent links');
  const timestampMs=Number(integer(h.timestamp));
  if(!Number.isSafeInteger(timestampMs)||timestampMs>8640000000000000)throw Error('Invalid block time');
  const selectedParentHash=HASH.test(v?.selectedParentHash??'')&&parents.includes(v.selectedParentHash)?v.selectedParentHash:null;
  const count=Array.isArray(block.transactions)?block.transactions.length:Array.isArray(v?.transactionIds)?v.transactionIds.length:null;
  if(count!==null&&count>100000)throw Error('Invalid transaction count');
  return {hash:h.hash,parents,selectedParentHash,daaScore:integer(h.daaScore),blueScore:integer(h.blueScore),timestampMs,txCount:count,observedAt};
}

export class DagBuffer {
  constructor(now=Date.now){this.now=now;this.epoch=randomUUID();this.blocks=new Map();this.status='reconnecting';this.lastBlockAt=null;this.startedAt=null;this.sequence=0;this.info=null;this.arrivals=[];this.cached=null;}
  begin(info){this.epoch=randomUUID();this.blocks.clear();this.arrivals=[];this.lastBlockAt=null;this.startedAt=this.now();this.sequence=0;this.status='warming';this.info={blockCount:integer(info.blockCount),virtualDaaScore:integer(info.virtualDaaScore)};this.cached=null;}
  updateInfo(info){this.info={blockCount:integer(info.blockCount),virtualDaaScore:integer(info.virtualDaaScore)};this.cached=null;}
  add(block){
    if(!['warming','live'].includes(this.status))return;
    const now=this.now(),b=headerBlock(block,now);if(this.blocks.has(b.hash))return;
    this.blocks.set(b.hash,b);while(this.blocks.size>LIMIT)this.blocks.delete(this.blocks.keys().next().value);
    this.lastBlockAt=now;this.arrivals.push(now);this.arrivals=this.arrivals.filter(t=>t>now-10000).slice(-2000);this.sequence++;this.status=this.blocks.size>=2?'live':'warming';this.cached=null;
  }
  disconnect(status='reconnecting'){this.status=status;this.cached=null;}
  snapshot(){
    const now=this.now();if(this.cached&&now-this.cached.at<500)return this.cached.body;
    const age=this.lastBlockAt===null?null:Math.max(0,now-this.lastBlockAt);
    const status=this.status==='live'&&age>8000?'stale':this.status;
    const elapsed=this.startedAt===null?0:Math.min(10000,now-this.startedAt);
    const observedBps=status==='live'&&elapsed>=2000?Math.round(this.arrivals.filter(t=>t>now-10000).length/elapsed*10000)/10:null;
    const body={schemaVersion:1,network:'mainnet',source:'Kaspire own node',epoch:this.epoch,status,serverTime:now,lastBlockAt:this.lastBlockAt,startedAt:this.startedAt,sequence:this.sequence,windowLimit:LIMIT,observedBps,info:this.info,blocks:[...this.blocks.values()]};
    this.cached={at:now,body};return body;
  }
}

export async function connectNode({onBlock,onClose,Socket=WebSocket}={}){
  const socket=new Socket(RPC_URL),pending=new Map();let seq=0,ended=false,openTimer,openReject;
  let closeResolve;const closed=new Promise(r=>closeResolve=r);
  const end=()=>{if(ended)return;ended=true;clearTimeout(openTimer);openReject?.(Error('Own node disconnected'));openReject=null;for(const p of pending.values()){clearTimeout(p.timer);p.reject(Error('Own node disconnected'));}pending.clear();closeResolve();onClose?.();};
  const stop=()=>{end();socket.close();};
  socket.addEventListener('close',end);socket.addEventListener('error',end);
  socket.addEventListener('message',event=>{try{
    if(typeof event.data!=='string'||Buffer.byteLength(event.data)>8*1024*1024)throw Error('Invalid RPC frame');
    const d=JSON.parse(event.data,(_key,v,c)=>typeof v==='number'&&/^\d+$/.test(c.source??'')&&!Number.isSafeInteger(v)?c.source:v);
    if(d.method==='blockAddedNotification'){if(!d.params?.BlockAdded?.block)throw Error('Invalid block event');onBlock?.(d.params.BlockAdded.block);return;}
    const task=pending.get(d.id);if(!task)return;if(task.method!==d.method)throw Error('RPC identity differs');
    pending.delete(d.id);clearTimeout(task.timer);d.error?task.reject(Error('Own node read rejected')):task.resolve(d.params);
  }catch{stop();}});
  await new Promise((resolve,reject)=>{
    openReject=reject;
    openTimer=setTimeout(()=>{stop();reject(Error('Own node timed out'));},5000);
    socket.addEventListener('open',()=>{clearTimeout(openTimer);openReject=null;resolve();},{once:true});
    socket.addEventListener('error',()=>{clearTimeout(openTimer);reject(Error('Own node unavailable'));},{once:true});
  });
  const request=(method,params)=>new Promise((resolve,reject)=>{
    if(ended){reject(Error('Own node disconnected'));return;}
    const id=++seq,timer=setTimeout(()=>{pending.delete(id);reject(Error('Own node timed out'));stop();},5000);
    pending.set(id,{method,resolve,reject,timer});socket.send(JSON.stringify({id,method,params}));
  });
  return {closed,close:stop,read(method){if(!['getInfo','getCurrentNetwork','getBlockDagInfo'].includes(method))return Promise.reject(Error('Not a public DAG read'));return request(method,{});},subscribe:()=>request('subscribe',{BlockAdded:{}})};
}

export async function collect(buffer,{signal,connect=connectNode}={}){
  let backoff=1000;
  while(!signal?.aborted){let rpc,heartbeat,checking=false,usable=false;
    try{
      rpc=await connect({onBlock:block=>{if(usable)buffer.add(block);},onClose:()=>buffer.disconnect()});
      const check=async()=>{
        const [info,network,dag]=await Promise.all(['getInfo','getCurrentNetwork','getBlockDagInfo'].map(m=>rpc.read(m)));
        if(network?.network!=='mainnet'||dag?.network!=='mainnet')throw Error('Not Mainnet');
        if(info?.isSynced!==true){usable=false;buffer.disconnect('node-unsynced');return;}
        if(!usable){buffer.begin(dag);usable=true;}else buffer.updateInfo(dag);
      };
      await check();await rpc.subscribe();backoff=1000;
      heartbeat=setInterval(async()=>{
        if(checking)return;checking=true;
        try{await check();const age=buffer.lastBlockAt===null?buffer.now()-buffer.startedAt:buffer.now()-buffer.lastBlockAt;if(usable&&age>10000)rpc.close();}catch{rpc.close();}finally{checking=false;}
      },3000);
      const abort=()=>rpc.close();signal?.addEventListener('abort',abort,{once:true});
      if(signal?.aborted)rpc.close();
      await rpc.closed;signal?.removeEventListener('abort',abort);
    }catch{buffer.disconnect('unavailable');}
    finally{usable=false;clearInterval(heartbeat);rpc?.close();}
    if(signal?.aborted)break;
    await delay(backoff,undefined,{signal}).catch(()=>{});backoff=Math.min(15000,backoff*2);
  }
}

export function createDagServer(buffer){
  let cachedSnapshot,cachedJson;
  const server=http.createServer((req,res)=>{
    const send=(status,value)=>{res.writeHead(status,{'content-type':'application/json','cache-control':'no-store','x-content-type-options':'nosniff'});res.end(JSON.stringify(value));};
    if(req.method!=='GET'){req.resume();send(405,{error:'Public DAG reads only.'});return;}
    if(req.url==='/health'){const s=buffer.snapshot();send(s.status==='live'?200:503,{ok:s.status==='live',readOnly:true,network:'mainnet',status:s.status});return;}
    if(req.url!=='/api/explorer/blockdag'){send(404,{error:'Unknown DAG read.'});return;}
    const snapshot=buffer.snapshot();if(snapshot!==cachedSnapshot){cachedSnapshot=snapshot;cachedJson=JSON.stringify(snapshot);}
    res.writeHead(200,{'content-type':'application/json','cache-control':'no-store','x-content-type-options':'nosniff'});res.end(cachedJson);
  });
  server.maxConnections=64;server.headersTimeout=5000;server.requestTimeout=5000;server.keepAliveTimeout=2000;
  return server;
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
  const buffer=new DagBuffer(),controller=new AbortController(),server=createDagServer(buffer);
  for(const name of ['SIGTERM','SIGINT'])process.once(name,()=>{controller.abort();server.closeAllConnections();server.close();});
  server.listen(3023,'127.0.0.1');collect(buffer,{signal:controller.signal});
}
