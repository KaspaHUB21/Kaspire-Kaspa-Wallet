import test from 'node:test';
import assert from 'node:assert/strict';
import {ActivityFeed,mergeActivity} from './generated/activityFeed.mjs';
import {isWalletPage} from './generated/walletPage.mjs';
const row=i=>({transactionId:i.toString(16).padStart(64,'0'),assetKind:'KAS',assetSymbol:'KAS',blockTime:i});
test('verified KCC20 units override fallback Activity values independently of response order',()=>{
  const base={transactionId:'bte',assetKind:'KCC20',assetSymbol:'BTE',tokenId:'c'};
  const exact={...base,displayAmount:'250',unitSource:'verified-kcc20'},fallback={...base,displayAmount:'0.025'};
  assert.equal(mergeActivity([[exact],[fallback]])[0].displayAmount,'250');
  assert.equal(mergeActivity([[fallback],[exact]])[0].displayAmount,'250');
});
test('activity displays 50 merged entries then another 50 without a false Load more',async()=>{
  const feed=new ActivityFeed();
  await feed.load('KAS history',async()=>({items:Array.from({length:121},(_,i)=>row(i))}),()=>{});
  assert.equal(feed.snapshot().items.length,50);assert.equal(feed.snapshot().items[0].blockTime,120);assert.equal(feed.snapshot().hasMore,true);
  feed.showMore();assert.equal(feed.snapshot().items.length,100);
  feed.showMore();assert.equal(feed.snapshot().items.length,121);assert.equal(feed.snapshot().hasMore,false);
});
test('slow and failing assets never block fresh KAS and saved entries survive failures',async()=>{
  const feed=new ActivityFeed();let release;
  const slow=feed.load('Covenant history',()=>new Promise(resolve=>{release=resolve;}),()=>{});
  await feed.load('KAS history',async()=>({items:[row(1)]}),()=>{});
  assert.equal(feed.snapshot().items.length,1);assert.equal(feed.loading.has('Covenant history'),true);
  release({items:[]});await slow;
  await feed.load('KAS history',async()=>{throw Error('offline');},()=>{});
  assert.equal(feed.snapshot().items.length,1);assert.match(feed.warnings.get('KAS history'),/retained/);
});
test('late refresh cannot overwrite a newer source generation',async()=>{
  const feed=new ActivityFeed();let release;
  const stale=feed.load('KAS history',()=>new Promise(resolve=>{release=resolve;}),()=>{});
  await feed.load('KAS history',async()=>({items:[row(2)]}),()=>{});
  release({items:[row(1)]});await stale;
  assert.equal(feed.snapshot().items[0].blockTime,2);
});
test('partial responses retain old entries and expose incomplete coverage',async()=>{
  const feed=new ActivityFeed();
  await feed.load('KAS history',async()=>({items:[row(1)]}),()=>{});
  await feed.load('KAS history',async()=>({items:[row(2)],warnings:['Partial address lookup']}),()=>{});
  assert.equal(feed.snapshot().items.length,2);assert.equal(feed.warnings.size,1);
});
test('fresh KAS and token legs remain separate while KRC20 aliases deduplicate',()=>{
  const id='a'.repeat(64),token={transactionId:id,assetKind:'KRC-20',assetSymbol:'SOULS',displayAmount:'21000'};
  const rows=mergeActivity([[{...row(1),transactionId:id}],[token],[{...token,assetKind:'KRC20'}]]);
  assert.equal(rows.length,2);
});
test('only exact packaged popup and side panel URLs may use private wallet operations',()=>{
  const root='chrome-extension://wallet-id/';
  assert.equal(isWalletPage(root+'wallet.html',root),true);
  assert.equal(isWalletPage(root+'sidepanel.html',root),true);
  assert.equal(isWalletPage(root+'sidepanel.html?view=00000000-0000-4000-8000-000000000001',root),true);
  for(const url of [undefined,root+'approval.html',root+'content.js',root+'wallet.html?untrusted=1','https://evil.example/sidepanel.html','chrome-extension://other-id/sidepanel.html'])assert.equal(isWalletPage(url,root),false);
});
