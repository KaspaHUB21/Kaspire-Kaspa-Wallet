import {kassealDetails,kassealDisplay,kassealImage} from '../background/kasseal';
type Hooks={command(name:string,values?:Record<string,unknown>):Promise<any>;shell(content:string,title?:string,back?:boolean):void;address():string};
const esc=(v:any)=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
const logo=(t:any)=>kassealImage(t)?`<img src="${esc(kassealImage(t))}" alt="">`:'◈';
const details=(s:any)=>kassealDetails(s).map(line=>{const split=line.indexOf(':');return split<0?`<p>${esc(line)}</p>`:`<div class="kron-detail-row"><span>${esc(line.slice(0,split))}</span><b>${esc(line.slice(split+1).trim())}</b></div>`;}).join('');
export async function openKasseal(hooks:Hooks,tokenId?:string){
  const address=hooks.address();
  hooks.shell('<section class="marketplace-screen kron-screen kasseal-screen"><div class="market-title"><h1>Kasseal</h1><button id="seal-reload" class="icon" aria-label="Reload Kasseal">↻</button></div><div id="seal-content"></div></section>','Kasseal',true);
  const host=document.querySelector<HTMLElement>('#seal-content')!;host.dataset.preserveCase='';
  let tokens:any[]=[],selected:any=null,context:any=null,quote:any=null,receipt:any=null;
  let amount='',side='buy',query='',cursor='',tab='swaps',loading=false,searching=false,error='',notice='',generation=0,preparations=0;
  let timer:ReturnType<typeof setTimeout>|undefined;
  const active=()=>host.isConnected&&address===hooks.address();
  async function run(work:()=>Promise<void>){if(loading)return;loading=true;error='';paint();try{await work();}catch(e){if(active()){error=(e as Error).message;try{await balances();}catch{/* Preserve the original error and saved state. */}}}finally{if(active()){loading=false;paint();}}}
  async function catalogue(more=false){
    const stamp=++generation,q=query,c=more?cursor:'';searching=true;paint();
    try{
      const page=await hooks.command('kassealTokens',{search:q,cursor:c});
      if(!active()||stamp!==generation)return;
      const rows=new Map<string,any>((more?tokens:[]).map(t=>[t.meta.covenantId,t]));
      if(c&&page.nextCursor===c)throw Error('Kasseal repeated the page cursor. Refresh the token list.');
      for(const t of page.tokens)rows.set(t.meta.covenantId,t);tokens=[...rows.values()];cursor=page.nextCursor??'';error='';
    }catch(e){if(active()&&stamp===generation)error=(e as Error).message;}
    finally{if(active()&&stamp===generation){searching=false;paint();}}
  }
  async function balances(){const result=await hooks.command('kassealContext');if(active())context=result;}
  async function finish(result:any){
    quote=null;const prep=result.summary.stage==='preparation';receipt=prep?null:result;
    if(context?.pending?.transactionId===result.transactionId)delete context.pending;
    try{await balances();}catch{notice='Transaction confirmed. The balance refresh is temporarily unavailable.';}
    if(prep){
      receipt=null;selected=result.token;side=result.summary.side;tab='swaps';
      amount=kassealDisplay(result.summary.rawAmount,side==='buy'?8:0).replaceAll(',','');
      notice='Token preparation confirmed. No sale has been sent yet.';
      if(++preparations<=8){
        quote=await hooks.command('kassealQuote',{tokenId:selected.meta.covenantId,side,amount});
        const prepared=await hooks.command('kassealPrepare',{quoteId:quote.quoteId});if(active())review(prepared);
      }else notice+=' Refresh the quote to continue.';
    }else receipt=result;
  }
  function paint(){
    if(!active())return;
    const focus=host.querySelector<HTMLInputElement>('#seal-search'),focused=document.activeElement===focus,pos=focus?.selectionStart??0;
    let html='';
    const pending=context?.pending;
    if(receipt)html=`<section class="receipt-screen"><div class="receipt-check">✓</div><h1>${receipt.summary.side==='buy'?'Bought':'Sold'} ${esc(receipt.token.meta.ticker)}</h1><article class="review-card">${details(receipt.summary)}</article><section class="copy-detail"><label>Transaction ID</label><code>${esc(receipt.transactionId)}</code><button id="seal-copy" class="outline">Copy transaction ID</button></section><button id="seal-return">Return to Kasseal</button></section>`;
    else{
      html=`<div class="segmented"><button data-seal-tab="swaps" class="${tab==='swaps'?'active':''}">DEX swaps</button><button data-seal-tab="history" class="${tab==='history'?'active':''}">My activity</button></div>`;
      if(pending)html+=`<article class="review-card kron-recovery"><h2>${pending.summary.stage==='preparation'?'Token preparation':'Swap'} awaiting confirmation</h2><p>The signed transaction is safely saved. Check it before creating another trade.</p><code>${esc(pending.transactionId)}</code><button id="seal-resume">Check saved ${pending.summary.stage==='preparation'?'preparation':'swap'}</button></article>`;
      if(tab==='history')html+=`<p class="hint">Confirmed Kasseal swaps recorded by this wallet on this device.</p>${(context?.history??[]).map((r:any)=>`<article class="review-card"><h2>${r.summary.side==='buy'?'Bought':'Sold'} ${esc(r.token.meta.ticker)}</h2><p>${esc(kassealDisplay(r.summary.tokenAmount,0))} ${esc(r.token.meta.ticker)}</p><small>${esc(new Date(r.timestamp).toLocaleString('en-US'))}</small><code class="wrap-id">${esc(r.transactionId)}</code><button class="outline" data-seal-copy="${esc(r.transactionId)}">Copy transaction ID</button></article>`).join('')||'<p>No confirmed swaps recorded yet.</p>'}`;
      else if(!selected)html+=`<label class="market-tools">Search ticker, name or covenant ID<input id="seal-search" maxlength="64" value="${esc(query)}"></label>${searching?'<div class="loading">Searching Kasseal…</div>':tokens.map(t=>`<button class="rocket-token market-offer" data-seal-token="${esc(t.meta.covenantId)}"><span class="rocket-logo">${logo(t)}</span><span><b>${esc(t.meta.ticker)}</b><small>${esc(t.meta.name)}</small><em>${t.phase==='bonding'?'Launchpad':'DEX'}</em></span><i>›</i></button>`).join('')||'<p>No tokens found.</p>'}${cursor?'<button id="seal-more" class="outline">Load more</button>':''}`;
      else{
        const t=selected,id=t.meta.covenantId,holding=context?.holdings?.find((h:any)=>h.covenantId===id);
        html+=`<button id="seal-back" class="outline">← Back to tokens</button><section class="token-detail"><div class="token-logo">${logo(t)}</div><h1>${esc(t.meta.ticker)}</h1><p>${esc(t.meta.name)} · ${t.phase==='bonding'?'Launchpad':'DEX'}</p><section class="copy-detail"><label>Token covenant</label><code>${esc(id)}</code></section><div class="segmented"><button data-seal-side="buy" class="${side==='buy'?'active':''}">Buy</button><button data-seal-side="sell" class="${side==='sell'?'active':''}">Sell</button></div><div class="form"><label>${side==='buy'?'KAS trade amount (deposit and network fee added)':'Token amount (whole tokens)'}<small class="available">${side==='buy'?`Available KAS: ${context?.balanceSompi!=null?esc(kassealDisplay(context.balanceSompi,8)):context?'Unavailable':'Loading…'}`:`Your token balance: ${Array.isArray(context?.holdings)?esc(kassealDisplay(holding?.rawBalance??0,0)):context?'Unavailable':'Loading…'} ${esc(t.meta.ticker)}`}</small><div class="amount"><input id="seal-amount" inputmode="decimal" value="${esc(amount)}"><span>${side==='buy'?'KAS':esc(t.meta.ticker)}</span></div></label>${t.phase==='bonding'?'<p class="hint">Curve trades use 1,000-token lots with exact whole-sompi prices. Unspent KAS stays in your wallet.</p>':'<p class="hint">Pool trades support any whole number of tokens.</p>'}<button id="seal-quote" class="outline" ${loading||pending?'disabled':''}>Refresh quote</button>${quote?`<article class="review-card">${details(quote)}</article>`:''}<button id="seal-review" ${!quote||loading||pending?'disabled':''}>Review swap</button></div></section>`;
      }
    }
    host.innerHTML=`${error?`<p class="error">${esc(error)}</p>`:''}${notice?`<p class="hint" role="status">${esc(notice)}</p>`:''}${loading?'<div class="loading">Loading Kasseal…</div>':''}${html}`;
    host.querySelectorAll<HTMLImageElement>('img').forEach(img=>img.onerror=()=>img.replaceWith(document.createTextNode('◈')));
    host.querySelectorAll<HTMLButtonElement>('button').forEach(b=>{if(loading)b.disabled=true;});
    host.querySelectorAll<HTMLButtonElement>('[data-seal-tab]').forEach(b=>b.onclick=()=>{tab=b.dataset.sealTab!;paint();});
    host.querySelectorAll<HTMLButtonElement>('[data-seal-token]').forEach(b=>b.onclick=()=>{selected=tokens.find(t=>t.meta.covenantId===b.dataset.sealToken);quote=null;amount='';side='buy';void run(balances);});
    host.querySelector<HTMLButtonElement>('#seal-back')?.addEventListener('click',()=>{selected=null;quote=null;error='';paint();});
    host.querySelector<HTMLInputElement>('#seal-search')?.addEventListener('input',e=>{
      query=(e.target as HTMLInputElement).value;++generation;clearTimeout(timer);cursor='';tokens=[];searching=true;error='';paint();
      timer=setTimeout(()=>void catalogue(),350);
    });
    if(focused){const input=host.querySelector<HTMLInputElement>('#seal-search');input?.focus();input?.setSelectionRange(pos,pos);}
    host.querySelector<HTMLButtonElement>('#seal-more')?.addEventListener('click',()=>{if(!searching)void catalogue(true);});
    host.querySelectorAll<HTMLButtonElement>('[data-seal-side]').forEach(b=>b.onclick=()=>{side=b.dataset.sealSide!;quote=null;amount='';error='';paint();});
    host.querySelector<HTMLInputElement>('#seal-amount')?.addEventListener('input',e=>{amount=(e.target as HTMLInputElement).value;quote=null;host.querySelector('.form .review-card')?.remove();host.querySelector<HTMLButtonElement>('#seal-review')!.disabled=true;});
    host.querySelector<HTMLButtonElement>('#seal-quote')?.addEventListener('click',()=>void run(async()=>{quote=await hooks.command('kassealQuote',{tokenId:selected.meta.covenantId,side,amount});}));
    host.querySelector<HTMLButtonElement>('#seal-review')?.addEventListener('click',()=>void run(async()=>{const p=await hooks.command('kassealPrepare',{quoteId:quote.quoteId});if(active())review(p);}));
    host.querySelector<HTMLButtonElement>('#seal-resume')?.addEventListener('click',()=>void run(async()=>{await finish(await hooks.command('kassealResume'));}));
    host.querySelector<HTMLButtonElement>('#seal-return')?.addEventListener('click',()=>{receipt=null;selected=null;quote=null;void run(balances);});
    host.querySelector<HTMLButtonElement>('#seal-copy')?.addEventListener('click',()=>void navigator.clipboard.writeText(receipt.transactionId));
    host.querySelectorAll<HTMLButtonElement>('[data-seal-copy]').forEach(b=>b.onclick=()=>void navigator.clipboard.writeText(b.dataset.sealCopy!));
  }
  function review(prepared:any){
    const overlay=document.createElement('div');overlay.className='kaspire-modal';overlay.dataset.preserveCase='';
    const prep=prepared.summary.stage==='preparation';
    overlay.innerHTML=`<section class="approval-sheet"><h1>${prep?'Prepare token cells':`${side==='buy'?'Buy':'Sell'} ${esc(prepared.token.meta.ticker)}`}</h1><article class="review-card">${details(prepared.summary)}</article><p>${prep?'This prepares your own tokens. It does not execute a sale.':'Slippage limit: 1%.'}</p><details class="raw-json"><summary>Unsigned transaction</summary><pre>${esc(JSON.stringify(prepared.rawPlan,null,2))}</pre></details><div class="approval-actions"><button id="seal-cancel" class="outline">Cancel</button><button id="seal-submit">${prep?'Authorize preparation':'Authorize & swap'}</button></div></section>`;
    document.body.append(overlay);overlay.querySelector<HTMLButtonElement>('#seal-cancel')!.onclick=()=>overlay.remove();
    overlay.querySelector<HTMLButtonElement>('#seal-submit')!.onclick=async()=>{
      overlay.querySelectorAll<HTMLButtonElement>('button').forEach(b=>b.disabled=true);overlay.querySelector('#seal-submit')!.textContent='Waiting for secure approval…';
      try{const result=await hooks.command('kassealSubmit',{id:prepared.id});overlay.remove();if(active())await run(()=>finish(result));}
      catch(e){overlay.remove();if(active()){quote=null;try{await balances();}catch{}error=(e as Error).message;paint();}}
    };
  }
  document.querySelector<HTMLButtonElement>('#seal-reload')!.onclick=()=>void run(async()=>{quote=null;await balances();await catalogue();});
  paint();await run(async()=>{
    await Promise.all([balances(),catalogue()]);
    if(tokenId&&active()){
      selected=tokens.find(t=>t.meta.covenantId===tokenId);
      if(!selected){const page=await hooks.command('kassealTokens',{search:tokenId});selected=page.tokens.find((t:any)=>t.meta.covenantId===tokenId);}
      if(!selected)throw Error('Kasseal token is not available.');
    }
  });
}
