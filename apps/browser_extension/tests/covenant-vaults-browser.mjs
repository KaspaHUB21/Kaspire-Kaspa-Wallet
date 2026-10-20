import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp,readFile,writeFile,mkdir,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve,extname} from 'node:path';
const native=JSON.parse(execFileSync('cargo',['run','--locked','--quiet','-p','kaspa_secure_core','--example','vault_browser_fixture'],{cwd:'../..',maxBuffer:2*1024*1024}).toString());
const profile=await mkdtemp(join(tmpdir(),'kaspire-vault-ui-')),output=resolve('artifacts/covenant-vaults-ui');await mkdir(output,{recursive:true});
const recovery=join(profile,'recovery.json');await writeFile(recovery,native.sealed);
const fixture=(await readFile('tests/hub21-fixture.js','utf8'))+'\nconst vaultNative='+JSON.stringify(native)+';\n'+await readFile('tests/covenant-vaults-fixture.js','utf8');
const server=createServer(async(req,res)=>{
  try{
    const path=new URL(req.url,'http://localhost').pathname;
    if(path==='/fixture.js'){res.setHeader('Content-Type','text/javascript');res.end(fixture);return;}
    const file=resolve('dist','.'+path);if(!file.startsWith(resolve('dist')+'/')){res.writeHead(403);res.end();return;}
    let content=await readFile(file);if(file.endsWith('.html'))content=content.toString().replace('<script type="module"','<script src="/fixture.js"></script><script type="module"');
    res.setHeader('Content-Type',({'.html':'text/html','.js':'text/javascript','.css':'text/css','.png':'image/png'})[extname(file)]??'application/octet-stream');res.end(content);
  }catch{res.writeHead(404);res.end();}
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const browser=spawn('chromium',['--headless=new','--no-sandbox','--disable-gpu','--disable-background-networking',`--user-data-dir=${profile}`,'--remote-debugging-port=9352','about:blank'],{stdio:'ignore'});
const delay=ms=>new Promise(r=>setTimeout(r,ms));let ws;
function cdp(method,params={}){return new Promise((resolve,reject)=>{const socket=new WebSocket(ws),timer=setTimeout(()=>{socket.close();reject(Error('CDP timeout: '+method));},15000);socket.onopen=()=>socket.send(JSON.stringify({id:1,method,params}));socket.onerror=reject;socket.onmessage=e=>{const m=JSON.parse(e.data);if(m.id!==1)return;clearTimeout(timer);socket.close();m.error?reject(Error(JSON.stringify(m.error))):resolve(m.result);};});}
async function uploadFile(){return new Promise((resolve,reject)=>{const socket=new WebSocket(ws),timer=setTimeout(()=>{socket.close();reject(Error('File input timeout'));},10000);socket.onopen=()=>socket.send(JSON.stringify({id:1,method:'DOM.getDocument'}));socket.onerror=reject;socket.onmessage=e=>{const m=JSON.parse(e.data);if(m.error){clearTimeout(timer);socket.close();reject(Error(JSON.stringify(m.error)));return;}if(m.id===1)socket.send(JSON.stringify({id:2,method:'DOM.querySelector',params:{nodeId:m.result.root.nodeId,selector:'#vault-file'}}));if(m.id===2)socket.send(JSON.stringify({id:3,method:'DOM.setFileInputFiles',params:{nodeId:m.result.nodeId,files:[recovery]}}));if(m.id===3){clearTimeout(timer);socket.close();resolve();}};});}
async function evaluate(expression){const r=await cdp('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true,userGesture:true});if(r.exceptionDetails)throw Error(r.exceptionDetails.exception?.description??r.exceptionDetails.text);return r.result.value;}
async function waitFor(expression){for(let i=0;i<100;i++){if(await evaluate(expression))return;await delay(80);}throw Error('UI not ready: '+expression);}
const click=selector=>evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);
async function shot(name){const s=await cdp('Page.captureScreenshot',{format:'png'});await writeFile(join(output,name+'.png'),Buffer.from(s.data,'base64'));}
async function fill(selector,value){await evaluate(`{const e=document.querySelector(${JSON.stringify(selector)});e.value=${JSON.stringify(value)};e.dispatchEvent(new Event('input',{bubbles:true}));}`);}
async function dimensions(){const r=await evaluate(`({body:document.body.clientWidth,scroll:document.body.scrollWidth,height:document.querySelector('.app').clientHeight,overflow:[...document.querySelectorAll('.vault-panel,.vault-toolbar,dialog[open]')].filter(e=>e.scrollWidth>e.clientWidth+2).map(e=>e.className)})`);assert.equal(r.scroll,r.body,JSON.stringify(r));assert.equal(r.overflow.length,0,JSON.stringify(r));assert(r.height>=600,JSON.stringify(r));}
async function open(theme){await cdp('Page.navigate',{url:`http://127.0.0.1:${server.address().port}/wallet.html?theme=${theme}`});await waitFor('!!document.querySelector("#vaults")');await click('#vaults');await waitFor('!!document.querySelector("[data-vault-start]")&&!document.querySelector(".vault-screen .loading")');}
async function create(theme,interrupted=false){
  await click('[data-vault-start="timeLock"]');await waitFor('!!document.querySelector("#vault-prepare")');await dimensions();await shot(theme+'-create');
  await click('#vault-prepare');await waitFor('!!document.querySelector("#vault-submit")&&!document.querySelector("#vault-submit").disabled');await click('#vault-submit');await waitFor('!!document.querySelector("#vault-password")');
  await click('#vault-eye');assert.equal(await evaluate('document.querySelector("#vault-password").type'),'text');
  await fill('#vault-password','short');await fill('#vault-password-confirm','other');await click('#vault-dialog-continue');assert.match(await evaluate('document.querySelector("#vault-password-error").textContent'),/match/);
  await fill('#vault-password',native.password);await fill('#vault-password-confirm',native.password);await shot(theme+'-recovery');await click('#vault-dialog-continue');await waitFor('!!document.querySelector("#vault-file-saved")');
  assert.equal(await evaluate('document.querySelector("#vault-download-continue").disabled'),true);
  await click('#vault-file-saved');await click('#vault-download-continue');await waitFor('!!document.querySelector("#accept-approval")');await dimensions();await shot(theme+'-approval');
  await evaluate('window.vaultFixtureMode='+JSON.stringify(interrupted?'interrupted':'confirmed'));await click('#accept-approval');
  if(interrupted){await waitFor('!!document.querySelector("[data-vault-resume]")&&!document.querySelector("[data-vault-resume]").disabled');assert.match(await evaluate('document.querySelector(".vault-pending").textContent'),/NOT complete/);await click('[data-vault-resume]');}
  await waitFor('document.querySelector("#vault-content").textContent.includes("Vault transaction confirmed")');assert.equal(await evaluate('window.vaultFixtureSigned'),1);assert.equal(await evaluate('window.vaultDownloads'),1);assert.equal(await evaluate('Boolean(document.querySelector("[data-vault-resume]"))'),false);await shot(theme+'-confirmed');
  await click('#vault-return');await waitFor('!!document.querySelector("[data-vault-id]")');await click('[data-vault-id]');await waitFor('!!document.querySelector("#vault-export")');await dimensions();await shot(theme+'-details');
  await click('#vault-home');await waitFor('!!document.querySelector("[data-vault-id]")');
  await evaluate('window.vaultFixtureOpened()');await click('#vault-reload');await waitFor('document.querySelector("#vault-content").textContent.includes("No active vaults")');assert.equal(await evaluate('document.querySelectorAll("[data-vault-id]").length'),0);
}
try{
  for(let i=0;i<100;i++){try{ws=(await(await fetch('http://127.0.0.1:9352/json/list')).json()).find(t=>t.type==='page')?.webSocketDebuggerUrl;if(ws)break;}catch{}await delay(80);}assert(ws);
  await cdp('Emulation.setDeviceMetricsOverride',{width:420,height:700,deviceScaleFactor:1,mobile:false});
  for(const theme of ['midnight','hub21','glacier','neptune']){
    await open(theme);assert.match(await evaluate('document.querySelector(".vault-intro").textContent'),/Your money/);await dimensions();await shot(theme+'-overview');await create(theme,theme==='neptune');
  }
  await open('glacier');await click('#vault-import');await waitFor('!!document.querySelector("#vault-file")');
  await uploadFile();await click('#vault-file-import');await waitFor('!!document.querySelector("#vault-password")');await fill('#vault-password',native.password);await click('#vault-dialog-continue');await waitFor('!!document.querySelector("#vault-ok")');await click('#vault-ok');await waitFor('!!document.querySelector("#vault-export")');await dimensions();
  console.log('Vault UI passed: four themes, create/recovery/download/approval/confirmed receipt, interrupted resume, no stale resume button, hidden opened vaults, import and home/reload.');
}finally{browser.kill('SIGTERM');await new Promise(r=>{browser.once('exit',r);setTimeout(r,2000);});server.close();await rm(profile,{recursive:true,force:true,maxRetries:5,retryDelay:100});}
