// Actual packaged extension, public watch-only address, no signing or broadcast.
// A stalled *standard* balance must not hide earlier positives. Reopening joins
// the same scan, and progress after the former 30s UI deadline must still arrive.
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
const scratch=await mkdtemp(join(tmpdir(),'kaspire-standard-holdings-'));
const extension=process.argv[2]?join(scratch,'extension'):resolve('dist');
if(process.argv[2])execFileSync('unzip',['-q',resolve(process.argv[2]),'-d',extension]);
const output=resolve('artifacts/standard-kcc20-browser');await mkdir(output,{recursive:true});
const port=9361,endpoint=`http://127.0.0.1:${port}`;
const browser=spawn('chromium',['--headless=new','--no-sandbox','--disable-gpu','--no-first-run',`--user-data-dir=${join(scratch,'profile')}`,`--disable-extensions-except=${extension}`,`--load-extension=${extension}`,`--remote-debugging-port=${port}`,'about:blank'],{stdio:'ignore'});
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function targets(){return(await fetch(endpoint+'/json/list')).json();}
function cdp(ws,method,params={}){return new Promise((resolve,reject)=>{const socket=new WebSocket(ws),timer=setTimeout(()=>{socket.close();reject(Error(method+' timed out'));},15000);socket.onopen=()=>socket.send(JSON.stringify({id:1,method,params}));socket.onerror=reject;socket.onmessage=e=>{const value=JSON.parse(e.data);if(value.id!==1)return;clearTimeout(timer);socket.close();value.error?reject(Error(JSON.stringify(value.error))):resolve(value.result);};});}
async function evaluate(ws,expression){const value=await cdp(ws,'Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(value.exceptionDetails)throw Error(value.exceptionDetails.exception?.description??value.exceptionDetails.text);return value.result?.value;}
async function until(fn,label){for(let i=0;i<100;i++){try{const value=await fn();if(value)return value;}catch{}await delay(100);}throw Error('Missing '+label);}
async function open(url){return(await(await fetch(endpoint+'/json/new?'+encodeURIComponent(url),{method:'PUT'})).json());}
async function shot(ws,name){const value=await cdp(ws,'Page.captureScreenshot',{format:'png'});await writeFile(join(output,name+'.png'),Buffer.from(value.data,'base64'));}
try {
  const worker=await until(async()=>(await targets()).find(t=>t.type==='service_worker'),'extension worker');
  await evaluate(worker.webSocketDebuggerUrl,`(()=>{
    const original=globalThis.fetch,base='https://kasvio.network/api/kcc20/v4';
    const cid='82f033aed87d6eb39f509b51b1c817a49e0b07c4789b619cab08d4c8fb82d18e',slow='b'.repeat(64),late='e'.repeat(64),owner='3485c974d6e79b75c4ff130ee0cd20ab01b8118329837b2db8ed3b7275777df4';
    let release;const blocked=new Promise(resolve=>{release=resolve;});
    const fixture=globalThis.holdingsFixture={release,calls:[],started:0};
    const envelope=(data,extra={})=>new Response(JSON.stringify({data,meta:{network:'mainnet',reference_commit:null,adapter:'kcc20',source_run:'v4:browser-fixture',source_fingerprint:'1'.repeat(64),decoder_fingerprint:'2'.repeat(64),snapshot_id:'fixed'},...extra}),{headers:{'content-type':'application/json'}});
    globalThis.fetch=async(input,options)=>{
      const url=String(input);if(!url.startsWith(base+'/'))return original(input,options);
      fixture.calls.push(url);fixture.started||=Date.now();
      const u=new URL(url),path=u.pathname;
      if(path.includes('/addresses/'))return envelope([cid,slow,late].map((id,i)=>({covenant_id:id,owner_scheme:0,owner_value:owner,balance_raw:['59973229','1','123000000'][i],balance_complete:true})),{address_context:{network:'mainnet',address:decodeURIComponent(path.split('/').at(-2)),owner_scheme:0,owner_value:owner,balances_complete:true},pagination:{has_more:false}});
      if(path.endsWith('/'+slow))await blocked;
      const id=path.split('/').at(-1),i=[cid,slow,late].indexOf(id);
      if(i>=0)return envelope({covenant_id:id,profile_id:'KCC20PublicMint@c8a0871',recognition:'hash_proven_reference_actor_family',metadata:{binding_verified:true,ticker:['KASPIREISTHEBESTKASPAWALLET','SLOW','LATE'][i],decimals:8}});
      if(path.endsWith('/balance')){
        const id=path.split('/').at(-2);
        return envelope({covenant_id:id,owner_value:u.searchParams.get('owner'),owner_scheme:0,available:true,balance_raw:id===cid?'59973229':id===late?'123000000':'1',outputs:[]});
      }
      return new Response('{}',{status:404});
    };return true;
  })()`);
  let page=await open(new URL('wallet.html',worker.url).href),ws=page.webSocketDebuggerUrl;
  await until(()=>evaluate(ws,'!!document.querySelector("#first-watch")'),'watch onboarding');
  await evaluate(ws,`document.querySelector('#first-watch-address').value='kaspa:qq6gtjt56mnekawylufsacxdyz4srwq3sv5cx7edhrknkun4wa7lgt8fklfu0';document.querySelector('#first-watch-name').value='Public holdings fixture';document.querySelector('#first-watch-password').value='Disposable-watch-fixture-2026';document.querySelector('#first-watch-confirm').value='Disposable-watch-fixture-2026';document.querySelector('#first-watch').click();true`);
  const positive=`document.querySelector('#asset-list')?.textContent.includes('KASPIREISTHEBESTKASPAWALLET0.59973229')`;
  await until(()=>evaluate(ws,positive),'immediate exact Kaspire balance before tail completes');
  await evaluate(ws,`document.querySelector('details[data-category="kcc20"]').open=true;true`);
  await shot(ws,'early-positive');
  const first=await evaluate(worker.webSocketDebuggerUrl,'({elapsed:Date.now()-holdingsFixture.started,calls:holdingsFixture.calls.length})');
  assert(first.elapsed<10000,'A positive holding must not wait for the catalogue tail');
  console.log('Early exact balance:',JSON.stringify(first));
  await cdp(ws,'Page.close');
  page=await open(new URL('wallet.html',worker.url).href);ws=page.webSocketDebuggerUrl;
  await until(()=>evaluate(ws,positive),'reopened view replays the active discovery snapshot');
  // Keep the subsequent positive blocked past the original per-command timeout.
  const elapsed=await evaluate(worker.webSocketDebuggerUrl,'Date.now()-holdingsFixture.started');
  await delay(Math.max(0,32500-elapsed));
  assert(await evaluate(ws,positive),'Earlier positives survive the old timeout');
  assert.equal(await evaluate(ws,`document.querySelector('#asset-list')?.textContent.includes('temporarily unavailable')`),false);
  await evaluate(worker.webSocketDebuggerUrl,'holdingsFixture.release();true');
  await until(()=>evaluate(ws,`document.querySelector('#asset-list')?.textContent.includes('LATE1.23')`),'late balance past 30 seconds');
  await until(()=>evaluate(worker.webSocketDebuggerUrl,'holdingsFixture.calls.filter(url=>url.includes("/balance?")).length===3'),'activity origins complete');
  const counts=await evaluate(worker.webSocketDebuggerUrl,`({addresses:holdingsFixture.calls.filter(url=>url.includes('/addresses/')).length,balances:holdingsFixture.calls.filter(url=>url.includes('/balance?')).length})`);
  assert.deepEqual(counts,{addresses:1,balances:3},'Reopened views share the same address-scoped scan');
  await shot(ws,'reopened-and-complete');
  assert.equal(await evaluate(ws,`[...document.querySelectorAll('#asset-list .error')].some(el=>/KCC20/.test(el.textContent))`),false);
  console.log('Packaged Chromium holdings: early positive, reopen replay, post-30s progress, exact units and request coalescing passed.');
} finally {
  browser.kill('SIGTERM');await delay(700);await rm(scratch,{recursive:true,force:true});
}
