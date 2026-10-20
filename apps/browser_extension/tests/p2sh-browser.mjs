import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtemp, readFile, writeFile, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve, extname } from 'node:path';

const native = JSON.parse(execFileSync('cargo',['run','--locked','--quiet','-p','kaspa_secure_core','--example','hidden_browser_fixture'],{cwd:'../..',maxBuffer:2*1024*1024}).toString());
const profile = await mkdtemp(join(tmpdir(),'kaspire-p2sh-ui-')), output = resolve('artifacts/p2sh-ui'); await mkdir(output,{recursive:true});
const fixture = await readFile('tests/hub21-fixture.js','utf8') + `
const p2shNative=${JSON.stringify(native)};
fixtureState.settings.theme=new URLSearchParams(location.search).get('theme')??'midnight';
fixtureState.addresses=[{address:fixtureAddress,name:'Wallet',path:"m/44'/111111'/0'/0/0",watchOnly:false}];
window.p2shPrivate=false;window.p2shSigned=0;let p2shApproval=null,p2shResolve=null;
const baseMessage=chrome.runtime.sendMessage;
chrome.runtime.getURL=path=>new URL(path,location.href).href;
chrome.runtime.connect=()=>{const messages=[],closed=[];let done=false;return {onMessage:{addListener:fn=>messages.push(fn)},onDisconnect:{addListener:fn=>closed.push(fn)},postMessage:message=>{Promise.resolve(chrome.runtime.sendMessage(message)).then(result=>{if(!done)messages.forEach(fn=>fn(result));});},disconnect:()=>{if(!done){done=true;closed.forEach(fn=>fn());}}};};
chrome.runtime.sendMessage=async message=>{
 if(message.command==='receiveAccount')return {result:{primaryAddress:fixtureAddress,addresses:[],canRotate:false}};
 if(message.command==='p2shSupport')return {result:{supported:!window.p2shPrivate,message:'P2SH requires a seed-based HD wallet. An imported private key cannot generate this account.'}};
 if(message.command==='p2shState')return {result:{descriptor:'kip22-p2sh-v1',receiveCount:2,changeCount:0,exposed:[]}};
 if(message.command==='p2shRefresh')return {result:{state:{descriptor:'kip22-p2sh-v1',exposed:[]},balanceSompi:'2000000000',receive:p2shNative.addresses[0],transactions:[{transactionId:'e'.repeat(64),amountSompi:'2000000000',incoming:true}],activityError:''}};
 if(message.command==='p2shPrepare')return {result:{id:'p2sh-review',review:p2shNative.cases[message.sendAll?1:0].review}};
 if(message.command==='p2shSubmit'){p2shApproval={id:'p2sh-approval',origin:'Kaspire Wallet',title:'Review P2SH payment',description:'Rebuilt by the local Rust core',details:['Verify recipient and network fee'],rawJson:{descriptor:'kip22-p2sh-v1'}};return new Promise(resolve=>{p2shResolve=resolve;});}
 if(message.command==='pendingApproval')return {result:p2shApproval};
 if(message.command==='resolveWalletApproval'){p2shApproval=null;if(message.approved){window.p2shSigned++;p2shResolve({result:{confirmed:true,transactionId:p2shNative.cases[0].saved.transactionId}});}else p2shResolve({error:{message:'Payment rejected. Nothing was signed.'}});return {result:true};}
 return baseMessage(message);
};
`;
const server=createServer(async(req,res)=>{
 try {
  const path=new URL(req.url,'http://localhost').pathname;
  if(path==='/fixture.js'){res.setHeader('Content-Type','text/javascript');res.end(fixture);return;}
  const file=resolve('dist','.'+path);if(!file.startsWith(resolve('dist')+'/')){res.writeHead(403);res.end();return;}
  let content=await readFile(file);if(file.endsWith('.html'))content=content.toString().replace('<script type="module"','<script src="/fixture.js"></script><script type="module"');
  res.setHeader('Content-Type',({'.html':'text/html','.js':'text/javascript','.css':'text/css','.png':'image/png'})[extname(file)]??'application/octet-stream');res.end(content);
 }catch{res.writeHead(404);res.end();}
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const browser=spawn('chromium',['--headless=new','--no-sandbox','--disable-gpu','--disable-background-networking',`--user-data-dir=${profile}`,'--remote-debugging-port=9354','about:blank'],{stdio:'ignore'});
const delay=ms=>new Promise(r=>setTimeout(r,ms));let ws;
function cdp(method,params={}){return new Promise((resolve,reject)=>{const socket=new WebSocket(ws),timer=setTimeout(()=>{socket.close();reject(Error('CDP timeout '+method));},15000);socket.onopen=()=>socket.send(JSON.stringify({id:1,method,params}));socket.onerror=reject;socket.onmessage=e=>{const m=JSON.parse(e.data);if(m.id!==1)return;clearTimeout(timer);socket.close();m.error?reject(Error(JSON.stringify(m.error))):resolve(m.result);};});}
async function evaluate(expression){const r=await cdp('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true,userGesture:true});if(r.exceptionDetails)throw Error(r.exceptionDetails.exception?.description??r.exceptionDetails.text);return r.result.value;}
async function waitFor(expression){for(let i=0;i<100;i++){if(await evaluate(expression))return;await delay(60);}throw Error('UI not ready: '+expression);}
const click=selector=>evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);
async function dimensions(){const r=await evaluate(`({viewport:innerWidth,width:document.body.clientWidth,scroll:document.body.scrollWidth,height:document.querySelector('.app').clientHeight,overflow:[...document.querySelectorAll('.p2sh-tabs,.vault-panel,dialog[open]')].filter(e=>e.scrollWidth>e.clientWidth+2).map(e=>e.className)})`);assert(r.width<=r.viewport,JSON.stringify(r));assert.equal(r.width,r.scroll,JSON.stringify(r));assert.equal(r.overflow.length,0,JSON.stringify(r));assert(r.height>=500,JSON.stringify(r));}
async function fill(selector,text){await evaluate(`{const input=document.querySelector(${JSON.stringify(selector)});input.value=${JSON.stringify(text)};input.dispatchEvent(new Event('input',{bubbles:true}));}`);}
try {
 let targets;for(let i=0;i<80;i++){try{targets=await(await fetch('http://127.0.0.1:9354/json/list')).json();break;}catch{await delay(100);}}
 ws=targets.find(t=>t.type==='page').webSocketDebuggerUrl;
 for(const theme of ['midnight','hub21','glacier','neptune']) {
  await cdp('Emulation.setDeviceMetricsOverride',{width:420,height:760,deviceScaleFactor:1,mobile:false});
  await cdp('Page.navigate',{url:`http://127.0.0.1:${server.address().port}/wallet.html?theme=${theme}`});
  await waitFor('!!document.querySelector("#receive")');await click('#receive');await waitFor('!!document.querySelector("#receive-p2sh")');
  assert(await evaluate('Boolean(document.querySelector("#receive-qr"))'));assert.equal(await evaluate('Boolean(document.querySelector("#p2sh-content"))'),false);
  const regularWidth = await evaluate('document.body.getBoundingClientRect().width');
  // Reproduce Chrome/Opera reporting a narrower viewport during popup sizing.
  // Switching panels must not turn that transient value into a smaller body.
  await cdp('Emulation.setDeviceMetricsOverride',{width:320,height:760,deviceScaleFactor:1,mobile:false});
  await click('#receive-p2sh');await waitFor('!!document.querySelector("#p2sh-accept")&&!document.querySelector("#p2sh-progress")');
  assert.equal(await evaluate('document.body.getBoundingClientRect().width'), regularWidth, theme+' P2SH must not resize the popup');
  await cdp('Emulation.setDeviceMetricsOverride',{width:420,height:760,deviceScaleFactor:1,mobile:false});
  assert.equal(await evaluate('/draft|experimental format|Test with small amounts/.test(document.querySelector("#p2sh-content").innerText)'),false);
  await dimensions();await click('#p2sh-accept');await waitFor('!!document.querySelector("#p2sh-max")&&!document.querySelector("#p2sh-progress")');
  await waitFor('!!document.querySelector("#p2sh-qr")?.src');await dimensions();
  const image=await cdp('Page.captureScreenshot',{format:'png'});await writeFile(join(output,theme+'.png'),Buffer.from(image.data,'base64'));
  await click('#p2sh-max');assert.equal(await evaluate('document.querySelector("#p2sh-amount").readOnly'),true);
  await fill('#p2sh-recipient',native.cases[0].request.recipient);await click('#p2sh-review');await waitFor('!!document.querySelector("#p2sh-submit")&&!document.querySelector("#p2sh-progress")');await dimensions();
  assert.equal(await evaluate('window.p2shSigned'),0);await click('#p2sh-submit');await waitFor('!!document.querySelector("#reject-approval")');await click('#reject-approval');
  await waitFor('!!document.querySelector("#p2sh-content [role=alert]")');assert.equal(await evaluate('window.p2shSigned'),0);
  await click('#p2sh-refresh');await waitFor('!!document.querySelector("#p2sh-max")&&!document.querySelector("#p2sh-progress")');
  await click('#p2sh-review');await waitFor('!!document.querySelector("#p2sh-submit")&&!document.querySelector("#p2sh-progress")');await click('#p2sh-submit');await waitFor('!!document.querySelector("#accept-approval")');await click('#accept-approval');await waitFor('!!document.querySelector("#p2sh-return")&&!document.querySelector("#p2sh-progress")');
  assert.equal(await evaluate('window.p2shSigned'),1);assert.match(await evaluate('document.querySelector("#p2sh-content").innerText'),/Payment confirmed by the Kaspire node/);
  await click('#receive-regular');await waitFor('!!document.querySelector("#receive-qr")');
  assert.equal(await evaluate('document.body.getBoundingClientRect().width'), regularWidth, theme+' regular Receive must keep its width');
  await evaluate('window.p2shPrivate=true');await click('#receive-p2sh');await waitFor('document.querySelector("#p2sh-content")?.innerText.includes("Seed-based HD wallet required")');assert.equal(await evaluate('!!document.querySelector("#p2sh-accept")'),false);
  console.log('P2SH Chromium layout, Max, rejection, receipt, private-key guidance: '+theme);
 }
} finally {browser.kill('SIGTERM');await new Promise(r=>server.close(r));await delay(150);await rm(profile,{recursive:true,force:true});}
