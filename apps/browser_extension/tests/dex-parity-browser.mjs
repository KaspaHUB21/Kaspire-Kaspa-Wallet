// Real MV3/offscreen/packaged Dart engine. Public watch-only data; no signing.
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtemp,readFile,mkdir,rm,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
const scratch=await mkdtemp(join(tmpdir(),'kaspire-dex-parity-')),port=9363;
const panel=process.env.KASPIRE_TEST_SURFACE==='panel';
const extension=process.argv[2]?join(scratch,'extension'):resolve('dist');
if(process.argv[2])execFileSync('unzip',['-q',resolve(process.argv[2]),'-d',extension]);
const k=JSON.parse(await readFile(process.env.KASPIRE_KFORGE_SNAPSHOT,'utf8'));
const f=JSON.parse(await readFile(process.env.KASPIRE_KASFORGE_SNAPSHOT,'utf8'));
const output=resolve('artifacts/dex-parity-browser');await mkdir(output,{recursive:true});
const browser=spawn('chromium',['--headless=new','--no-sandbox','--disable-gpu','--no-first-run',`--user-data-dir=${join(scratch,'profile')}`,`--disable-extensions-except=${extension}`,`--load-extension=${extension}`,`--remote-debugging-port=${port}`,'about:blank'],{stdio:'ignore'});
const delay=ms=>new Promise(r=>setTimeout(r,ms));
const endpoint=`http://127.0.0.1:${port}`;
const targets=async()=> (await fetch(endpoint+'/json/list')).json();
function cdp(ws,method,params={}){return new Promise((resolve,reject)=>{const s=new WebSocket(ws),t=setTimeout(()=>{s.close();reject(Error(method+' timed out'));},30000);s.onopen=()=>s.send(JSON.stringify({id:1,method,params}));s.onerror=reject;s.onmessage=e=>{const m=JSON.parse(e.data);if(m.id!==1)return;clearTimeout(t);s.close();m.error?reject(Error(JSON.stringify(m.error))):resolve(m.result);};});}
async function ev(ws,expression){const r=await cdp(ws,'Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(r.exceptionDetails)throw Error(r.exceptionDetails.exception?.description??r.exceptionDetails.text);return r.result?.value;}
async function until(fn,label){for(let i=0;i<160;i++){try{const r=await fn();if(r)return r;}catch{}await delay(100);}throw Error('Missing '+label);}
let ws,worker;
try{
  worker=await until(async()=> (await targets()).find(t=>t.type==='service_worker'),'worker');
  await until(()=>ev(worker.webSocketDebuggerUrl,'!!globalThis.chrome?.runtime?.onMessage'),'extension runtime');
  await ev(worker.webSocketDebuggerUrl,`(()=>{const original=fetch,k=${JSON.stringify(k)},f=${JSON.stringify(f)};globalThis.dexCalls=[];globalThis.dexSenders=[];chrome.runtime.onMessage.addListener((m,s)=>{if(m?.kind==='dex-engine-host')dexSenders.push({id:s.id,url:s.url,documentId:s.documentId});return false;});globalThis.fetch=async(input,options)=>{
    const u=new URL(String(input));if(u.protocol!=='https:')return original(input,options);dexCalls.push({url:u.href,method:options?.method??'GET'});let data;
    if(u.host==='api.kforge.xyz'&&u.pathname==='/v6/registry')data=k.registry;
    else if(u.host==='api.kforge.xyz'&&u.pathname==='/v6/tokens')data=k.tokens;
    else if(u.host==='api.kforge.xyz'&&u.pathname.includes('/holdings/'))data={wallet:decodeURIComponent(u.pathname.split('/').at(-1)),holdings:[{tokenCovId:k.tokens[0].tokenCovId,rungCovId:k.tokens[0].rungCovId,ticker:k.tokens[0].ticker,amount:10000000}]};
    else if(u.host==='kaspa.pumpforge.tech'&&u.pathname.endsWith('/tokenlist'))data=f.tokenlist;
    else if(u.host==='kaspa.pumpforge.tech'&&u.pathname.endsWith('/markets'))data=f.markets;
    else if(u.host==='kaspa.pumpforge.tech'&&u.pathname.includes('/portfolio/'))data={ok:true,address:'${'kaspa:qp0mtdvzscrkfft702j85s8yzdl8a87n5d6pgtm8vrxg6hqu0wywzvwkevdk3'}',positions:[{token:f.cid,tokens:1000000}],orders:[],activity:[]};
    else if(u.pathname.endsWith('/balance'))data={balance:'12345678900'};
    else return new Response('{}',{status:503});return new Response(JSON.stringify(data),{headers:{'content-type':'application/json'}});
  };return true;})()`);
  const page=await (await fetch(endpoint+'/json/new?'+encodeURIComponent(new URL(panel?'sidepanel.html':'wallet.html',worker.url).href),{method:'PUT'})).json();ws=page.webSocketDebuggerUrl;
  await cdp(ws,'Emulation.setDeviceMetricsOverride',{width:panel?360:420,height:900,deviceScaleFactor:1,mobile:false});
  await until(()=>ev(ws,'!!document.querySelector("#first-watch")'),'watch onboarding');
  await ev(ws,`document.querySelector('#first-watch-address').value='kaspa:qp0mtdvzscrkfft702j85s8yzdl8a87n5d6pgtm8vrxg6hqu0wywzvwkevdk3';document.querySelector('#first-watch-name').value='Disposable parity test';document.querySelector('#first-watch-password').value='Disposable-parity-test-2026';document.querySelector('#first-watch-confirm').value='Disposable-parity-test-2026';document.querySelector('#first-watch').click();true`);
  await until(()=>ev(ws,'!!document.querySelector("#swap")'),'home');
  const click=selector=>ev(ws,`document.querySelector(${JSON.stringify(selector)}).click();true`);
  for(const theme of ['midnight','hub21','glacier','neptune']){
    await ev(ws,`(async()=>{await chrome.runtime.sendMessage({channel:'wallet',command:'setSettings',settings:{theme:'${theme}'}});location.reload();return true})()`);
    await until(()=>ev(ws,'!!document.querySelector("#swap")'),'themed home');
    await click('#swap');await until(()=>ev(ws,'!!document.querySelector("#braid-open")'),'DEX menu');
    await click('#braid-open');await until(()=>ev(ws,'!!document.querySelector("[data-dex-picker=from]")&&!document.querySelector("#dex-content .loading")'),'Braid offscreen context');
    const error=await ev(ws,'document.querySelector("#dex-content .error")?.textContent??""');if(error)console.log('Host diagnostics',await ev(worker.webSocketDebuggerUrl,'(async()=>({senders:dexSenders,contexts:await chrome.runtime.getContexts({})}))()'));
    assert.equal(error,'');
    await click('[data-dex-picker=to]');assert.equal(await ev(ws,'document.querySelector("#dex-token-search").placeholder'),'Search ticker or covenant ID');
    await ev(ws,`document.querySelector('#dex-token-search').value='GUZA';document.querySelector('#dex-token-search').dispatchEvent(new Event('input'));true`);
    assert.equal(await ev(ws,'document.querySelectorAll("[data-dex-pick]").length'),1);await click('[data-dex-pick]');
    assert.match(await ev(ws,'document.querySelector("#dex-content").textContent'),/3cb7bd371ea2014af95f3471d2995ede8ffbde454d3a37e3b566880daf011c5a/);
    await click('#back');await until(()=>ev(ws,'!!document.querySelector("#swap")'),'back home');
    for(const venue of ['kforge','kasforge']){
      await click('#swap');await until(()=>ev(ws,`!!document.querySelector('#${venue}-open')`),venue+' menu item');await click('#'+venue+'-open');await until(()=>ev(ws,'document.querySelectorAll("[data-dex-token]").length>0&&!document.querySelector("#dex-content .loading")'),venue+' catalogue through offscreen bridge');
      await click('[data-dex-token]');await click('[data-dex-side=sell]');assert.equal(await ev(ws,'document.querySelectorAll(".token-detail.rocket-detail .rocket-side button").length'),2);assert.equal(await ev(ws,'document.querySelectorAll("[data-dex-percent]").length'),4);
      assert.equal(await ev(ws,'document.body.getBoundingClientRect().right<=innerWidth&&document.body.scrollWidth<=innerWidth&&document.querySelector("#dex-reload").getBoundingClientRect().right<=innerWidth'),true,theme+' '+venue+' viewport overflow');
      const shot=await cdp(ws,'Page.captureScreenshot',{format:'png'});await writeFile(join(output,(panel?'panel-':'popup-')+theme+'-'+venue+'.png'),Buffer.from(shot.data,'base64'));
      await click('#dex-back');await click('[data-dex-tab=activity]');assert.match(await ev(ws,'document.querySelector("#dex-content").textContent'),/Completed activity/);await click('#back');await until(()=>ev(ws,'!!document.querySelector("#swap")'),'home');
    }
  }
  // Exercise confirmation and recovery in the packaged renderer. Intercept the
  // wallet port for transaction actions: no signing or broadcast leaves this tab.
  await ev(ws,`(()=>{const connect=chrome.runtime.connect.bind(chrome.runtime);chrome.runtime.connect=options=>{
    if(options?.name!=='wallet-operation')return connect(options);
    let listener,port;return {onMessage:{addListener:f=>{listener=f;}},onDisconnect:{addListener(){}},disconnect(){port?.disconnect();},postMessage(m){
      if(m.command!=='dex'||!['quote','prepare','submit','status'].includes(m.action)){port=connect(options);port.onMessage.addListener(listener);port.postMessage(m);return;}
      const tokenId=m.args.tokenId??'a'.repeat(64),verified={tokens:'50',walletNet:'100000000',marketKas:'99000000',protocolFee:'1000000',networkFee:'0',cellReserveChange:'0'};
      const r=m.venue==='kforge'?{id:'b'.repeat(64),side:'buy',symbol:'KF',tokenId,verified,state:'confirmed'}:{buildId:'fixture-order',side:'buy',symbol:'FORGE',tokenId,amount:'1',state:'filled',finalVerified:m.action==='status',verifiedDetails:{tokenAmountRaw:'50',kasAmountSompi:'100000000'},transactionIds:['b'.repeat(64)],settlementId:'c'.repeat(64)};
      const result=m.action==='quote'?{id:'fixture-quote',review:{tradeSummary:{verified}},receiveTokens:'50',localAmount:m.args.amount,rawPlan:{fixture:true}}:m.action==='prepare'?{id:'fixture-order',reviews:[{feeSompi:'1000'}],rawPlan:{fixture:true}}:r;
      queueMicrotask(()=>listener({result}));
    }};
  };return true;})()`);
  for(const [venue,name] of [['kforge','KForge'],['kasforge','KasForge']]){
    await click('#swap');await until(()=>ev(ws,`!!document.querySelector('#${venue}-open')`),name+' menu');await click('#'+venue+'-open');await until(()=>ev(ws,'!!document.querySelector("[data-dex-token]:not(:disabled)")'),name+' catalogue');
    await click('[data-dex-token]');
    await ev(ws,`document.querySelector('#dex-amount').value='1';document.querySelector('#dex-amount').dispatchEvent(new Event('input'));true`);
    await click('#dex-quote');await until(()=>ev(ws,'!!document.querySelector("#dex-review:not(:disabled)")'),name+' quote');
    await click('#dex-review');await until(()=>ev(ws,'document.querySelector("#dex-submit")?.textContent==="Authorize & swap"'),name+' secure review');await click('#dex-submit');
    if(venue==='kasforge'){
      await until(()=>ev(ws,'!!document.querySelector("#dex-status:not(:disabled)")'),'unverified fill recovery');
      assert.equal(await ev(ws,'!!document.querySelector("#dex-content .receipt-check")'),false);await click('#dex-status');
    }
    await until(()=>ev(ws,'!!document.querySelector("#dex-content .receipt-check")'),name+' confirmed receipt');
    assert.match(await ev(ws,'document.querySelector("#dex-content").textContent'),new RegExp(name+' swap confirmed[\\s\\S]+50[\\s\\S]+Return to '+name));
    await click('#dex-return');await until(()=>ev(ws,'!!document.querySelector("[data-dex-token]:not(:disabled)")'),name+' return to catalogue');
    await click('#back');await until(()=>ev(ws,'!!document.querySelector("#swap")'),'home');
  }
  const calls=await ev(worker.webSocketDebuggerUrl,'dexCalls');assert(calls.some(c=>c.url.includes('api.kforge.xyz/v6/registry')));assert(calls.some(c=>c.url.includes('kaspa.pumpforge.tech/api/v1/markets')));assert(!calls.some(c=>c.method==='POST'));
  console.log(`Packaged ${panel?'360px Side Panel':'420px popup'}: Braid identity/search; KForge and KasForge catalogue, four sell presets, activity, confirmed and unverified receipts, Return buttons and all four themes passed. No signing/broadcast.`);
}finally{browser.kill('SIGTERM');await delay(500);await rm(scratch,{recursive:true,force:true});}
