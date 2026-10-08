import {test} from 'node:test';
import assert from 'node:assert/strict';
import {privateFetch} from './private-indexer';
test('Nexus display reads fail over to official without leaking local authentication headers',async()=>{
 const original=globalThis.fetch;const seen:string[]=[];
 try {
  globalThis.fetch=async(input,init)=>{
   const url=String(input);seen.push(url);
   if(url.startsWith('http://127.0.0.1:18801'))return new Response('{}',{status:403});
   assert.ok(url.startsWith('https://krc721-indexer.kaspa.com/'));
   assert.equal(init?.headers,undefined);
   return new Response(JSON.stringify({message:'success',result:[{tick:'TEST',tokenId:'1'}]}));
  };
  const r=await privateFetch('/v1/wallets/kaspa:test?limit=50');
  assert.equal((await r.json()).result.length,1);assert.equal(seen.length,2);
 }finally{globalThis.fetch=original;}
});
test('valid empty local inventory never selects fallback',async()=>{
 const original=globalThis.fetch;let calls=0;
 try{globalThis.fetch=async()=>{calls++;return new Response(JSON.stringify({message:'success',result:[]}));};
  await privateFetch('/v1/wallets/kaspa:test');assert.equal(calls,1);
 }finally{globalThis.fetch=original;}
});
