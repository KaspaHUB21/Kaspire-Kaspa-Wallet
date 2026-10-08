// Server-side only. This address is never passed to browser components.
const base = (process.env.KRC721_PRIVATE_BASE_URL || "http://127.0.0.1:18801").replace(/\/$/, "");
const parsedBase = new URL(base);
if (parsedBase.protocol !== "http:" || parsedBase.hostname !== "127.0.0.1" || parsedBase.username || parsedBase.password || parsedBase.pathname !== "/") {
  throw new Error("KRC721_PRIVATE_BASE_URL must point to a loopback HTTP service.");
}

export type PrivateToken = {
  tick: string;
  tokenId: string;
  owner?: string;
  status?: { state?: string; listingTxId?: string };
  metadata?: { name?: string; attributes?: Array<{ trait_type: string; value: string | number | boolean | null }> } | null;
  cache?: { metadata: string; image: string };
  imageUrl?: string;
};
export type CatalogToken = {
  ticker?: string;
  tokenId?: string | number;
  attributes?: Array<{ trait_type: string; value: string | number | boolean | null }>;
  traits?: Record<string, string | number | boolean | { value?: string | number | boolean | null } | null>;
  rarityRank?: number | null;
  metadataState?: string;
  imageState?: string;
};

export async function privateFetch(path: string, signal?: AbortSignal) {
  if (!path.startsWith("/") || path.startsWith("//")) throw new Error("Invalid private API path.");
  try {
  const response = await fetch(base + path, {
    cache: "no-store",
    signal: signal ?? AbortSignal.timeout(15_000),
    headers: process.env.KRC721_PRIVATE_API_KEY ? { "X-KRC721-Key": process.env.KRC721_PRIVATE_API_KEY } : {}
  });
  if (response.ok) {
    const value=await response.clone().json();
    if(value?.message==='success'&&value.result!=null)return response;
  }
  } catch { /* The local source is unavailable; use only the official read API. */ }
  return officialRead(path);
}

async function officialRead(path:string):Promise<Response> {
 const url=new URL(path,'http://127.0.0.1'),parts=url.pathname.split('/').filter(Boolean);
 if(parts[0]!=='v1')throw Error('Invalid NFT fallback route.');
 if(parts[1]==='wallets'||parts[1]==='nfts') {
  const route=parts[1]==='wallets'?'address':'nfts';
  const tail=parts.slice(2).map((p,i)=>parts[1]==='nfts'&&i===0?p.toLowerCase():p).join('/');
  url.searchParams.set('direction','forward');
  return fetch(`https://krc721-indexer.kaspa.com/api/v1/krc721/mainnet/${route}/${tail}?${url.searchParams}`,{signal:AbortSignal.timeout(12000)});
 }
 if(parts[1]==='catalog'&&parts.length===3) {
  const offset=Number(url.searchParams.get('offset')||0),limit=100;
  const r=await fetch('https://api.kaspa.com/krc721/tokens',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({ticker:parts[2].toUpperCase(),limit,offset,sortField:'tokenId',sortDirection:'asc',traits:{}}),signal:AbortSignal.timeout(12000)});
  if(!r.ok)return r;
  const data=await r.json(),items=data.items,total=Number(data.totalCount);
  if(!Array.isArray(items)||!Number.isSafeInteger(total)||total<0)throw Error('Official NFT catalog unavailable.');
  return new Response(JSON.stringify({message:'success',result:items,totalCount:total,metadataReady:total,next:offset+items.length<total?offset+items.length:null}),{status:200,headers:{'content-type':'application/json'}});
 }
 throw Error('No official fallback for this display route.');
}

export async function privateJson<T>(path: string, signal?: AbortSignal): Promise<T> {
  const response = await privateFetch(path, signal);
  if (!response.ok) throw new Error(`Private indexer returned HTTP ${response.status}.`);
  const data = await response.json();
  if (data.message !== "success") throw new Error("Private indexer returned no successful result.");
  return data as T;
}

export async function privateToken(ticker: string, tokenId: string): Promise<PrivateToken | null> {
  const response = await privateFetch(`/v1/nfts/${encodeURIComponent(ticker)}/${encodeURIComponent(tokenId)}`);
  if (response.status === 404) return null;
  if (!response.ok) throw new Error(`Private NFT lookup returned HTTP ${response.status}.`);
  const data = await response.json();
  if (data.message !== "success") throw new Error("Private NFT lookup failed.");
  return data.result;
}

export async function privateWallet(walletAddress: string, ticker?: string) {
  const path = `/v1/wallets/${encodeURIComponent(walletAddress)}${ticker ? `/${encodeURIComponent(ticker)}` : ""}`;
  const tokens: PrivateToken[] = [];
  const seen = new Set<string>();
  let cursor: string | number | null = null;
  do {
    const query = new URLSearchParams({ limit: "50" });
    if (cursor !== null) query.set("offset", String(cursor));
    const data: { result: PrivateToken[]; next?: string | number | null } = await privateJson(path + "?" + query);
    tokens.push(...data.result);
    cursor = data.next ?? null;
    if (cursor !== null) {
      if (!data.result.length || seen.has(String(cursor))) throw new Error("Private wallet pagination did not advance.");
      seen.add(String(cursor));
    }
  } while (cursor !== null);
  return tokens;
}

const snapshots = new Map<string, { expiresAt: number; value: { items: CatalogToken[]; totalCount: number; metadataReady: number } }>();
const pending = new Map<string, Promise<{ items: CatalogToken[]; totalCount: number; metadataReady: number }>>();
export async function privateCollectionSnapshot(ticker: string, signal?: AbortSignal) {
  const cached = snapshots.get(ticker);
  if (cached && cached.expiresAt > Date.now()) return cached.value;
  if (pending.has(ticker)) return pending.get(ticker)!;
  const request = (async () => {
    const items: CatalogToken[] = [];
    const seen = new Set<number>();
    let cursor: number | null = 0;
    let totalCount = 0, metadataReady = 0;
    do {
      const data: { result: CatalogToken[]; next: number | null; totalCount: number; metadataReady: number } =
        await privateJson(`/v1/catalog/${encodeURIComponent(ticker)}?limit=500&offset=${cursor}`, signal);
      items.push(...data.result);
      totalCount = data.totalCount;
      metadataReady = data.metadataReady;
      cursor = data.next;
      if (cursor !== null) {
        if (!data.result.length || seen.has(cursor)) throw new Error("Private catalog pagination did not advance.");
        seen.add(cursor);
      }
    } while (cursor !== null);
    if (items.length !== totalCount) throw new Error("Collection inventory changed; retry the lookup.");
    const value = { items, totalCount, metadataReady };
    snapshots.set(ticker, { expiresAt: Date.now() + 30_000, value });
    return value;
  })().finally(() => pending.delete(ticker));
  pending.set(ticker, request);
  return request;
}
