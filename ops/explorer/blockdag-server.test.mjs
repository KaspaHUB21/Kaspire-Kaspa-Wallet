import test from 'node:test';
import assert from 'node:assert/strict';
import {DagBuffer,headerBlock,createDagServer,connectNode,collect,LIMIT,RPC_URL} from './blockdag-server.mjs';
const hash=n=>n.toString(16).padStart(64,'0');
const block=n=>({header:{hash:hash(n),daaScore:String(n),blueScore:String(n),timestamp:1700000000000+n,parentsByLevel:[[hash(n-1)],[hash(1)]]},verboseData:{hash:hash(n),selectedParentHash:hash(n-1)},transactions:[{privatePayload:'not forwarded'}]});
const info={blockCount:'12345678901234567890',virtualDaaScore:'12345'};
test('normalizes actual parent/selected-parent links, omitting transactions and unused header fields',()=>{
 const b=headerBlock(block(2),1700000005000);assert.deepEqual(b.parents,[hash(1)]);assert.equal(b.selectedParentHash,hash(1));assert.equal(b.txCount,1);assert.equal(b.daaScore,'2');assert(!JSON.stringify(b).includes('privatePayload'));
 for(const mutate of [b=>b.header.hash='bad',b=>b.verboseData.hash=hash(9),b=>b.header.parentsByLevel[0]=[hash(2)],b=>b.header.daaScore=9007199254740992,b=>b.header.timestamp='18446744073709551615']){const b=block(2);mutate(b);assert.throws(()=>headerBlock(b,1));}
});
test('bounded real observation window, duplicate suppression, stale state, exact counts and fresh reconnect epochs',()=>{
 let now=1700000000000;const b=new DagBuffer(()=>now);assert.equal(b.snapshot().observedBps,null);assert.equal(b.snapshot().status,'reconnecting');b.begin(info);const epoch=b.epoch;
 for(let n=2;n<LIMIT+20;n++){now+=100;b.add(block(n));}
 let s=b.snapshot();assert.equal(s.blocks.length,LIMIT);assert.equal(s.info.blockCount,info.blockCount);assert.equal(s.status,'live');assert.equal(s.observedBps,10);const seq=s.sequence;b.add(block(LIMIT+19));assert.equal(b.snapshot().sequence,seq);
 now+=9000;s=b.snapshot();assert.equal(s.status,'stale');assert.equal(s.observedBps,null);assert.equal(s.blocks.length,LIMIT);
 b.disconnect();b.add(block(10000));assert.equal(b.snapshot().sequence,seq);b.begin(info);assert.notEqual(b.epoch,epoch);assert.equal(b.snapshot().blocks.length,0);assert.equal(b.snapshot().observedBps,null);
});
test('HTTP route is fixed, GET-only, bounded and cannot become an RPC proxy',async t=>{
 const buffer=new DagBuffer(),server=createDagServer(buffer);await new Promise(r=>server.listen(0,'127.0.0.1',r));t.after(()=>{server.closeAllConnections();server.close();});const root='http://127.0.0.1:'+server.address().port;
 const r=await fetch(root+'/api/explorer/blockdag');assert.equal(r.status,200);assert.equal((await r.json()).network,'mainnet');assert.equal((await fetch(root+'/health')).status,503);
 for(const path of ['/submit','/api/explorer/blockdag?url=http://evil','/api/explorer/blockdag/../rpc'])assert.equal((await fetch(root+path)).status,404);
 assert.equal((await fetch(root+'/api/explorer/blockdag',{method:'POST',body:'{}'})).status,405);
});
class Socket extends EventTarget {
 static instance;
 constructor(url){super();assert.equal(url,RPC_URL);Socket.instance=this;this.sent=[];queueMicrotask(()=>this.dispatchEvent(new Event('open')));}
 send(raw){const d=JSON.parse(raw);this.sent.push(d);queueMicrotask(()=>this.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({id:d.id,method:d.method,params:d.method==='subscribe'?{id:1}:{network:'mainnet'}})})));}
 close(){this.dispatchEvent(new Event('close'));}
}
test('wire protocol uses a fixed node and the exact BlockAdded scope; send/sign methods are impossible',async()=>{
 const observed=[];const c=await connectNode({Socket,onBlock:b=>observed.push(headerBlock(b,1))});await c.read('getCurrentNetwork');await c.subscribe();assert.deepEqual(Socket.instance.sent.at(-1).params,{BlockAdded:{}});
 await assert.rejects(c.read('submitTransaction'));assert(!Socket.instance.sent.some(d=>/submit|sign|shutdown/i.test(d.method)));
 Socket.instance.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({method:'blockAddedNotification',params:{BlockAdded:{block:block(2)}}})}));assert.equal(observed[0].hash,hash(2));
 c.close();await c.closed;
});
test('close before opening rejects instead of leaving an unresolved connection',async()=>{
 class Closed extends EventTarget {constructor(){super();queueMicrotask(()=>this.dispatchEvent(new Event('close')));}close(){}}
 await assert.rejects(connectNode({Socket:Closed}));
});
test('collector checks sync/network and never relays unsynced notifications',async()=>{
 for(const synced of [true,false]){
  const controller=new AbortController(),b=new DagBuffer();let hooks,reads=[];
  const connect=async opts=>{hooks=opts;let done;const closed=new Promise(r=>done=r);return {closed,close:()=>{opts.onClose();done();},read:async method=>{reads.push(method);return method==='getInfo'?{isSynced:synced}:method==='getCurrentNetwork'?{network:'mainnet'}:{...info,network:'mainnet'};},subscribe:async()=>{opts.onBlock(block(2));opts.onBlock(block(3));controller.abort();}};};
  await collect(b,{signal:controller.signal,connect});
  assert.equal(b.blocks.size,synced?2:0);assert.deepEqual(reads,['getInfo','getCurrentNetwork','getBlockDagInfo']);
 }
 const controller=new AbortController(),b=new DagBuffer();let subscribed=false;
 await collect(b,{signal:controller.signal,connect:async()=>({close(){controller.abort();},read:async method=>method==='getInfo'?{isSynced:true}:({...info,network:'testnet-10'}),subscribe:async()=>{subscribed=true;}})});
 assert.equal(subscribed,false);assert.equal(b.blocks.size,0);
});
