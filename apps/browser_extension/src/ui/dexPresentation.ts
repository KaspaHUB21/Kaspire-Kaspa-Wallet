import {formatRawTokenAmount} from '../shared/tokenAmount';
const escape=(value:unknown)=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));

type CovenantDex='rocket'|'dex';
type TradePanel={prefix:CovenantDex;name:string;ticker:string;image?:string;tokenId:string;marketId?:string;marketLabel:string;price:string;volume:string;marketValue:string;marketValueLabel?:string;side:string;buyLabel:string;amount:string;available:string;quoteLabel:string;quoteDisabled:boolean;reviewDisabled:boolean;quoteHtml?:string;recoveryHtml?:string;error?:string};
export function covenantTradePanel(v:TradePanel){
  const {prefix:p}=v, logo=/^https:\/\//i.test(v.image??'')?`<img src="${escape(v.image)}" alt="">`:'◈';
  const covenant=(label:string,id:string)=>`<section class="copy-detail"><label>${escape(label)}</label><code>${escape(id)}</code></section>`;
  const metric=(label:string,value:string)=>`<div><small>${escape(label)}</small><b>${escape(value)}</b></div>`;
  return `<button id="${p}-back" class="outline">← Back to swaps</button><section class="token-detail rocket-detail"><div class="token-logo">${logo}</div><h1>${escape(v.ticker)}</h1><p>${escape(v.name)}</p>${covenant('Token covenant',v.tokenId)}${covenant(v.marketLabel,v.marketId??'Unavailable')}<div class="price-grid">${metric('Price',v.price)}${metric('24h volume',v.volume)}${metric(v.marketValueLabel??'Pool',v.marketValue)}</div><div class="segmented rocket-side"><button data-${p}-side="buy" class="${v.side==='buy'?'active':''}">Buy</button><button data-${p}-side="sell" class="${v.side==='sell'?'active':''}">Sell</button></div><div class="form"><label>${escape(v.side==='buy'?v.buyLabel:'Token amount')}<small class="available">Available: ${escape(v.available)}</small><div class="amount"><input id="${p}-amount" inputmode="${v.side==='sell'&&p==='dex'?'numeric':'decimal'}" value="${escape(v.amount)}"><span>${escape(v.side==='buy'?'KAS':v.ticker)}</span></div></label>${v.recoveryHtml??''}<button id="${p}-quote" class="outline" ${v.quoteDisabled?'disabled':''}>${escape(v.quoteLabel)}</button>${v.quoteHtml?`<section class="tx-meta rocket-quote">${v.quoteHtml}</section>`:''}<p class="error">${escape(v.error)}</p><button id="${p}-review" ${v.reviewDisabled?'disabled':''}>Review swap</button></div></section>`;
}

export function covenantSwapReview(v:{prefix:CovenantDex;network:string;title:string;details:string;warning:string;raw:unknown}){
  return `<section class="approval-sheet"><p class="eyebrow">SECURE REVIEW · ${escape(v.network)}</p><h1>${escape(v.title)}</h1><div class="approval-details">${v.details}</div><p class="warning-box">${escape(v.warning)}</p><details class="raw-json"><summary>Raw plan JSON</summary><pre>${escape(JSON.stringify(v.raw,null,2))}</pre></details><div class="approval-actions"><button id="${v.prefix}-cancel" class="outline">Cancel</button><button id="${v.prefix}-submit">Authorize &amp; swap</button></div></section>`;
}

export function covenantSwapConfirmation(v:{name:string;network:string;buttonId:'rocket-done'|'dex-return';raw:unknown;details?:string}){
  return `<section class="receipt-screen" data-preserve-case><div class="receipt-check">✓</div><p class="eyebrow">${escape(v.network)} SWAP CONFIRMED</p><h1>${escape(v.name)} swap confirmed</h1>${v.details?`<article class="review-card">${v.details}</article>`:''}<details class="raw-json" ${v.details?'':'open'}><summary>Receipt and transaction details</summary><pre>${escape(JSON.stringify(v.raw,null,2))}</pre></details><button id="${v.buttonId}">Return to ${escape(v.name)}</button></section>`;
}

