import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {confirmedSale, createSalesFeed} from './nft-market-sales.mjs';

const seller = 'kaspa:' + 'q'.repeat(61), buyer = 'kaspa:' + 'p'.repeat(61);
const feeAddress = 'kaspa:' + 'z'.repeat(61);
const offer = {ticker:'KASGOTHS', tokenId:'1528', priceSompi:20000000000,
  listingTransactionId:'a'.repeat(64), seller, feeAddress};
const listing = {index:0, amount:29825700, script_public_key_address:buyer};
const tx = {transaction_id:'b'.repeat(64), is_accepted:true, accepting_block_time:Date.now()-1000,
  inputs:[{previous_outpoint_hash:offer.listingTransactionId, previous_outpoint_index:'0'}],
  outputs:[{index:0, amount:19609825700, script_public_key_address:seller},
    {index:1, amount:1000000, script_public_key_address:buyer},
    {index:2, amount:420000000, script_public_key_address:feeAddress}]};

test('accepted purchase reports signed price without reserve or network fee', () => {
  const sale = confirmedSale(offer, listing, tx);
  assert.equal(sale.priceSompi, '20000000000');
  assert.equal(sale.buyerAddress, buyer);
  assert.equal(sale.transactionId, tx.transaction_id);
});

test('rejects cancellation, unaccepted tx, wrong input and wrong payment', () => {
  for (const alter of [t=>t.outputs.splice(1), t=>t.is_accepted=false,
    t=>t.inputs[0].previous_outpoint_hash='c'.repeat(64),
    t=>t.outputs[0].amount++, t=>t.outputs[2].amount--,
    t=>t.outputs[1].script_public_key_address=seller]) {
    const invalid=structuredClone(tx); alter(invalid);
    assert.equal(confirmedSale(offer, listing, invalid), null);
  }
});

test('discovers missing completion notification for every marketplace collection and persists it', async () => {
  const state = await mkdtemp(join(tmpdir(), 'agora-sales-'));
  let calls=0;
  const get=async url=>{
    calls++;
    if(url.includes('/transactions/')) return {is_accepted:true,transaction_id:offer.listingTransactionId,outputs:[listing]};
    if(url.endsWith('/utxos')) return [];
    if(url.includes('full-transactions')) return [tx];
    throw Error('unexpected URL');
  };
  try {
    const config={state,get,node:'https://local',records:()=>[offer]};
    const feed=createSalesFeed(config);
    const page=await feed(0);
    assert.equal(page.sales.length,1);
    assert.equal(calls,3);
    await feed(0);
    assert.equal(calls,3);
    const restarted=createSalesFeed(config);
    assert.equal((await restarted(0)).sales.length,1);
    assert.equal(calls,3);
  } finally {await rm(state,{recursive:true,force:true});}
});

test('discovers confirmed sales outside the original launch collections', async () => {
  const state = await mkdtemp(join(tmpdir(), 'agora-sales-'));
  const other = {...offer, ticker:'KDC', tokenId:'778', listingTransactionId:'d'.repeat(64)};
  const otherListing = {...listing};
  const otherSale = structuredClone(tx);
  otherSale.transaction_id = 'e'.repeat(64);
  otherSale.inputs[0].previous_outpoint_hash = other.listingTransactionId;
  try {
    const feed=createSalesFeed({state,node:'https://local',records:()=>[other],get:async url=>{
      if(url.includes('/transactions/')) return {is_accepted:true,transaction_id:other.listingTransactionId,outputs:[otherListing]};
      if(url.endsWith('/utxos')) return [];
      if(url.includes('full-transactions')) return [otherSale];
      throw Error('unexpected URL');
    }});
    const page=await feed(0);
    assert.equal(page.sales.length,1);
    assert.equal(page.sales[0].ticker,'KDC');
  } finally {await rm(state,{recursive:true,force:true});}
});

test('outage is not an empty successful history', async () => {
  const state = await mkdtemp(join(tmpdir(), 'agora-sales-'));
  try {
    const feed=createSalesFeed({state,get:async()=>{throw Error('offline');},node:'https://local',records:()=>[offer]});
    await assert.rejects(feed(0), /offline/);
  } finally {await rm(state,{recursive:true,force:true});}
});
