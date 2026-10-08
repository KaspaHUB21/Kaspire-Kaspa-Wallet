// Display data only. Transaction authorization always uses OFFICIAL directly.
export const NFT_READ = "https://kaspire.kaslab.space/krc721-read-v1";
export const NFT_OFFICIAL = "https://krc721-indexer.kaspa.com/api/v1/krc721/mainnet";
export function nftIdentity(ticker: string, id?: string) {
  if (!/^[A-Z0-9_-]{1,32}$/.test(ticker) || (id !== undefined && !/^\d{1,20}$/.test(id)))
    throw new Error("Invalid NFT identity.");
}
async function json(response: Response) {
  if (!response.ok) throw new Error(`NFT source unavailable (${response.status}).`);
  const text = await response.text();
  if (text.length > 4 * 1024 * 1024) throw new Error("NFT response too large.");
  return JSON.parse(text);
}
const unavailable = (s: number) => s === 408 || s === 429 || s >= 500;
export async function nftWalletPage(address: string, cursor = "", ticker = "", limit = 50) {
  if (!/^kaspa:[a-z0-9]{61,63}$/.test(address)) throw new Error("Invalid NFT wallet address.");
  if (ticker) nftIdentity(ticker);
  const path = `/address/${encodeURIComponent(address)}${ticker ? `/${encodeURIComponent(ticker.toLowerCase())}` : ""}`;
  const query = new URLSearchParams({limit: String(limit), direction: "forward", ...(cursor ? {offset: cursor} : {})});
  let response: Response | undefined;
  try {
    response = await fetch(`${NFT_READ}${path}?${query}`, {signal: AbortSignal.timeout(5000)});
    const local = await json(response);
    if (Array.isArray(local?.result) && (local.message == null || local.message === 'success')) return local;
  } catch { /* Invalid local responses are source failures, not empty wallets. */ }
  response = await fetch(`${NFT_OFFICIAL}${path}?${query}`, {signal: AbortSignal.timeout(12000)});
  const value = await json(response);
  if (!Array.isArray(value?.result) || (value.message != null && value.message !== 'success')) throw new Error("Invalid NFT wallet response.");
  return value;
}
export function nftImage(ticker: string, id: string) {
  nftIdentity(ticker, id);
  return `${NFT_READ}/images/${encodeURIComponent(ticker)}/${encodeURIComponent(id)}`;
}
export async function nftMetadata(ticker: string, ids: string[]) {
  ids.forEach(id => nftIdentity(ticker, id));
  if (!ids.length || ids.length > 100) throw new Error("Invalid NFT metadata batch.");
  let local: any[] = [], fallback = false;
  try {
    const response = await fetch(`${NFT_READ}/metadata/${ticker}?ids=${ids.join(",")}`, {signal: AbortSignal.timeout(5000)});
    if (unavailable(response.status) || response.status === 404) fallback = true;
    else {
      const data = await json(response);
      if (!Array.isArray(data.items)) throw new Error("Invalid NFT metadata response.");
      local = data.items; fallback = data.ranksAvailable !== true;
    }
  } catch {
    fallback = true;
  }
  if (fallback) try {
    const response = await fetch("https://api.kaspa.com/krc721/tokens", {method:"POST", headers:{"content-type":"application/json"},
      body: JSON.stringify({ticker, tokenIds: ids, limit:ids.length, offset:0, sortField:"tokenId", sortDirection:"asc", traits:{}}), signal:AbortSignal.timeout(10000)});
    const remote = await json(response);
    for (const item of Array.isArray(remote.items) ? remote.items : []) {
      const own = local.find(row => String(row.tokenId) === String(item.tokenId));
      if (own) { if (own.rarityRank == null) own.rarityRank = item.rarityRank; }
      else local.push(item);
    }
  } catch { /* Metadata failure must never hide owned NFTs. */ }
  return local;
}
export async function officialNft(ticker: string, id: string) {
  nftIdentity(ticker, id);
  const value = await json(await fetch(`${NFT_OFFICIAL}/nfts/${ticker.toLowerCase()}/${id}`, {signal:AbortSignal.timeout(12000)}));
  if (!value?.result || typeof value.result.owner !== "string") throw new Error("Official NFT ownership verification unavailable.");
  return value.result;
}
export async function requireUnlistedNft(address: string, ticker: string, id: string) {
  const nft = await officialNft(ticker, id);
  if (nft.owner !== address) throw new Error("The selected wallet does not own this NFT.");
  if (nft.status?.state === "listed") throw new Error("This NFT is listed. Cancel its listing before sending or listing again.");
  return true;
}
