import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,rm,mkdir,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
const profile=await mkdtemp(join(tmpdir(),'kaspire-side-panel-'));
const port=9350,display=':83';
const xvfb=spawn('Xvfb',[display,'-screen','0','1366x900x24','-nolisten','tcp'],{stdio:'ignore'});
const delay=ms=>new Promise(r=>setTimeout(r,ms));
await delay(250);
const browser=spawn('chromium',['--no-sandbox','--disable-gpu','--no-first-run','--no-default-browser-check',`--user-data-dir=${profile}`,`--disable-extensions-except=${resolve('dist')}`,`--load-extension=${resolve('dist')}`,`--remote-debugging-port=${port}`,'--window-size=1366,900','about:blank'],{stdio:'ignore',env:{...process.env,DISPLAY:display}});
let browserSocket;
async function targets(){return(await fetch(`http://127.0.0.1:${port}/json/list`)).json();}
function cdp(ws,method,params={}){return new Promise((resolveValue,reject)=>{
  const socket=new WebSocket(ws),timer=setTimeout(()=>{socket.close();reject(Error('CDP timeout: '+method));},15000);
  socket.onopen=()=>socket.send(JSON.stringify({id:1,method,params}));socket.onerror=reject;
  socket.onmessage=event=>{const m=JSON.parse(event.data);if(m.id!==1)return;clearTimeout(timer);socket.close();m.error?reject(Error(JSON.stringify(m.error))):resolveValue(m.result);};
});}
async function evaluate(ws,expression,userGesture=false){const r=await cdp(ws,'Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true,userGesture});if(r.exceptionDetails)throw Error(r.exceptionDetails.exception?.description??r.exceptionDetails.text);return r.result?.value;}
async function until(test,label){for(let i=0;i<100;i++){try{const value=await test();if(value)return value;}catch{}await delay(100);}throw Error('Not ready: '+label);}
try{
  const worker=await until(async()=> (await targets()).find(t=>t.type==='service_worker'),'extension worker');
  const id=new URL(worker.url).host,base=`chrome-extension://${id}/`;
  browserSocket=(await(await fetch(`http://127.0.0.1:${port}/json/version`)).json()).webSocketDebuggerUrl;
  const wallet=(await(await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(base+'wallet.html')}`,{method:'PUT'})).json()).webSocketDebuggerUrl;
  await until(()=>evaluate(wallet,'!!document.querySelector("#dual-window:not(:disabled)")'),'dual-window button');
  const initial=await evaluate(wallet,'(async()=>({popup:chrome.runtime.getManifest().action.default_popup,path:(await chrome.sidePanel.getOptions({})).path,behavior:await chrome.sidePanel.getPanelBehavior(),panels:await chrome.runtime.getContexts({contextTypes:["SIDE_PANEL"]})}))()');
  assert.equal(initial.popup,'wallet.html');assert.equal(initial.path,'sidepanel.html');assert.notEqual(initial.behavior.openPanelOnActionClick,true);assert.equal(initial.panels.length,0);
  await evaluate(wallet,'document.querySelector("#dual-window").click();true',true);
  const panel=await until(async()=> (await targets()).find(t=>t.url.startsWith(base+'sidepanel.html?view=')),'actual Chrome side panel');
  await until(()=>evaluate(panel.webSocketDebuggerUrl,'!!document.querySelector("#dual-window:not(:disabled)")'),'panel UI');
  assert.equal(await evaluate(panel.webSocketDebuggerUrl,'document.documentElement.classList.contains("side-panel")'),true);
  assert.equal(await evaluate(panel.webSocketDebuggerUrl,'document.querySelector("#dual-window").getAttribute("aria-pressed")'),'true');
  const contexts=await evaluate(wallet,'chrome.runtime.getContexts({contextTypes:["SIDE_PANEL"]})');assert.equal(contexts.length,1);
  // No automatic toolbar conversion, even after explicit panel opening.
  assert.notEqual((await evaluate(wallet,'chrome.sidePanel.getPanelBehavior()')).openPanelOnActionClick,true);
  const realHeight=await evaluate(panel.webSocketDebuggerUrl,'({viewport:innerHeight,app:document.querySelector(".app").getBoundingClientRect().height})');
  assert.ok(Math.abs(realHeight.viewport-realHeight.app)<=1,JSON.stringify(realHeight));
  const box=await evaluate(panel.webSocketDebuggerUrl,'({width:innerWidth,body:document.body.getBoundingClientRect().width,scroll:document.documentElement.scrollWidth})');
  assert.ok(Math.abs(box.body-box.width)<=1,JSON.stringify(box));assert.ok(box.scroll<=box.width+1,JSON.stringify(box));
  const screenshot=await cdp(panel.webSocketDebuggerUrl,'Page.captureScreenshot',{format:'png'});
  await mkdir('artifacts/side-panel',{recursive:true});await writeFile('artifacts/side-panel/chrome-side-panel.png',Buffer.from(screenshot.data,'base64'));
  await evaluate(panel.webSocketDebuggerUrl,'document.querySelector("#dual-window").click();true',true);
  await until(async()=>!(await evaluate(wallet,'chrome.runtime.getContexts({contextTypes:["SIDE_PANEL"]})')).length,'side panel closed');
  console.log('Chrome side panel: opt-in opening, unchanged popup default, actual SIDE_PANEL context, native browser dimensions and explicit close passed.');
}finally{
  if(browserSocket)await cdp(browserSocket,'Browser.close').catch(()=>{});
  browser.kill('SIGTERM');xvfb.kill('SIGTERM');await delay(300);await rm(profile,{recursive:true,force:true});
}