// A server-reported fill, accepted order deposit, refund, or obsolete atomic
// transaction must never get the same success screen as a verified trade.
export function forgeSwapConfirmed(venue:string,receipt:any){
  if(venue==='kforge')return receipt?.state==='confirmed';
  return venue==='kasforge'&&receipt?.finalVerified===true&&receipt.state==='filled';
}
export function braidRouteLabel(leg:any){
  const label=(v:unknown)=>typeof v==='string'&&v.trim()&&v.trim().toLowerCase()!=='null'?v.trim():null;
  const venue=label(leg?.venue),name=({kr:'KaspaRocket',krc:'KaspaRocket Launchpad',krcurve:'KaspaRocket Launchpad',ksc:'Kasseal Launchpad',kasseal:'Kasseal',kron:'KRON',braid:'Braid'} as Record<string,string>)[venue?.toLowerCase()??'']??venue??'Swap route';
  const from=label(leg?.from),to=label(leg?.to),token=label(leg?.tick)??'Token',side=label(leg?.side)?.toLowerCase();
  return `${name}: ${from&&to?`${from} → ${to}`:side==='buy'?`KAS → ${token}`:side==='sell'?`${token} → KAS`:'Route details unavailable'}`;
}
export function sellPresets(balance:string|null|undefined,decimals:number,select:(amount:string)=>void,disabled=false){
  const row=document.createElement('div');row.className='sell-presets';
  for(const percent of [25,50,75,100]){
    const button=document.createElement('button');button.className='outline';button.textContent=percent===100?'MAX':percent+'%';
    button.disabled=disabled||balance==null||!/^\d+$/.test(balance);button.onclick=()=>{if(!button.disabled)select(formatRawTokenAmount(String(BigInt(balance!)*BigInt(percent)/100n),decimals));};row.append(button);
  }
  return row;
}
const number=(v:any)=>v==null||String(v)===''||!Number.isFinite(Number(v))||Number(v)<0?null:Number(v);
let cached:{at:number;rate:number}|undefined,pending:Promise<number|null>|undefined;
async function kasUsd():Promise<number|null>{
  if(cached&&Date.now()-cached.at<120000)return cached.rate;
  return pending??= (async()=>{
    try{const r=await fetch('https://kaspatoken.kaslab.space/api/kaspa/stats',{signal:AbortSignal.timeout(5000)});if(!r.ok)return null;const data=await r.json(),rate=number(data?.data?.price_usd),at=Date.parse(data?.updated_at);
      if(rate==null||rate<=0||!Number.isFinite(at)||Math.abs(Date.now()-at)>900000)return null;cached={rate,at:Date.now()};return rate;
    }catch{return null;}finally{pending=undefined;}
  })();
}
export function kassealMetrics(token:any){const cap=number(token?.marketCapSompi),supply=number(token?.supply?.total),volume=number(token?.volume24hSompi);return {capKas:cap==null?null:cap/1e8,priceKas:cap==null||supply==null||supply<=0?null:cap/1e8/supply,volumeKas:volume==null?null:volume/1e8};}
const fmt=(v:number|null,decimals=8)=>v==null?'—':v.toLocaleString('en-US',{maximumFractionDigits:decimals});
export async function showDexMetrics(element:HTMLElement,metrics:{capKas:any;priceKas:any;volumeKas:any}){
  const cap=number(metrics.capKas),price=number(metrics.priceKas),volume=number(metrics.volumeKas);
  const paint=(usd:number|null)=>{if(!element.isConnected)return;element.textContent=`Market cap: ${cap==null||usd==null?'—':(cap*usd).toLocaleString('en-US',{style:'currency',currency:'USD',maximumFractionDigits:0})} · Price: ${fmt(price)} KAS per token · 24h volume: ${fmt(volume,2)} KAS`;};
  paint(null);paint(await kasUsd());
}
