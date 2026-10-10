import test from 'node:test';
import assert from 'node:assert/strict';
import {alertCaption, formatKas, initialListingPlan} from './nft-market-telegram-alerts.mjs';

test('formats sompi exactly without floating point rounding', () => {
  assert.equal(formatKas('39900000000'), '399');
  assert.equal(formatKas('12100000001'), '121.00000001');
});

test('initial setup backfills only the newest four listings in chronological order', () => {
  const offers = Array.from({length: 7}, (_, index) => ({createdAt:index, listingTransactionId:String(index)}));
  const plan = initialListingPlan(offers, 4);
  assert.deepEqual(plan.alreadySeen.map(x => x.listingTransactionId), ['0','1','2']);
  assert.deepEqual(plan.backfill.map(x => x.listingTransactionId), ['3','4','5','6']);
});

test('captions contain escaped identity, rank and exact KAS price', () => {
  const caption = alertCaption('listing', {ticker:'KDC<',tokenId:'778',rarityRank:501,priceSompi:'12100000000'});
  assert.match(caption, /KDC&lt; #778/);
  assert.match(caption, /#501/);
  assert.match(caption, /121 KAS/);
});

import {mkdtemp, readFile, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {runAlerts} from './nft-market-telegram-alerts.mjs';

async function alertFixture(t) {
  const dir = await mkdtemp(join(tmpdir(), 'kaspire-alert-test-'));
  const config = {token:'test-only',chatId:'-123',threadId:'42',imageBase:'http://local/images',
    listingsUrl:'http://local/listings',salesUrl:'http://local/sales',alertState:join(dir,'sent.json')};
  await writeFile(config.alertState, JSON.stringify({version:1,listings:[],sales:[]}));
  t.after(() => rm(dir,{recursive:true,force:true}));
  const offer = (id,ticker='MAXITEARS') => ({listingTransactionId:id,ticker,tokenId:id,
    createdAt:Number(id),priceSompi:'100000000',rarityRank:3});
  return {config,offer};
}

test('dead image sends text; later listing and sale send photos; next cycle sends no duplicates', async t => {
  const {config,offer}=await alertFixture(t);
  const offers=[offer('1','PROBIFI'),offer('2')];
  const sales=[{...offer('3'),transactionId:'sale3',soldAt:3}];
  const calls=[];
  t.mock.method(globalThis,'fetch',async (url,options) => {
    if(url===config.listingsUrl)return Response.json({offers});
    if(url===config.salesUrl)return Response.json({sales});
    if(url.startsWith(config.imageBase))return url.includes('PROBIFI')
      ? new Response('',{status:404}) : new Response('preview',{headers:{'content-type':'image/webp'}});
    calls.push({url,body:options.body});
    return Response.json({ok:true,result:{message_id:100+calls.length}});
  });
  assert.deepEqual(await runAlerts(config),{listings:2,sales:1,failed:0});
  assert.equal(calls.length,3);
  assert.match(calls[0].url,/\/sendMessage$/);
  assert.equal(calls[0].body.get('message_thread_id'),'42');
  assert.match(calls[0].body.get('text'),/PROBIFI #1/);
  assert.match(calls[0].body.get('text'),/Image unavailable/);
  assert.match(calls[1].url,/\/sendPhoto$/);
  assert.equal(calls[1].body.get('photo').name,'MAXITEARS-2.webp');
  const state=JSON.parse(await readFile(config.alertState,'utf8'));
  assert.deepEqual(state.listings,['1','2']);
  assert.deepEqual(state.sales,['sale3']);
  assert.equal(state.receipts['listing:1'].messageId,101);
  assert.deepEqual(await runAlerts(config),{listings:0,sales:0,failed:0});
  assert.equal(calls.length,3);
});

test('Telegram rejection stays pending and does not block later listings or sales', async t => {
  const {config,offer}=await alertFixture(t);
  let rejectFirst=true;
  t.mock.method(globalThis,'fetch',async (url,options) => {
    if(url===config.listingsUrl)return Response.json({offers:[offer('1'),offer('2')]});
    if(url===config.salesUrl)return Response.json({sales:[{...offer('3'),transactionId:'sale3',soldAt:3}]});
    if(url.startsWith(config.imageBase))return new Response('preview',{headers:{'content-type':'image/png'}});
    if(rejectFirst&&options.body.get('caption').includes('#1</b>'))return Response.json({ok:false,description:'test rejection'},{status:400});
    return Response.json({ok:true,result:{message_id:987}});
  });
  assert.deepEqual(await runAlerts(config),{listings:1,sales:1,failed:1});
  let state=JSON.parse(await readFile(config.alertState,'utf8'));
  assert.deepEqual(state.listings,['2']);assert.deepEqual(state.sales,['sale3']);
  assert.equal(state.receipts['listing:1'],undefined);
  rejectFirst=false;
  assert.deepEqual(await runAlerts(config),{listings:1,sales:0,failed:0});
  state=JSON.parse(await readFile(config.alertState,'utf8'));
  assert.deepEqual(state.listings,['2','1']);
});
