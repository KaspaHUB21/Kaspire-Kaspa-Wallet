import {formatRawTokenAmount} from '../shared/tokenAmount';
type Row=Record<string,any>;
type Hooks={command(name:string,args?:Record<string,unknown>,signal?:AbortSignal):Promise<any>;shell(html:string,title?:string,back?:boolean):void;address():string};
const esc=(v:unknown)=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
const units=(v:unknown,d:number)=>typeof v==='string'&&/^\d+$/.test(v)?formatRawTokenAmount(v,d):'Unavailable';
export function nativeBalance(value:Row){
 if(!value||typeof value.complete!=='boolean'||typeof value.verifiedRaw!=='string'||!/^\d{1,40}$/.test(value.verifiedRaw)||typeof value.maximumRaw!=='string'||!/^\d{1,40}$/.test(value.maximumRaw)||typeof value.maximumAmount!=='string'||value.maximumAmount.length>48||!/^(0|[1-9]\d*)(\.\d{1,6})?$/.test(value.maximumAmount)||!Number.isInteger(value.count)||value.count<0||value.count>64)throw Error('kUSDT balance unavailable.');
 const [whole,fraction='']=value.maximumAmount.split('.');if(BigInt(whole+fraction.padEnd(6,'0'))!==BigInt(value.maximumRaw)||BigInt(value.maximumRaw)>BigInt(value.verifiedRaw))throw Error('kUSDT balance verification differs.');return value;
}
function details(r:Row){
 if(r?.profile!=='trestly-mainnet-v2'||!['buy','sell'].includes(r.side))throw Error('Invalid native swap review.');
 const buy=r.side==='buy',line=(label:string,value:string)=>`<div class="kron-detail-row"><span>${esc(label)}</span><b>${esc(value)}</b></div>`;
 return line('You pay',units(r.amountIn,buy?8:6)+(buy?' KAS':' kUSDT'))+line('You receive',units(r.amountOut,buy?6:8)+(buy?' kUSDT':' KAS'))+line('Pool fee','0.50% · included')+line('Network fee','up to '+units(r.maxFeeSompi,8)+' KAS')+(buy?line('Your token storage',units(r.tokenValueSompi,8)+' KAS · not a fee'):'');
}
export async function openNativeSwap(hooks:Hooks){
 const address=hooks.address(),lifetime=new AbortController();
 hooks.shell('<section class="marketplace-screen native-swap-screen"><div class="market-title"><span class="market-emblem"><img src="trestly.svg" alt="Trestly"></span><div><h1>KAS ↔ kUSDT</h1><p>Trestly KasPool · Kaspa Layer 1</p></div><button id="native-refresh" class="icon" aria-label="Refresh KAS / kUSDT">↻</button></div><div id="native-content" data-preserve-case></div></section>','KAS / kUSDT',true);
 const host=document.querySelector<HTMLElement>('#native-content')!;
 let side='buy',amount='',quote:Row|undefined,pending:Row|undefined,receipt:Row|undefined,balance:Row|undefined,loaded=false,previousReceipt=false,busy=false,balanceLoading=false,error='',balanceError='',revision=0,balanceRevision=0,balanceAbort:AbortController|undefined;
 const active=()=>host.isConnected&&!lifetime.signal.aborted&&hooks.address()===address;
 const call=(action:string,args:Row={},signal=lifetime.signal)=>hooks.command('dex',{venue:'trestly',action,args},signal);
 const observer=new MutationObserver(()=>{if(host.isConnected)return;observer.disconnect();balanceAbort?.abort();lifetime.abort();});observer.observe(document.body,{childList:true,subtree:true});
 async function context(){const value=await call('context');if(active()){pending=value.pending??undefined;if(value.last?.transactionId!==receipt?.transactionId)previousReceipt=true;receipt=value.last??undefined;loaded=true;}}
 async function loadBalance(){
  balanceAbort?.abort();balanceAbort=new AbortController();const turn=++balanceRevision;balanceLoading=true;balanceError='';paint();
  try{const value=nativeBalance(await call('balance',{},AbortSignal.any([lifetime.signal,balanceAbort.signal])));if(active()&&turn===balanceRevision)balance=value;}
  catch(e){if(active()&&turn===balanceRevision)balanceError=(e as Error).message;}
  finally{if(active()&&turn===balanceRevision){balanceLoading=false;paint();}}
 }
 async function run(work:()=>Promise<void>){if(busy||!active())return;busy=true;error='';receipt=undefined;previousReceipt=false;paint();try{await work();}catch(e){if(active())error=(e as Error).message;}finally{if(active()){busy=false;paint();}}}
 async function submit(action:'submit'|'resume',id?:string){try{const result=await call(action,id?{id}:{});if(active()){receipt=result;quote=undefined;amount='';}}finally{if(active()){await context();if(side==='sell'&&!pending)void loadBalance();}}}
 function paint(){
  if(!active())return;
  const canMax=!!balance&&balance.complete&&BigInt(balance.maximumRaw)>0n&&!busy&&!balanceLoading&&!balanceError;
  const saved=pending?`<article class="review-card native-recovery"><h2>Saved swap · check status</h2><p>Keep the same signed transaction until its result is confirmed. Do not create another swap.</p><code>${esc(pending.transactionId)}</code><button id="native-resume" ${busy?'disabled':''}>Check / resend saved swap</button></article>`:'';
  const available=side==='sell'?`<article class="review-card"><p class="available" role="status">${balanceLoading?'Checking kUSDT balance…':balanceError?'kUSDT balance unavailable':balance?(balance.complete||balance.count>0?(balance.complete?'Available: ':'Verified available: ')+units(balance.verifiedRaw,6)+' kUSDT':'Balance incomplete · verification unavailable'):'kUSDT balance unavailable'}</p>${balance&&(balanceLoading||balanceError)?`<p>Last verified: ${esc(units(balance.verifiedRaw,6))} kUSDT</p>`:''}${balance&&!balance.complete?'<p>Some token cells could not be verified. This is not a zero balance. MAX is unavailable until verification is complete.</p>':''}${balance&&BigInt(balance.verifiedRaw)>BigInt(balance.maximumRaw)?`<p>Your balance spans multiple token cells. MAX uses the largest verified cell: ${esc(units(balance.maximumRaw,6))} kUSDT. Larger swaps require consolidation first.</p>`:''}${balanceError?`<p class="error">${esc(balanceError)}</p>`:''}<button id="native-balance" class="outline" ${busy||balanceLoading?'disabled':''}>Refresh balance</button></article>`:'';
  host.innerHTML=`<p>Native swap · no dApp connection</p>${error?`<p class="error" role="alert">${esc(error)}</p>`:''}${busy?'<p class="loading" role="status">Checking pool and wallet coins on the Kaspa node…</p>':''}${saved}${loaded&&!pending?`<div class="segmented rocket-side"><button data-native-side="buy" class="${side==='buy'?'active':''}" ${busy?'disabled':''}>Buy kUSDT</button><button data-native-side="sell" class="${side==='sell'?'active':''}" ${busy?'disabled':''}>Sell kUSDT</button></div>${available}<div class="form"><label>${side==='buy'?'You pay KAS':'You pay kUSDT'}<div class="amount"><input id="native-amount" inputmode="decimal" autocomplete="off" value="${esc(amount)}" ${busy?'disabled':''}>${side==='sell'?`<button id="native-max" class="outline" ${canMax?'':'disabled'}>MAX</button>`:''}</div></label><button id="native-quote" class="outline" ${busy||!amount?'disabled':''}>${quote?'Refresh quote':'Get live quote'}</button>${quote?`<article id="native-quote-result" class="review-card">${details(quote.review)}</article><button id="native-review" ${busy?'disabled':''}>Review swap</button>`:''}</div>`:!busy&&!loaded?'<button id="native-retry" class="outline">Retry loading saved swaps</button>':''}${receipt?.status==='confirmed'&&!pending?`<article class="review-card"><h2>${previousReceipt?'Last confirmed swap':'Swap confirmed'}</h2>${details(receipt.review)}<p>Actual network fee: ${esc(units(receipt.feeSompi,8))} KAS</p><code>${esc(receipt.transactionId)}</code><button id="native-copy" class="outline">Copy transaction ID</button></article>`:''}<p class="note">kUSDT is backed through Trestly’s USDT bridge. This swap stays on Kaspa L1; it does not bridge to Ethereum or BNB Chain.</p>`;
  host.querySelectorAll<HTMLButtonElement>('[data-native-side]').forEach(button=>button.onclick=()=>{side=button.dataset.nativeSide!;revision++;balanceRevision++;balanceAbort?.abort();balanceLoading=false;amount='';quote=undefined;receipt=undefined;error='';paint();if(side==='sell')void loadBalance();});
  host.querySelector<HTMLInputElement>('#native-amount')?.addEventListener('input',event=>{amount=(event.target as HTMLInputElement).value.replaceAll(',','.');(event.target as HTMLInputElement).value=amount;revision++;quote=undefined;host.querySelector('#native-review')?.remove();host.querySelector('#native-quote-result')?.remove();host.querySelector<HTMLButtonElement>('#native-quote')!.disabled=busy||!amount;});
  host.querySelector<HTMLButtonElement>('#native-max')?.addEventListener('click',()=>{if(canMax){revision++;amount=balance!.maximumAmount;quote=undefined;paint();}});
  host.querySelector<HTMLButtonElement>('#native-balance')?.addEventListener('click',()=>void loadBalance());
  host.querySelector<HTMLButtonElement>('#native-quote')?.addEventListener('click',()=>void run(async()=>{const turn=revision,value=await call('quote',{side,amount});if(active()&&turn===revision)quote=value;}));
  host.querySelector<HTMLButtonElement>('#native-review')?.addEventListener('click',()=>void run(async()=>{const turn=revision,plan=await call('prepare',{id:quote!.id});if(active()&&turn===revision)review(plan);}));
  host.querySelector<HTMLButtonElement>('#native-resume')?.addEventListener('click',()=>void run(()=>submit('resume')));
  host.querySelector<HTMLButtonElement>('#native-retry')?.addEventListener('click',()=>void run(context));
  host.querySelector<HTMLButtonElement>('#native-copy')?.addEventListener('click',()=>void navigator.clipboard.writeText(receipt!.transactionId));
 }
 function review(plan:Row){
  const overlay=document.createElement('div');overlay.className='kaspire-modal';overlay.dataset.preserveCase='';
  overlay.innerHTML=`<section class="approval-sheet"><h1>Review KAS / kUSDT swap</h1><article class="review-card">${details(plan.review)}</article><p>The pool fee is already included. This approval is bound to the exact pool state and quoted output. A changed pool requires a new quote and review.</p><details class="raw-json"><summary>Verified transaction details</summary><pre>${esc(JSON.stringify(plan.review,null,2))}</pre></details><div class="approval-actions"><button id="native-cancel" class="outline">Cancel</button><button id="native-confirm">Confirm swap</button></div></section>`;
  document.body.append(overlay);overlay.querySelector<HTMLButtonElement>('#native-cancel')!.onclick=()=>overlay.remove();
  overlay.querySelector<HTMLButtonElement>('#native-confirm')!.onclick=()=>{overlay.remove();void run(()=>submit('submit',plan.id));};
 }
 document.querySelector<HTMLButtonElement>('#native-refresh')!.onclick=()=>void run(async()=>{revision++;quote=undefined;loaded=false;await context();if(side==='sell'&&!pending)void loadBalance();});
 window.addEventListener('pagehide',()=>{balanceAbort?.abort();lifetime.abort();observer.disconnect();},{once:true});
 paint();await run(context);
}
