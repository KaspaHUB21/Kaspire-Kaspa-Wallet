import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createNexusPriceReader,matchingNexusOrder} from './kaspacom-nexus-prices.mjs';
const tx='a'.repeat(64),owner='kaspa:owner',id='b'.repeat(24);
const row={orderId:id,ticker:'KASGOTHS',tokenId:'991',isDecentralized:true,
  status:'LISTED_FOR_SALE',sellerWalletAddress:owner,totalPrice:12.34};
const detail={...row,psktSeller:JSON.stringify({inputs:[{transactionId:tx}]})};
function source(calls,override={}) {return async(path,body)=>{
  calls.push({path,body});return body ? {orders:[row]} : {...detail,...override};
};}
test('targeted price uses two reads, concurrent users share one request and TTL',async()=>{
  const calls=[];let time=0;
  const read=createNexusPriceReader(source(calls),{now:()=>time});
  const [a,b]=await Promise.all([read('KASGOTHS','991'),read('KASGOTHS','991')]);
  assert.deepEqual(a,b);assert.equal(calls.length,2);
  assert.equal(calls[0].body.tokenId,'991');
  assert.equal(calls[0].body.onlyDecentralize,true);
  assert.equal(a.listingTransactionId,tx);
  await read('KASGOTHS','991');assert.equal(calls.length,2);
  time=90001;await read('KASGOTHS','991');assert.equal(calls.length,4);
});
test('missing listing is negatively cached without an order-detail query',async()=>{
  let count=0;const read=createNexusPriceReader(async()=>{count++;return {orders:[]};});
  assert.equal(await read('KASGOTHS','991'),null);
  assert.equal(await read('KASGOTHS','991'),null);assert.equal(count,1);
});
test('global request budget refuses excess work and resets the next minute',async()=>{
  const calls=[];let time=0;
  const read=createNexusPriceReader(source(calls),{requestLimit:2,now:()=>time});
  await read('KASGOTHS','991');
  await assert.rejects(read('HASH','1'),/temporarily unavailable/);
  assert.equal(calls.length,2);
  time=60001;assert.equal(await read('HASH','1'),null);assert.equal(calls.length,3);
});
test('concurrency is capped without queueing unlimited upstream work',async()=>{
  let release;const wait=new Promise(r=>release=r);let calls=0;
  const read=createNexusPriceReader(async()=>{calls++;await wait;return {orders:[]};},{concurrency:1});
  const first=read('HASH','1');
  await assert.rejects(read('HASH','2'),/temporarily unavailable/);
  release();await first;assert.equal(calls,1);
});
test('failure is cached briefly, never interpreted as a missing listing',async()=>{
  let count=0,time=0;
  const read=createNexusPriceReader(async()=>{count++;throw Error('offline');},{now:()=>time});
  await assert.rejects(read('HASH','1'),/offline/);
  await assert.rejects(read('HASH','1'),/temporarily unavailable/);assert.equal(count,1);
  time=15001;await assert.rejects(read('HASH','1'),/offline/);assert.equal(count,2);
});
for (const override of [{status:'CANCELLED'},{sellerWalletAddress:'other'},
  {totalPrice:'NaN'},{psktSeller:'{}'}]) {
  test('changed or invalid order cannot supply a price '+JSON.stringify(override),async()=>{
    await assert.rejects(createNexusPriceReader(source([],override))('KASGOTHS','991'));
  });
}
test('owner, listing transaction and indexer state must all match the cached price',()=>{
  const order={...row,listingTransactionId:tx};
  const state={ticker:'KASGOTHS',tokenId:'991',owner,listingId:tx,listingStatus:'LISTED'};
  assert.equal(matchingNexusOrder(order,state),order);
  for(const changed of [{owner:'other'},{listingId:'c'.repeat(64)},{listingStatus:'UNLISTED'},
    {ticker:'HASH'},{tokenId:'1'}]) assert.equal(matchingNexusOrder(order,{...state,...changed}),null);
});
test('invalid identifiers never reach KaspaCom',async()=>{
  let count=0;const read=createNexusPriceReader(async()=>{count++;return {};});
  await assert.rejects(read('../HASH','1'));await assert.rejects(read('HASH','x'));
  assert.equal(count,0);
});
