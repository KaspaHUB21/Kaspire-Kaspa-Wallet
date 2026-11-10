import {formatRawTokenAmount} from '../shared/tokenAmount';
import {braidRouteLabel,covenantTradePanel,covenantSwapReview,covenantSwapConfirmation,forgeSwapConfirmed,showDexMetrics} from './dexPresentation';
type Hooks={command(name:string,args?:Record<string,unknown>,signal?:AbortSignal):Promise<any>;shell(html:string,title?:string,back?:boolean):void;address():string};
type Venue='braid'|'kforge'|'kasforge';
const esc=(v:any)=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
const labels={braid:'Braid',kforge:'KForge',kasforge:'KasForge'};
const raw=(n:any,d=8)=>{try{const s=formatRawTokenAmount(String(n),d);const [w,f]=s.split('.');return w!.replace(/\B(?=(\d{3})+(?!\d))/g,',')+(f?'.'+f:'');}catch{return 'Unavailable';}};
const kas=(n:unknown)=>typeof n==='number'&&Number.isFinite(n)&&n>=0?`${n.toLocaleString('en-US',{maximumFractionDigits:8})} KAS`:'—';
const line=(label:string,value:any)=>`<div class="kron-detail-row detail-row"><span>${esc(label)}</span><b>${esc(value)}</b></div>`;
const copy=(label:string,value:any)=>value==null?'':`<section class="copy-detail"><label>${esc(label)}</label><code>${esc(value)}</code><button class="outline" data-dex-copy="${esc(value)}">Copy ${esc(label.toLowerCase())}</button></section>`;
const done=(r:any,venue:Venue)=>venue==='kforge'?['confirmed','obsolete'].includes(r?.state):r?.finalVerified===true||r?.verifiedFinal===true;
const receiptId=(r:any,venue:Venue)=>venue==='kforge'?r?.id:venue==='kasforge'?r?.buildId:r?.ref;
function route(q:any){return (Array.isArray(q?.txs)?q.txs:[]).flatMap((t:any)=>Array.isArray(t?.legs)?t.legs:[]).filter((l:any)=>l&&typeof l==='object').map((l:any)=>`<p>${esc(braidRouteLabel(l))}</p>`).join('');}
function kforgeDetails(v:any,side:string,symbol:string){return !v?'':line('Token amount',`${raw(v.tokens,0)} ${symbol}`)+line(side==='buy'?'Total KAS paid (all-in)':'Net KAS received',`${raw(v.walletNet)} KAS`)+line('Market cost / proceeds',`${raw(v.marketKas)} KAS`)+line('Protocol fee',`${raw(v.protocolFee)} KAS`)+line('Network fee',`${raw(v.networkFee)} KAS`)+line('Token-cell reserve change',`${raw(v.cellReserveChange)} KAS`)+(v.buyBudgetSompi!=null?line('KAS trade amount entered',`${raw(v.buyBudgetSompi)} KAS`)+line('Not used for tokens (lot rounding)',`${raw(v.unspentBudgetSompi)} KAS`):'');}
export async function openSharedDex(hooks:Hooks,venue:Venue,network:string,tokenId?:string){
  const name=labels[venue],address=hooks.address(),forge=venue!=='braid',networkLabel=network==='mainnet'?'MAINNET':'TESTNET 10';
  const emblem=venue==='kforge'?'kforge.svg':'kasforge.png';
  hooks.shell(`<section class="marketplace-screen"><div class="market-title">${forge?`<span class="market-emblem"><img src="${emblem}" alt=""></span><div><p class="eyebrow">${networkLabel} DEX</p><h1>${name}</h1></div>`:`<h1>${name} · ${network==='mainnet'?'Mainnet':'Testnet 10'}</h1>`}<button id="dex-reload" class="icon" aria-label="Refresh ${name}">↻</button></div><div id="dex-content"></div></section>`,name,true);
  const host=document.querySelector<HTMLElement>('#dex-content')!;host.dataset.preserveCase='';
  const marketTitle=host.parentElement!.querySelector<HTMLElement>('.market-title')!;
  const lifetime=new AbortController();
  let tokens:any[]=[],context:any=null,selected:any=null,from:any=null,to:any=null,quote:any=null,receipt:any=null;
  let side='buy',amount='',tab='swaps',query='',error='',notice='',busy=false,progress='',tokenBalance:string|null=null,fromGeneration=0,checks=0;
  let timer:ReturnType<typeof setTimeout>|undefined;
  const active=()=>host.isConnected&&hooks.address()===address;
  const call=(action:string,args:any={})=>hooks.command('dex',{venue,action,args},lifetime.signal);
  async function run(action:()=>Promise<void>,background=false){if(busy)return;busy=true;error='';if(!background)paint();try{await action();}catch(e){if(active())error=(e as Error).message;}finally{busy=false;progress='';if(active()){paint();schedule();}}}
  async function balances(){const next=await call('context');if(!active())return;context=next;notice=next.warning??'';}
  async function notes(){
    const stamp=++fromGeneration,token=from;tokenBalance=null;
    if(!token||token.id==='0'.repeat(64)){paint();return;}
    try{const d=await call('notes',{tokenId:token.id});let sum=0n;for(const r of d.notes)sum+=BigInt(String(r.amount??r.state?.amount));if(active()&&stamp===fromGeneration)tokenBalance=String(sum);}catch(e){if(active()&&stamp===fromGeneration)notice=(e as Error).message;}
    if(active())paint();
  }
  function holding():string|null{
    if(venue==='braid')return from?.id==='0'.repeat(64)?context?.balanceSompi??null:tokenBalance;
    if(!selected||!context)return null;
    if(venue==='kforge')return Array.isArray(context.assets)?String(context.assets.find((a:any)=>a.covenantId===selected.id)?.rawBalance??'0'):null;
    const rows=context.portfolio?.positions;if(!Array.isArray(rows))return null;const n=String(rows.find((a:any)=>a.token===selected.id)?.tokens??'0');return /^\d+$/.test(n)?n:null;
  }
  function choose(t:any){selected=t;quote=null;amount='';side='buy';paint();}
  async function refresh(){await Promise.all([call('tokens').then(rows=>{if(!active())return;tokens=rows;if(venue==='braid'){from??=tokens[0];to??=tokens[1];}const id=selected?.id??tokenId;if(id){selected=tokens.find(t=>t.id===id);tokenId=undefined;}paint();}),balances()]);}
  function identity(t:any,label='Token covenant ID'){return t?.id&&t.id!=='0'.repeat(64)?copy(label,t.id):'<p>Kaspa native asset</p>';}
  function picker(label:string,t:any,input:boolean){return `<label>${label}<button class="outline dex-selector" data-dex-picker="${input?'from':'to'}">${esc(t?.symbol??'Select token')}</button></label>${identity(t,`${label} covenant ID`)}`;}
  function presets(value:string|null,decimals:number){return `<div class="sell-presets">${[25,50,75,100].map(n=>`<button class="outline" data-dex-percent="${n}" ${value==null||busy?'disabled':''}>${n===100?'MAX':n+'%'}</button>`).join('')}</div>`;}
  function quoteDetails(q:any){
    if(venue==='kforge')return kforgeDetails(q?.review?.tradeSummary?.verified,side,selected?.symbol??q?.token?.symbol??'');
    if(venue==='kasforge')return line('Route',selected?.graduated?'Pool':'Bonding curve')+line(side==='buy'?'Trade amount':'You sell',`${q?.localAmount??amount} ${side==='buy'?'KAS':selected?.symbol??''}`)+line('Estimated received',side==='buy'?`${raw(q?.receiveTokens,0)} ${selected?.symbol??''}`:`${q?.receiveKas??'Unavailable'} KAS`)+Object.entries({'swapFeeKas':'Protocol fee','settleTipKas':'Settlement tip','tokenDepositKas':'Token deposit'}).map(([key,label])=>typeof q?.[key]==='number'?line(label,`${q[key].toLocaleString('en-US',{maximumFractionDigits:8})} KAS`):'').join('');
    const f=tokens.find(t=>t.id===q?.localFromId)??from,t=tokens.find(t=>t.id===q?.localToId)??to,fee=q?.walletFee;
    return line('You pay',`${raw(q?.localAmount,f?.decimals??0)} ${f?.symbol??''}`)+line('Estimated received',`${raw(q?.amountOut,t?.decimals??0)} ${t?.symbol??''}`)+line('Guaranteed minimum',`${raw(q?.localFloor,t?.decimals??0)} ${t?.symbol??''}`)+line('Kaspire fee',fee?`${raw(fee.amount,fee.unit==='token'?(f?.decimals??0):8)} ${fee.unit==='token'?f?.symbol:'KAS'}${BigInt(fee.carrier??0)>0n?` + ${raw(fee.carrier)} KAS cell reserve (within 1% share)`:''}`:'See independently checked fee terms')+(q?.staged?'<p>Two steps via KAS. The first sale cannot be reversed; a failed second purchase returns intermediate KAS, not the original tokens.</p>':'')+route(q);
  }
  function receiptDetails(r:any){
    if(venue==='kforge')return kforgeDetails(r.verified,r.side,r.symbol)+copy('Token covenant ID',r.tokenId)+copy('Transaction ID',r.id);
    if(venue==='braid'){const out=tokens.find(t=>t.id===r.quote?.localToId),p=r.status;
      return quoteDetails(r.quote)+(r.verifiedFinal&&r.state==='done'&&p?.received?.amount!=null?line('Verified received',`${raw(p.received.amount,out?.decimals??0)} ${out?.symbol??r.to}`):'')+copy('Deposit transaction ID',r.transactionId)+copy('Final transaction ID',p?.exec?.txid??p?.refund?.txid??p?.reclaim?.txid??r.recoverySigned?.transactionId)+line('Status',r.statusWarning??p?.wait?.reason??p?.fill?.reason??r.state)+copy('Swap reference',r.ref);}
    const v=r.verifiedDetails??{};
    return line('Direction',`${r.side} ${r.symbol}`)+line(done(r,venue)?'Token amount':'Requested token amount',v.tokenAmountRaw!=null?`${raw(v.tokenAmountRaw,0)} ${r.symbol}`:r.side==='sell'?`${raw(r.amount,0)} ${r.symbol}`:'Awaiting settlement')+line('KAS amount',v.kasAmountSompi!=null?`${raw(v.kasAmountSompi)} KAS`:r.side==='buy'?`${r.amount} KAS (trade amount)`:'Awaiting settlement')+line('Status',r.status?.message??r.status?.order?.status??r.status?.status??r.statusWarning??r.state)+copy('Token covenant ID',r.tokenId)+copy('Order transaction ID',r.transactionIds?.at(-1))+copy('Settlement / cancellation ID',r.settlementId??r.cancelId);
  }
  async function updateReceipt(action:string){const old=receipt;receipt=await call(action,{id:receiptId(old,venue)});if(!forgeSwapConfirmed(venue,receipt))await balances();}
  function schedule(){clearTimeout(timer);if(!active()||!receipt||done(receipt,venue)||busy||document.visibilityState==='hidden')return;
    if(venue==='kasforge'&&!(receipt.signed?.length)&&!receipt.cancelId)return;
    timer=setTimeout(()=>{checks++;void run(()=>updateReceipt('status'),true);},checks<4?2000:checks<15?6000:15000);
  }
  function paint(){
    if(!active()){clearTimeout(timer);return;}
    const focused=host.querySelector<HTMLInputElement>('#dex-search'),keepFocus=document.activeElement===focused,pos=focused?.selectionStart??0;
    const confirmed=forgeSwapConfirmed(venue,receipt);
    marketTitle.style.display=confirmed?'none':'';
    const catalogue=tab==='activity'||!selected&&!receipt;
    let html=!forge||catalogue?`<div class="market-tabs two"><button data-dex-tab="swaps" class="${tab==='swaps'?'active':''}">DEX swaps</button><button data-dex-tab="activity" class="${tab==='activity'?'active':''}">My activity</button></div>`:'';
    if(tab==='activity'){
      const saved=context?.saved??[],open=saved.filter((r:any)=>!done(r,venue)),closed=saved.filter((r:any)=>done(r,venue));
      const rows=(entries:any[])=>entries.slice().reverse().map(r=>`<button class="outline market-offer" data-dex-receipt="${esc(receiptId(r,venue))}"><span><b>${esc(r.from?`${r.from} → ${r.to}`:`${r.side} ${r.symbol}`)}</b><small>${esc(r.state)}</small><small>${venue==='kforge'?`${raw(r.verified?.tokens,0)} ${esc(r.symbol)} · ${raw(r.verified?.walletNet)} KAS`:venue==='kasforge'?`${r.verifiedDetails?.tokenAmountRaw!=null?raw(r.verifiedDetails.tokenAmountRaw,0)+' '+esc(r.symbol):'Settlement quantity pending'}${r.verifiedDetails?.kasAmountSompi!=null?' · '+raw(r.verifiedDetails.kasAmountSompi)+' KAS':''}`:''}</small></span><i>›</i></button>`).join('');
      html+=open.length?`<h2>Saved swaps requiring attention</h2>${rows(open)}`:'';html+=`<h2>Completed activity</h2>${rows(closed)||'<p>No completed local swaps yet.</p>'}`;
      if(venue==='kasforge')html+=(context?.activity??[]).filter((r:any)=>!r.localVerified).map((r:any)=>`<article class="review-card"><b>${esc(r.side)} ${esc(r.tick)}</b>${line('Tokens',r.tokens==null?'Unavailable':raw(r.tokens,0))}${line('KAS',r.kasSompi==null?'Unavailable':raw(r.kasSompi)+' KAS')}${copy('Transaction ID',r.txid)}<small>Indexed activity; local settlement verification is separate.</small></article>`).join('');
    }else if(confirmed){
      html+=covenantSwapConfirmation({name,network:networkLabel,buttonId:'dex-return',raw:receipt,details:receiptDetails(receipt)});
    }else if(receipt){
      const finished=done(receipt,venue),title=finished?(venue==='braid'?'Swap finished':receipt.state==='obsolete'?'Obsolete swap archived':receipt.state==='refunded'?'Order refunded':'Order cancelled'):'Saved swap · status / recovery';
      html+=`<section class="receipt-screen">${finished&&!forge?'<div class="receipt-check">✓</div>':''}<h1>${title}</h1><article class="review-card">${receiptDetails(receipt)}</article><details class="raw-json"><summary>Public recovery receipt</summary><pre>${esc(JSON.stringify(receipt,null,2))}</pre></details><button id="dex-export" class="outline">Export public recovery receipt</button>${finished?`<button id="dex-return">Return to ${name}</button>`:`<button id="dex-status" class="outline">Check status</button><button id="dex-resume" class="outline">Resume same saved ${venue==='kasforge'?'order':'swap'}</button>${venue==='kforge'?'':'<button id="dex-recover" class="outline">Review recovery / cancellation</button>'}`}<button id="dex-activity" class="outline">My activity</button></section>`;
    }else{
      const pending=(context?.saved??[]).find((r:any)=>!done(r,venue)&&r.signed!=null);
      const recovery=pending?`<article class="review-card kron-recovery"><h2>Signed swap saved</h2><p>Check the exact saved transaction before creating another.</p><button data-dex-receipt="${esc(receiptId(pending,venue))}">Check saved swap</button></article>`:'';
      if(venue==='braid'){
        const selling=from?.id!=='0'.repeat(64),d=from?.decimals??0,balance=holding();
        html+=recovery+`<article class="review-card">One covenant deposit, then independently verified execution or refund. Kaspire partner fee: 1%, waived when the minimum executable fee cannot be covered. Staged swaps may return intermediate KAS.</article>${picker('From',from,true)}${picker('To',to,false)}`;
        html+=`<p class="available">${selling?'Token balance':'Available KAS'}: ${selling?balance==null?'Unavailable':raw(balance,d):context?.balanceSompi==null?'Unavailable':raw(context.balanceSompi)} ${selling?esc(from?.symbol):'KAS'}</p>${selling?presets(balance,d):''}<label>${selling?'Token amount':'Total KAS to pay (all-in)'}<input id="dex-amount" inputmode="decimal" value="${esc(amount)}"></label><button id="dex-quote" class="outline">Refresh quote</button>${quote?`<article class="review-card">${quoteDetails(quote)}</article>`:''}<button id="dex-review" ${!quote||pending?'disabled':''}>Review swap</button>`;
      }else if(!selected){
        const rows=tokens.filter(t=>`${t.symbol} ${t.name} ${t.id}`.toLowerCase().includes(query.trim().toLowerCase()));
        html+=recovery+`<div class="review-card"><b>${name} · ${network==='mainnet'?'Mainnet':'Testnet 10'}</b><p>Market swaps across covenant bonding curves and pools.</p></div><div class="market-tools"><label>Token ticker, name or covenant ID<input id="dex-search" maxlength="120" value="${esc(query)}"></label></div>${rows.map(t=>`<button class="rocket-token market-offer" data-dex-token="${esc(t.id)}"><span class="rocket-logo">${/^https:\/\//.test(t.logo??'')?`<img src="${esc(t.logo)}" alt="">`:'◈'}</span><span><b>${esc(t.symbol)}</b><small>${esc(t.name)} · ${t.graduated?'Pool':'Launchpad'}</small><code>${esc(t.id)}</code><em>Price ${esc(kas(t.priceKas))}</em></span><i>›</i></button>`).join('')||(busy?'<div class="loading">Loading covenant tokens…</div>':'<div class="empty">No tokens found</div>')}`;
      }else{
        const balance=holding();
        const available=side==='buy'?(context?.balanceSompi==null?'Unavailable':`${raw(context.balanceSompi)} KAS`):(balance==null?'Unavailable':`${raw(balance,0)} ${selected.symbol}`);
        html+=covenantTradePanel({prefix:'dex',name:selected.name,ticker:selected.symbol,image:selected.logo,tokenId:selected.id,
          marketId:venue==='kforge'?(selected.graduated?selected.pool:selected.curve):selected.activeMarket,marketLabel:selected.graduated?'Pool covenant':'Curve covenant',
          price:kas(selected.priceKas),volume:kas(selected.volume24hKas),marketValue:kas(selected.marketCapKas),marketValueLabel:'Market cap',
          side,buyLabel:'KAS trade amount',amount,available,quoteLabel:quote||error?'Refresh quote':'Get live quote',quoteDisabled:!context||!!pending,
          reviewDisabled:!quote||!!pending,error,quoteHtml:quote?quoteDetails(quote):undefined,recoveryHtml:recovery});
      }
    }
    host.innerHTML=`${error&&(!forge||!selected||receipt)?`<p class="error">${esc(error)}</p>`:''}${notice&&!confirmed?`<p class="hint">${esc(notice)}</p>`:''}${busy?`<div class="loading" role="status">${esc(progress||'Checking current state…')}</div>`:''}${html}`;
    if(forge&&selected&&side==='sell'&&!receipt)host.querySelector('.form label')?.insertAdjacentHTML('beforebegin',presets(holding(),0));
    if(forge&&!selected&&tab==='swaps'&&!receipt)host.querySelectorAll<HTMLElement>('[data-dex-token]').forEach(button=>{
      const t=tokens.find(t=>t.id===button.dataset.dexToken),em=button.querySelector<HTMLElement>('em');
      if(t&&em)void showDexMetrics(em,{capKas:t.marketCapKas,priceKas:t.priceKas,volumeKas:t.volume24hKas});
    });
    host.querySelectorAll<HTMLButtonElement|HTMLInputElement>('button,input').forEach(e=>{if(busy)e.disabled=true;});host.querySelectorAll<HTMLImageElement>('img').forEach(i=>i.onerror=()=>i.replaceWith(document.createTextNode('◈')));
    host.querySelectorAll<HTMLButtonElement>('[data-dex-copy]').forEach(b=>b.onclick=()=>void navigator.clipboard.writeText(b.dataset.dexCopy!));
    host.querySelectorAll<HTMLButtonElement>('[data-dex-tab]').forEach(b=>b.onclick=()=>{tab=b.dataset.dexTab!;paint();});
    host.querySelectorAll<HTMLButtonElement>('[data-dex-token]').forEach(b=>b.onclick=()=>choose(tokens.find(t=>t.id===b.dataset.dexToken)));
    host.querySelectorAll<HTMLButtonElement>('[data-dex-receipt]').forEach(b=>b.onclick=()=>{receipt=context.saved.find((r:any)=>receiptId(r,venue)===b.dataset.dexReceipt);tab='swaps';checks=0;paint();schedule();});
    host.querySelectorAll<HTMLButtonElement>('[data-dex-side]').forEach(b=>b.onclick=()=>{side=b.dataset.dexSide!;quote=null;amount='';paint();});
    host.querySelectorAll<HTMLButtonElement>('[data-dex-picker]').forEach(b=>b.onclick=()=>selectToken(b.dataset.dexPicker==='from'));
    host.querySelectorAll<HTMLButtonElement>('[data-dex-percent]').forEach(b=>b.onclick=()=>{const value=holding();if(value==null)return;amount=formatRawTokenAmount(String(BigInt(value)*BigInt(b.dataset.dexPercent!)/100n),venue==='braid'?from?.decimals??0:0).replaceAll(',','');quote=null;paint();});
    host.querySelector<HTMLInputElement>('#dex-search')?.addEventListener('input',e=>{query=(e.target as HTMLInputElement).value;paint();});
    if(keepFocus){const input=host.querySelector<HTMLInputElement>('#dex-search');input?.focus();input?.setSelectionRange(pos,pos);}
    host.querySelector<HTMLInputElement>('#dex-amount')?.addEventListener('input',e=>{amount=(e.target as HTMLInputElement).value;quote=null;if(forge)host.querySelector('.rocket-quote')?.remove();host.querySelector('#dex-review')?.setAttribute('disabled','');});
    host.querySelector('#dex-back')?.addEventListener('click',()=>{selected=null;quote=null;error='';paint();});
    host.querySelector('#dex-quote')?.addEventListener('click',()=>void run(async()=>{const entered=amount.trim();if(forge&&!(side==='buy'?/^\d+(?:\.\d{1,8})?$/:/^\d+$/).test(entered))throw Error(side==='buy'?'Enter a KAS amount with up to 8 decimal places.':'Enter a whole token amount.');quote=await call('quote',venue==='braid'?{from:from.id,to:to.id,amount}:{tokenId:selected.id,side,amount:entered});}));
    host.querySelector('#dex-review')?.addEventListener('click',()=>void run(async()=>{const prepared=venue==='kforge'?quote:await call('prepare',{id:quote.id});review(prepared);}));
    for(const [id,action]of [['dex-status','status'],['dex-resume','resume'],['dex-recover','recover']])host.querySelector('#'+id)?.addEventListener('click',()=>void run(()=>updateReceipt(action!)));
    host.querySelector('#dex-return')?.addEventListener('click',()=>{receipt=null;quote=null;selected=null;amount='';tab='swaps';void run(balances);});
    host.querySelector('#dex-activity')?.addEventListener('click',()=>{receipt=null;tab='activity';paint();});
    host.querySelector('#dex-export')?.addEventListener('click',()=>{const url=URL.createObjectURL(new Blob([JSON.stringify(receipt,null,2)],{type:'application/json'})),a=document.createElement('a');a.href=url;a.download=`kaspire-${venue}-${receiptId(receipt,venue)}.json`;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);});
  }
  function selectToken(input:boolean){const modal=document.createElement('div');modal.className='kaspire-modal';modal.innerHTML=`<section class="approval-sheet"><h1>Select token</h1><input id="dex-token-search" placeholder="Search ticker or covenant ID" autocomplete="off"><div id="dex-token-results"></div><button id="dex-picker-close" class="outline">Cancel</button></section>`;document.body.append(modal);
    const list=()=>{const q=modal.querySelector<HTMLInputElement>('#dex-token-search')!.value.toLowerCase();const rows=tokens.filter(t=>`${t.symbol} ${t.id}`.toLowerCase().includes(q));modal.querySelector('#dex-token-results')!.innerHTML=rows.map(t=>`<button class="outline" data-dex-pick="${esc(t.id)}"><b>${esc(t.symbol)}</b><code>${t.id==='0'.repeat(64)?'Kaspa native asset':esc(t.id)}</code></button>`).join('');modal.querySelectorAll<HTMLButtonElement>('[data-dex-pick]').forEach(b=>b.onclick=()=>{const t=tokens.find(t=>t.id===b.dataset.dexPick);if(input)from=t;else to=t;quote=null;amount='';modal.remove();paint();if(input)void notes();});};list();modal.querySelector('#dex-token-search')!.addEventListener('input',list);modal.querySelector('#dex-picker-close')!.addEventListener('click',()=>modal.remove());modal.querySelector<HTMLInputElement>('#dex-token-search')!.focus();}
  function review(prepared:any){
    const modal=document.createElement('div');modal.className=forge?'kaspire-modal approval-modal':'kaspire-modal';modal.dataset.preserveCase='';
    if(forge){
      const token=prepared.token??selected,market=venue==='kforge'?(token.graduated?token.pool:token.curve):token.activeMarket;
      const reviews=Array.isArray(prepared.reviews)?prepared.reviews:prepared.review?[prepared.review]:[];
      const fees=reviews.reduce((sum:bigint,r:any)=>sum+BigInt(String(r.feeSompi??0)),0n);
      modal.innerHTML=covenantSwapReview({prefix:'dex',network:networkLabel,title:`${side.toUpperCase()} ${token.symbol}`,
        details:line('Token covenant',token.id)+line(token.graduated?'Pool covenant':'Curve covenant',market)+quoteDetails(quote)
          +(venue==='kasforge'?line('Deposit network fees',`${raw(fees)} KAS`)+line('Order preparation transactions',reviews.length):''),
        warning:venue==='kasforge'?'Verify both covenant IDs. A signed order deposit is not a completed swap. Settlement is checked independently; unfilled orders can be recovered.':'Ticker symbols are not unique. Verify both covenant IDs. The atomic swap is checked by the local Rust/WASM core.',
        raw:prepared.rawPlan});
    }else{
      modal.innerHTML=`<section class="approval-sheet"><h1>Review ${name} swap</h1><article class="review-card">${quoteDetails(quote)}</article><p>Authorize one covenant deposit. Execution/refund is verified separately. Staged routes may return intermediate KAS.</p><details class="raw-json"><summary>Native review and unsigned plan</summary><pre>${esc(JSON.stringify(prepared,null,2))}</pre></details><button id="dex-cancel" class="outline">Cancel</button><button id="dex-submit">Continue to secure approval</button></section>`;
    }
    document.body.append(modal);
    const close=()=>{modal.remove();lifetime.signal.removeEventListener('abort',close);};
    modal.querySelector('#dex-cancel')!.addEventListener('click',close);
    modal.querySelector('#dex-submit')!.addEventListener('click',()=>{
      close();if(!active())return;
      void run(async()=>{
        try{receipt=await call('submit',{id:prepared.id});}
        finally{
          quote=null;checks=0;
          // Verified success does not wait on unrelated balance/indexer reads.
          if(!forgeSwapConfirmed(venue,receipt)){
            try{await balances();receipt??=(context?.saved??[]).find((r:any)=>!done(r,venue)&&r.signed!=null);}catch{/* Keep the submission error and durable recovery. */}
          }
        }
      });
    });
    lifetime.signal.addEventListener('abort',close,{once:true});
  }
  document.querySelector('#dex-reload')!.addEventListener('click',()=>void run(async()=>{quote=null;await refresh();}));
  const onProgress=(e:Event)=>{if(!active()){document.removeEventListener('kaspire-operation-progress',onProgress);return;}progress=String((e as CustomEvent).detail);if(busy)paint();};document.addEventListener('kaspire-operation-progress',onProgress);
  document.addEventListener('visibilitychange',()=>{if(active())schedule();},{passive:true,signal:lifetime.signal});
  const observer=new MutationObserver(()=>{if(!host.isConnected){clearTimeout(timer);lifetime.abort();document.removeEventListener('kaspire-operation-progress',onProgress);observer.disconnect();}});observer.observe(document.body,{childList:true,subtree:true});
  paint();await run(refresh);if(venue==='braid')void notes();
}
