import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp,readFile,writeFile,mkdir,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve,extname} from 'node:path';
const profile=await mkdtemp(join(tmpdir(),'kaspire-neptune-nft-ui-'));
const output=resolve('artifacts/neptune-nft-ui');await mkdir(output,{recursive:true});
const server=createServer(async(req,res)=>{
  try{
    const path=new URL(req.url,'http://localhost').pathname;
    if(path==='/fixture.js'){res.setHeader('Content-Type','text/javascript');res.end((await readFile('tests/hub21-fixture.js'))+'\n'+(await readFile('tests/neptune-nft-fixture.js')));return;}
    const file=resolve('dist',`.${path==='/'?'/wallet.html':path}`);if(!file.startsWith(resolve('dist')+'/'))throw Error('Invalid path');
    let content=await readFile(file);if(file.endsWith('.html'))content=content.toString().replace('<script type="module"','<script src="/fixture.js"></script><script type="module"');
    res.setHeader('Content-Type',({'.html':'text/html','.css':'text/css','.js':'text/javascript','.png':'image/png','.ttf':'font/ttf'})[extname(file)]??'application/octet-stream');res.end(content);
  }catch{res.writeHead(404);res.end();}
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const browser=spawn('chromium',['--headless=new','--no-sandbox','--disable-gpu',`--user-data-dir=${profile}`,'--remote-debugging-port=9338','about:blank'],{stdio:'ignore'});
const delay=ms=>new Promise(r=>setTimeout(r,ms));let ws;
async function cdp(method,params={}){return new Promise((resolveValue,reject)=>{const socket=new WebSocket(ws),timer=setTimeout(()=>{socket.close();reject(Error('CDP timeout'));},15000);socket.onopen=()=>socket.send(JSON.stringify({id:1,method,params}));socket.onmessage=event=>{const value=JSON.parse(event.data);if(value.id!==1)return;clearTimeout(timer);socket.close();value.error?reject(Error(JSON.stringify(value.error))):resolveValue(value.result);};socket.onerror=reject;});}
async function evaluate(expression){const value=await cdp('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(value.exceptionDetails)throw Error(value.exceptionDetails.text);return value.result.value;}
async function wait(expression){for(let i=0;i<80;i++){if(await evaluate(expression))return;await delay(100);}throw Error('Not ready: '+expression+' · '+JSON.stringify(await evaluate('({body:document.body.innerText,last:window.lastNexusRequest})')));}
async function click(selector){await evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);await delay(120);}
async function shot(name){await delay(200);const png=await cdp('Page.captureScreenshot',{format:'png'});await writeFile(join(output,name+'.png'),Buffer.from(png.data,'base64'));}
try{
  for(let i=0;i<80;i++){try{ws=(await(await fetch('http://127.0.0.1:9338/json/list')).json()).find(x=>x.type==='page')?.webSocketDebuggerUrl;if(ws)break;}catch{}await delay(100);}assert(ws);
  await cdp('Emulation.setDeviceMetricsOverride',{width:420,height:760,deviceScaleFactor:2,mobile:false});
  await cdp('Page.navigate',{url:`http://127.0.0.1:${server.address().port}/wallet.html`});await wait('!!document.querySelector("#balance")');
  await wait('!!document.querySelector("#nexus-bell.nexus-ring")');
  assert.equal(await evaluate('document.querySelector("#nexus-bell .nexus-count").textContent'),'1');
  assert.equal(await evaluate('getComputedStyle(document.querySelector("#nexus-bell svg")).animationName'),'nexus-bell-ring');
  assert.equal(await evaluate('document.documentElement.dataset.theme'),'neptune');
  assert.match(await evaluate('getComputedStyle(document.body).backgroundImage'),/ocean.png/);
  assert.match(await evaluate('getComputedStyle(document.querySelector(".balance-card")).backgroundImage'),/water-glass.png/);
  const position=await evaluate('(()=>{const orb=document.querySelector(".neptune-orb").getBoundingClientRect(),logo=document.querySelector(".orb-logo").getBoundingClientRect();return [(logo.x+logo.width/2-orb.x)/orb.width,(logo.y+logo.height/2-orb.y)/orb.height]})()');
  assert(Math.abs(position[0]-.55)<.01&&Math.abs(position[1]-.4)<.01);await shot('neptune-home');
  for(const theme of ['midnight','hub21','glacier','neptune']) {
    await evaluate(`document.documentElement.dataset.theme=${JSON.stringify(theme)}`);
    const actions=await evaluate(`Array.from(document.querySelectorAll('.quick-actions.four button')).map(button=>({icon:button.querySelector('b').getBoundingClientRect().top,label:button.querySelector('span').getBoundingClientRect().top}))`);
    for(const action of actions){assert(Math.abs(action.icon-actions[0].icon)<1,theme+' action icon alignment');assert(Math.abs(action.label-actions[0].label)<1,theme+' action label alignment');}
    if(theme!=='midnight') {
      for(const selector of ['#nexus-bell','#copy-main-address']) {
        const frame=await evaluate(`(()=>{const s=getComputedStyle(document.querySelector(${JSON.stringify(selector)}));return {border:s.borderTopWidth,shadow:s.boxShadow,background:s.backgroundImage};})()`);
        assert(parseFloat(frame.border)>=1,theme+' header icon border');
        assert.notEqual(frame.shadow,'none',theme+' header icon relief');
        assert.notEqual(frame.background,'none',theme+' header icon material');
      }
    }
  }
  await evaluate("document.documentElement.dataset.theme='neptune'");
  await wait('!!document.querySelector("[data-category=krc721] .asset-icon img[data-nft-image]")');
  await click('[data-category=krc721] summary');await click('[data-group=krc721]');
  await wait('document.querySelectorAll(".nft-grid .nft-card").length===2');
  for(const theme of ['midnight','hub21','glacier','neptune']) {
    await evaluate(`document.documentElement.dataset.theme=${JSON.stringify(theme)}`);
    const layout=await evaluate('(()=>{const card=document.querySelector(".nft-grid .nft-card"),image=card.querySelector("[data-open-nft]").getBoundingClientRect(),send=card.querySelector("[data-send-nft]").getBoundingClientRect(),list=card.querySelector("[data-list-nft]").getBoundingClientRect();return {imageBottom:image.bottom,sendTop:send.top,sendHeight:send.height,listTop:list.top,sendRight:send.right,listLeft:list.left,cardWidth:card.getBoundingClientRect().width}})()');
    assert(layout.sendTop>=layout.imageBottom,theme+' actions must be below image');
    assert(layout.sendHeight>=36&&layout.sendHeight<=40,theme+' normal button height');
    assert.equal(layout.sendTop,layout.listTop,theme+' buttons must share a row');
    assert(layout.listLeft>layout.sendRight,theme+' separate buttons');
    await shot(theme+'-nft-gallery');
  }
  await cdp('Page.reload');await wait('!!document.querySelector("#marketplace")');
  await click('#settings');await click('[data-view="display"]');await wait('!!document.querySelector("#theme")');
  for(const theme of ['midnight','neptune']) {
    await evaluate(`(()=>{const select=document.querySelector('#theme');select.value=${JSON.stringify(theme)};select.dispatchEvent(new Event('change'));})()`);
    await wait(`document.documentElement.dataset.theme===${JSON.stringify(theme)}`);
    assert.equal(await evaluate('document.body.getBoundingClientRect().width'),420);
  }
  await cdp('Page.reload');await wait('!!document.querySelector("#marketplace")');
  await click('#marketplace');await wait('!!document.querySelector("#agora-nft")');assert.equal(await evaluate('document.querySelector("#agora-dotk b").textContent'),'dot.k Market');await shot('agora-choice');
  await click('#agora-nft');await wait('document.querySelectorAll(".nft-market-card").length===10');
  assert.equal(await evaluate('document.querySelector("#nft-market-sort").value'),'recent');
  assert.equal(await evaluate('document.querySelectorAll(".nft-listing-state").length'),0);
  await click('.nft-market-card details summary');assert.match(await evaluate('document.querySelector(".nft-market-card details").textContent'),/Seller wallet[\s\S]*Background[\s\S]*Blue/);
  assert.equal(await evaluate('document.querySelector(".nft-market-card h2").textContent'),'KASZOMBIES #55');await shot('nft-browse');
  await click('#nft-market-more');await wait('document.querySelectorAll(".nft-market-card").length===12');assert.equal(await evaluate('!!document.querySelector("#nft-market-more")'),false);
  await evaluate('const collection=document.querySelector("#nft-market-collection");collection.value="KASZOMBIES";collection.dispatchEvent(new Event("change"))');await wait('!!document.querySelector(".nft-traits")');assert.equal(await evaluate('document.querySelector(".nft-traits").open'),false);
  await evaluate('const sort=document.querySelector("#nft-market-sort");sort.value="high";sort.dispatchEvent(new Event("change"))');await wait('window.lastNftRequest.params?.sort==="high"');
  await click('[data-tab="owned"]');await wait('!!document.querySelector("#nft-owned-collection")');assert.equal(await evaluate('document.querySelectorAll("#nft-owned-collection option").length'),3);assert.equal(await evaluate('document.querySelectorAll(".nft-card-actions [data-action=send]").length'),2);await shot('my-nfts');
  await click('[data-tab="listings"]');await wait('document.querySelector(".nft-market-card")?.textContent.includes("Published")');assert.equal(await evaluate('document.querySelector(".nft-market-card").textContent.includes("Publish -")'),false);await shot('my-listings');
  assert.equal(await evaluate('[...document.querySelectorAll(".nft-market-card")].filter(card=>/cancelled|sold/.test(card.querySelector(".nft-listing-state")?.textContent)).every(card=>!card.querySelector("button")&&!/incomplete|Recovery|Publishing/.test(card.textContent))'),true);
  assert.equal(await evaluate('document.querySelectorAll("[data-action=recovery]").length'),1);
  assert.equal(await evaluate('document.querySelectorAll("[data-action=resume]").length'),1);
  assert.equal(await evaluate('document.querySelector(\'[data-nft-row="3"]\').textContent.includes("Published")'),true);
  await cdp('Page.reload');await wait('!!document.querySelector("#marketplace")');
  assert(await evaluate('document.querySelector("#nexus-bell").getBoundingClientRect().right<=420'));
  await click('#marketplace');await click('#agora-nexus');await wait('!!document.querySelector("#nexus-search")');
  assert.match(await evaluate('document.querySelector("#nexus-content").textContent'),/Never miss the perfect NFT deal[\s\S]*Settle securely on Kaspire/);await shot('nexus-home');
  await evaluate('document.querySelector("#nexus-search").value="KASZOMBIES";document.querySelector("#nexus-search").dispatchEvent(new Event("input"))');await click('[data-nexus-action=search]');await wait('document.querySelectorAll(".nexus-token").length===2');
  assert.equal(await evaluate('document.querySelector(".nexus-screen .nft-traits").open'),false);
  await evaluate('const ns=document.querySelector("#nexus-sort");ns.value="rarityRank";ns.dispatchEvent(new Event("change"))');await wait('window.lastNexusRequest.query?.sort==="rarityRank"');await shot('nexus-collection');
  await click('[data-token="0"]');await wait('!!document.querySelector(".nexus-detail")');
  assert.match(await evaluate('document.querySelector(".nexus-detail").textContent'),/Current listing status: LISTED/);
  assert(!/Kaspire listing price:/.test(await evaluate('document.querySelector(".nexus-detail").textContent')));await shot('nexus-nft');
  await click('[data-nexus-action=offer]');await wait('!!document.querySelector("#nexus-duration")');
  assert.equal(await evaluate('document.querySelector("#nexus-duration").value'),'30');assert.equal(await evaluate('document.querySelector("#nexus-offer-submit").disabled'),true);
  await evaluate('const na=document.querySelector("#nexus-amount");na.value="12.5";na.dispatchEvent(new Event("input"));const nc=document.querySelector("#nexus-ack");nc.checked=true;nc.dispatchEvent(new Event("change"))');await shot('nexus-offer');await click('#nexus-offer-submit');await wait('!document.querySelector("#nexus-offer-submit")');
  await wait('!!document.querySelector("#nexus-success-done")');assert.match(await evaluate('document.querySelector(".approval-sheet").textContent'),/Offer created successfully/);await click('#nexus-success-done');
  await click('[data-nexus-action=dashboard]');await wait('!!document.querySelector("[data-offer]")');await click('[data-nexus-action=agree-to-relist]');await wait('!!document.querySelector("#nexus-action-confirm")');
  assert.match(await evaluate('document.querySelector(".approval-sheet").textContent'),/No funds are locked or spent/);await click('#nexus-action-confirm');await wait('document.querySelector("[data-offer]").textContent.toLowerCase().includes("agreed waiting relist")');await shot('nexus-negotiation');
  await click('[data-nexus-action=notifications]');await wait('!!document.querySelector(".nexus-notification")');await shot('nexus-notifications');
  // Autosizing must have an intrinsic 420px width even when starting at 20px.
  await cdp('Emulation.setDeviceMetricsOverride',{width:20,height:700,deviceScaleFactor:1,mobile:false});
  assert.equal(await evaluate('parseFloat(getComputedStyle(document.documentElement).width)'),420);
  assert.equal(await evaluate('parseFloat(getComputedStyle(document.body).width)'),420);
  await cdp('Emulation.setDeviceMetricsOverride',{width:420,height:700,deviceScaleFactor:1,mobile:false});
  await cdp('Page.reload');await wait('!!document.querySelector("#receive")');await click('#receive');await wait('document.querySelector("#receive-qr")?.complete');assert.equal(await evaluate('getComputedStyle(document.querySelector("#receive-qr")).filter'),'none');await shot('receive');
  console.log('Neptune/NFT browser checks passed: theme selection, collection thumbnails, vertical gallery with horizontal Send + List in four themes, terminal/remote/pending listings, intrinsic popup width, orb placement, pagination, filters and QR visibility.');
}finally{browser.kill('SIGTERM');await new Promise(r=>{browser.once('exit',r);setTimeout(r,3000);});server.close();await rm(profile,{recursive:true,force:true,maxRetries:5,retryDelay:100});}
