type Hooks = {
  command(name:string,values?:Record<string,unknown>):Promise<any>;
  shell(content:string,title?:string,back?:boolean):void;
  address():string;
  dotk():void;
  send(nft:any):void;
};
const esc=(value:any)=>String(value??"").replace(/[&<>"']/g,char=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[char]!));
function money(value:any) {
  const raw=BigInt(String(value??0)),digits=raw.toString().padStart(9,"0"),fraction=digits.slice(-8).replace(/0+$/,"");
  return `${digits.slice(0,-8)}${fraction?`.${fraction}`:""} KAS`;
}
export function nftImageFallback(container:Element) {
  container.querySelectorAll<HTMLImageElement>('img[data-nft-image]').forEach(image=>{
    image.onerror=()=>{
      const match=image.src.match(/^https:\/\/kaspire\.kaslab\.space\/krc721-read-v1\/images\/([A-Z0-9_-]{1,32})\/(\d{1,20})$/);
      image.onerror=null;
      if(match) image.src=`https://krc721-cache.kaspa.com/krc721/mainnet/optimized/${encodeURIComponent(match[1]!.toLowerCase())}/${match[2]}`;
    };
  });
}
export function agoraChooser(hooks:Hooks) {
  hooks.shell('<section class="agora-choice"><p class="eyebrow">K-AGORA</p><h1>Marketplace</h1><button id="agora-dotk" class="market-name"><b>dot.k Market</b><small>Covenant names</small></button><button id="agora-nft" class="market-name"><b>NFT Market</b><small>KRC-721 · PSKT listings</small></button></section>',"K-Agora",true);
  document.querySelector<HTMLButtonElement>("#agora-dotk")!.onclick=hooks.dotk;
  document.querySelector<HTMLButtonElement>("#agora-nft")!.onclick=()=>void openNftMarket(hooks);
}
export async function openNftMarket(hooks:Hooks,initialNft?:any,initialTab="browse") {
  const address=hooks.address();
  let tab=initialTab,query="",collection="",ownedCollection="",high=false,traits:Record<string,string>={},limit=10;
  let offers:any[]=[],owned:any[]=[],listings:any[]=[],collections:string[]=[],ownedCollections:string[]=[],traitOptions:any={},offset:any=null,cursor:any=null,pendingBroadcast=false;
  let epoch=0,loading=false,error="",searchTimer:ReturnType<typeof setTimeout>;
  hooks.shell('<section class="nft-market-screen"><div class="market-title"><div><p class="eyebrow">K-AGORA</p><h1>NFT Market</h1></div><button id="nft-market-refresh" class="icon" aria-label="Refresh NFT Market">↻</button></div><div id="nft-market-content"></div></section>',"NFT Market",true);
  const host=document.querySelector<HTMLElement>("#nft-market-content")!;
  const active=()=>host.isConnected && address===hooks.address();
  function options(rows:string[],selected:string) {
    return '<option value="">All collections</option>'+rows.map(tick=>`<option value="${esc(tick)}" ${tick===selected?"selected":""}>${esc(tick)}</option>`).join("");
  }
  function card(nft:any,index:number) {
    const state=typeof nft.status==="string"?nft.status:nft.status?.state;
    const terminal=["sold","cancelled"].includes(state);
    // Directory records from the app have no local extension recovery stage.
    // Missing local fields must never turn a published or cancelled offer into
    // an incomplete listing. Retain recovery only for a real unfinished local flow.
    const unfinished=!!nft.localId && ["commit","reveal","offer"].includes(nft.stage) && !terminal;
    const publication=tab!=="listings" || terminal ? "" : unfinished
      ? '<p>Finish pending listing</p><button class="outline" data-action="recovery">Recovery code</button>'
      : nft.published || !nft.localId
        ? '<p>Published</p>'
        : nft.publicationBlocked
          ? `<p>Publication rejected: ${esc(nft.publicationError)}</p>`
          : '<p>Publishing automatically · waiting for confirmation</p>';
    return `<article class="market-offer nft-market-card" data-nft-row="${index}">${nft.imageUrl?`<img data-nft-image src="${esc(nft.imageUrl)}" alt="${esc(nft.ticker)} #${esc(nft.tokenId)}">`:""}<h2 data-preserve-case>${esc(nft.ticker)} #${esc(nft.tokenId)}</h2><p>${nft.rarityRank==null?"Rarity rank unavailable":nft.rarityRank===-1?"Legendary":`Rarity rank #${esc(nft.rarityRank)}`}</p>${tab!=="owned"?`<strong>${money(nft.priceSompi)}</strong><p class="nft-listing-state">${esc(state??"pending")}</p>`:""}<div class="nft-card-actions">${tab==="browse" && state==="active" && nft.seller!==address?'<button data-action="buy">Buy NFT</button>':""}${tab==="owned"?`<button data-action="send" ${state==="listed"?"disabled":""}>Send</button><button data-action="list">${state==="listed"?"Listed":"List"}</button>`:""}${tab==="listings" && !terminal?unfinished?'<button data-action="resume">Resume listing</button>':'<button data-action="cancel">Cancel listing</button>':""}</div>${publication}</article>`;
  }
  function paint() {
    if(!active()) return;
    const rows=tab==="browse"?offers:tab==="owned"?owned:listings.slice(0,limit);
    const tools=tab==="browse"?`<div class="market-tools"><input id="nft-market-search" placeholder="Search NFTs" value="${esc(query)}"><select data-preserve-case id="nft-market-collection" aria-label="Collection">${options(collections,collection)}</select><select id="nft-market-sort" aria-label="Sort price"><option value="low" ${!high?"selected":""}>Price: Low to High</option><option value="high" ${high?"selected":""}>Price: High to Low</option></select>${collection?`<details class="nft-traits"><summary>Trait filters${Object.keys(traits).length?` (${Object.keys(traits).length})`:""}</summary>${Object.entries(traitOptions).map(([name,values])=>`<label>${esc(name)}<select data-trait="${esc(name)}"><option value="">All</option>${(Array.isArray(values)?values:[]).map((v:any)=>`<option value="${esc(v)}" ${traits[name]===String(v)?"selected":""}>${esc(v)}</option>`).join("")}</select></label>`).join("")}</details>`:""}</div>`:tab==="owned"?`<div class="market-tools"><select data-preserve-case id="nft-owned-collection" aria-label="My NFT collection">${options(ownedCollections,ownedCollection)}</select></div>`:"";
    host.innerHTML=`<div class="market-tabs">${[["browse","Browse"],["owned","My NFTs"],["listings","My listings"]].map(([id,label])=>`<button data-tab="${id}" class="${tab===id?"active":""}">${label}</button>`).join("")}</div>${tools}${error?`<p class="error">${esc(error)}</p>`:""}${tab==="listings" && pendingBroadcast?'<button id="nft-resume-broadcast">Resume saved transaction</button>':""}<div class="nft-market-grid">${rows.map(card).join("")}</div>${loading?'<div class="loading">Loading NFTs…</div>':!rows.length?'<p class="empty">No NFTs found.</p>':""}${(tab==="browse"?offset!=null:tab==="owned"?cursor!=null:listings.length>limit)?'<button id="nft-market-more" class="outline">Load more</button>':""}`;
    nftImageFallback(host);
    host.querySelectorAll<HTMLButtonElement>("[data-tab]").forEach(button=>button.onclick=()=>{tab=button.dataset.tab!;limit=10;void load();});
    const search=host.querySelector<HTMLInputElement>("#nft-market-search");
    if(search) search.oninput=()=>{query=search.value;clearTimeout(searchTimer);searchTimer=setTimeout(()=>void load(),450);};
    host.querySelector<HTMLSelectElement>("#nft-market-collection")?.addEventListener("change",event=>{collection=(event.target as HTMLSelectElement).value;traits={};void load();});
    host.querySelector<HTMLSelectElement>("#nft-market-sort")?.addEventListener("change",event=>{high=(event.target as HTMLSelectElement).value==="high";void load();});
    host.querySelector<HTMLSelectElement>("#nft-owned-collection")?.addEventListener("change",event=>{ownedCollection=(event.target as HTMLSelectElement).value;void load();});
    host.querySelectorAll<HTMLSelectElement>("[data-trait]").forEach(select=>select.onchange=()=>{if(select.value) traits[select.dataset.trait!]=select.value;else delete traits[select.dataset.trait!];void load();});
    host.querySelector<HTMLButtonElement>("#nft-market-more")?.addEventListener("click",()=>{if(tab==="listings"){limit+=10;paint();}else void load(true);});
    host.querySelector<HTMLButtonElement>("#nft-resume-broadcast")?.addEventListener("click",()=>void transact({action:"resumeBroadcast"}));
    host.querySelectorAll<HTMLElement>("[data-nft-row]").forEach(element=>{
      const nft=rows[Number(element.dataset.nftRow)];
      element.querySelectorAll<HTMLButtonElement>("[data-action]").forEach(button=>button.onclick=()=>{
        const action=button.dataset.action;
        if(action==="send") hooks.send(nft);
        else if(action==="list") {if(nft.status?.state==="listed"){tab="listings";void load();}else list(nft);}
        else if(action==="recovery") recovery(nft);
        else void transact({action,offer:nft,localId:nft.localId});
      });
    });
  }
  async function load(more=false,refresh=false) {
    const stamp=++epoch;loading=true;error="";paint();
    try {
      if(tab==="browse") {
        const page=await hooks.command("nftMarketBrowse",{params:{q:query,collection,traits,high,offset:more?offset:0,refresh}});
        if(!active()||stamp!==epoch)return;
        offers=more?[...offers,...page.offers]:page.offers;offset=page.nextOffset;collections=page.collections??[];traitOptions=page.traitOptions??{};
      } else if(tab==="owned") {
        const page=await hooks.command("nftMarketOwned",{cursor:more?cursor:"",collection:ownedCollection});
        if(!active()||stamp!==epoch)return;
        owned=more?[...owned,...page.nfts]:page.nfts;cursor=page.next;
      } else {
        const page=await hooks.command("nftMarketListings");
        if(!active()||stamp!==epoch)return;
        listings=page.records;pendingBroadcast=page.pendingBroadcast;
      }
    } catch(e) {if(active()&&stamp===epoch)error=(e as Error).message;}
    finally {if(active()&&stamp===epoch){loading=false;paint();}}
  }
  function recovery(record:any) {
    const overlay=document.createElement("div");overlay.className="kaspire-modal";
    overlay.innerHTML=`<section class="approval-sheet"><h1>Public recovery code</h1><p>No private keys are included. Keep this with your wallet backup.</p><textarea readonly rows="9">${esc(JSON.stringify(record))}</textarea><div class="approval-actions"><button class="outline" id="nft-recovery-close">Close</button><button id="nft-recovery-copy">Copy</button></div></section>`;
    document.body.append(overlay);overlay.querySelector<HTMLButtonElement>("#nft-recovery-close")!.onclick=()=>overlay.remove();overlay.querySelector<HTMLButtonElement>("#nft-recovery-copy")!.onclick=()=>void navigator.clipboard.writeText(JSON.stringify(record));
  }
  function list(nft:any) {
    const overlay=document.createElement("div");overlay.className="kaspire-modal";
    overlay.innerHTML=`<section class="approval-sheet"><p class="eyebrow">LIST NFT</p><h1 data-preserve-case>${esc(nft.ticker)} #${esc(nft.tokenId)}</h1><label>Price in KAS<input id="nft-list-price" inputmode="decimal" placeholder="Minimum 10 KAS"></label><p class="error" id="nft-price-error"></p><div class="approval-actions"><button class="outline" id="nft-list-close">Cancel</button><button id="nft-list-review">Review listing</button></div></section>`;
    document.body.append(overlay);overlay.querySelector<HTMLButtonElement>("#nft-list-close")!.onclick=()=>overlay.remove();
    overlay.querySelector<HTMLButtonElement>("#nft-list-review")!.onclick=()=>{
      const value=overlay.querySelector<HTMLInputElement>("#nft-list-price")!.value.trim();
      const [whole,fraction=""]=value.split(".");const price=Number(whole+fraction.padEnd(8,"0"));
      if(!/^\d+(?:\.\d{0,8})?$/.test(value)||!Number.isSafeInteger(price)||price<1_000_000_000||price>9_000_000_000_000_000){overlay.querySelector("#nft-price-error")!.textContent="Enter 10–90,000,000 KAS, with at most 8 decimal places.";return;}
      overlay.remove();void transact({action:"list",nft,priceSompi:price});
    };
  }
  async function transact(input:any) {
    if(loading)return;loading=true;error="";paint();
    try {
      const result=await hooks.command("nftMarketOperation",input);
      if(!active())return;
      const overlay=document.createElement("div");overlay.className="kaspire-modal";
      overlay.innerHTML=`<section class="approval-sheet"><h1>${input.action==="list"||input.action==="resume"?"NFT listed":"Transaction submitted"}</h1>${result.transactionId?`<label>Transaction ID</label><code>${esc(result.transactionId)}</code>`:""}<button id="nft-receipt-done">Done</button></section>`;
      document.body.append(overlay);overlay.querySelector<HTMLButtonElement>("#nft-receipt-done")!.onclick=()=>overlay.remove();
      tab="listings";
    } catch(e){error=(e as Error).message;}
    finally {loading=false;if(active()){const message=error;await load(false,true);error=message;paint();}}
  }
  document.querySelector<HTMLButtonElement>("#nft-market-refresh")!.onclick=()=>void load(false,true);
  void hooks.command("nftMarketCollections").then(ticks=>{if(active()){ownedCollections=ticks;paint();}}).catch(()=>undefined);
  void hooks.command("nftMarketPublishPending").catch(()=>undefined);
  // Retry only saved unpublished offers; Browse is never periodically reloaded.
  const timer=setInterval(()=>{
    if(!active()){clearInterval(timer);return;}
    void hooks.command("nftMarketPublishPending").catch(()=>undefined);
    if(tab==="listings" && !loading && listings.some(row=>row.stage==="complete"&&!row.published&&!row.publicationBlocked&&!['sold','cancelled'].includes(row.status))) void load();
  },30000);
  await load();
  if(initialNft && active()) list(initialNft);
}
