import test from 'node:test';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import fs from 'node:fs';
import {createRelay,validateSubmission,POOL,TOKEN} from './native-kusdt-relay.mjs';
const Ws=createRequire(import.meta.url)('ws'),WebSocketServer=Ws.WebSocketServer??Ws.Server;
const id='ab'.repeat(32);
function fixture(){return {version:1,inputs:[{previousOutpoint:{transactionId:'11'.repeat(32),index:0},sequence:0,sigOpCount:0,computeBudget:123456,signatureScript:'0102',verboseData:null}],outputs:[POOL,TOKEN,TOKEN].map((c,i)=>({value:150000000+i,scriptPublicKey:'0000aa20'+'22'.repeat(32)+'87',covenant:{authorizingInput:0,covenantId:c},verboseData:null})),lockTime:0,subnetworkId:'00'.repeat(20),gas:0,payload:'',mass:0,storageMass:0,verboseData:null};}
const payload=()=>({transactionId:id,transactionJson:JSON.stringify(fixture()).replace('"sequence":0','"sequence":18446744073709551615')});
async function setup(t,{rejected=false,wrongId=false,wrongChain=false,drop=false,rest='absent',mempool=false,submittedId=id}={}){
 const frames=[],wss=new WebSocketServer({host:'127.0.0.1',port:0});await new Promise(r=>wss.once('listening',r));
 wss.on('connection',ws=>ws.on('message',data=>{const raw=data.toString(),r=JSON.parse(raw);frames.push(raw);let params;
  if(r.method==='getInfo')params={isSynced:true,isUtxoIndexed:true};
  else if(r.method==='getCurrentNetwork')params={network:wrongChain?'testnet-10':'mainnet'};
  else if(r.method==='getMempoolEntry'){
   if(!mempool){ws.send(JSON.stringify({id:r.id,method:r.method,error:{message:`Transaction ${id} not found`}}));return;}
   params={mempoolEntry:{transaction:{verboseData:{transactionId:id}}}};
  }else if(r.method==='submitTransaction'){
   if(drop){ws.close();return;}
   if(rejected){ws.send(JSON.stringify({id:r.id,method:r.method,error:{message:'transaction rejected: input is already spent'}}));return;}
   params={transactionId:wrongId?'cd'.repeat(32):submittedId};
  }else assert.fail('Unexpected RPC method '+r.method);
  ws.send(JSON.stringify({id:r.id,method:r.method,params}));
 }));
 const server=createRelay({rpcUrl:'ws://127.0.0.1:'+wss.address().port,request:async()=>rest==='offline'?new Response('',{status:503}):rest==='confirmed'?Response.json({transaction_id:id,is_accepted:true}):new Response('',{status:404})});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 t.after(async()=>{server.closeAllConnections();for(const ws of wss.clients)ws.terminate();await Promise.all([new Promise(r=>server.close(r)),new Promise(r=>wss.close(r))]);});
 const root='http://127.0.0.1:'+server.address().port;
 return {frames,post:body=>fetch(root+'/submit',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)}),status:()=>fetch(root+'/transactions/'+id)};
}
test('wRPC validation preserves full u64 text, compute budgets and covenant bindings',()=>{
 const body=payload();assert.deepEqual(validateSubmission(body),{id,raw:body.transactionJson});
 for(const change of [t=>t.version=0,t=>delete t.inputs[0].computeBudget,t=>t.outputs[0].covenant.covenantId='33'.repeat(32),t=>t.inputs.push(t.inputs[0]),t=>t.outputs[0].value=-1]){const tx=fixture();change(tx);assert.throws(()=>validateSubmission({transactionId:id,transactionJson:JSON.stringify(tx)}));}
 assert.throws(()=>validateSubmission({transactionId:id,transactionJson:payload().transactionJson.replace('"version":1','"version":1,"version":1')}));
});
test('actual HTTP -> JSON WebSocket forwarding embeds the ORIGINAL transaction once',async t=>{
 const s=await setup(t),body=payload(),r=await s.post(body);assert.equal(r.status,200);assert.equal((await r.json()).transactionId,id);
 const submits=s.frames.filter(f=>f.includes('"method":"submitTransaction"'));assert.equal(submits.length,1);
 assert(submits[0].includes('"transaction":'+body.transactionJson+',"allowOrphan":false'));assert(submits[0].includes('18446744073709551615'));
});
test('node rejection is returned with its cause, never retried or called success',async t=>{
 const s=await setup(t,{rejected:true}),r=await s.post(payload());assert.equal(r.status,422);const error=await r.json();assert.equal(error.code,'node_rejected');assert.match(error.error,/already spent/);assert.equal(s.frames.filter(f=>f.includes('submitTransaction')).length,1);
});
test('wrong transaction response is unknown, not confirmed and never retried',async t=>{
 const s=await setup(t,{wrongId:true}),r=await s.post(payload());assert.equal(r.status,502);assert.equal((await r.json()).code,'status_unknown');assert.equal(s.frames.filter(f=>f.includes('submitTransaction')).length,1);
});
test('dropped node connection retains unknown state, without a second submission',async t=>{
 const s=await setup(t,{drop:true}),r=await s.post(payload());assert.equal(r.status,503);assert.equal(s.frames.filter(f=>f.includes('submitTransaction')).length,1);
});
test('wrong chain and malformed requests cannot reach submitTransaction',async t=>{
 const s=await setup(t,{wrongChain:true});assert.equal((await s.post(payload())).status,503);assert.equal((await s.post({signedTxJson:'wrong format'})).status,400);assert.equal(s.frames.filter(f=>f.includes('submitTransaction')).length,0);
});
if(process.env.KASPIRE_NATIVE_FIXTURES)for(const side of ['buy','sell'])test('REAL native Mainnet-state '+side+' passes the HTTP -> WebSocket transport without any JSON conversion',async t=>{
 const body=JSON.parse(fs.readFileSync(process.env.KASPIRE_NATIVE_FIXTURES+'/trestly-'+side+'.json','utf8'));
 validateSubmission(body);
 const s=await setup(t,{submittedId:body.transactionId}),r=await s.post(body);assert.equal(r.status,200);assert.equal((await r.json()).transactionId,body.transactionId);
 const frame=s.frames.find(f=>f.includes('"method":"submitTransaction"'));assert(frame.includes('"transaction":'+body.transactionJson+',"allowOrphan":false'));
});
for(const [options,expected]of [[{rest:'confirmed'},'confirmed'],[{mempool:true},'mempool'],[{},'not_seen'],[{rest:'offline'},'unknown']])test('read-only recovery reports '+expected+' without broadcasting',async t=>{
 const s=await setup(t,options),r=await s.status();assert.equal(r.status,200);assert.deepEqual(await r.json(),{transactionId:id,status:expected});assert.equal(s.frames.filter(f=>f.includes('submitTransaction')).length,0);
});
