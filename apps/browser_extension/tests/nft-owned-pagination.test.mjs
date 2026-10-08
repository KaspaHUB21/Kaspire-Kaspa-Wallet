import test from 'node:test';
import assert from 'node:assert/strict';
import {nftOwned} from './generated/nftMarket.mjs';
test('collection inventory pages contain ten matching NFTs and no phantom final page',async()=>{
 const previous=globalThis.fetch;
 globalThis.fetch=async raw=>{
  const url=new URL(raw);
  if(url.pathname.includes('/metadata/'))return new Response(JSON.stringify({items:[],ranksAvailable:true}));
  assert.ok(url.pathname.endsWith('/test'));
  const offset=Number(url.searchParams.get('offset')??0),limit=Number(url.searchParams.get('limit'));
  const total=21, end=Math.min(offset+limit,total);
  return new Response(JSON.stringify({result:Array.from({length:end-offset},(_,i)=>({tick:'TEST',tokenId:String(offset+i)})),next:end<total?String(end):null}));
 };
 try{const address='kaspa:'+ 'q'.repeat(61);let next='',sizes=[];do{const page=await nftOwned(address,next,'TEST');sizes.push(page.nfts.length);next=page.next;}while(next);assert.deepEqual(sizes,[10,10,1]);}
 finally{globalThis.fetch=previous;}
});
test('a cursor after the only NFT does not expose Load more',async()=>{
 const previous=globalThis.fetch;
 globalThis.fetch=async raw=>{const url=new URL(raw);return new Response(JSON.stringify(url.pathname.includes('/metadata/')?{items:[],ranksAvailable:true}:url.searchParams.has('offset')?{result:[],next:null}:{result:[{tick:'TEST',tokenId:'1'}],next:'end'}));};
 try{const page=await nftOwned('kaspa:'+'q'.repeat(61),'','TEST');assert.equal(page.nfts.length,1);assert.equal(page.next,null);}finally{globalThis.fetch=previous;}
});
