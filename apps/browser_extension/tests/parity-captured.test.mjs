// Optional public read-only captures; never seeds, partner kits or broadcasts.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {standardKcc20Assets,standardKcc20TransferData} from './generated/standardKcc20.mjs';
import {Kcc20Kascov} from './generated/kcc20Kascov.mjs';
import {engine} from './dex-engine.test.mjs';
import init,* as core from './generated/wasm/kaspa_secure_core.mjs';
await init({module_or_path:await readFile(new URL('./generated/wasm/kaspa_secure_core_bg.wasm',import.meta.url))});
const capture=async name=>process.env[name]?JSON.parse(await readFile(process.env[name],'utf8')):null;
const v4=await capture('KASPIRE_KASVIO_V4_SNAPSHOT'),cov=await capture('KASPIRE_KASCOV_SNAPSHOT');
function key(url){const u=new URL(url);u.searchParams.sort();return decodeURI(u.href);}
function source(snapshot,mutate=()=>{}){const records=new Map(Object.entries(snapshot.responses).map(([u,r])=>[key(u),r]));return async url=>{
  const r=records.get(key(url));if(!r)throw Object.assign(Error('Uncaptured public read '+url),{httpStatus:404});if(r.status!==200)throw Object.assign(Error('HTTP '+r.status),{httpStatus:r.status});const body=structuredClone(r.body);mutate(url,body);return body;
};}
test('recorded V4 address discovery and Kasseal/standard live signing cells', {skip:!v4},async()=>{
  const get=source(v4),rows=await standardKcc20Assets(get,v4.owner);
  for(const cid of v4.samples){const a=rows.find(r=>r.covenantId===cid);assert(a);assert.match(a.image_url,/\/api\/kcc20\/v4\/images\//);
    const b=await standardKcc20TransferData(get,cid,v4.owner,a.symbol==='UNNACHOD'?10000:1e12,{fullPlan:true,kassealOwnerOnly:a.standard==='kasseal-kcc20'});assert(b.cells.length>0);
  }
  assert(!rows.some(r=>r.symbol.startsWith('BRAVE-')));
});
test('Kasvio offline: recorded Kascov programs and own-node outputs authorize the same transfers',{skip:!cov},async()=>{
  const read=source(cov),get=async url=>{if(new URL(url).hostname==='kasvio.network')throw Object.assign(Error('HTTP 503'),{httpStatus:503});return read(url);};
  const rows=await standardKcc20Assets(get,cov.owner);
  for(const cid of cov.samples){const a=rows.find(r=>r.covenantId===cid);assert(a);const b=await standardKcc20TransferData(get,cid,cov.owner,a.symbol==='UNNACHOD'?10000:1e12,{fullPlan:true,kassealOwnerOnly:a.standard==='kasseal-kcc20'});assert(b.cells.length>0);}
});
test('Kascov omitted, altered or duplicate cells never become zero or spendable',{skip:!cov},async()=>{
  for(const mutate of [b=>b.omitted_unproven=1,b=>b.cells.push(b.cells[0]),b=>b.cells[0].amount_str='1',b=>b.cells[0].program_hex+='00',b=>b.cells[0].script_hex='aa20'+'0'.repeat(64)+'87',b=>b.cells[0].owner='00'+'0'.repeat(64)]){
    const get=source(cov,(url,b)=>{if(url.includes('/cells?'))mutate(b);});await assert.rejects(new Kcc20Kascov(get).balance(cov.samples[0],cov.owner));
  }
});
const k=await capture('KASPIRE_KFORGE_SNAPSHOT'),live=await capture('KASPIRE_KFORGE_LIVE_INPUTS');
test('compiled KForge curve/pool buys and sells reach the actual Rust/WASM verifier',{skip:!k||!live},async()=>{
  for(const name of ['curve-buy','curve-sell','pool-buy','pool-sell']){
    const trade=k.trades[name],selected=k.tokens.find(t=>t.tokenCovId===trade.token.tokenCovId||t.covenantId===trade.token.covenantId)||trade.token;
    const e=await engine(m=>{
      if(m.operation==='storeRead')return null;
      if(m.operation==='progress')return null;
      if(m.operation==='prepare')return JSON.parse(core.preparePskt(JSON.stringify(m.body.request)));
      assert.equal(m.operation,'http');const u=new URL(m.body.url);let body;
      if(u.pathname==='/v6/registry')body=k.registry;
      else if(u.pathname==='/v6/tokens')body=k.tokens;
      else if(u.pathname.startsWith('/v6/holdings/'))body=k.wallets[decodeURIComponent(u.pathname.split('/').at(-1))];
      else if(m.body.method==='POST'){assert.equal(u.pathname,trade.path);body=trade.response;}
      else if(u.pathname.includes('/transactions/'))body=live.origins[u.pathname.split('/').at(-1)];
      else if(u.pathname.endsWith('/utxos'))body=live.utxos[decodeURIComponent(u.pathname.split('/').at(-2))];
      else throw Error('Uncaptured endpoint '+u);
      if(u.searchParams.has('address')&&u.pathname.endsWith('/utxos'))body={network:'mainnet',covenantIdsIncluded:true,entries:live.utxos[u.searchParams.get('address')]};
      if(body==null)throw Error('Missing capture '+u);return {status:200,headers:{},body:Buffer.from(JSON.stringify(body)).toString('base64')};
    });
    const catalogue=await e.run('kforge','tokens',{}, {address:trade.wallet});
    const token=catalogue.find(t=>t.curve===trade.body.token);assert(token);
    const side=name.endsWith('buy')?'buy':'sell';
    // Pool buy budget in sompi; curve budget funds exactly one captured lot.
    const budget=side==='buy'?(name==='pool-buy'?String(trade.body.kas/1e8):'100'):
      String(name==='curve-sell'?trade.body.qty*1000000:trade.body.tokens);
    const q=await e.run('kforge','quote',{tokenId:token.id,side,amount:budget},{address:trade.wallet});
    assert.match(q.review.reviewHash,/^[a-f0-9]{64}$/);assert(q.review.tradeSummary.verified.tokens);assert.equal(e.calls.some(c=>c.operation==='sign'),false);
  }
});
const f=await capture('KASPIRE_KASFORGE_SNAPSHOT');
const braid=await capture('KASPIRE_BRAID_STAGED_REVIEW');
test('captured Braid staged token-to-token plan passes browser WASM and pins the fee',{skip:!braid},()=>{
  const r=JSON.parse(core.preparePskt(JSON.stringify(braid)));assert.match(r.reviewHash,/^[a-f0-9]{64}$/);
  const changed=structuredClone(braid);changed.tradeSummary.feeBps='200';assert.throws(()=>core.preparePskt(JSON.stringify(changed)));
});
test('compiled KasForge Mainnet quotes and 3.8 buy/sell builds pass independent native review',{skip:!f},async()=>{
  const template=JSON.parse(await readFile(new URL('../../../crates/kaspa_secure_core/src/kcc20_standard_template.json',import.meta.url),'utf8'));
  for(const side of ['buy','sell']){
    const address=f.account.address,e=await engine(m=>{
      if(m.operation==='storeRead')return null;
      if(m.operation==='progress')return null;
      if(m.operation==='asset')return JSON.stringify(template);
      if(m.operation==='prepare')return JSON.parse(core.preparePskt(JSON.stringify(m.body.request)));
      assert.equal(m.operation,'http');const u=new URL(m.body.url);let body;
      if(u.pathname.endsWith('/tokenlist'))body=f.tokenlist;
      else if(u.pathname==='/api/v1/markets')body=f.markets;
      else if(u.pathname.includes('/market/'))body=f.market;
      else if(u.pathname.includes('/quote/'))body=f.trades[side].quote;
      else if(u.pathname.includes('/account/'))body=f.account;
      else if(u.pathname.includes('/portfolio/'))body=f.portfolio;
      else if(u.pathname.endsWith('/build')){assert.equal(m.body.method,'POST');body=f.trades[side].build;}
      else if(u.pathname.endsWith('/info/blockdag'))body={networkName:'kaspa-mainnet',virtualDaaScore:f.clocks[0]};
      else if(u.pathname.endsWith('/utxos'))body=f.live[u.searchParams.get('address')];
      if(body==null)throw Error('Missing Forge capture '+u);return {status:200,headers:{},body:Buffer.from(JSON.stringify(body)).toString('base64')};
    });
    const q=await e.run('kasforge','quote',{tokenId:f.cid,side,amount:f.trades[side].amount},{address});
    const p=await e.run('kasforge','prepare',{id:q.id},{address});
    assert(p.reviews.length>0);for(const r of p.reviews)assert.match(r.reviewHash,/^[a-f0-9]{64}$/);
    assert.equal(e.calls.some(c=>c.operation==='sign'),false);
  }
});
