// Actual browser-action popup, not an emulated viewport or wallet browser tab.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
const profile=await mkdtemp(join(tmpdir(),'kaspire-popup-sizing-'));
const browser=spawn('chromium',['--headless=new','--no-sandbox','--disable-gpu',`--user-data-dir=${profile}`,`--disable-extensions-except=${resolve('dist')}`,`--load-extension=${resolve('dist')}`,'--remote-debugging-port=9340','about:blank'],{stdio:'ignore'});
const delay=ms=>new Promise(r=>setTimeout(r,ms));
async function targets(){return await(await fetch('http://127.0.0.1:9340/json/list')).json();}
async function evaluate(ws,expression){return new Promise((yes,no)=>{const socket=new WebSocket(ws),timer=setTimeout(()=>{socket.close();no(Error('CDP timeout'));},10000);socket.onopen=()=>socket.send(JSON.stringify({id:1,method:'Runtime.evaluate',params:{expression,userGesture:true,awaitPromise:true,returnByValue:true}}));socket.onmessage=event=>{const result=JSON.parse(event.data);if(result.id!==1)return;clearTimeout(timer);socket.close();if(result.error||result.result?.exceptionDetails)no(Error(JSON.stringify(result)));else yes(result.result.result.value);};socket.onerror=no;});}
try {
  let worker;
  for(let i=0;i<80&&!worker;i++){try{worker=(await targets()).find(t=>t.type==='service_worker');}catch{}if(!worker)await delay(100);}
  assert(worker,'Extension worker must load');
  // Settings are public preferences; no vault, seed or chain transaction is used.
  const tab=await(await fetch('http://127.0.0.1:9340/json/new?'+encodeURIComponent(new URL('wallet.html',worker.url).href),{method:'PUT'})).json();
  let baseline;
  for(const theme of ['midnight','neptune','midnight','neptune']) {
    const result=await evaluate(tab.webSocketDebuggerUrl,`chrome.runtime.sendMessage({channel:'wallet',command:'setSettings',settings:{theme:${JSON.stringify(theme)}}})`);
    assert.equal(result.result?.theme,theme,JSON.stringify(result));
    await evaluate(worker.webSocketDebuggerUrl,'chrome.action.openPopup().then(()=>true)');
    let popup;
    for(let i=0;i<50&&!popup;i++){popup=(await targets()).find(t=>t.type==='page'&&t.url.endsWith('/wallet.html')&&t.id!==tab.id);if(!popup)await delay(100);}
    assert(popup,'Real browser action popup must open');
    await delay(250);
    const dimensions=await evaluate(popup.webSocketDebuggerUrl,'({theme:document.documentElement.dataset.theme,width:innerWidth,height:innerHeight,body:document.body.getBoundingClientRect().width})');
    assert.equal(dimensions.theme,theme);
    baseline??=dimensions;
    // Chromium may add a scrollbar and cap popup height to the screen size.
    assert(dimensions.width>=420&&dimensions.width<=440,JSON.stringify(dimensions));
    assert.equal(dimensions.width,baseline.width);
    assert.equal(dimensions.body,420);
    assert(dimensions.height>=400,JSON.stringify(dimensions));
    assert.equal(dimensions.height,baseline.height);
    await fetch('http://127.0.0.1:9340/json/close/'+popup.id);
    await delay(150);
  }
  console.log('Actual Chromium action popup: repeated Neptune selection, persistence and 420px autosizing passed.');
} finally {
  browser.kill('SIGTERM');await new Promise(r=>{browser.once('exit',r);setTimeout(r,3000);});
  await rm(profile,{recursive:true,force:true,maxRetries:5,retryDelay:100});
}
