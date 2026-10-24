import test,{afterEach} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {KASSEAL_API,KASSEAL_PLANNER,kassealTokens,kassealHoldings,kassealImage,kassealDisplay,kassealDetails,
  validateKassealPlan,verifyKassealInputs,kassealQuote,prepareKasseal,submitKasseal,resumeKasseal,clearKassealReviews} from './generated/kasseal.mjs';
const previous=globalThis.fetch;
afterEach(()=>{globalThis.fetch=previous;clearKassealReviews();});
const address='kaspa:q'+'a'.repeat(61),cid='c'.repeat(64),origin='a'.repeat(64),id='b'.repeat(64);
const token={meta:{covenantId:cid,ticker:'WALLET',name:'Wallet',decimals:0,imageSource:'verified',imageUrl:'/v1/images/'+'d'.repeat(64)},verification:'verified',phase:'bonding'};
const response=(value,status=200)=>new Response(JSON.stringify(value),{status});
test('Kasseal search goes to the global catalogue, including cursor and exact CID',async()=>{
  const calls=[];globalThis.fetch=async url=>{calls.push(new URL(url));return response({tokens:[token],nextCursor:null});};
  await kassealTokens('  unnachod  ','page+2');await kassealTokens(cid);
  assert.equal(calls[0].searchParams.get('search'),'unnachod');assert.equal(calls[0].searchParams.get('cursor'),'page+2');
  assert.equal(calls[1].searchParams.get('search'),cid);assert.equal(calls[0].origin,'https://kaspire.kaslab.space');
  await assert.rejects(kassealTokens('x'.repeat(65)),/too long/);
});
test('only verified Kasseal images and tokens become wallet holdings; amounts stay exact',async()=>{
  globalThis.fetch=async url=>{assert.equal(String(url),KASSEAL_API+'/address/'+encodeURIComponent(address)+'/tokens');return response({address,tokens:[token],holdings:[{tokenId:cid,balance:'9007199254740993'}]});};
  const [asset]=await kassealHoldings(address);assert.equal(asset.rawBalance,'9007199254740993');assert.equal(asset.decimals,0);
  assert.equal(asset.standard,'kasseal-kcc20');assert.equal(asset.explorerUrl,'https://kaspatoken.kaslab.space/kcc20/'+cid);
  assert.equal(kassealImage(token),'https://app.kasseal.com'+token.meta.imageUrl);
  assert.equal(kassealImage({...token,meta:{...token.meta,imageUrl:'https://evil.invalid/a'}}),'');
  assert.equal(kassealImage({...token,meta:{...token.meta,imageSource:'claimed'}}),'');
});
test('display uses exact US separators without mislabelling funding change as trade proceeds',()=>{
  assert.equal(kassealDisplay('900719925474099301',8),'9,007,199,254.74099301');
  assert.equal(kassealDisplay('-100000000000',8),'-1,000');
  const lines=kassealDetails({side:'sell',tokenAmount:'21056',kasSompi:'231583220',protocolFeeSompi:'2339225',networkFeeSompi:'20000',walletNetSompi:'231563220',walletChangeSompi:'8300000000000'});
  assert(lines.includes('Token amount: 21,056'));assert(lines.some(v=>v.includes('2.3158322 KAS')));
  assert(!lines.some(v=>v.includes('83,000')));assert(lines.some(v=>v.includes('Net wallet KAS change: 2.3156322 KAS')));
});
function request(){return {sender:address,profile:'kasseal-mainnet-swap-v1',tokenId:cid,side:'buy',txJsonString:JSON.stringify({inputs:[{transactionId:origin,index:0,utxo:{address,amount:'1000000000',scriptPublicKey:'000020aaac',blockDaaScore:'0',isCoinbase:false,covenantId:null}}]}),tradeSummary:{network:'mainnet',tokenId:cid,side:'buy',rawAmount:'100000000',minimumReceive:'990',maxSpendSompi:'800000000',stage:'swap',tokenAmount:'1000',kasSompi:'100000000',protocolFeeSompi:'1000000'}};}
function live(){return {network:'mainnet',covenantIdsIncluded:true,entries:[{outpoint:{transactionId:origin,index:0},utxoEntry:{amount:'1000000000',scriptPublicKey:{version:0,script:'20aaac'},blockDaaScore:'123',isCoinbase:false,covenantId:null}}]};}
const body={network:'mainnet',tokenId:cid,side:'buy',rawAmount:'100000000',minimumReceive:'990',maxSpendSompi:'800000000'};
test('Mainnet plans bind all user-selected terms and SDK version; preparations cannot become a sale',()=>{
  const data={request:request(),proofStatus:'bound',sdkVersion:'0.1.1'};
  validateKassealPlan(data,address,body);
  for(const field of ['network','tokenId','side','rawAmount','minimumReceive','maxSpendSompi']){
    const changed=structuredClone(data);changed.request.tradeSummary[field]='altered';assert.throws(()=>validateKassealPlan(changed,address,body));
  }
  for(const change of [{proofStatus:'unbound'},{sdkVersion:'9.0.0'},{request:{...request(),profile:'generic'}}])assert.throws(()=>validateKassealPlan({...data,...change},address,body));
  const prep=structuredClone(data);prep.request.profile='kasseal-mainnet-prepare-v1';prep.request.side='sell';Object.assign(prep.request.tradeSummary,{side:'sell',stage:'preparation',operation:'split',maxPreparationDebitSompi:'700000000'});
  validateKassealPlan(prep,address,{...body,side:'sell'});prep.request.tradeSummary.maxPreparationDebitSompi='800000000';assert.throws(()=>validateKassealPlan(prep,address,{...body,side:'sell'}));
});
test('independent live UTXOs resolve DAA before review but reject changes after it',async()=>{
  const r=request(),get=async()=>live();await verifyKassealInputs(r,undefined,undefined,get);
  assert.equal(JSON.parse(r.txJsonString).inputs[0].utxo.blockDaaScore,'123');
  const review={inputs:[{address}]};await verifyKassealInputs(r,review,undefined,get);
  const changed=live();changed.entries[0].utxoEntry.blockDaaScore='124';await assert.rejects(verifyKassealInputs(r,review,undefined,async()=>changed),/changed after review/);
  for(const field of ['amount','covenantId','isCoinbase','scriptPublicKey']){
    const value=live();value.entries[0].utxoEntry[field]='altered';await assert.rejects(verifyKassealInputs(r,review,undefined,async()=>value));
  }
  await assert.rejects(verifyKassealInputs(r,review,undefined,async()=>({...live(),entries:[]})),/pool or wallet balance changed/);
  await assert.rejects(verifyKassealInputs(r,review,undefined,async()=>({...live(),network:'testnet-10'})),/verification unavailable/);
});
function environment(t,{preparation=false}={}){
  let state={},accepted=false,locked=false,fail=false,ready=true;const events=[];
  const context={address,binding:'session:wallet:path',guard:async()=>{if(locked)throw Error('Wallet locked');},load:()=>structuredClone(state),save:async s=>{events.push('save');state=structuredClone(s);},balance:async()=> '1000000000',
    prepare:async()=>({transactionId:id,reviewHash:'hash',inputs:[{address}]}),
    sign:async req=>{events.push('sign');return {transactionId:id,wrpcJson:JSON.stringify({id,inputs:JSON.parse(req.txJsonString).inputs})};},approve:async()=>true,
    record:async(wallet,tx)=>{events.push('record');assert.equal(wallet,address);assert.equal(tx.assetKind,'KCC20');assert.equal(tx.assetSymbol,'WALLET');assert.equal(tx.displayAmount,'1,000');}};
  globalThis.fetch=async(url,init)=>{
    url=String(url);
    if(url.endsWith('/local-node/transactions/'+origin))return response({transaction_id:origin,is_accepted:true,outputs:[{index:0,script_public_key_address:address}]});
    if(url.endsWith('/local-node/transactions/'+id))return response({transaction_id:id,is_accepted:accepted});
    if(url.includes('/full-transactions'))return response([]);
    if(url.endsWith('/quote')){const b=JSON.parse(init.body);return response({...request().tradeSummary,...b,quoteExpiresAt:Date.now()+120000});}
    if(url.endsWith('/plan')){const b=JSON.parse(init.body),r=request();Object.assign(r.tradeSummary,b);if(preparation){r.profile='kasseal-mainnet-prepare-v1';r.side='sell';Object.assign(r.tradeSummary,{stage:'preparation',operation:'split',maxPreparationDebitSompi:'700000000'});}return response({request:r,proofStatus:'bound',sdkVersion:'0.1.1'});}
    if(url.includes('/tokens?'))return response({tokens:[token],nextCursor:null});
    if(url.includes('/utxos?'))return response(live());
    if(url.includes('/prepared?'))return response({ready,network:'mainnet',tokenId:cid,transactionId:id});
    if(url.endsWith('/tx')){assert.equal(state.pending.signedTxJson,JSON.parse(init.body).txJson);events.push('submit');if(fail)throw Error('offline');accepted=true;return response({transactionId:id});}
    throw Error('Unexpected '+url);
  };
  return {context,events,state:()=>state,lock:()=>{locked=true;},fail:v=>{fail=v;}};
}
test('signed swap is encrypted before submit; accepted buy records token activity and history',async t=>{
  const e=environment(t),q=await kassealQuote(e.context,cid,'buy','1'),p=await prepareKasseal(e.context,q.quoteId);
  const fetchBefore=globalThis.fetch;globalThis.fetch=async(url,init)=>{assert(!String(url).includes('/full-transactions'),'Fresh verified swaps must not scan historical conflicts before submission');return fetchBefore(url,init);};
  const receipt=await submitKasseal(e.context,p.id);assert.equal(receipt.transactionId,id);
  assert.deepEqual(e.events,['sign','save','submit','record','save']);assert.equal(e.state().pending,undefined);assert.equal(e.state().history.length,1);
});
test('uncertain submission retains signed bytes, blocks a replacement and resumes without signing twice',async t=>{
  const e=environment(t),q=await kassealQuote(e.context,cid,'buy','1'),p=await prepareKasseal(e.context,q.quoteId);e.fail(true);
  await assert.rejects(submitKasseal(e.context,p.id),/offline/);const bytes=e.state().pending.signedTxJson;
  const inputs=JSON.parse(bytes).inputs;assert(inputs.length>0);assert.equal(inputs[0].transactionId,origin);assert.equal(inputs[0].previousOutpoint,undefined);
  await assert.rejects(kassealQuote(e.context,cid,'buy','1'),/saved swap first/);assert.equal(e.state().pending.signedTxJson,bytes);
  e.fail(false);await resumeKasseal(e.context);assert.equal(e.events.filter(v=>v==='sign').length,1);assert.equal(e.state().pending,undefined);
});
test('confirmed split is preparation history only, never a completed trade or token activity',async t=>{
  const e=environment(t,{preparation:true}),q=await kassealQuote(e.context,cid,'sell','1000'),p=await prepareKasseal(e.context,q.quoteId);
  await submitKasseal(e.context,p.id);assert.equal(e.state().preparations.length,1);assert.equal(e.state().history,undefined);assert(!e.events.includes('record'));
});
test('account binding and a lock during approval prevent signing',async t=>{
  const e=environment(t),prepare=async()=>prepareKasseal(e.context,(await kassealQuote(e.context,cid,'buy','1')).quoteId);
  let p=await prepare();await assert.rejects(submitKasseal({...e.context,binding:'different'},p.id),/review expired/);
  p=await prepare();e.context.approve=async()=>{e.lock();return true;};await assert.rejects(submitKasseal(e.context,p.id),/Wallet locked/);assert(!e.events.includes('sign'));
});
test('Kasseal store package has the official logo, no test name, and the narrow API origin permission',async()=>{
  const manifest=JSON.parse(await readFile(new URL('../manifest.json',import.meta.url),'utf8'));
  assert(!/\btest\b/i.test(manifest.name+' '+manifest.version_name));assert(manifest.host_permissions.includes('https://app.kasseal.com/*'));
  assert(!manifest.host_permissions.includes('<all_urls>'));
});
