// Actual packaged background/provider/approval UI and native WASM. All chain
// responses and broadcasts are synthetic; run in a network-isolated namespace.
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp,mkdir,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import init,* as rawCore from './generated/wasm/kaspa_secure_core.mjs';
import {secureCore} from './generated/secretInputs.mjs';
import initKaspa,{payToScriptHashScript} from '../node_modules/@kronsdk/kron-sdk/vendor/kaspa/kaspa.js';
await initKaspa({module_or_path:await readFile('node_modules/@kronsdk/kron-sdk/vendor/kaspa/kaspa_bg.wasm')});
const exports=await init({module_or_path:await readFile('tests/generated/wasm/kaspa_secure_core_bg.wasm')});
const core=secureCore(rawCore,exports.memory),owner=core.publicKey('private:'+'11'.repeat(32));
const sender=JSON.parse(core.importPrivateKey('11'.repeat(32))).address;
const recipient=JSON.parse(core.importPrivateKey('22'.repeat(32))).address;
const recipientOwner=core.publicKey('private:'+'22'.repeat(32));
const template=JSON.parse(await readFile('../../crates/kaspa_secure_core/src/kcc20_standard_template.json','utf8'));
const redeem=template.prefix+'08881300000000000020'+recipientOwner+'0100010120'+'0'.repeat(64)+'20'+'0'.repeat(64)+template.suffix;
const script=payToScriptHashScript(redeem),borrowedSpk=script.script;script.free();
const scratch=await mkdtemp(join(tmpdir(),'kaspire-native-dapp-'));
const extension=process.argv[2]?join(scratch,'extension'):resolve('dist');
if(process.argv[2])execFileSync('unzip',['-q',resolve(process.argv[2]),'-d',extension]);
const port=9371,endpoint=`http://127.0.0.1:${port}`,display=':85';
const server=createServer((_req,res)=>{res.setHeader('content-type','text/html');res.end('<!doctype html><h1>Native KCC20 fixture</h1>');});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const site=`http://127.0.0.1:${server.address().port}`;
const xvfb=spawn('Xvfb',[display,'-screen','0','1366x900x24','-nolisten','tcp'],{stdio:'ignore'});
const delay=ms=>new Promise(r=>setTimeout(r,ms));await delay(250);
const browser=spawn('chromium',['--no-sandbox','--disable-gpu','--no-first-run',`--user-data-dir=${join(scratch,'profile')}`,`--disable-extensions-except=${extension}`,`--load-extension=${extension}`,`--remote-debugging-port=${port}`,'about:blank'],{stdio:'ignore',env:{...process.env,DISPLAY:display}});
function cdp(ws,method,params={}){return new Promise((resolve,reject)=>{const socket=new WebSocket(ws),timer=setTimeout(()=>{socket.close();reject(Error(method+' timeout'));},20000);socket.onopen=()=>socket.send(JSON.stringify({id:1,method,params}));socket.onerror=reject;socket.onmessage=e=>{const m=JSON.parse(e.data);if(m.id!==1)return;clearTimeout(timer);socket.close();m.error?reject(Error(JSON.stringify(m.error))):resolve(m.result);};});}
async function evaluate(ws,expression,userGesture=false){const r=await cdp(ws,'Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true,userGesture});if(r.exceptionDetails)throw Error(r.exceptionDetails.exception?.description??r.exceptionDetails.text);return r.result?.value;}
async function targets(){return(await fetch(endpoint+'/json/list')).json();}
async function until(fn,label,attempts=180){for(let i=0;i<attempts;i++){try{const v=await fn();if(v)return v;}catch{}await delay(100);}throw Error('Missing '+label);}
async function open(url){return(await(await fetch(endpoint+'/json/new?'+encodeURIComponent(url),{method:'PUT'})).json()).webSocketDebuggerUrl;}
let browserWs;
try{
  const worker=await until(async()=>(await targets()).find(t=>t.type==='service_worker'),'worker'),ws=worker.webSocketDebuggerUrl;
  browserWs=(await(await fetch(endpoint+'/json/version')).json()).webSocketDebuggerUrl;
  await evaluate(ws,`(()=>{
    const original=globalThis.fetch,cid='cc'.repeat(32),owner=${JSON.stringify(owner)},sender=${JSON.stringify(sender)},recipientOwner=${JSON.stringify(recipientOwner)},borrowedSpk=${JSON.stringify(borrowedSpk)};
    let release;const displayBlocked=new Promise(r=>{release=r;});
    const f=globalThis.kcc20Fixture={calls:[],broadcasts:[],count:1,borrowed:false,recipientUnavailable:false,blockPayment:false,displayStarted:false,accepted:new Set(),releaseDisplay:release};
    const envelope=data=>Response.json({data,meta:{network:'mainnet',reference_commit:'c8a087117735a1f87c5c6d115fcddeaf2562c784'}});
    const spk='aa20855a2552d9b37d5da29c0ffa7de5c35d712440d66e77048bbb80e31ab2f769d187';
    const rows=()=>Array.from({length:f.count},(_,i)=>({txid:(160+i+(f.offset??0)).toString(16).repeat(32),output_index:0,balance_raw:'1000',amount_sompi:'100000000'}));
    globalThis.fetch=async(input,options={})=>{
      const url=String(input);if(url.startsWith('chrome-extension:')||url.startsWith('http://127.0.0.1:'))return original(input,options);
      f.calls.push(url);const u=new URL(url),p=u.pathname,id=p.split('/').at(-1);
      if(url==='https://gothdag.kaslab.space/api/covenant-broadcast'){
        const plans=(await chrome.storage.local.get('pendingKcc20Plans')).pendingKcc20Plans,plan=plans?.[sender],tx=plan?.transactions[plan.nextStep];
        if(!tx||JSON.parse(options.body).signedTxJson!==tx.signedTxJson)throw Error('Broadcast before immutable journal');
        f.broadcasts.push(tx.transactionId);f.accepted.add(tx.transactionId);return Response.json({txId:tx.transactionId});
      }
      if(p.startsWith('/api/local-node/transactions/')){
        if(f.accepted.has(id))return f.freezeConfirmation?new Response('{}',{status:503}):Response.json({transaction_id:id,is_accepted:true});
        const row=rows().find(r=>r.txid===id),borrow=id==='dd'.repeat(32);
        if(!row&&!borrow)return new Response('{}',{status:404});
        return Response.json({transaction_id:id,is_accepted:true,outputs:[{index:0,covenant_id:cid,amount:borrow?'500000000':'100000000',script_public_key:borrow?borrowedSpk:spk,script_public_key_address:'kaspa:'+(borrow?'p':'q').repeat(61)}]});
      }
      if(p.endsWith('/utxos')){
        if(decodeURIComponent(p).includes(sender))return Response.json([{address:sender,outpoint:{transactionId:'bb'.repeat(32),index:0},utxoEntry:{amount:2000000000,scriptPublicKey:{version:0,scriptPublicKey:'20'+owner+'ac'},blockDaaScore:123,isCoinbase:false}}]);
        const borrow=p.includes('kaspa:'+'p'.repeat(61));return Response.json((borrow?[{txid:'dd'.repeat(32)}]:rows()).map(r=>({outpoint:{transactionId:r.txid,index:0},utxoEntry:{amount:borrow?'500000000':'100000000',blockDaaScore:123,isCoinbase:false,scriptPublicKey:{scriptPublicKey:borrow?borrowedSpk:spk}}})));
      }
      if(p.endsWith('/info/fee-estimate'))return Response.json({priorityBucket:{feerate:100}});
      if(p.endsWith('/info/price'))return Response.json({price:0.03});
      if(url.startsWith('https://kasvio.network/api/kcc20/v4/')){
        if(p.includes('/addresses/')){f.displayStarted=true;await displayBlocked;return new Response('{}',{status:503});}
        if(p.endsWith('/tokens/'+cid)){
          if(f.blockPayment)await new Promise(r=>{f.releasePayment=r;});
          return envelope({covenant_id:cid,profile_id:'KCC20PublicMint@c8a0871',recognition:'hash_proven_reference_actor_family',metadata:{binding_verified:true,covenant_id:cid,ticker:'WALLET',decimals:0}});
        }
        if(p.endsWith('/balance')){
          const recipient=u.searchParams.get('owner')===recipientOwner,outputs=recipient?(f.borrowed?[{txid:'dd'.repeat(32),output_index:0,balance_raw:'5000',amount_sompi:'500000000'}]:[]):rows();
          return envelope({covenant_id:cid,owner_value:recipient?recipientOwner:owner,owner_scheme:0,available:!(recipient&&f.recipientUnavailable),balance_raw:recipient?(f.borrowed?'5000':'0'):String(f.count*1000),outputs});
        }
        if(p.includes('/transactions/')){const borrow=id==='dd'.repeat(32);return envelope({txid:id,outputs:[{io_index:0,actor:'KCC20',covenant_id:cid,token_amount:borrow?'5000':'1000',owner_scheme:0,owner_value:borrow?recipientOwner:owner,state_hash_verified:true,template_hash:'9703112ee6e3555107cd168858992b77d3b74f655205b2b463b1f9ec2ec73cf7',borrow_scheme:borrow?1:0,borrow_guard:'0'.repeat(64),extension_commitment:'0'.repeat(64)}]});}
      }
      if(p.endsWith('/balance'))return Response.json({balance:2000000000});
      return new Response('{}',{status:503});
    };return true;
  })()`);
  const base=new URL('.',worker.url).href,wallet=await open(base+'wallet.html');
  await until(()=>evaluate(wallet,'!!document.querySelector("#first-key")'),'onboarding');
  await evaluate(wallet,'document.querySelector("#first-key").click();true');
  await until(()=>evaluate(wallet,'!!document.querySelector("#private-key")'),'import form');
  await evaluate(wallet,`document.querySelector('#private-key').value='11'.repeat(32);document.querySelector('#password').value='Disposable native fixture 2026';document.querySelector('#password-confirm').value='Disposable native fixture 2026';document.querySelector('#submit').click();true`);
  await until(()=>evaluate(wallet,'!!document.querySelector("#send")'),'wallet home');
  await until(()=>evaluate(ws,'kcc20Fixture.displayStarted'),'stalled background discovery');
  const dapp=await open(site+'/dapp');await until(()=>evaluate(dapp,'!!window.kaspire'),'provider');
  await evaluate(dapp,'window.connected="pending";kaspire.requestAccounts().then(v=>window.connected=v).catch(e=>window.connected=e.message);true');
  const connection=await until(async()=>(await targets()).find(t=>t.url.includes('/approval.html')),'connection review');
  await until(()=>evaluate(connection.webSocketDebuggerUrl,'!!document.querySelector("#approve")'),'connection approve');
  await evaluate(connection.webSocketDebuggerUrl,'document.querySelector("#approve").click();true');
  await until(()=>evaluate(dapp,'Array.isArray(window.connected)'),'connected');
  const start=async amount=>evaluate(dapp,`window.payment='pending';kaspire.sendKCC20({to:${JSON.stringify(recipient)},covenantId:'cc'.repeat(32),amount:${amount}}).then(v=>window.payment={ok:v}).catch(e=>window.payment={error:e.message});true`);
  const popup=async selector=>until(async()=>{for(const t of (await targets()).filter(t=>t.url.includes('/approval.html')))if(await evaluate(t.webSocketDebuggerUrl,`!!document.querySelector(${JSON.stringify(selector)})`).catch(()=>false))return t.webSocketDebuggerUrl;},selector).catch(async error=>{
    console.log('Payment diagnostic:',await evaluate(dapp,'window.payment'),await evaluate(ws,'kcc20Fixture.calls.slice(-15)'));
    for(const t of (await targets()).filter(t=>t.url.includes('/approval.html')))console.log('Approval:',await evaluate(t.webSocketDebuggerUrl,'document.body.innerText').catch(()=>''));
    throw error;
  });
  // Cancellation while a source is stalled; late completion cannot sign.
  await evaluate(ws,'kcc20Fixture.blockPayment=true;true');await start(500);
  let ui=await popup('#cancel-preparation');assert.equal(await evaluate(ui,'!!document.querySelector("#approve")'),false);
  await evaluate(ui,'document.querySelector("#cancel-preparation").click();true');
  await until(()=>evaluate(dapp,'!!window.payment.error'),'cancelled result');
  await evaluate(ws,'kcc20Fixture.blockPayment=false;kcc20Fixture.releasePayment();true');await delay(700);
  assert.equal(await evaluate(ws,'kcc20Fixture.broadcasts.length'),0);
  // Each theme reaches native review despite the unrelated blocked display lane.
  for(const theme of ['midnight','hub21','glacier','neptune']){
    await evaluate(wallet,`chrome.runtime.sendMessage({channel:'wallet',command:'setSettings',settings:{theme:${JSON.stringify(theme)}}})`);
    await start(500);ui=await popup('#approve');
    assert.match(await evaluate(ui,'document.body.innerText'),/Authorize complete KCC20 payment plan/);
    assert.equal(await evaluate(ui,'document.documentElement.dataset.theme'),theme);
    await cdp(ui,'Emulation.setDeviceMetricsOverride',{width:390,height:760,deviceScaleFactor:1,mobile:false});
    assert(await evaluate(ui,'document.documentElement.scrollWidth<=innerWidth+1'),theme+' narrow layout');
    await evaluate(ui,'document.querySelector("#reject").click();true');await until(()=>evaluate(dapp,'!!window.payment.error'),'rejected');
    assert.equal(await evaluate(ws,'kcc20Fixture.broadcasts.length'),0);
  }
  // Failed recipient availability cannot fund a new cell or sign anything.
  await evaluate(ws,'kcc20Fixture.recipientUnavailable=true;true');await start(500);
  const failure=await until(()=>evaluate(dapp,'window.payment.error'),'recipient lookup failure');assert.match(failure,/No new cell was funded/);
  assert.equal(await evaluate(ws,'kcc20Fixture.broadcasts.length'),0);
  await evaluate(ws,'kcc20Fixture.recipientUnavailable=false;kcc20Fixture.borrowed=true;true');
  await start(500);ui=await popup('#approve');
  assert.match(await evaluate(ui,'document.body.innerText'),/reusing existing cell/);
  await evaluate(ui,'document.querySelector("#approve").click();true');
  const paid=await until(()=>evaluate(dapp,'window.payment.ok'),'borrowed receive signed with native VM');assert.match(paid,/^[0-9a-f]{64}$/);
  assert.equal(await evaluate(ws,'kcc20Fixture.broadcasts.length'),1);
  assert.equal(await evaluate(wallet,`chrome.storage.local.get('pendingKcc20Plans').then(v=>Object.keys(v.pendingKcc20Plans??{}).length)`),0);
  // Seven fragmented inputs: one explicit review, three immutable transactions.
  await evaluate(ws,'kcc20Fixture.count=7;kcc20Fixture.borrowed=false;true');await start(6999);ui=await popup('#approve');
  assert.match(await evaluate(ui,'document.body.innerText'),/3 on-chain transactions/);
  await evaluate(ui,'document.querySelector("#approve").click();true');
  const final=await until(()=>evaluate(dapp,'window.payment.ok'),'complete multi-transaction native plan');
  assert.equal(await evaluate(ws,'kcc20Fixture.broadcasts.length'),4);
  assert.equal(final,await evaluate(ws,'kcc20Fixture.broadcasts.at(-1)'),'dApp receives final payment ID only');
  // Ambiguous node confirmation leaves every signed step durable. Reopening
  // and Continue must not sign again or rebroadcast the already accepted step.
  await evaluate(ws,'kcc20Fixture.count=4;kcc20Fixture.offset=16;kcc20Fixture.freezeConfirmation=true;true');await start(3999);ui=await popup('#approve');
  await evaluate(ui,'document.querySelector("#approve").click();true');
  const pending=await until(()=>evaluate(dapp,'window.payment.error'),'uncertain saved plan',350);
  assert.match(pending,/signed and saved/);assert.match(pending,/do not pay again/);
  assert.equal(await evaluate(ws,'kcc20Fixture.broadcasts.length'),5);
  const journal=await evaluate(wallet,`chrome.storage.local.get('pendingKcc20Plans').then(v=>v.pendingKcc20Plans[${JSON.stringify(sender)}])`);
  assert.equal(journal.nextStep,0);assert.equal(journal.transactions.length,2);
  await start(500);assert.match(await until(()=>evaluate(dapp,'window.payment.error'),'duplicate blocked'),/approved KCC20 payment plan is saved/);
  assert.equal(await evaluate(ws,'kcc20Fixture.broadcasts.length'),5);
  await evaluate(ws,'kcc20Fixture.freezeConfirmation=false;true');await cdp(wallet,'Page.reload');
  await until(()=>evaluate(wallet,'[...document.querySelectorAll("button")].some(b=>b.textContent==="Continue KCC20 transfer")'),'reopened recovery card');
  await evaluate(wallet,'[...document.querySelectorAll("button")].find(b=>b.textContent==="Continue KCC20 transfer").click();true');
  await until(()=>evaluate(wallet,'!!document.querySelector(".receipt-check")'),'recovery receipt');
  assert.equal(await evaluate(ws,'kcc20Fixture.broadcasts.length'),6,'Accepted parent is not sent twice');
  assert.equal(await evaluate(wallet,`chrome.storage.local.get('pendingKcc20Plans').then(v=>Object.keys(v.pendingKcc20Plans??{}).length)`),0);
  const recorded=await evaluate(wallet,`chrome.storage.local.get('walletActivity').then(v=>(v.walletActivity??[]).map(r=>r.transaction).filter(t=>t.assetKind==='KCC20'))`);
  assert.equal(recorded.length,6,'Every confirmed plan step is recorded exactly once');
  assert.equal(new Set(recorded.map(t=>t.transactionId)).size,6);
  await evaluate(wallet,'document.querySelector("#close-receipt").click();true');
  await until(()=>evaluate(wallet,'!!document.querySelector("#dual-window:not(:disabled)")'),'home after recovery');
  // The real Chrome Side Panel, not sidepanel.html opened as an ordinary tab.
  await cdp(wallet,'Page.bringToFront');
  await evaluate(wallet,'document.querySelector("#dual-window").click();true',true);
  const panel=await until(async()=>(await targets()).find(t=>t.url.startsWith(base+'sidepanel.html?view=')),'side panel');
  const panelWs=panel.webSocketDebuggerUrl;
  await until(()=>evaluate(panelWs,'document.documentElement.dataset.panelApprovalReady==="true"'),'registered side panel');
  await evaluate(ws,'kcc20Fixture.blockPayment=true;true');await start(500);
  await until(()=>evaluate(panelWs,'!!document.querySelector("#cancel-kcc20-preparation")'),'panel preparation');
  assert.equal((await targets()).some(t=>t.url.includes('/approval.html')),false);
  assert.equal(await evaluate(panelWs,'!!document.querySelector("#accept-approval")'),false);
  await evaluate(panelWs,'document.querySelector("#cancel-kcc20-preparation").click();true');
  await until(()=>evaluate(dapp,'!!window.payment.error'),'panel cancelled immediately');
  await evaluate(ws,'kcc20Fixture.blockPayment=false;kcc20Fixture.releasePayment();true');await delay(700);
  await start(500);
  await until(()=>evaluate(panelWs,'!!document.querySelector("#accept-approval")'),'panel native review');
  assert.match(await evaluate(panelWs,'document.querySelector(".approval-sheet").innerText'),/TOTAL network fees/);
  assert.equal((await targets()).some(t=>t.url.includes('/approval.html')),false);
  await evaluate(panelWs,'document.querySelector("#reject-approval").click();true');
  await until(()=>evaluate(dapp,'!!window.payment.error'),'panel rejected');
  assert.equal(await evaluate(ws,'kcc20Fixture.broadcasts.length'),6);
  await mkdir('artifacts/kcc20-dapp',{recursive:true});
  const image=await cdp(wallet,'Page.captureScreenshot',{format:'png'});await writeFile('artifacts/kcc20-dapp/completed.png',Buffer.from(image.data,'base64'));
  console.log('Packaged KCC20: blocked background discovery, cancel/late result in popup and real side panel, all four themes at 390px, rejected review, fail-closed recipient lookup, native Borrowed Receive, durable-before-broadcast, three-step plan and final-ID return passed. Synthetic broadcasts only.');
}finally{
  if(browserWs)await cdp(browserWs,'Browser.close').catch(()=>{});
  browser.kill('SIGTERM');xvfb.kill('SIGTERM');server.close();await delay(300);await rm(scratch,{recursive:true,force:true});
}
