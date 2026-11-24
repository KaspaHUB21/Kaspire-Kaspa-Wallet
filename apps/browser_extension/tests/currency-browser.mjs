// Exercise actual option values, event handlers, MV3 storage and fiat rendering
// in the packaged action popup and real Side Panel. No live network or signing.
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtemp,mkdir,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import init,* as raw from './generated/wasm/kaspa_secure_core.mjs';
import {secureCore} from './generated/secretInputs.mjs';
const wasm=await init({module_or_path:await readFile(new URL('./generated/wasm/kaspa_secure_core_bg.wasm',import.meta.url))});
const address=JSON.parse(secureCore(raw,wasm.memory).importWallet('abandon '.repeat(11)+'about','')).address;
const password='Currency display testing only 2026!';
const codes=['USD','EUR','GBP','AUD','CAD','JPY','CNY','CHF','INR','BRL','KRW'];
const rates={USD:1,EUR:.9,GBP:.8,AUD:1.5,CAD:1.4,JPY:150,CNY:7.2,CHF:.95,INR:83,BRL:5,KRW:1300};
const root=resolve(process.env.KASPIRE_CURRENCY_ARTIFACTS_DIR??'artifacts/currency');await mkdir(root,{recursive:true});
const scratch=await mkdtemp(join(tmpdir(),'kaspire-currency-')),extension=join(scratch,'extension'),port=9394;
execFileSync('unzip',['-q',resolve(process.argv[2]),'-d',extension]);
const pause=ms=>new Promise(r=>setTimeout(r,ms));
const xvfb=spawn('Xvfb',[':119','-screen','0','1366x900x24','-nolisten','tcp'],{stdio:'ignore'});await pause(600);
const launch=()=>spawn('chromium',['--no-sandbox','--disable-gpu','--no-first-run','--window-size=1366,900',`--user-data-dir=${join(scratch,'profile')}`,`--disable-extensions-except=${extension}`,`--load-extension=${extension}`,`--remote-debugging-port=${port}`,'about:blank'],{stdio:'ignore',env:{...process.env,DISPLAY:':119'}});
let browser=launch(),worker,base,anchor,ui,browserWs;
const targets=async()=> (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
function cdp(ws,method,params={}){return new Promise((yes,no)=>{const s=new WebSocket(ws),timer=setTimeout(()=>{s.close();no(Error('CDP timed out: '+method));},40000);s.onopen=()=>s.send(JSON.stringify({id:1,method,params}));s.onerror=no;s.onmessage=e=>{const r=JSON.parse(e.data);if(r.id!==1)return;clearTimeout(timer);s.close();r.error?no(Error(JSON.stringify(r.error))):yes(r.result);};});}
async function ev(ws,expression){const r=await cdp(ws,'Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true,userGesture:true});if(r.exceptionDetails)throw Error(r.exceptionDetails.exception?.description??r.exceptionDetails.text);return r.result?.value;}
async function until(fn,label){for(let n=0;n<160;n++){try{const v=await fn();if(v)return v;}catch{}await pause(100);}throw Error('Missing '+label);}
async function open(url){return(await(await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(url)}`,{method:'PUT'})).json()).webSocketDebuggerUrl;}
async function rpc(command,args={},page=ui){const r=await ev(page,`chrome.runtime.sendMessage(${JSON.stringify({channel:'wallet',command,...args})})`);if(r.error)throw Error(r.error.message);return r.result;}
async function setupWorker(){
 const w=await until(async()=> (await targets()).find(t=>t.type==='service_worker'),'worker');worker=w.webSocketDebuggerUrl;base='chrome-extension://'+new URL(w.url).host+'/';browserWs=(await(await fetch(`http://127.0.0.1:${port}/json/version`)).json()).webSocketDebuggerUrl;
 await until(()=>ev(worker,'typeof chrome!=="undefined"&&!!chrome.storage?.local'),'worker extension APIs');
 await ev(worker,`(()=>{const original=fetch;globalThis.fxFailed=false;globalThis.fxDelay=0;globalThis.fxWrites=[];globalThis.fxCalls=[];globalThis.fxSaveDelay=0;const set=chrome.storage.local.set.bind(chrome.storage.local);chrome.storage.local.set=async value=>{if('walletCurrencyPreferenceV1'in value){fxWrites.push(value.walletCurrencyPreferenceV1);if(fxSaveDelay)await new Promise(r=>setTimeout(r,fxSaveDelay));}return set(value)};globalThis.fetch=async(input,options={})=>{const u=new URL(String(input));if(u.protocol!=='https:')return original(input,options);fxCalls.push({url:u.href,method:options.method??'GET'});if((options.method??'GET')!=='GET')throw Error('No live transaction permitted');if(u.host==='open.er-api.com'){if(fxDelay)await new Promise(r=>setTimeout(r,fxDelay));return Response.json({rates:${JSON.stringify(rates)}},{status:fxFailed?503:200});}if(u.pathname.endsWith('/info/price'))return Response.json({price:.03});if(u.pathname.endsWith('/balance'))return Response.json({balance:10000000000});if(u.pathname.endsWith('/utxos')||u.pathname.includes('/full-transactions'))return Response.json([]);return Response.json({},{status:503});};return true;})()`);
}
async function home(page=ui){await cdp(page,'Page.reload');await until(()=>ev(page,'!!document.querySelector("#settings")'),'home');}
async function display(page=ui){if(!await ev(page,'!!document.querySelector("#currency")')){if(!await ev(page,'!!document.querySelector("[data-view=display]")')){await home(page);await ev(page,'document.querySelector("#settings").click();true');}await until(()=>ev(page,'!!document.querySelector("[data-view=display]")'),'display link');await ev(page,'document.querySelector("[data-view=display]").click();true');}await until(()=>ev(page,'!!document.querySelector("#currency")'),'currency selector');}
async function pick(code,page=ui){await display(page);await ev(page,`(()=>{const s=document.querySelector('#currency');s.value=${JSON.stringify(code)};s.dispatchEvent(new Event('change',{bubbles:true}));return true;})()`);await until(async()=> (await rpc('status',{},page)).settings.currency===code,'saved '+code);await until(()=>ev(page,'!!document.querySelector("#currency:not(:disabled)")'),'saved selector');assert.equal(await ev(page,'document.querySelector("#currency").value'),code);}
async function fiat(code,page=ui){await home(page);const expected=new Intl.NumberFormat('en-US',{style:'currency',currency:code}).format(3*rates[code]);await until(()=>ev(page,'document.querySelector("#fiat")?.textContent.includes('+JSON.stringify(expected)+')'),'converted '+code+' '+expected);}
async function actualPopup(){const before=(await targets()).map(t=>t.id);await ev(worker,'chrome.action.openPopup().then(()=>true)');const t=await until(async()=> (await targets()).find(t=>t.url===base+'wallet.html'&&!before.includes(t.id)),'real popup');ui=t.webSocketDebuggerUrl;await until(()=>ev(ui,'!!document.querySelector("#settings")'),'popup loaded');return t;}
async function close(t){await cdp(browserWs,'Target.closeTarget',{targetId:t.id});}
const checks=[];
try{
 await setupWorker();anchor=await open(base+'wallet.html');ui=anchor;
 // Let the initial status/render finish before creating the watch vault. A
 // concurrent initial status call can correctly lock an uninitialized session.
 await until(()=>ev(ui,'!!document.querySelector("#first-create")'),'onboarding ready');
 await rpc('createWatch',{address,password,name:'Currency test watch wallet'});await home();
 await display();
 const options=await ev(ui,'[...document.querySelector("#currency").options].map(o=>({text:o.textContent,value:o.value}))');
 if(process.env.KASPIRE_CURRENCY_REPRO==='1'){
  assert.equal(options[1].value,'Eur');await ev(ui,'document.querySelector("#currency").selectedIndex=1;document.querySelector("#currency").dispatchEvent(new Event("change",{bubbles:true}));true');await pause(500);assert.equal((await rpc('status')).settings.currency,'USD');
  await writeFile(join(root,'reproduction.json'),JSON.stringify({options,selectedDisplay:'Eur',stored:(await rpc('status')).settings.currency},null,2));console.log('Reproduced actual UI: EUR text/value becomes Eur, selection is silently ignored and USD remains.');
 }else{
  assert.deepEqual(options,codes.map(code=>({text:code,value:code})));
  for(const surface of ['popup','panel']){
   let target;
   if(surface==='popup')target=await actualPopup();
   else{await home(anchor);await ev(anchor,'document.querySelector("#dual-window").click();true');target=await until(async()=> (await targets()).find(t=>t.url.startsWith(base+'sidepanel.html?view=')),'real Side Panel');ui=target.webSocketDebuggerUrl;await until(()=>ev(ui,'document.documentElement.dataset.panelApprovalReady==="true"'),'panel ready');}
   for(const code of codes){await pick(code);await fiat(code);await display();assert.equal(await ev(ui,'document.querySelector("#currency").value'),code);}
   await pick('EUR');await fiat('EUR');const picture=await cdp(ui,'Page.captureScreenshot',{format:'png'});await writeFile(join(root,'currency-'+surface+'.png'),Buffer.from(picture.data,'base64'));
   await close(target);await home(anchor);await display(anchor);assert.equal(await ev(anchor,'document.querySelector("#currency").value'),'EUR');
   checks.push(surface+': all 11 real selector events persist, converted amounts render, screen reentry and closure preserve choice.');
  }
  ui=anchor;await display();const bad=await ev(ui,'chrome.runtime.sendMessage({channel:"wallet",command:"setSettings",settings:{currency:"Eur"}})');assert.match(bad.error.message,/Unsupported display currency/);assert.equal((await rpc('status')).settings.currency,'EUR');
  await ev(worker,'fxSaveDelay=600;true');await display();await ev(ui,'document.querySelector("#currency").value="GBP";document.querySelector("#currency").dispatchEvent(new Event("change",{bubbles:true}));document.querySelector("#back").click();true');await until(async()=> (await rpc('status')).settings.currency==='GBP','slow save');await home();await fiat('GBP');await ev(worker,'fxSaveDelay=0;fxFailed=true;true');
  await pick('JPY');await home();await display();assert.equal(await ev(ui,'document.querySelector("#currency").value'),'JPY');await ev(worker,'fxFailed=false;true');await fiat('JPY');
  const old=await ev(ui,'chrome.storage.local.get("walletState").then(r=>r.walletState)');old.settings.currency='USD';await ev(ui,`chrome.storage.local.set({walletState:${JSON.stringify(old)}})`);assert.equal((await rpc('status')).settings.currency,'JPY');await display();assert.equal(await ev(ui,'document.querySelector("#currency").value'),'JPY');
  await rpc('lock');await rpc('unlock',{password});await home();await display();assert.equal(await ev(ui,'document.querySelector("#currency").value'),'JPY');
  checks.push('Invalid mixed-case requests reject visibly; delayed writes, navigation during saving, FX failure, stale wallet saves, lock/unlock retain the selected code.');
  const stopped=new Promise(r=>browser.once('exit',r));browser.kill('SIGTERM');await stopped;await pause(400);browser=launch();await setupWorker();ui=await open(base+'wallet.html');await until(()=>rpc('status'),'restarted worker');assert.equal((await rpc('status')).settings.currency,'JPY');await rpc('unlock',{password});await fiat('JPY');await display();assert.equal(await ev(ui,'document.querySelector("#currency").value'),'JPY');
  assert((await ev(worker,'fxCalls')).every(c=>c.method==='GET'));
  checks.push('Full browser/worker restart retains JPY and conversion; only intercepted GET reads, no live payments.');
  await writeFile(join(root,'report.json'),JSON.stringify({passed:true,version:await ev(ui,'chrome.runtime.getManifest().version'),checks},null,2));console.log('Packaged UI currency checks passed:',checks);
 }
}catch(e){if(ui){const shot=await cdp(ui,'Page.captureScreenshot',{format:'png'}).catch(()=>null);if(shot)await writeFile(join(root,'failure.png'),Buffer.from(shot.data,'base64'));}throw e;}
finally{const stopped=new Promise(r=>browser.once('exit',r));browser.kill('SIGTERM');await stopped;await pause(400);xvfb.kill('SIGTERM');await rm(scratch,{recursive:true,force:true,maxRetries:8,retryDelay:150});}
