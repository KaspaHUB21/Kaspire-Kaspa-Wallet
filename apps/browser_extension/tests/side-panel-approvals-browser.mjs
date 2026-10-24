import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp,rm,mkdir,writeFile,readFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
const profile=await mkdtemp(join(tmpdir(),'kaspire-panel-approvals-'));
const port=9351,display=':84',password='Side panel fixture password 2026';
const fixture=await readFile('tests/fixtures/dapp.html');
const server=createServer((req,res)=>{res.setHeader('content-type','text/html');res.end(fixture);});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const site=`http://127.0.0.1:${server.address().port}`;
const xvfb=spawn('Xvfb',[display,'-screen','0','1366x900x24','-nolisten','tcp'],{stdio:'ignore'});
const delay=ms=>new Promise(r=>setTimeout(r,ms));await delay(250);
const browser=spawn('chromium',['--no-sandbox','--disable-gpu','--no-first-run','--no-default-browser-check',`--user-data-dir=${profile}`,`--disable-extensions-except=${resolve('dist')}`,`--load-extension=${resolve('dist')}`,`--remote-debugging-port=${port}`,'--window-size=1366,900','about:blank'],{stdio:'ignore',env:{...process.env,DISPLAY:display}});
let browserSocket;
async function targets(){return(await fetch(`http://127.0.0.1:${port}/json/list`)).json();}
function cdp(ws,method,params={}){return new Promise((resolveValue,reject)=>{
  const socket=new WebSocket(ws),timer=setTimeout(()=>{socket.close();reject(Error('CDP timeout: '+method));},20000);
  socket.onopen=()=>socket.send(JSON.stringify({id:1,method,params}));socket.onerror=reject;
  socket.onmessage=event=>{const m=JSON.parse(event.data);if(m.id!==1)return;clearTimeout(timer);socket.close();m.error?reject(Error(JSON.stringify(m.error))):resolveValue(m.result);};
});}
async function evaluate(ws,expression,userGesture=false){const r=await cdp(ws,'Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true,userGesture});if(r.exceptionDetails)throw Error(r.exceptionDetails.exception?.description??r.exceptionDetails.text);return r.result?.value;}
async function until(test,label){for(let i=0;i<160;i++){try{const v=await test();if(v)return v;}catch{}await delay(100);}throw Error('Not ready: '+label);}
async function open(url){return(await(await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(url)}`,{method:'PUT'})).json()).webSocketDebuggerUrl;}
async function noPopup(){assert.equal((await targets()).some(t=>t.url.includes('/approval.html')),false,'Side panel flow must not create an external approval window');}
try{
  const worker=await until(async()=> (await targets()).find(t=>t.type==='service_worker'),'worker');
  const base=`chrome-extension://${new URL(worker.url).host}/`;
  browserSocket=(await(await fetch(`http://127.0.0.1:${port}/json/version`)).json()).webSocketDebuggerUrl;
  const wallet=await open(base+'wallet.html');
  await until(()=>evaluate(wallet,'!!document.querySelector("#first-create")'),'onboarding');
  await evaluate(wallet,'document.querySelector("#first-create").click();true');
  await until(()=>evaluate(wallet,'!!document.querySelector("#password-confirm")'),'password');
  await evaluate(wallet,`document.querySelector('#password').value=${JSON.stringify(password)};document.querySelector('#password-confirm').value=${JSON.stringify(password)};document.querySelector('#submit').click();true`);
  await until(()=>evaluate(wallet,'document.querySelectorAll("[data-word]").length===24'),'generated recovery phrase');
  const words=await evaluate(wallet,'Array.from(document.querySelectorAll("[data-word]"),e=>e.value)');
  await evaluate(wallet,'document.querySelector("#verify").click();true');
  await until(()=>evaluate(wallet,'document.querySelectorAll("[data-check]").length===3'),'recovery verification');
  await evaluate(wallet,`{const words=${JSON.stringify(words)};for(const e of document.querySelectorAll('[data-check]'))e.value=words[Number(e.dataset.check)];document.querySelector('#finish').click();}true`);words.fill('');
  await until(()=>evaluate(wallet,'!!document.querySelector("#dual-window:not(:disabled)")&&!!document.querySelector("#send")'),'wallet home');
  await evaluate(worker.webSocketDebuggerUrl,'chrome.runtime.onConnect.addListener(p=>{if(p.name==="wallet-sidepanel-approvals")globalThis.panelPresenterProbe={url:p.sender?.url,documentId:p.sender?.documentId,tabId:p.sender?.tab?.id};});true');
  await evaluate(wallet,'document.querySelector("#dual-window").click();true',true);
  const panel=await until(async()=> (await targets()).find(t=>t.url.startsWith(base+'sidepanel.html?view=')),'actual panel');
  const ui=panel.webSocketDebuggerUrl;
  try{await until(()=>evaluate(ui,'document.documentElement.dataset.panelApprovalReady==="true"'),'verified approval presenter');}
  catch(error){console.log('Presenter public diagnostics:',await evaluate(worker.webSocketDebuggerUrl,'(async()=>({sender:globalThis.panelPresenterProbe,contexts:await chrome.runtime.getContexts({contextTypes:["SIDE_PANEL"]})}))()'));throw error;}
  const dapp=await open(site+'/dapp.html');await until(()=>evaluate(dapp,'!!window.kaspire'),'provider');
  await evaluate(dapp,'window.connected="pending";kaspire.requestAccounts().then(v=>window.connected=v).catch(e=>window.connected="error:"+e.message);true');
  await until(()=>evaluate(ui,'!!document.querySelector("#accept-approval")'),'in-panel connection');await noPopup();
  assert.match(await evaluate(ui,'document.querySelector(".approval-sheet").innerText'),/Connect dApp/);
  assert.ok((await evaluate(ui,'document.querySelector(".approval-sheet").innerText')).includes(site));
  assert.equal(await evaluate(dapp,'window.connected'),'pending');
  await evaluate(ui,'document.querySelector("#accept-approval").click();true');await until(()=>evaluate(dapp,'Array.isArray(window.connected)'),'connected');
  await evaluate(dapp,'window.rejected="pending";kaspire.signMessage("Reject this side-panel message").then(()=>window.rejected="SIGNED").catch(e=>window.rejected="rejected:"+e.code);true');
  await until(()=>evaluate(ui,'!!document.querySelector("#reject-approval")'),'message reject');await noPopup();
  await evaluate(ui,'document.querySelector("#reject-approval").click();true');await until(()=>evaluate(dapp,'String(window.rejected).startsWith("rejected:")'),'rejection propagated');
  await evaluate(dapp,'window.signed="pending";kaspire.signMessage("Explicit side-panel signature").then(v=>window.signed=v).catch(e=>window.signed="error:"+e.message);true');
  await until(()=>evaluate(ui,'!!document.querySelector("#accept-approval")'),'message review');await noPopup();
  const reviewImage=await cdp(ui,'Page.captureScreenshot',{format:'png'});await mkdir('artifacts/side-panel',{recursive:true});await writeFile('artifacts/side-panel/in-panel-message-review.png',Buffer.from(reviewImage.data,'base64'));
  await evaluate(ui,'document.querySelector("#accept-approval").click();true');await until(()=>evaluate(dapp,'typeof window.signed?.signedMessage==="string"'),'explicit signature');
  const publicKey=await evaluate(dapp,'window.signed.publicKey');assert.match(publicKey,/^[0-9a-f]{64}$/);
  const tx={version:0,inputs:[{transactionId:'44'.repeat(32),index:0,sequence:'0',sigOpCount:1,signatureScript:'',utxo:{amount:'200000000',scriptPublicKey:`000020${publicKey}ac`,blockDaaScore:'100',isCoinbase:false}}],outputs:[{value:'199000000',scriptPublicKey:`000020${publicKey}ac`}],subnetworkId:'0'.repeat(40),lockTime:'0',gas:'0',storageMass:'0',payload:''};
  const request={psktTransactionJson:JSON.stringify(tx),submitTransaction:false,signInputs:[{index:0,sighashType:1}],scripts:[]};
  await evaluate(dapp,`window.payment='pending';kaspire.signPskt(${JSON.stringify(request)}).then(()=>window.payment='SIGNED').catch(e=>window.payment='rejected:'+e.code);true`);
  await until(()=>evaluate(ui,'!!document.querySelector("#accept-approval")'),'transaction review');await noPopup();
  assert.match(await evaluate(ui,'document.querySelector(".approval-sheet").innerText'),/Approve reviewed PSKT/);
  await evaluate(ui,'document.querySelector("#reject-approval").click();true');await until(()=>evaluate(dapp,'String(window.payment).startsWith("rejected:")'),'transaction rejected');
  await evaluate(ui,'chrome.runtime.sendMessage({channel:"wallet",command:"lock"})');
  await evaluate(dapp,'window.unlockFlow="pending";kaspire.signMessage("Unlock inside side panel").then(v=>window.unlockFlow=v).catch(e=>window.unlockFlow="error:"+e.message);true');
  await until(()=>evaluate(ui,'!!document.querySelector("#panel-unlock-password")'),'in-panel unlock');await noPopup();
  await evaluate(ui,'document.querySelector("#panel-unlock-password").value="wrong password";document.querySelector("#panel-unlock-submit").click();true');
  await until(()=>evaluate(ui,'!!document.querySelector("#panel-unlock-error")?.textContent&&!document.querySelector("#panel-unlock-submit").disabled'),'wrong password error');
  await evaluate(ui,`document.querySelector('#panel-unlock-password').value=${JSON.stringify(password)};document.querySelector('#panel-unlock-submit').click();true`);
  await until(()=>evaluate(ui,'!!document.querySelector("#accept-approval")'),'review after unlock');await noPopup();
  assert.equal(await evaluate(dapp,'window.unlockFlow'),'pending','Unlocking must not sign the message');
  await evaluate(ui,'document.querySelector("#accept-approval").click();true');await until(()=>evaluate(dapp,'typeof window.unlockFlow?.signedMessage==="string"'),'signed after explicit review');
  await evaluate(ui,'chrome.runtime.sendMessage({channel:"wallet",command:"setSettings",settings:{autoLockMinutes:1}})');
  await evaluate(dapp,'window.expired="pending";kaspire.signMessage("Must reject after timed expiry").then(()=>window.expired="SIGNED").catch(e=>window.expired="rejected:"+e.code);true');
  await until(()=>evaluate(ui,'!!document.querySelector("#accept-approval")'),'expiry review');
  const currentWorker=await until(async()=> (await targets()).find(t=>t.type==='service_worker'),'active worker');
  await evaluate(currentWorker.webSocketDebuggerUrl,'globalThis.panelRealNow=Date.now;Date.now=()=>globalThis.panelRealNow()+120000;true');
  try {
    await evaluate(ui,'document.querySelector("#accept-approval").click();true');
    await until(()=>evaluate(dapp,'String(window.expired).startsWith("rejected:")'),'expired approval rejected');
  }finally{await evaluate(currentWorker.webSocketDebuggerUrl,'Date.now=globalThis.panelRealNow;delete globalThis.panelRealNow;true');}
  await until(()=>evaluate(ui,'!!document.querySelector("#password")'),'timed lock visible');await noPopup();
  await evaluate(ui,`document.querySelector('#password').value=${JSON.stringify(password)};document.querySelector('#submit').click();true`);
  await until(()=>evaluate(ui,'!!document.querySelector("#send")'),'unlock after expiry');
  await evaluate(ui,'chrome.runtime.sendMessage({channel:"wallet",command:"setSettings",settings:{autoLockMinutes:15}})');
  const screenshot=await cdp(ui,'Page.captureScreenshot',{format:'png'});await mkdir('artifacts/side-panel',{recursive:true});await writeFile('artifacts/side-panel/in-panel-approval-flow.png',Buffer.from(screenshot.data,'base64'));
  await evaluate(dapp,'window.closedRequest="pending";kaspire.signMessage("Cancel when panel closes").then(()=>window.closedRequest="SIGNED").catch(e=>window.closedRequest="rejected:"+e.code);true');
  await until(()=>evaluate(ui,'!!document.querySelector("#accept-approval")'),'close pending review');
  await evaluate(ui,'document.querySelector("#dual-window").click();true',true);
  await until(()=>evaluate(dapp,'String(window.closedRequest).startsWith("rejected:")'),'panel close rejects request');await noPopup();
  await evaluate(dapp,'window.fallback="pending";kaspire.signMessage("Popup fallback only after panel closed").then(()=>window.fallback="SIGNED").catch(e=>window.fallback="rejected:"+e.code);true');
  const popup=await until(async()=> (await targets()).find(t=>t.url.includes('/approval.html')),'normal popup fallback');
  await until(()=>evaluate(popup.webSocketDebuggerUrl,'!!document.querySelector("#reject")'),'popup reject');
  await evaluate(popup.webSocketDebuggerUrl,'setTimeout(()=>document.querySelector("#reject").click(),20);true');await until(()=>evaluate(dapp,'String(window.fallback).startsWith("rejected:")'),'fallback rejected');
  console.log('Actual Chrome Side Panel: dApp connect, explicit message approval/rejection, native PSKT review/rejection, locked-wallet unlock with wrong-password recovery, timed-expiry rejection, no automatic signing, close cancellation and normal popup fallback passed. No transaction broadcast.');
}finally{
  if(browserSocket)await cdp(browserSocket,'Browser.close').catch(()=>{});
  browser.kill('SIGTERM');xvfb.kill('SIGTERM');server.close();await delay(300);await rm(profile,{recursive:true,force:true});
}
