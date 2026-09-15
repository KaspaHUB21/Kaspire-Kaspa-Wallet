import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp,readFile,writeFile,mkdir,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve,extname} from 'node:path';

const profile=await mkdtemp(join(tmpdir(),'kaspire-hub21-ui-'));
const output=resolve('artifacts/hub21-ui'); await mkdir(output,{recursive:true});
const server=createServer(async(req,res)=>{
  try {
    const path=decodeURIComponent(new URL(req.url,'http://localhost').pathname);
    if(path==='/fixture.js'){res.setHeader('Content-Type','text/javascript');res.end(await readFile('tests/hub21-fixture.js'));return;}
    const file=resolve('dist',`.${path==='/'?'/wallet.html':path}`);
    if(!file.startsWith(resolve('dist')+'/')){res.writeHead(403);res.end();return;}
    let content=await readFile(file);
    if(file.endsWith('.html'))content=content.toString().replace('<script type="module"','<script src="/fixture.js"></script><script type="module"');
    res.setHeader('Content-Type',({'.html':'text/html','.css':'text/css','.js':'text/javascript','.png':'image/png'})[extname(file)]??'application/octet-stream');res.end(content);
  } catch {res.writeHead(404);res.end();}
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const browser=spawn('chromium',['--headless=new','--no-sandbox','--disable-gpu','--disable-background-networking',`--user-data-dir=${profile}`,'--remote-debugging-port=9336','about:blank'],{stdio:'ignore'});
const delay=ms=>new Promise(r=>setTimeout(r,ms));
let ws;
async function cdp(method,params={}) {
  return new Promise((resolve,reject)=>{
    const socket=new WebSocket(ws);const timeout=setTimeout(()=>{socket.close();reject(Error('CDP timeout'))},10000);
    socket.onopen=()=>socket.send(JSON.stringify({id:1,method,params}));
    socket.onmessage=event=>{const value=JSON.parse(event.data);if(value.id!==1)return;clearTimeout(timeout);socket.close();if(value.error)reject(Error(JSON.stringify(value.error)));else resolve(value.result)};
    socket.onerror=reject;
  });
}
async function evaluate(expression){const value=await cdp('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(value.exceptionDetails)throw Error(value.exceptionDetails.text);return value.result.value;}
async function waitFor(expression){for(let i=0;i<60;i++){if(await evaluate(expression))return;await delay(100)}throw Error(`Not ready: ${expression}`)}
async function shot(name){await delay(150);const png=await cdp('Page.captureScreenshot',{format:'png'});await writeFile(join(output,name+'.png'),Buffer.from(png.data,'base64'));}
async function click(selector){await evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);await delay(100);}
try {
  for(let i=0;i<80;i++){try{const targets=await(await fetch('http://127.0.0.1:9336/json/list')).json();ws=targets.find(x=>x.type==='page')?.webSocketDebuggerUrl;if(ws)break;}catch{}await delay(100)}
  assert(ws,'Chromium unavailable');
  await cdp('Emulation.setDeviceMetricsOverride',{width:420,height:700,deviceScaleFactor:2,mobile:false});
  await cdp('Page.navigate',{url:`http://127.0.0.1:${server.address().port}/wallet.html`});
  await waitFor('document.querySelectorAll(".asset-group").length===5');
  const ordered=await evaluate(`Array.from(document.querySelectorAll('.asset-group')).map(g=>({category:g.dataset.category,values:Array.from(g.querySelectorAll('.asset-row b,.kns-chips button')).map(e=>e.textContent.trim().replace(/^◎ /,''))}))`);
  assert.deepEqual(ordered.map(x=>x.values),[['BURTLE','KASBTC','ZULU'],['ALPHA','BURTLE','ZETA'],['ANGELS','BURTLE','ZOMBIES'],['alpha.kas','beta.kas','zulu.kas'],['alpha.k','zulu.k']]);
  const geometry=await evaluate(`['#top-lock','#settings','#copy-main-address','#network'].map(s=>{const e=document.querySelector(s),r=e.getBoundingClientRect(),icon=e.querySelector('svg')?.getBoundingClientRect();return {width:r.width,height:r.height,x:r.x,y:r.y,centered:!icon||(Math.abs((icon.x+icon.width/2)-(r.x+r.width/2))<1&&Math.abs((icon.y+icon.height/2)-(r.y+r.height/2))<1)}})`);
  assert.deepEqual(geometry.map(x=>[x.width,x.height]),[[38,38],[38,38],[38,38],[76,38]]);
  assert(geometry.every(x=>x.centered));
  assert.equal(geometry[3].x-(geometry[2].x+38),5);
  assert.equal(geometry[1].x-(geometry[3].x+76),5);
  assert.equal(geometry[1].y,geometry[2].y);
  assert.match(await evaluate(`getComputedStyle(document.querySelector('.balance-card')).backgroundImage`), /196, 147, 34/);
  await shot('home');
  await evaluate(`document.querySelector('[data-category="dotk"]').open=true`);
  assert.deepEqual(await evaluate(`Array.from(document.querySelectorAll('[data-category="dotk"] .asset-row b')).map(x=>x.textContent)`),['alpha.k','zulu.k']);
  await click('[data-group="dotk"][data-index="0"]');
  await waitFor('document.querySelector("#dotk-proof")?.textContent.includes("Ownership verified")');
  assert.equal(await evaluate('document.querySelector("#dotk-detail h1").textContent'),'alpha.k');
  assert.equal(await evaluate('Boolean(document.querySelector("#send-token"))'),false);
  await shot('dotk');
  await cdp('Page.reload');await waitFor('document.querySelectorAll(".asset-group").length===5');
  await evaluate(`document.querySelector('#copy-main-address').dispatchEvent(new MouseEvent('mouseenter'))`);await delay(100);
  assert.equal(await evaluate(`getComputedStyle(document.querySelector('.address-verification')).display`),'block');
  await evaluate(`document.querySelector('#copy-main-address').dispatchEvent(new MouseEvent('mouseleave'))`);
  assert.equal(await evaluate(`getComputedStyle(document.querySelector('.address-verification')).display`),'none');
  await evaluate(`document.querySelector('[data-category="krc20"]').open=true`);
  await click('[data-group="krc20"][data-index="1"]');await waitFor('document.querySelector("#floor-kas")?.textContent.includes("0.869")');
  assert.equal(await evaluate(`document.querySelector('.token-detail h1').textContent`),'KASBTC');
  assert.match(await evaluate(`document.querySelector('.token-detail > p').textContent`),/KASBTC/);
  await shot('token');await click('#send-token');
  assert.equal(await evaluate(`document.querySelector('#asset-select').selectedOptions[0].textContent`),'KASBTC');
  await shot('send');
  await cdp('Page.reload');await waitFor('document.querySelectorAll(".asset-group").length===5');
  await evaluate(`document.querySelector('[data-category="kcc20"]').open=true`);await click('[data-group="kcc20"][data-index="1"]');
  assert.equal(await evaluate(`document.querySelector('#asset-select').selectedOptions[0].textContent`),'BURTLE');
  assert.equal(await evaluate(`document.querySelector('.send-screen h1').textContent`),'Send BURTLE');
  await cdp('Page.reload');await waitFor('document.querySelectorAll(".asset-group").length===5');
  await evaluate(`document.querySelector('[data-category="krc721"]').open=true`);await click('[data-group="krc721"][data-index="1"]');
  assert.equal(await evaluate(`document.querySelector('.nft-screen h1').textContent`),'BURTLE NFTs');
  await cdp('Page.reload');await waitFor('document.querySelectorAll(".asset-group").length===5');
  await evaluate(`document.querySelector('[data-category="kns"]').open=true`);await click('[data-group="kns"][data-index="1"]');
  assert.equal(await evaluate(`document.querySelector('.send-screen h1').textContent`),'Send beta.kas');
  assert.equal(await evaluate(`document.querySelector('#asset-select').selectedOptions[0].textContent`),'beta.kas');
  await cdp('Page.reload');await waitFor('!!document.querySelector("#receive")');await click('#receive');await waitFor('document.querySelector("#receive-qr")?.complete');await shot('receive');
  await click('#back');await waitFor('!!document.querySelector("#settings")');await click('#settings');await shot('settings');
  await click('[data-view="display"]');assert.equal(await evaluate(`document.querySelector('#theme').value`),'hub21');
  await evaluate(`const select=document.querySelector('#theme');select.value='midnight';select.dispatchEvent(new Event('change'))`);await waitFor('document.documentElement.dataset.theme==="midnight"');
  await click('#back');await waitFor('!!document.querySelector("#balance")');await shot('midnight');
  await click('#network');await click('[data-network="igra"]');await waitFor('document.querySelector("#balance")?.textContent.includes("iKAS")');
  assert.deepEqual(await evaluate(`Array.from(document.querySelectorAll('.asset-row b')).map(x=>x.textContent)`),['ALPHA','ZED']);
  console.log('HUB21 browser checks passed: sorting, case, dimensions, icon alignment, tooltip lifecycle, token/send/receive/settings, theme persistence and L2 sorting.');
} finally {
  browser.kill('SIGTERM');await new Promise(r=>{browser.once('exit',r);setTimeout(r,3000)});server.close();await rm(profile,{recursive:true,force:true,maxRetries:5,retryDelay:100});
}
