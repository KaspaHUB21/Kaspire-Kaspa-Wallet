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
  assert(!/Kaspire listing price:/.test(await evaluate('document.querySelector(".nexus-detail").textContent')));
  assert.match(await evaluate('document.querySelector(".nexus-detail").textContent'),/KaspaCom listing price: 11 KAS/);
  assert.equal(await evaluate('document.querySelector(".nexus-market-link").href'),'https://kaspa.com/nft/collections/KASZOMBIES/55');await shot('nexus-nft');
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
  await cdp('Page.reload');await wait('!!document.querySelector("#swap")');await click('#swap');await wait('!!document.querySelector("#kron-open")');
  await click('#kron-open');await wait('!!document.querySelector("[data-kron-token]")');await click('[data-kron-token]');await wait('document.querySelector(".available")?.textContent.includes("100 KAS")');
  await click('[data-kron-side=sell]');assert.match(await evaluate('document.querySelector(".available").textContent'),/420\.29 ROCKET/);
  await evaluate('const ka=document.querySelector("#kron-amount");ka.value="420.29";ka.dispatchEvent(new Event("input"))');await click('#kron-quote');await wait('!!document.querySelector(".form .review-card")');
  assert.match(await evaluate('document.querySelector(".form .review-card").textContent'),/420\.29 ROCKET/);
  for(const theme of ['midnight','hub21','glacier','neptune']) {
    await evaluate(`document.documentElement.dataset.theme=${JSON.stringify(theme)}`);
    assert.equal(await evaluate('document.body.getBoundingClientRect().width'),420);
    assert(await evaluate('(()=>{const h=document.querySelector(".kron-screen .market-title h1").getBoundingClientRect(),r=document.querySelector("#kron-reload").getBoundingClientRect();return h.right<r.left&&r.right<=420&&h.height<50})()'),theme+' KRON title and reload alignment');
    assert(await evaluate('Array.from(document.querySelectorAll(".kron-detail-row b")).every(e=>e.getBoundingClientRect().right<=420)'),theme+' quote fits popup');await shot(theme+'-kron-swap');
  }
  await click('#kron-review');await wait('!!document.querySelector("#kron-submit")');assert.match(await evaluate('document.querySelector(".approval-sheet").textContent'),/420\.29 ROCKET/);
  await click('#kron-submit');await wait('!!document.querySelector("#accept-approval")');
  assert.equal(await evaluate('window.kronFixtureSigned'),0,'No signing before visible security approval');
  assert.match(await evaluate('document.querySelector(".approval-modal").textContent'),/Secure KRON swap/);
  await click('#reject-approval');await wait('!!document.querySelector(".kron-screen .error")');
  assert.equal(await evaluate('window.kronFixtureSigned'),0,'Rejecting approval never signs');
  await click('#kron-quote');await wait('!!document.querySelector(".form .review-card")');
  await click('#kron-review');await wait('!!document.querySelector("#kron-submit")');await click('#kron-submit');
  await wait('!!document.querySelector("#accept-approval")');await click('#accept-approval');
  await wait('!!document.querySelector("#kron-return")');assert.match(await evaluate('document.querySelector(".receipt-screen").textContent'),/Sold ROCKET[\s\S]*420\.29 ROCKET/);
  assert.equal(await evaluate('window.kronFixtureSigned'),1,'Exactly the explicitly approved swap is signed');
  assert.equal(await evaluate('!!document.querySelector("#kron-resume")'),false);await shot('kron-receipt');await click('#kron-return');await wait('!!document.querySelector("[data-kron-token]")');
  await cdp('Page.reload');await wait('!!document.querySelector("#activity")');
  await evaluate(`window.swapActivityFixture=[{
    transactionId:'a'.repeat(64),blockTime:1792024147269,isAccepted:true,incoming:false,assetKind:'KAS',assetSymbol:'KAS',
    amountSompi:927320000,amountIsWalletChange:true,walletInputSompi:8362180460120,walletOutputSompi:8361253140120,walletBalanceChangeSompi:-927320000,
    from:[{address:'kaspa:pool',amountSompi:50760024000000,ownerId:'pool-covenant'},{address:fixtureAddress,amountSompi:8362180460120,isWallet:true}],
    to:[{address:'kaspa:pool',amountSompi:50760824000000,ownerId:'pool-covenant'},{address:fixtureAddress,amountSompi:8361253140120,isWallet:true}],
    feeSompi:37320000,totalInputSompi:59122254460120,totalOutputSompi:59122217140120,inputCount:3,outputCount:6,
  },{transactionId:'b'.repeat(64),blockTime:1792024020128,isAccepted:true,incoming:true,assetKind:'KAS',assetSymbol:'KAS',amountSompi:1101480000,amountIsWalletChange:true,walletInputSompi:8361078980120,walletOutputSompi:8362180460120,walletBalanceChangeSompi:1101480000,from:[],to:[]}];`);
  await click('#activity');await wait('document.querySelectorAll(".activity-row").length===2');
  assert.match(await evaluate('document.querySelectorAll(".activity-row")[0].innerText'),/Sent[\s\S]*Wallet balance change[\s\S]*-9\.2732 KAS/);
  assert.match(await evaluate('document.querySelectorAll(".activity-row")[1].innerText'),/Received[\s\S]*\+11\.0148 KAS/);
  assert.doesNotMatch(await evaluate('document.querySelector("#history").innerText'),/50760/);
  await click('[data-tx="0"]');await wait('!!document.querySelector(".wallet-movement")');
  assert.match(await evaluate('document.querySelector(".tx-detail-head").innerText'),/-9\.2732 KAS/);
  assert.match(await evaluate('document.querySelector(".detail-section").innerText'),/Wallet balance change[\s\S]*9\.2732 KAS[\s\S]*Confirmed/);
  assert.match(await evaluate('document.querySelector(".wallet-movement").innerText'),/KAS balance change[\s\S]*-9\.2732 KAS/);
  assert.equal(await evaluate('document.querySelector(".full-transaction").open'),false);
  assert.doesNotMatch(await evaluate('document.querySelector(".transaction-detail").innerText'),/507600\.24 KAS/);
  await shot('swap-wallet-activity');await click('.full-transaction summary');
  assert.match(await evaluate('document.querySelector(".full-transaction").innerText'),/not the amount sent by your wallet[\s\S]*507600\.24 KAS[\s\S]*507608\.24 KAS/);
  await shot('swap-full-transaction');
  await cdp('Page.reload');await wait('!!document.querySelector("#receive")');await click('#receive');await wait('document.querySelector("#receive-qr")?.complete');assert.equal(await evaluate('getComputedStyle(document.querySelector("#receive-qr")).filter'),'none');await shot('receive');
  await cdp('Emulation.setDeviceMetricsOverride',{width:320,height:900,deviceScaleFactor:1,mobile:false});
  await cdp('Page.navigate',{url:`http://127.0.0.1:${server.address().port}/sidepanel.html`});
  await wait('!!document.querySelector("#balance")');
  assert.equal(await evaluate('document.documentElement.classList.contains("side-panel")'),true);
  await evaluate(`fixtureAssets.kcc20.push({symbol:'KASPIREISTHEBESTKASPAWALLET',rawBalance:'21000000',decimals:0,covenantId:'c'.repeat(64)});`);
  await click('#activity');await wait('!!document.querySelector("#history")');await click('#back');
  await wait('Array.from(document.querySelectorAll(".asset-row b")).some(e=>e.textContent==="KASPIREISTHEBESTKASPAWALLET")');
  await evaluate('document.querySelector("details[data-category=kcc20]").open=true');
  for(const theme of ['midnight','hub21','glacier','neptune']) {
    await evaluate(`document.documentElement.dataset.theme=${JSON.stringify(theme)}`);
    assert.equal(await evaluate('document.documentElement.scrollWidth<=innerWidth'),true,theme+' side panel overflows');
    assert.equal(await evaluate('document.body.getBoundingClientRect().width'),320);
    const header=await evaluate('Array.from(document.querySelectorAll(".top .icon")).map(e=>{const r=e.getBoundingClientRect();return {x:r.x,y:r.y,w:r.width,h:r.height}})');
    assert.ok(header.every(r=>r.x>=0&&r.x+r.w<=320),theme+' header overflows');
    assert.ok(header.every(r=>Math.abs(r.y-header[0].y)<1),theme+' header controls misaligned');
    await shot(theme+'-side-panel-320');
  }
  await evaluate(`{
    const base=chrome.runtime.sendMessage;
    window.pendingActivityFixture=[];
    window.activityFixtureRows=Array.from({length:121},(_,i)=>({transactionId:i.toString(16).padStart(64,'0'),blockTime:1792800000000-i,isAccepted:true,incoming:true,assetKind:i===0?'KCC20':'KAS',assetSymbol:i===0?'KASPIREISTHEBESTKASPAWALLET':'KAS',displayAmount:'21000000',amountSompi:100000000,from:[],to:[]}));
    chrome.runtime.sendMessage=async message=>{
      if(message.command!=='historySource')return base(message);
      if(message.source==='Covenant history')return new Promise(resolve=>pendingActivityFixture.push(()=>resolve({result:{items:[]}})));
      if(message.source==='KAS history')return {result:{items:activityFixtureRows.slice(0,message.limit)}};
      return {result:{items:[]}};
    };
  }`);
  await click('#activity');await wait('document.querySelectorAll(".activity-row").length===50');
  assert.match(await evaluate('document.querySelector("#activity-status").textContent'),/Loading additional/);
  assert.equal(await evaluate('document.documentElement.scrollWidth<=innerWidth'),true);
  assert.match(await evaluate('document.querySelector(".activity-row strong").textContent'),/21,000,000 KASPIREISTHEBESTKASPAWALLET/);
  await shot('side-panel-progressive-activity');
  await click('#activity-more');await wait('document.querySelectorAll(".activity-row").length===100');
  await click('#activity-more');await wait('document.querySelectorAll(".activity-row").length===121');
  assert.equal(await evaluate('document.querySelector("#activity-more").hidden'),true);
  await evaluate('pendingActivityFixture.splice(0).forEach(resolve=>resolve())');
  console.log('Neptune/NFT/KRON and Side Panel layout checks passed: four themes, 320px panel, aligned header, long names, progressive 50/100/121 activity with a stalled source, gallery, listings, Nexus, swaps and QR.');
}finally{browser.kill('SIGTERM');await new Promise(r=>{browser.once('exit',r);setTimeout(r,3000);});server.close();await rm(profile,{recursive:true,force:true,maxRetries:5,retryDelay:100});}
