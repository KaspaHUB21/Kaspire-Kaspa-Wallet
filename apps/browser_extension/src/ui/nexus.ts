import {nftImageFallback} from './nftMarket';
type Hooks={command(name:string,values?:Record<string,unknown>):Promise<any>;shell(content:string,title?:string,back?:boolean):void;address():string;market(nft?:any,seller?:boolean):void};
const esc=(v:any)=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
function kas(v:any){const n=BigInt(v??0);return `${n/100000000n}${n%100000000n?'.'+(n%100000000n).toString().padStart(8,'0').replace(/0+$/,''):''} KAS`;}
const rank=(v:any)=>v==null?'Rarity rank unavailable':v===-1?'Legendary':`Rarity rank #${v}`;
const intro='Never miss the perfect NFT deal. Submit private offers. Negotiate directly with collectors. Receive instant alerts. Settle securely on Kaspire.';

export function mountNexusBell(hooks:Hooks,container:HTMLElement){
  const button=container.querySelector<HTMLButtonElement>('#nexus-bell');if(!button)return;
  const address=hooks.address();let busy=false;
  button.onclick=()=>void openNexus(hooks,'notifications');
  async function poll(){
    if(busy||!button!.isConnected||address!==hooks.address()||document.hidden)return;
    busy=true;
    try{const result=await hooks.command('nexusPoll');if(!button!.isConnected||address!==hooks.address())return;const unread=(result.notifications??[]).filter((n:any)=>!n.readAt).length;button!.title=result.connected?'NFT notifications':'Open to activate private NFT notifications';button!.classList.toggle('nexus-ring',unread>0);button!.querySelector('.nexus-count')!.textContent=unread?String(unread):'';}catch{/* The wallet must remain usable when the offer relay is unavailable. */}finally{busy=false;}
  }
  void poll();const timer=setInterval(()=>{if(!button.isConnected){clearInterval(timer);return;}void poll();},10000);
}
export async function openNexus(hooks:Hooks,initialView='home'){
  const address=hooks.address();let view=initialView,ticker='',id='',owner='',sort='tokenId',query='',offerTab='received',traits:Record<string,string[]>={};
  let rows:any[]=[],catalog:any[]=[],data:any={},next:number|null=null,loading=false,error='',epoch=0,loadedView='';
  hooks.shell('<section class="nexus-screen"><div id="nexus-content"></div></section>','Nexus Offers',true);
  const host=document.querySelector<HTMLElement>('#nexus-content')!;
  const active=()=>host.isConnected&&address===hooks.address();
  async function nexusCommand(name:string,values?:Record<string,unknown>){try{return await hooks.command(name,values);}catch(e){if((e as Error).message.includes('Unknown wallet command'))throw new Error('The extension background is outdated. Reload Kaspire on the browser extensions page, then reopen the wallet.');throw e;}}
  const request=(path:string,query:Record<string,string>={},body?:Record<string,unknown>)=>nexusCommand('nexusRequest',{path,query,...(body===undefined?{}:{body})});
  const button=(action:string,label:string,cls='')=>`<button class="${cls}" data-nexus-action="${action}" ${loading?'disabled':''}>${label}</button>`;
  async function connect(){if((await nexusCommand('nexusStatus')).connected)return;await nexusCommand('nexusConnect');}
  const image=(row:any)=>`<img data-nft-image src="${esc(row.imageUrl??`https://kaspire.kaslab.space/krc721-read-v1/images/${ticker.toUpperCase()}/${id}`)}" alt="${esc(row.ticker??ticker)} #${esc(row.tokenId??id)}">`;
  function offerCard(row:any,index:number){
    const nft=row.nftCache??{},seller=offerTab==='received',unexpired=Date.parse(row.expiresAt)>Date.now(),open=row.status==='OPEN'&&unexpired,counter=row.status==='COUNTERED'&&unexpired;
    return `<article class="market-offer" data-offer="${index}"><h2 data-preserve-case>${esc(nft.collectionId?.toUpperCase())} #${esc(nft.tokenId)}</h2><strong>${kas(row.currentAmountSompi)}</strong><p>${esc(row.status.replaceAll('_',' '))}</p><p>Expires: ${esc(new Date(row.expiresAt).toLocaleString())}</p><details><summary>Offer history</summary>${(row.revisions??[]).map((r:any)=>`<p>${esc(r.type.replaceAll('_',' '))} ${r.amountSompi==null?'':kas(r.amountSompi)} · ${esc(new Date(r.createdAt).toLocaleString())}</p>`).join('')}</details><div class="nexus-actions">${seller&&open?button('counter','Counter offer','outline')+button('decline','Decline','outline')+button('agree-to-relist','Agree to relist'):''}${!seller&&counter?button('accept-counter','Accept counter offer')+button('cancel','Decline counter offer','outline'):''}${!seller&&open?button('cancel','Cancel offer','outline'):''}${seller&&['AGREED_WAITING_RELIST','RELIST_DETECTED'].includes(row.status)?button('settle','List on Kaspire at agreed price'):''}${!seller&&row.status==='RELIST_DETECTED'?button('settle','Buy on Kaspire · review PSKT'):''}${button('detail','View NFT','outline')}</div></article>`;
  }
  function paint(){
    if(!active())return;
    let html=view==='home'?`<article class="review-card"><p>${intro}</p></article><label>Ticker, ticker + token ID, or wallet<input id="nexus-search" value="${esc(query)}" placeholder="KASGOTHS #187 or kaspa:…"></label>${button('search','Search')}<div class="nexus-actions">${button('active','Browse active offers')}${button('dashboard','My offers','outline')}</div>`:`${button('home','‹ Nexus home','outline')}<div class="nexus-actions">${button('dashboard','My offers','outline')}${button('notifications','Notifications','outline')}${button('reload','Reload','outline')}</div>`;
    if(view==='wallet')html+=`<code class="nexus-wallet">${esc(owner)}</code>${rows.map((r,i)=>`<button data-collection="${i}" class="market-name"><b data-preserve-case>${esc(r.ticker)}</b><small>${r.count} NFTs</small></button>`).join('')}`;
    if(view==='collection')html+=`<h1 data-preserve-case>${esc(ticker.toUpperCase())}</h1>${owner?`<code class="nexus-wallet">${esc(owner)}</code>`:''}<select id="nexus-sort"><option value="tokenId" ${sort==='tokenId'?'selected':''}>Token ID</option><option value="rarityRank" ${sort==='rarityRank'?'selected':''}>Rarity Rank</option></select>${catalog.length?`<details class="nft-traits"><summary>Trait filters</summary>${catalog.map((g:any,gi:number)=>`<details><summary>${esc(g.traitType)}</summary>${g.values.map((v:any,vi:number)=>`<label class="nexus-trait"><input type="checkbox" data-trait="${gi}:${vi}" ${(traits[g.traitType]??[]).includes(v.value)?'checked':''}><span>${esc(v.value)} · ${v.count}${v.rarity==null?'':` · ${esc(v.rarity)}%`}</span></label>`).join('')}</details>`).join('')}</details>`:''}`;
    if(['collection','active'].includes(view))html+=`<div class="nft-market-grid">${rows.map((row,i)=>`<article class="market-offer nexus-token" data-token="${i}" tabindex="0" role="button">${image(row)}<h2 data-preserve-case>${esc((row.ticker??row.collectionId)?.toUpperCase())} #${esc(row.tokenId)}</h2><p>${rank(row.rarityRank)}</p>${view==='active'?`<strong>${esc(row.amountKas)} KAS</strong><p>${esc(row.statusLabel??row.status)}</p>`:''}</article>`).join('')}</div>`;
    if(view==='nft'&&data.tokenId)html+=`<article class="market-offer nexus-detail">${image(data)}<h1 data-preserve-case>${esc(ticker.toUpperCase())} #${esc(id)}</h1><p>${rank(data.rarityRank)}</p><div class="review-card"><p>Current listing status: ${esc(data.listingStatus)}</p>${data.listingPriceSompi==null?'':`<p>Kaspire listing price: ${kas(data.listingPriceSompi)}</p>`}${data.listingPriceUnavailable?'<p>Kaspire listing price is temporarily unavailable.</p>':''}${data.kaspireListing?button('listing','Open Kaspire listing'):''}</div><details class="nft-traits"><summary>Owner & NFT traits</summary><code class="nexus-wallet">${esc(data.currentOwnerWallet??'Unknown')}</code>${(data.attributes??[]).map((t:any)=>`<p><b>${esc(t.trait_type)}</b>: ${esc(t.value)}</p>`).join('')}</details><h2>Best offers</h2>${(data.bestOffers??[]).map((o:any)=>`<p><strong>${kas(o.currentAmountSompi)}</strong> · ${esc(o.status)}</p>`).join('')||'<p>No active offers yet.</p>'}${data.currentOwnerWallet===address?'':button('offer','Make private offer')}</article>`;
    if(view==='dashboard')html+=`<div class="market-tabs">${['received','sent'].map(v=>`<button data-offer-tab="${v}" class="${v===offerTab?'active':''}">${v==='received'?'Received offers':'Sent offers'}</button>`).join('')}</div>${rows.map(offerCard).join('')}`;
    if(view==='notifications')html+=rows.map((n,i)=>`<button class="market-name nexus-notification" data-notification="${i}"><b>${esc(n.payloadJson?.title??n.type)}</b><span>${esc(n.payloadJson?.message??'')}</span><small>${esc(new Date(n.createdAt).toLocaleString())}</small></button>`).join('');
    if(error)html+=`<p class="error">${esc(error)}</p>`;
    if(loading)html+='<div class="loading">Loading Nexus…</div>';
    else if(!error&&!rows.length&&['collection','active','wallet','dashboard','notifications'].includes(view))html+='<p>No results found.</p>';
    if(next!=null&&['active','collection'].includes(view))html+=button('more','Load more','outline');
    host.innerHTML=html;nftImageFallback(host);
    host.querySelector<HTMLInputElement>('#nexus-search')?.addEventListener('input',e=>query=(e.target as HTMLInputElement).value);
    host.querySelector<HTMLInputElement>('#nexus-search')?.addEventListener('keydown',e=>{if(e.key==='Enter')void search();});
    host.querySelector<HTMLSelectElement>('#nexus-sort')?.addEventListener('change',e=>{sort=(e.target as HTMLSelectElement).value;void load();});
    host.querySelectorAll<HTMLInputElement>('[data-trait]').forEach(input=>input.onchange=()=>{const [gi,vi]=input.dataset.trait!.split(':').map(Number),g=catalog[gi!],v=g.values[vi!].value,values=new Set(traits[g.traitType]??[]);if(input.checked)values.add(v);else values.delete(v);if(values.size)traits[g.traitType]=[...values];else delete traits[g.traitType];void load();});
    host.querySelectorAll<HTMLButtonElement>('[data-collection]').forEach(b=>b.onclick=()=>{ticker=rows[Number(b.dataset.collection)].collectionId;view='collection';sort='tokenId';traits={};void load();});
    host.querySelectorAll<HTMLElement>('[data-token]').forEach(card=>{const open=()=>detail(rows[Number(card.dataset.token)]);card.onclick=open;card.onkeydown=e=>{if(e.key==='Enter'||e.key===' ')open();};});
    host.querySelectorAll<HTMLButtonElement>('[data-notification]').forEach(b=>b.onclick=()=>{const p=rows[Number(b.dataset.notification)].payloadJson;if(p?.collectionId&&p?.tokenId)detail(p);});
    host.querySelectorAll<HTMLButtonElement>('[data-offer-tab]').forEach(b=>b.onclick=()=>{offerTab=b.dataset.offerTab!;void load();});
    host.querySelectorAll<HTMLButtonElement>('[data-nexus-action]').forEach(b=>b.onclick=()=>{
      const action=b.dataset.nexusAction!,offer=b.closest<HTMLElement>('[data-offer]'),row=offer?rows[Number(offer.dataset.offer)]:null;
      if(row){if(action==='counter')void offerModal(row);else if(action==='detail')detail(row.nftCache);else if(action==='settle')hooks.market({...row.nftCache,ticker:row.nftCache.collectionId.toUpperCase(),suggestedPriceSompi:row.currentAmountSompi},offerTab==='received');else void act(row,action);return;}
      if(action==='search')void search();else if(action==='more')void load(true);else if(action==='offer')void offerModal();else if(action==='listing')hooks.market();else if(action==='reload')void load();else{view=action;if(view==='home'){++epoch;loading=false;error='';paint();}else void load();}
    });
  }
  function detail(row:any){ticker=String(row.collectionId??row.ticker);id=String(row.tokenId);view='nft';void load();}
  async function search(){loading=true;error='';paint();try{const result=await request('search',{q:query.trim()});if(!active())return;view=result.kind;ticker=result.collectionId??'';id=result.tokenId??'';traits={};sort='tokenId';owner='';if(view==='wallet'){owner=result.walletAddress;rows=result.collections;next=null;}else{await load();return;}}catch(e){error=(e as Error).message;}finally{loading=false;paint();}}
  async function load(more=false){
    if(view!==loadedView){rows=[];catalog=[];data={};next=null;loadedView=view;}
    const stamp=++epoch;loading=true;error='';paint();
    try{
      if(['home','dashboard','notifications'].includes(view))await connect();
      let result:any;
      if(view==='collection')result=await request('collection/'+ticker,{offset:String(more?next??0:0),sort,traits:JSON.stringify(traits),...(owner?{wallet:owner}:{})});
      else if(view==='nft')result=await request(`nft/${ticker}/${id}`);
      else if(view==='active')result=await request('offers/active',{offset:String(more?next??0:0)});
      else if(view==='dashboard')result=await request('dashboard/'+offerTab);
      else if(view==='notifications')result=await request('dashboard/notifications');
      if(!active()||stamp!==epoch)return;
      data=Array.isArray(result)?{}:result??{};const page=view==='collection'?data.tokens??[]:view==='active'?data.offers??[]:Array.isArray(result)?result:[];rows=more?[...rows,...page]:page;catalog=data.catalog??[];next=data.nextOffset??null;
      if(view==='notifications')await request('notifications/read',{},{});
    }catch(e){if(active()&&stamp===epoch)error=(e as Error).message;}finally{if(active()&&stamp===epoch){loading=false;paint();}}
  }
  async function offerModal(existing?:any){
    try{await connect();}catch(e){error=(e as Error).message;paint();return;}if(!active())return;
    const overlay=document.createElement('div');overlay.className='kaspire-modal';
    overlay.innerHTML=`<section class="approval-sheet"><h1>${existing?'Counter offer':'Make Private Offer'}</h1><p>Your offer is private and non-binding. No funds are locked.</p><label>Amount in KAS:<input id="nexus-amount" inputmode="decimal"></label>${existing?'':`<label>Duration:<select id="nexus-duration">${[7,14,21,30,60].map(d=>`<option value="${d}" ${d===30?'selected':''}>${d} days</option>`).join('')}</select></label>`}<label class="nexus-trait"><input id="nexus-ack" type="checkbox"><span>This is a non-binding offer. No funds are locked.</span></label><p id="nexus-offer-error" class="error"></p><div class="approval-actions"><button id="nexus-offer-cancel" class="outline">Cancel</button><button id="nexus-offer-submit" disabled>Submit</button></div></section>`;
    document.body.append(overlay);
    const amount=overlay.querySelector<HTMLInputElement>('#nexus-amount')!,ack=overlay.querySelector<HTMLInputElement>('#nexus-ack')!,submit=overlay.querySelector<HTMLButtonElement>('#nexus-offer-submit')!;
    const valid=()=>submit.disabled=!ack.checked||!/^\d{1,8}(\.\d{1,8})?$/.test(amount.value.trim())||Number(amount.value)<=0||Number(amount.value)>90000000;
    amount.oninput=valid;ack.onchange=valid;overlay.querySelector<HTMLButtonElement>('#nexus-offer-cancel')!.onclick=()=>overlay.remove();
    submit.onclick=async()=>{submit.disabled=true;try{await request(existing?`offers/${existing.id}/counter`:'offers',{}, {amountKas:amount.value.trim(),durationDays:Number(overlay.querySelector<HTMLSelectElement>('#nexus-duration')?.value??30),acknowledgedNonBinding:true,...(existing?{}:{collectionId:ticker,tokenId:id})});overlay.innerHTML=`<section class="approval-sheet"><h1>${existing?'Counter offer created successfully':'Offer created successfully'}</h1><p>Your offer is private and non-binding. No funds are locked.</p><div class="approval-actions"><button id="nexus-success-done">Done</button></div></section>`;overlay.querySelector<HTMLButtonElement>('#nexus-success-done')!.onclick=()=>{overlay.remove();void load();};}catch(e){overlay.querySelector('#nexus-offer-error')!.textContent=(e as Error).message;valid();}};
  }
  async function act(row:any,action:string){
    const overlay=document.createElement('div');overlay.className='kaspire-modal';overlay.innerHTML=`<section class="approval-sheet"><h1>${action==='agree-to-relist'?'Agree to relist?':action==='accept-counter'?'Accept counter offer?':'Confirm offer action'}</h1><p>This changes only your non-binding offer. No funds are locked or spent.</p><div class="approval-actions"><button id="nexus-action-cancel" class="outline">Cancel</button><button id="nexus-action-confirm">Confirm</button></div></section>`;document.body.append(overlay);
    overlay.querySelector<HTMLButtonElement>('#nexus-action-cancel')!.onclick=()=>overlay.remove();overlay.querySelector<HTMLButtonElement>('#nexus-action-confirm')!.onclick=async()=>{overlay.remove();loading=true;paint();try{await request(`offers/${row.id}/${action}`,{},{});await load();}catch(e){error=(e as Error).message;loading=false;paint();}};
  }
  paint();if(view!=='home')await load();
}
