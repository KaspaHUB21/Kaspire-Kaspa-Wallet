import test from 'node:test';
import assert from 'node:assert/strict';
import {RankedCatalogue} from './ranked-catalogue.mjs';
const cid=n=>n.toString(16).padStart(64,'0'),now=1792946446829;
const token=(n,cap)=>({meta:{covenantId:cid(n),ticker:'T'+n,name:'Token '+n},verification:'verified',marketCapSompi:String(cap)});
const trade=(n,value,tx=n,time=now)=>({kind:'trade',tokenId:cid(n),txid:cid(tx),timeMs:time,trade:{kasSompi:String(value)}});
test('global cap/volume ordering is applied before pagination, with complete tape paging and deduplication',async()=>{
 const calls=[],rows=Array.from({length:45},(_,i)=>token(i+1,i+1===45?'999999999999999999999999999':'100'));
 const get=async path=>{
  calls.push(path);const u=new URL(path,'https://fixture.invalid');
  if(u.pathname==='/tokens')return u.searchParams.has('cursor')?{tokens:rows.slice(25)}:{tokens:rows.slice(0,25),nextCursor:'catalogue-two'};
  return u.searchParams.has('cursor')?{items:[trade(1,99999,1000),trade(2,200,2000),trade(3,99999,3000,now-86400001)]}:{items:[trade(1,99999,1000)],nextCursor:'tape-two'};
 };
 const rank=new RankedCatalogue(get,()=>now);
 const [a,b]=await Promise.all([rank.page(),rank.page()]);
 assert.equal(a.tokens[0].meta.covenantId,cid(45));assert.equal(a.tokens[1].meta.covenantId,cid(1));
 assert.equal(a.tokens[1].volume24hSompi,'99999');assert.equal(a.tokens[2].meta.covenantId,cid(2));
 assert.equal(a.tokens.length,20);assert.equal(a.nextCursor,b.nextCursor);assert.equal(calls.length,4);
 const second=await rank.page(a.nextCursor),third=await rank.page(second.nextCursor);
 assert.equal(new Set([...a.tokens,...second.tokens,...third.tokens].map(r=>r.meta.covenantId)).size,45);
 assert.equal(third.nextCursor,null);assert.equal(calls.length,4);
 await assert.rejects(rank.page(a.nextCursor,'other'),/match/);
});
test('unknown volume preserves tokens and is never reported as zero',async()=>{
 const rank=new RankedCatalogue(async path=>{if(path.startsWith('/tape'))throw Error('offline');return {tokens:[token(1,1),token(2,2)]};},()=>now);
 const page=await rank.page();assert.equal(page.tokens[0].meta.covenantId,cid(2));
 assert.equal(page.tokens[0].volume24hSompi,null);assert.equal(page.ranking.volumeComplete,false);assert.match(page.warning,/unavailable/);
});
test('repeated tape cursors cannot create fake complete volume; expired/query-changing cursors fail explicitly',async()=>{
 let clock=now;
 const rows=Array.from({length:21},(_,i)=>token(i+1,1));
 const rank=new RankedCatalogue(async path=>path.startsWith('/tokens')?{tokens:rows}:{items:[trade(1,1)],nextCursor:'repeated'},()=>clock);
 const a=await rank.page();assert.equal(a.ranking.volumeComplete,false);
 const search=await rank.page('','Token 2');assert.equal(search.tokens.length,3);
 clock+=300001;await assert.rejects(rank.page(a.nextCursor),/expired/);
 await assert.rejects(rank.page('not-a-cursor'),/cursor/);
});
