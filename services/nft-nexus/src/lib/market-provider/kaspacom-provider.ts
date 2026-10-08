import { privateToken } from "./private-indexer";
import { env } from "@/lib/validation/env";
import { kasToSompi } from "@/lib/offers/money";
import { getOrFetchRarityRank } from "@/lib/market-provider/rarity-cache";
import { getCollectionInfo, getKrc721ImageUrl, isBlacklistedCollection, normalizeCollectionId } from "./collections";
import type { MarketProvider, NftReference, NftSnapshot } from "./types";

type KaspaComListedOrder = {
  orderId?: string;
  id?: string;
  tokenId?: string | number;
  totalPrice?: string | number;
  requiredKaspa?: string | number;
  status?: string;
  sellerWalletAddress?: string;
  isDecentralized?: boolean;
  listingSource?: "pskt" | "legacy";
};

type KaspaComListedOrdersResponse = {
  orders?: KaspaComListedOrder[];
  totalCount?: number;
};

const ACTIVE_LISTING_STATUSES = new Set(["LISTED_FOR_SALE", "LISTED"]);
const COLLECTION_LISTING_CACHE_MS = 10 * 60 * 1000;
const COLLECTION_LISTING_STALE_MS = 24 * 60 * 60 * 1000;
const COLLECTION_LISTING_BACKOFF_MAX_MS = 60 * 60 * 1000;
const COLLECTION_LISTING_PAGE_SIZE = 50;
const collectionListingCache = new Map<string, { checkedAt: number; orders: Map<string, KaspaComListedOrder> }>();
const collectionListingInflight = new Map<string, Promise<Map<string, KaspaComListedOrder>>>();
const collectionListingBackoff = new Map<string, { failures: number; retryAt: number }>();
export class KaspaComMarketProvider implements MarketProvider {
  async parseMarketUrl(url: string): Promise<NftReference | null> {
    let parsed: URL;
    try {
      parsed = new URL(url);
    } catch {
      return null;
    }

    if (!["kaspa.com", "www.kaspa.com"].includes(parsed.hostname)) {
      return null;
    }

    const parts = parsed.pathname.split("/").filter(Boolean);
    const nftIndex = parts.findIndex((part) => part.toLowerCase() === "nft");
    if (nftIndex === -1) {
      return null;
    }

    if (parts[nftIndex + 1]?.toLowerCase() === "collections" && parts.length >= nftIndex + 4) {
      return { collectionId: normalizeCollectionId(parts[nftIndex + 2]), tokenId: parts[nftIndex + 3] };
    }

    if (parts.length >= nftIndex + 3) {
      return { collectionId: normalizeCollectionId(parts[nftIndex + 1]), tokenId: parts[nftIndex + 2] };
    }

    return null;
  }

  async getNftSnapshot(ref: NftReference): Promise<NftSnapshot | null> {
    const collection = getCollectionInfo(ref.collectionId);
    if (!collection) {
      return null;
    }
    // Ownership and protocol listing state are authoritative in our local
    // indexer. Do not fan out to KaspaCom for every unlisted token (or for
    // Next.js link prefetches). KaspaCom is only needed to enrich an active
    // on-chain listing with its marketplace order id and price.
    const [tokenDetails, rarityRank] = await Promise.all([
      fetchTokenDetails(collection.ticker, ref.tokenId),
      getOrFetchRarityRank(collection.collectionId, ref.tokenId)
    ]);
    if (!tokenDetails) return null;
    const isListedOnChain = tokenDetails.status?.state === "listed";
    const listing = isListedOnChain ? await fetchListedOrder(collection.ticker, ref.tokenId) : null;
    const matchingOrder = isActiveListing(listing) && listing?.sellerWalletAddress === tokenDetails.owner ? listing : null;
    const listingPriceSompi = matchingOrder?.totalPrice !== undefined ? kasToSompi(String(matchingOrder.totalPrice)) : null;
    const listingId = isListedOnChain
      ? matchingOrder?.orderId ?? matchingOrder?.id ?? tokenDetails.status?.listingTxId ?? null
      : null;

    return {
      collectionId: collection.collectionId,
      collectionName: collection.displayName,
      tokenId: ref.tokenId,
      name: `${collection.displayName} #${ref.tokenId}`,
      imageUrl: getKrc721ImageUrl(ref.collectionId, ref.tokenId),
      ownerWallet: tokenDetails.owner ?? null,
      marketUrl: this.getCanonicalMarketUrl(ref),
      listingStatus: isListedOnChain ? "LISTED" : "UNLISTED",
      listingPriceSompi,
      listingId,
      rarityRank,
      checkedAt: new Date()
    };
  }

