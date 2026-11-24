import type { ApiEnvelope, ChartPoint, ChartRange, Holder, HolderActivity, HomeSearchIndex, HomeSummary, KaspaStats, KaspaStatsRange, Kcc20DexInterval, Kcc20DexMarket, Kcc20DexTokenDetail, Kcc20TokenDetail, Kcc20TokenList, Kcc20TransactionOwners, KnsDomain, KnsMarketplace, Krc721HolderSnapshot, Krc721WalletCollection, MarketOverview, SourceNotice, Token, TokenLayer, TokenListResponse, TokenTransaction, TransactionType, WalletDetail, WalletNetwork } from "../types/token";

const API_BASE_URL = (import.meta.env.VITE_API_BASE_URL || "/api").replace(/\/$/, "");

async function request<T>(path: string, init?: RequestInit): Promise<ApiEnvelope<T>> {
  const response = await fetch(API_BASE_URL + path, {
    headers: {
      Accept: "application/json"
    },
    ...init
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(text || "API request failed");
  }

  return response.json() as Promise<ApiEnvelope<T>>;
}

export function getTokens(layer: TokenLayer) {
  return request<TokenListResponse>("/tokens?layer=" + encodeURIComponent(layer));
}

export function getToken(id: string) {
  return request<Token>("/token/" + encodeURIComponent(id));
}

export function getHolders(id: string) {
  return request<{ holders: Holder[] }>("/token/" + encodeURIComponent(id) + "/holders?fast=1");
}

export function getHolderActivity(id: string, addresses: string[]) {
  return request<{ activity: HolderActivity[] }>("/token/" + encodeURIComponent(id) + "/holder-activity", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ addresses })
  });
}

export function getKcc20Tokens() {
  return request<Kcc20TokenList>("/kcc20/tokens");
}

export function getKcc20Token(covenantId: string) {
  return request<Kcc20TokenDetail>("/kcc20/token/" + encodeURIComponent(covenantId));
}

export function getKcc20TransactionOwners(covenantId: string, txids: string[]) {
  return request<{ transactions: Kcc20TransactionOwners[] }>("/kcc20/token/" + encodeURIComponent(covenantId) + "/transaction-owners", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ txids })
  });
}

export function getKcc20DexMarkets() {
  return request<{ markets: Kcc20DexMarket[] }>("/kcc20/dex/markets");
}

export function getKcc20DexToken(covenantId: string, interval: Kcc20DexInterval) {
  return request<Kcc20DexTokenDetail>("/kcc20/dex/token/" + encodeURIComponent(covenantId) + "?interval=" + encodeURIComponent(interval));
}

export function getKrc721HolderSnapshot(id: string) {
  return request<Krc721HolderSnapshot>("/token/" + encodeURIComponent(id) + "/krc721-holder-snapshot");
}

export function getTransactions(id: string, type?: TransactionType, cursor?: string | null) {
  const params = new URLSearchParams();
  if (type) {
    params.set("type", type);
  }
  if (cursor) {
    params.set("cursor", cursor);
  }
  const suffix = params.toString() ? "?" + params.toString() : "";
  return request<{ transactions: TokenTransaction[]; next_cursor: string | null }>("/token/" + encodeURIComponent(id) + "/tx" + suffix);
}

export function getChart(id: string, range: ChartRange) {
  return request<{ points: ChartPoint[] }>("/token/" + encodeURIComponent(id) + "/chart?range=" + range + "&_=" + Date.now(), { cache: "no-store" });
}

export function getMarketOverview() {
  return request<MarketOverview>("/market/overview");
}

export function getHomeSummary() {
  return request<HomeSummary>("/home/summary");
}

export function getHomeSearchIndex() {
  return request<HomeSearchIndex>("/home/search-index");
}

export function getKaspaStats(range: KaspaStatsRange = "24h") {
  return request<KaspaStats>("/kaspa/stats?range=" + encodeURIComponent(range));
}

export function getKnsMarketplace(query = "") {
  const params = new URLSearchParams();
  if (query.trim()) {
    params.set("query", query.trim());
  }
  const suffix = params.toString() ? "?" + params.toString() : "";
  return request<KnsMarketplace>("/kns/market" + suffix);
}

export function getKnsSearch(query: string) {
  const params = new URLSearchParams({ query: query.trim() });
  return request<{ query: string; domains: KnsDomain[] }>("/kns/search?" + params.toString());
}

export function getSources() {
  return request<{ sources: SourceNotice[] }>("/sources");
}

export function getWallet(network: WalletNetwork, address: string, includeNfts = true,includeKcc20 = true) {
  const query=new URLSearchParams();if(!includeNfts)query.set("include_nfts","false");if(!includeKcc20)query.set("include_kcc20","false");
  return request<WalletDetail>("/wallet/" + encodeURIComponent(network) + "/" + encodeURIComponent(address) + (query.size?"?"+query.toString():""));
}

export function getWalletKcc20Holdings(address:string) {
  return request<import("../types/token").Kcc20WalletHoldings>("/wallet/krc20/"+encodeURIComponent(address)+"/kcc20");
}

export function getWalletKrc721Holdings(address: string) {
  return request<{address: string; tokens: NonNullable<WalletDetail["krc721_tokens"]>}>("/wallet/krc20/" + encodeURIComponent(address) + "/krc721");
}

export function getWalletKrc721Collection(address: string, ticker: string, offset = 0, limit = 4) {
  const params = new URLSearchParams({ offset: String(offset), limit: String(limit) });
  return request<Krc721WalletCollection>("/wallet/krc20/" + encodeURIComponent(address) + "/krc721/" + encodeURIComponent(ticker) + "?" + params.toString());
}

export function getWalletTransactions(network: WalletNetwork, address: string, cursor?: string | null,standard?:string) {
  const params = new URLSearchParams();
  if(standard)params.set("standard",standard);
  if (cursor) {
    params.set("cursor", cursor);
  }
  const suffix = params.toString() ? "?" + params.toString() : "";
  return request<{ transactions: TokenTransaction[]; next_cursor: string | null }>("/wallet/" + encodeURIComponent(network) + "/" + encodeURIComponent(address) + "/tx" + suffix);
}

