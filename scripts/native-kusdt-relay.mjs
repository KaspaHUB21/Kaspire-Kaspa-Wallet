// Native KasPool transport only. No keys, SDK Transaction conversion, witness
// changes, public-node fallback, automatic retry, or transaction persistence.
import http from 'node:http';
import {pathToFileURL} from 'node:url';
export const POOL='28e7758e6fc0e2054cceb7f87f9da44a53accfa0a1795c8075c80fb99c83aaad';
export const TOKEN='50b3477e7368d0c5bfbd64483b4607350ec411377972f33e40b2d4b6d1513fd3';
const MAX=1024*1024,ID=/^[a-f0-9]{64}$/;
export class RelayError extends Error{constructor(status,code,message){super(message);this.status=status;this.code=code;}}
const invalid=()=>{throw new RelayError(400,'invalid_request','Invalid native kUSDT transaction request.');};
const object=(v,keys)=>{if(!v||typeof v!=='object'||Array.isArray(v)||Object.keys(v).some(k=>!keys.includes(k)))invalid();};
const uint=(v,max=(1n<<64n)-1n)=>{if(typeof v!=='bigint'||v<0n||v>max)invalid();};
const hex=(v,min,max)=>{if(typeof v!=='string'||v.length<min||v.length>max||v.length%2||! /^[a-f0-9]*$/.test(v))invalid();};
function exactJson(raw){
 let value;try{value=JSON.parse(raw,(_key,v,context)=>{if(typeof v!=='number')return v;if(!/^(0|[1-9]\d*)$/.test(context.source))invalid();return BigInt(context.source);});}catch{invalid();}
 // JSON.parse accepts duplicate fields; a consensus deserializer may not.
 const tokens=raw.match(/"(?:\\.|[^"\\])*"|[{}\[\]:,]|[^\s{}\[\]:,]+/g)??[],stack=[];
 for(let i=0;i<tokens.length;i++){
  const t=tokens[i];if(t==='{'||t==='['){stack.push(t==='{'?new Set():null);if(stack.length>20)invalid();}
  else if(t==='}'||t===']')stack.pop();
  else if(t.startsWith('"')&&tokens[i+1]===':'){const set=stack.at(-1),key=JSON.parse(t);if(!set||set.has(key))invalid();set.add(key);}
 }
 return value;
}
export function validateSubmission(body){
 object(body,['transactionId','transactionJson']);if(!ID.test(body.transactionId??'')||typeof body.transactionJson!=='string'||Buffer.byteLength(body.transactionJson)>MAX/2)invalid();
 const t=exactJson(body.transactionJson);
 object(t,['version','inputs','outputs','lockTime','subnetworkId','gas','payload','mass','storageMass','verboseData']);
 if(t.version!==1n||t.gas!==0n||t.payload!==''||t.subnetworkId!=='00'.repeat(20)||t.mass!==0n||t.storageMass!==0n||t.verboseData!==null)invalid();uint(t.lockTime);
 if(!Array.isArray(t.inputs)||!t.inputs.length||t.inputs.length>8||!Array.isArray(t.outputs)||t.outputs.length<3||t.outputs.length>8)invalid();
 const points=new Set(),covenants=[];
 for(const i of t.inputs){
  object(i,['previousOutpoint','signatureScript','sequence','sigOpCount','computeBudget','verboseData']);object(i.previousOutpoint,['transactionId','index']);
  if(!ID.test(i.previousOutpoint.transactionId??'')||i.verboseData!==null)invalid();uint(i.previousOutpoint.index,0xffffffffn);uint(i.sequence);uint(i.sigOpCount,255n);uint(i.computeBudget,100_000_000n);hex(i.signatureScript,2,192*1024);
  const p=i.previousOutpoint.transactionId+':'+i.previousOutpoint.index;if(points.has(p))invalid();points.add(p);
 }
 for(const o of t.outputs){
  object(o,['value','scriptPublicKey','covenant','verboseData']);uint(o.value);if(o.value===0n||o.verboseData!==null)invalid();hex(o.scriptPublicKey,8,2048);if(!o.scriptPublicKey.startsWith('0000'))invalid();
  if(o.covenant!==null){object(o.covenant,['authorizingInput','covenantId']);uint(o.covenant.authorizingInput,BigInt(t.inputs.length-1));if(![POOL,TOKEN].includes(o.covenant.covenantId))invalid();covenants.push(o.covenant.covenantId);}
 }
 if(covenants.filter(c=>c===POOL).length!==1||!covenants.includes(TOKEN))invalid();
 return {id:body.transactionId,raw:body.transactionJson};
}
export async function connectRpc(url,Socket=WebSocket){
 const socket=new Socket(url),tasks=new Map();let counter=0,openTimer;
 const fail=()=>{for(const p of tasks.values()){clearTimeout(p.timer);p.reject(new RelayError(503,'node_unavailable','Kaspire node connection is unavailable. Signed transaction remains saved.'));}tasks.clear();};
 socket.addEventListener('close',fail);socket.addEventListener('error',fail);
 socket.addEventListener('message',event=>{try{
  if(typeof event.data!=='string'||Buffer.byteLength(event.data)>2*MAX)throw Error();const r=JSON.parse(event.data),p=tasks.get(r.id);if(!p)return;if(r.method!==p.method)throw Error();tasks.delete(r.id);clearTimeout(p.timer);
  if(r.error)p.reject(new RelayError(422,'node_rejected',String(r.error.message??'Node rejected the transaction.').slice(0,800)));else if(r.params&&typeof r.params==='object')p.resolve(r.params);else p.reject(new RelayError(502,'invalid_node_response','Invalid Kaspire node response.'));
 }catch{fail();socket.close();}});
 await new Promise((resolve,reject)=>{openTimer=setTimeout(()=>{reject(new RelayError(503,'node_unavailable','Kaspire node connection timed out.'));socket.close();},5000);socket.addEventListener('open',()=>{clearTimeout(openTimer);resolve();},{once:true});socket.addEventListener('error',()=>{clearTimeout(openTimer);reject(new RelayError(503,'node_unavailable','Kaspire node connection failed.'));},{once:true});});
 return {call:(method,params,rawTransaction)=>new Promise((resolve,reject)=>{
  const id=++counter,timer=setTimeout(()=>{tasks.delete(id);reject(new RelayError(504,'status_unknown','Node response timed out. Keep the saved transaction and check its status.'));socket.close();},15000);
  tasks.set(id,{resolve,reject,timer,method});
  // Embed the original JSON text verbatim. In particular never round u64s,
  // discard computeBudget/covenant bindings, or append a redeemScript.
  socket.send(rawTransaction===undefined?JSON.stringify({id,method,params}):`{"id":${id},"method":"submitTransaction","params":{"transaction":${rawTransaction},"allowOrphan":false}}`);
 }),close:()=>{clearTimeout(openTimer);fail();socket.close();}};
}
async function healthy(rpc){const info=await rpc.call('getInfo',{}),network=await rpc.call('getCurrentNetwork',{});if(info.isSynced!==true||info.isUtxoIndexed!==true||network.network!=='mainnet')throw new RelayError(503,'node_unavailable','Kaspire Mainnet node is not synced and UTXO-indexed.');}
export function createRelay({rpcUrl='ws://127.0.0.1:18110',restUrl='http://127.0.0.1:8000',connect=connectRpc,request=fetch,maxActive=8}={}){
 let active=0;
 const server=http.createServer(async(req,res)=>{
  const send=(status,value)=>{res.writeHead(status,{'content-type':'application/json','cache-control':'no-store','x-content-type-options':'nosniff'});res.end(JSON.stringify(value));};
  const url=new URL(req.url,'http://localhost');let rpc;
  if(active>=maxActive){send(503,{code:'busy',error:'Native swap relay is busy. Keep the saved transaction.'});req.resume();return;}active++;
  try{
   if(req.method==='GET'&&url.pathname==='/health'){rpc=await connect(rpcUrl);await healthy(rpc);send(200,{ok:true,network:'mainnet',profile:'native-kusdt-wrpc-v1'});return;}
   const match=/^\/transactions\/([a-f0-9]{64})$/.exec(url.pathname);
   if(req.method==='GET'&&match){
    rpc=await connect(rpcUrl);await healthy(rpc);const id=match[1];let accepted=false,restKnown=false;
    try{const response=await request(restUrl+'/transactions/'+id,{redirect:'error',signal:AbortSignal.timeout(5000)});if(response.status===404)restKnown=true;else if(response.ok){const text=await response.text();if(text.length>2*MAX)throw Error();const tx=JSON.parse(text);if(tx.transaction_id!==id||typeof tx.is_accepted!=='boolean')throw Error();accepted=tx.is_accepted;restKnown=true;}}catch{/* Never turn an unread source into a confirmed transaction. */}
    if(accepted){send(200,{transactionId:id,status:'confirmed'});return;}
    try{const value=await rpc.call('getMempoolEntry',{transactionId:id,includeOrphanPool:true,filterTransactionPool:false});if(value.mempoolEntry?.transaction?.verboseData?.transactionId!==id)throw new RelayError(502,'invalid_node_response','Mempool transaction identity differs.');send(200,{transactionId:id,status:'mempool'});return;}
    catch(error){if(error.code!=='node_rejected'||error.message!==`Transaction ${id} not found`)throw error;}
    send(200,{transactionId:id,status:restKnown?'not_seen':'unknown'});return;
   }
   if(req.method!=='POST'||url.pathname!=='/submit'){send(404,{code:'not_found',error:'Unsupported native swap relay route.'});req.resume();return;}
   if(!/^application\/json(?:;|$)/i.test(req.headers['content-type']??''))invalid();
   const declared=Number(req.headers['content-length']);if(!Number.isSafeInteger(declared)||declared<=0||declared>MAX)throw new RelayError(413,'invalid_size','Invalid native swap request size.');
   const chunks=[];let size=0;for await(const chunk of req){size+=chunk.length;if(size>MAX)throw new RelayError(413,'invalid_size','Native swap request too large.');chunks.push(chunk);}
   let body;try{body=JSON.parse(Buffer.concat(chunks).toString('utf8'));}catch{invalid();}const {id,raw}=validateSubmission(body);
   rpc=await connect(rpcUrl);await healthy(rpc);
   const result=await rpc.call('submitTransaction',undefined,raw);
   if(result.transactionId!==id)throw new RelayError(502,'status_unknown','Node returned a different transaction ID. Keep the saved transaction.');
   send(200,{transactionId:id,status:'submitted'});
  }catch(error){const known=error instanceof RelayError;send(known?error.status:502,{code:known?error.code:'status_unknown',error:known?error.message:'Native swap status is unavailable. Signed transaction remains saved.'});}
  finally{rpc?.close();active--;}
 });
 server.requestTimeout=25000;server.headersTimeout=10000;server.keepAliveTimeout=5000;
 return server;
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)createRelay().listen(8016,'127.0.0.1');