  getCanonicalMarketUrl(ref: NftReference) {
    const base = env.KASPACOM_MARKETPLACE_BASE_URL.replace(/\/$/, "");
    const collection = getCollectionInfo(ref.collectionId);
    const ticker = collection?.ticker ?? ref.collectionId.toUpperCase();
    return `${base}/nft/collections/${encodeURIComponent(ticker)}/${encodeURIComponent(ref.tokenId)}`;
  }

  async isSupportedCollection(_collectionId: string) {
    return !isBlacklistedCollection(_collectionId);
  }
}

async function fetchListedOrder(ticker: string, tokenId: string) {
  try {
    const orders = await fetchCollectionListedOrders(ticker);
    return orders.get(String(tokenId)) ?? null;
  } catch {
    // An unavailable API is not proof that an NFT is unlisted. UNKNOWN prevents
    // the watcher from replacing a previously verified listing state.
    return undefined;
  }
}

async function fetchCollectionListedOrders(ticker: string) {
  const now = Date.now();
  const cached = collectionListingCache.get(ticker);
  if (cached && now - cached.checkedAt < COLLECTION_LISTING_CACHE_MS) return cached.orders;
  const backoff = collectionListingBackoff.get(ticker);
  if (backoff && now < backoff.retryAt) {
    if (cached && now - cached.checkedAt < COLLECTION_LISTING_STALE_MS) return cached.orders;
    throw new Error("KaspaCom collection listing check is in backoff.");
  }
  if (!collectionListingInflight.has(ticker)) {
    const request = (async () => {
      try {
        const psktOrders = await fetchCollectionListingSource(ticker, "pskt");
        const orders = new Map<string, KaspaComListedOrder>();
        for (const order of psktOrders) {
          const tokenId = String(order.tokenId ?? "");
          if (tokenId && isActiveListing(order)) orders.set(tokenId, order);
        }
        collectionListingCache.set(ticker, { checkedAt: Date.now(), orders });
        collectionListingBackoff.delete(ticker);
        return orders;
      } catch (error) {
        const failures = Number(collectionListingBackoff.get(ticker)?.failures ?? 0) + 1;
        const delay = Math.min(COLLECTION_LISTING_BACKOFF_MAX_MS, 60_000 * 2 ** Math.min(failures - 1, 6));
        collectionListingBackoff.set(ticker, { failures, retryAt: Date.now() + delay });
        if (cached && Date.now() - cached.checkedAt < COLLECTION_LISTING_STALE_MS) return cached.orders;
        throw error;
      }
    })().finally(() => collectionListingInflight.delete(ticker));
    collectionListingInflight.set(ticker, request);
  }
  return collectionListingInflight.get(ticker)!;
}

async function fetchCollectionListingSource(ticker: string, source: "pskt" | "legacy") {
  const endpoint = source === "pskt"
    ? `https://api.kaspa.com/krc721-orders-v2/sell-orders?${new URLSearchParams({ ticker })}`
    : `https://api.kaspa.com/krc721-orders/listed-orders/${encodeURIComponent(ticker)}`;
  const orders: KaspaComListedOrder[] = [];
  const seenPages = new Set<string>();
  for (let page = 0; ; page += 1) {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        pagination: { limit: COLLECTION_LISTING_PAGE_SIZE, offset: page * COLLECTION_LISTING_PAGE_SIZE },
        sort: { field: "createdAt", direction: "desc" }
      }),
      cache: "no-store"
    });
    if (!response.ok) throw new Error(`KaspaCom ${source} listing check returned HTTP ${response.status}.`);
    const data = (await response.json()) as KaspaComListedOrdersResponse;
    const pageOrders = data.orders ?? [];
    const fingerprint = JSON.stringify(pageOrders.map((order) => [order.orderId ?? order.id, order.tokenId]));
    if (pageOrders.length && seenPages.has(fingerprint)) throw new Error("Marketplace listing pagination did not advance.");
    seenPages.add(fingerprint);
    orders.push(...pageOrders.map((order) => ({ ...order, listingSource: source })));
    const totalCount = Number(data.totalCount ?? 0);
    if (!pageOrders.length || pageOrders.length < COLLECTION_LISTING_PAGE_SIZE || (totalCount > 0 && orders.length >= totalCount)) break;
  }
  return orders;
}

function isActiveListing(order: KaspaComListedOrder | null | undefined) {
  if (!order) {
    return false;
  }

  const status = String(order.status ?? "").toUpperCase();
  return !status || ACTIVE_LISTING_STATUSES.has(status);
}

async function fetchTokenDetails(ticker: string, tokenId: string) {
  return privateToken(ticker, tokenId);
}
