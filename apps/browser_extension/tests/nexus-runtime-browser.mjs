import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const debugPort=9341;const sitePort=8889;const profile=await mkdtemp(join(tmpdir(),"kaspire-browser-test-"));
const fixture=await readFile(new URL("./fixtures/dapp.html",import.meta.url));
const server=createServer((request,response)=>{if(request.url==="/dapp.html"){response.writeHead(200,{"content-type":"text/html"});response.end(fixture)}else{response.writeHead(404);response.end()}});
await new Promise(resolveReady=>server.listen(sitePort,"127.0.0.1",resolveReady));
const browser=spawn("chromium",["--headless=new","--no-sandbox","--disable-gpu",`--user-data-dir=${profile}`,`--disable-extensions-except=${resolve("dist")}`,`--load-extension=${resolve("dist")}`,`--remote-debugging-port=${debugPort}`,"about:blank"],{stdio:"ignore"});

async function targets(){for(let attempt=0;attempt<80;attempt++){try{return await(await fetch(`http://127.0.0.1:${debugPort}/json/list`)).json()}catch{await delay(100)}}throw new Error("Chromium debugging endpoint did not start.")}
async function open(url){return(await(await fetch(`http://127.0.0.1:${debugPort}/json/new?${encodeURIComponent(url)}`,{method:"PUT"})).json()).webSocketDebuggerUrl}
function evaluate(webSocketDebuggerUrl,expression){return new Promise((resolveValue,reject)=>{const socket=new WebSocket(webSocketDebuggerUrl);const timer=setTimeout(()=>{socket.close();reject(new Error("CDP evaluation timed out."))},50000);socket.onopen=()=>socket.send(JSON.stringify({id:1,method:"Runtime.evaluate",params:{expression,returnByValue:true,awaitPromise:true}}));socket.onerror=reject;socket.onmessage=event=>{const message=JSON.parse(event.data);if(message.id!==1)return;clearTimeout(timer);socket.close();if(message.result?.exceptionDetails)reject(new Error(message.result.exceptionDetails.exception?.description??message.result.exceptionDetails.text));else resolveValue(message.result?.result?.value)}})}
function command(webSocketDebuggerUrl,method,params={}){return new Promise((resolveValue,reject)=>{const socket=new WebSocket(webSocketDebuggerUrl);const timer=setTimeout(()=>{socket.close();reject(new Error("CDP command timed out."))},8000);socket.onopen=()=>socket.send(JSON.stringify({id:1,method,params}));socket.onerror=reject;socket.onmessage=event=>{const message=JSON.parse(event.data);if(message.id!==1)return;clearTimeout(timer);socket.close();message.error?reject(new Error(message.error.message)):resolveValue(message.result)}})}
async function observe(webSocketDebuggerUrl){const events=[];const socket=new WebSocket(webSocketDebuggerUrl);await new Promise((resolveReady,reject)=>{socket.onerror=reject;socket.onopen=()=>{socket.send(JSON.stringify({id:1,method:"Runtime.enable"}));socket.send(JSON.stringify({id:2,method:"Log.enable"}));resolveReady()}});socket.onmessage=event=>events.push(JSON.parse(event.data));return{events,close:()=>socket.close()}}
const delay=milliseconds=>new Promise(resolveDelay=>setTimeout(resolveDelay,milliseconds));
async function waitFor(page,expression){for(let attempt=0;attempt<60;attempt++){try{if(await evaluate(page,expression))return}catch{}await delay(100)}throw new Error(`Browser condition did not become true: ${expression}`)}


try {
 let worker;
 for(let i=0;i<80&&!worker;i++){worker=(await targets()).find(t=>t.type==='service_worker');if(!worker)await delay(100);}
 assert(worker);
 await evaluate(worker.webSocketDebuggerUrl, `globalThis.realNexusFetch=fetch;globalThis.fetch=async(url,opts)=>{
  const path=new URL(String(url)).pathname;
  if(!path.includes('/nexus-test-v1/'))return realNexusFetch(url,opts);
  const body=opts?.body?JSON.parse(opts.body):{};
  if(path.endsWith('internal-challenge')){
   const nonce='a'.repeat(43),issued=new Date().toISOString(),expires=new Date(Date.now()+300000).toISOString(),address=body.walletAddress;
   return new Response(JSON.stringify({nonce,expiresAt:expires,message:'Kaspire Internal NFT Offers\\n\\nDomain: kaspire.kaslab.space\\nPurpose: internal-private-offers-v1\\nWallet: '+address+'\\nNonce: '+nonce+'\\nIssued at: '+issued+'\\nExpires at: '+expires+'\\n\\nAuthenticate this wallet for private offers and notifications inside Kaspire only.\\nThis signature does not create a transaction or spend funds.'}),{status:200});
  }
  if(path.endsWith('internal-verify'))return new Response(JSON.stringify({walletAddress:body.walletAddress,token:'test-notification-bearer'}),{status:200});
  if(path.endsWith('dashboard/notifications'))return new Response(JSON.stringify([{id:'notice',readAt:null,createdAt:new Date().toISOString(),type:'NEW_OFFER',payloadJson:{title:'Runtime test offer',message:'Synthetic notification'}}]),{status:200});
  if(path.endsWith('notifications/read'))return new Response('{"ok":true}',{status:200});
  return new Response('[]',{status:200});
 };true`);
 const extensionId=new URL(worker.url).host;
 const wallet=await open('chrome-extension://'+extensionId+'/wallet.html');
 await waitFor(wallet,'Boolean(document.querySelector("#first-create"))');
 await evaluate(wallet,'document.querySelector("#first-create").click();true');
 await waitFor(wallet,'Boolean(document.querySelector("#password"))');
 await evaluate(wallet,'document.querySelector("#password").value="synthetic nexus runtime password";document.querySelector("#password-confirm").value="synthetic nexus runtime password";document.querySelector("#submit").click();true');
 await waitFor(wallet,'document.querySelectorAll("[data-word]").length>0');
 await evaluate(wallet,'globalThis.testWords=[...document.querySelectorAll("[data-word]")].map(i=>i.value);document.querySelector("#verify").click();true');
 await waitFor(wallet,'document.querySelectorAll("[data-check]").length===3');
 await evaluate(wallet,'for(const i of document.querySelectorAll("[data-check]"))i.value=testWords[Number(i.dataset.check)];document.querySelector("#finish").click();true');
 await waitFor(wallet,'Boolean(document.querySelector("#nexus-bell.nexus-ring"))');
 for(const method of ['nexusStatus','nexusConnect','nexusPoll']){
  const result=await evaluate(wallet,`chrome.runtime.sendMessage({channel:"wallet",command:${JSON.stringify(method)}})`);
  assert(!result.error,method+': '+result.error?.message);assert.equal(result.result.connected,true);
 }
 await evaluate(wallet,'document.querySelector("#nexus-bell").click();true');
 await waitFor(wallet,'document.body.innerText.includes("Runtime test offer")');
 assert(!String(await evaluate(wallet,'document.body.innerText')).includes('Unknown wallet command'));
 console.log('Real extension worker: Nexus status, connect, poll, ringing bell and notification screen passed without a second unlock.');
} finally {
 browser.kill('SIGTERM');server.close();await delay(250);await rm(profile,{recursive:true,force:true});
}
