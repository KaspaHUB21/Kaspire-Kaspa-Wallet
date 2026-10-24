// UI-only deterministic public data. No wallet secrets or network signing.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp,readFile,mkdir,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve,extname} from 'node:path';
const output=resolve('artifacts/kasseal-ui');await mkdir(output,{recursive:true});
const profile=await mkdtemp(join(tmpdir(),'kaspire-kasseal-ui-'));
const fixture=await readFile('tests/hub21-fixture.js','utf8')+`
fixtureState.settings.theme=new URLSearchParams(location.search).get('theme')??'midnight';
const cid='c'.repeat(64),other='d'.repeat(64);
const sealToken=(ticker='WALLET',id=cid)=>({meta:{covenantId:id,ticker,name:ticker,decimals:0},verification:'verified',phase:'bonding'});
fixtureAssets.rocket=[{symbol:'ROCKET',covenantId:'e'.repeat(64),rawBalance:'2105645645',decimals:3,standard:'kasparocket-kcc20',priceKas:.015}];
fixtureAssets.kasseal=[];window.sealCalls=[];window.sealCopies=[];window.sealLinks=[];window.sealPending=null;
let sealReceipt=null;
Object.defineProperty(navigator,'clipboard',{value:{writeText:async text=>window.sealCopies.push(text)},configurable:true});
chrome.tabs.create=options=>window.sealLinks.push(options.url);
const baseSend=chrome.runtime.sendMessage;
chrome.runtime.connect=()=>{const messages=[],closed=[];let done=false;return {onMessage:{addListener:fn=>messages.push(fn)},onDisconnect:{addListener:fn=>closed.push(fn)},postMessage:message=>{Promise.resolve(chrome.runtime.sendMessage(message)).then(result=>{if(!done)messages.forEach(fn=>fn(result));});},disconnect:()=>{if(!done){done=true;closed.forEach(fn=>fn());}}};};
chrome.runtime.sendMessage=async message=>{
  const cmd=message.command;window.sealCalls.push(message);
  if(cmd==='kassealTokens'){
    if(message.search==='slow')await new Promise(r=>setTimeout(r,1200));
    const tokens=message.search?[sealToken(message.search==='slow'?'STALE':'UNNACHOD')]:message.cursor?[sealToken(),sealToken('SECOND',other)]:[sealToken()];
    return {result:{tokens,nextCursor:message.search||message.cursor?null:'next-page'}};
  }
  if(cmd==='kassealContext')return {result:{balanceSompi:'8300000000000',holdings:[{covenantId:cid,rawBalance:'49389000'}],history:sealReceipt?[sealReceipt]:[],...(window.sealPending?{pending:window.sealPending}:{})}};
  if(cmd==='kassealResume'){window.sealPending=null;return {error:{message:'The pool changed. The obsolete swap was archived. Refresh the quote.'}};}
  if(cmd==='kassealQuote')return {result:{quoteId:'quote',network:'mainnet',tokenId:cid,side:message.side,rawAmount:message.amount,
    tokenAmount:'10000',kasSompi:'231583220',protocolFeeSompi:'2339225',walletNetSompi:'231563220',networkFeeSompi:'20000'}};
  if(cmd==='kassealPrepare')return {result:{id:'review',token:sealToken('UNNACHOD'),summary:{stage:'swap',side:'sell',tokenId:cid,tokenAmount:'10000',kasSompi:'231583220',protocolFeeSompi:'2339225',networkFeeSompi:'20000',walletNetSompi:'231563220'},rawPlan:{publicFixture:true}}};
  if(cmd==='kassealSubmit'){
    sealReceipt={transactionId:'f'.repeat(64),timestamp:Date.now(),token:sealToken('UNNACHOD'),summary:{stage:'swap',side:'sell',tokenId:cid,tokenAmount:'10000',kasSompi:'231583220',protocolFeeSompi:'2339225',networkFeeSompi:'20000',walletNetSompi:'231563220'}};
    return {result:sealReceipt};
  }
  return baseSend(message);
};
`;
const server=createServer(async(req,res)=>{
  try{
    const path=new URL(req.url,'http://localhost').pathname;
    if(path==='/fixture.js'){res.setHeader('content-type','text/javascript');res.end(fixture);return;}
    const file=resolve('dist','.'+path);if(!file.startsWith(resolve('dist')+'/'))throw Error('Invalid path');
    let content=await readFile(file);if(file.endsWith('.html'))content=content.toString().replace('<script type="module"','<script src="/fixture.js"></script><script type="module"');
    res.setHeader('content-type',({'.html':'text/html','.js':'text/javascript','.css':'text/css','.png':'image/png'})[extname(file)]??'application/octet-stream');res.end(content);
  }catch{res.writeHead(404);res.end();}
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const browser=spawn('chromium',['--headless=new','--no-sandbox','--disable-gpu',`--user-data-dir=${profile}`,'--remote-debugging-port=9358','about:blank'],{stdio:'ignore'});
const delay=ms=>new Promise(r=>setTimeout(r,ms));let ws;
function cdp(method,params={}){return new Promise((yes,no)=>{const socket=new WebSocket(ws),timer=setTimeout(()=>{socket.close();no(Error('CDP timeout'));},15000);socket.onopen=()=>socket.send(JSON.stringify({id:1,method,params}));socket.onmessage=e=>{const result=JSON.parse(e.data);if(result.id!==1)return;clearTimeout(timer);socket.close();result.error?no(Error(JSON.stringify(result.error))):yes(result.result);};socket.onerror=no;});}
async function evaluate(expression){const result=await cdp('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(result.exceptionDetails)throw Error(result.exceptionDetails.exception?.description??result.exceptionDetails.text);return result.result.value;}
async function wait(expression){for(let i=0;i<100;i++){if(await evaluate(expression))return;await delay(75);}throw Error('UI not ready: '+expression+' '+await evaluate('document.body.innerText'));}
const click=selector=>evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);
const fill=(selector,value)=>evaluate(`(()=>{const input=document.querySelector(${JSON.stringify(selector)});input.focus();input.value=${JSON.stringify(value)};input.dispatchEvent(new Event('input',{bubbles:true}));})()`);
async function screenshot(name){const value=await cdp('Page.captureScreenshot',{format:'png'});await writeFile(join(output,name+'.png'),Buffer.from(value.data,'base64'));}
try{
  for(let i=0;i<80;i++){try{ws=(await(await fetch('http://127.0.0.1:9358/json/list')).json()).find(t=>t.type==='page')?.webSocketDebuggerUrl;if(ws)break;}catch{}await delay(100);}assert(ws);
  await cdp('Emulation.setDeviceMetricsOverride',{width:420,height:760,deviceScaleFactor:1,mobile:false});
  for(const theme of ['midnight','hub21','glacier','neptune']){
    await cdp('Page.navigate',{url:`http://127.0.0.1:${server.address().port}/wallet.html?theme=${theme}`});await wait('!!document.querySelector("#swap")');
    await click('#swap');await wait('!!document.querySelector("#kasseal-open")');
    assert.deepEqual(await evaluate('[...document.querySelectorAll("#rocket-open,#kasseal-open,#kron-open")].map(b=>b.id)'),['rocket-open','kasseal-open','kron-open']);
    assert.equal(await evaluate('document.querySelector("#kasseal-open img").getAttribute("src")'),'kasseal.png');
    await click('#kasseal-open');await wait('document.querySelectorAll("[data-seal-token]").length===1&&!document.querySelector(".loading")');
    await click('#seal-more');await wait('document.querySelectorAll("[data-seal-token]").length===2');assert.equal(await evaluate('!!document.querySelector("#seal-more")'),false);
    await fill('#seal-search','unnachod');await wait('document.querySelector("[data-seal-token] b")?.textContent==="UNNACHOD"');
    await fill('#seal-search','slow');await delay(450);await fill('#seal-search','unnachod');await delay(1400);
    assert.equal(await evaluate('document.querySelector("[data-seal-token] b").textContent'),'UNNACHOD');
    await click('[data-seal-token]');await wait('!!document.querySelector("#seal-amount")&&!document.querySelector(".loading")');
    assert.match(await evaluate('document.querySelector(".available").textContent'),/Available KAS: 83,000/);
    assert(!/Available: 0 WALLET/.test(await evaluate('document.body.innerText')));
    await click('[data-seal-side="sell"]');assert.match(await evaluate('document.querySelector(".available").textContent'),/49,389,000/);
    const fields=await evaluate('(()=>{const input=document.querySelector("#seal-amount").getBoundingClientRect(),available=document.querySelector(".available").getBoundingClientRect(),side=[...document.querySelectorAll("[data-seal-side]")].map(e=>e.getBoundingClientRect());return {width:input.width,height:input.height,top:input.top,availableBottom:available.bottom,buyWidth:side[0].width,sellWidth:side[1].width,tabRight:side[1].right,containerRight:document.querySelector(".token-detail .segmented").getBoundingClientRect().right};})()');
    assert(fields.width>=150&&fields.height>=40&&fields.top>=fields.availableBottom,theme+' amount/available layout: '+JSON.stringify(fields));
    assert(Math.abs(fields.buyWidth-fields.sellWidth)<1&&Math.abs(fields.tabRight-fields.containerRight)<8,theme+' two-column tabs');
    await fill('#seal-amount','10000');await click('#seal-quote');await wait('!document.querySelector("#seal-review").disabled');
    assert.match(await evaluate('document.querySelector(".form .review-card").textContent'),/2.3158322 KAS/);
    await screenshot(theme+'-sell');await click('#seal-review');await wait('!!document.querySelector("#seal-submit")');
    assert.match(await evaluate('document.querySelector(".approval-sheet").innerText'),/Net wallet KAS change.*2.3156322 KAS/s);
    await screenshot(theme+'-review');await click('#seal-submit');await wait('!!document.querySelector("#seal-return")');
    await click('#seal-copy');assert.equal(await evaluate('window.sealCopies.at(-1)'),'f'.repeat(64));
    await click('#seal-return');await wait('!!document.querySelector("[data-seal-tab=history]")&&!document.querySelector(".loading")');
    await click('[data-seal-tab="history"]');assert.match(await evaluate('document.querySelector("#seal-content").innerText'),/Sold UNNACHOD.*10,000/s);
    await evaluate('window.sealPending={transactionId:"a".repeat(64),summary:{stage:"swap"}}');
    await click('#seal-reload');await wait('!!document.querySelector("#seal-resume")&&!document.querySelector(".loading")');
    await click('#seal-resume');await wait('!document.querySelector("#seal-resume")&&!document.querySelector(".loading")');
    assert.match(await evaluate('document.querySelector("#seal-content .error").textContent'),/archived/);
    await click('[data-seal-tab="swaps"]');await click('[data-seal-token]');await wait('!!document.querySelector("#seal-quote")&&!document.querySelector(".loading")');
    assert.equal(await evaluate('document.querySelector("#seal-quote").disabled'),false,'Proven obsolete recovery must release the quote UI');
    assert.equal(await evaluate('document.body.scrollWidth<=document.body.clientWidth'),true,theme+' horizontal overflow');
    await click('#back');await wait('!!document.querySelector("[data-category=kcc20]")');await click('[data-category="kcc20"] summary');
    await evaluate('[...document.querySelectorAll("[data-group=kcc20]")].find(b=>b.textContent.includes("ROCKET")).click()');await wait('!!document.querySelector("#rocket-send")');
    assert.equal(await evaluate('!!document.querySelector("#rocket-swap")'),true);assert.match(await evaluate('document.querySelector(".token-detail").innerText'),/Price per token/);
    await click('#rocket-explorer');assert.equal(await evaluate('window.sealLinks.at(-1)'),'https://kaspatoken.kaslab.space/kcc20/'+'e'.repeat(64));
  }
  console.log('Kasseal UI: all four themes, global/racing search, pagination, buy/sell balances, review, receipt/history, obsolete-recovery refresh and Rocket details/explorer passed.');
}finally{browser.kill('SIGTERM');await new Promise(r=>{browser.once('exit',r);setTimeout(r,3000);});server.close();await rm(profile,{recursive:true,force:true,maxRetries:5,retryDelay:100});}
