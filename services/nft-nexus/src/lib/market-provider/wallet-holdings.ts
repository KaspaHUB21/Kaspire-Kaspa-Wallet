import { storedCollectionRanks } from "./stored-rarity";
import { privateWallet, privateCollectionSnapshot } from "./private-indexer";
import { SUPPORTED_COLLECTIONS, getCollectionInfo, getKrc721ImageUrl, normalizeTicker } from "./collections";
import type { CollectionTraitCatalog, CollectionTraitFilters, CollectionTokenPage } from "./kaspacom-tokens";
import { isCollectionBlacklisted } from "@/server/services/blacklist-service";

type WalletLookupSummary = {
  ticker?: string;
  tokenIds?: string[];
  listedTokenIds?: string[];
  unlistedTokenIds?: string[];
};

type WalletLookupToken = {
  ticker?: string;
  tokenId?: string | number;
  traits?: Record<string, string | number | boolean | { value?: string | number | boolean | null } | null>;
  attributes?: Array<{ trait_type?: string; value?: string | number | boolean | null }>;
  rarityRank?: number;
};

type LegacyListedOrder = {
  id?: string;
  orderId?: string;
  ticker?: string;
  tokenId?: string | number;
  sellerWalletAddress?: string;
  rarityRank?: number;
};

type LegacyListedOrdersResponse = {
  orders?: LegacyListedOrder[];
  totalCount?: number;
};

type WalletLookupCollection = {
  ticker?: string;
  tokenIds?: WalletLookupToken[];
  totalTokenCount?: number;
  hasMore?: boolean;
  listedTokenIds?: string[];
  unlistedTokenIds?: string[];
};

type KnsOwnerResponse = {
  success?: boolean;
  data?: {
    owner?: string;
  };
};

export type WalletCollectionSummary = {
  collectionId: string;
  ticker: string;
  displayName: string;
  count: number;
  previewTokenId: string | null;
  imageUrl: string | null;
  listedCount: number;
  unlistedCount: number;
};

export type WalletResolution = {
  query: string;
  walletAddress: string;
  knsName: string | null;
};

const KASPA_ADDRESS_PATTERN = /^kaspa(?:test)?:[a-z0-9]{20,}$/i;
const LEGACY_LISTING_PAGE_LIMIT = 50;
const LEGACY_LISTING_CACHE_MS = 30 * 60 * 1000;
const LEGACY_ESCROW_SCAN_TICKERS = ["KASRANKS"];
const legacyListingCache = new Map<string, { checkedAt: number; orders: LegacyListedOrder[] }>();
const legacyListingInflight = new Map<string, Promise<LegacyListedOrder[]>>();

export function looksLikeWalletQuery(query: string) {
  const trimmed = query.trim();
  return KASPA_ADDRESS_PATTERN.test(trimmed) || /^[a-z0-9][a-z0-9-]{0,62}\.kas$/i.test(trimmed);
}

export async function resolveWalletQuery(query: string): Promise<WalletResolution | null> {
  const trimmed = query.trim();
  if (KASPA_ADDRESS_PATTERN.test(trimmed)) {
    return { query: trimmed, walletAddress: trimmed, knsName: null };
  }

  if (!/^[a-z0-9][a-z0-9-]{0,62}\.kas$/i.test(trimmed)) {
    return null;
  }

  const name = trimmed.toLowerCase().replace(/\.kas$/, "");
  const response = await fetch(`https://api.knsdomains.org/mainnet/api/v1/${encodeURIComponent(name)}.kas/owner`, {
    cache: 'no-store'
  });
  if (!response.ok) {
    return null;
  }

  const data = (await response.json()) as KnsOwnerResponse;
  const owner = data.data?.owner;
  if (!owner || !KASPA_ADDRESS_PATTERN.test(owner)) {
    return null;
  }

  return { query: trimmed, walletAddress: owner, knsName: `${name}.kas` };
}

export async function fetchWalletCollectionSummaries(walletAddress: string): Promise<WalletCollectionSummary[]> {
  const holdings = await privateWallet(walletAddress);
  const grouped = new Map<string, WalletLookupSummary>();
  for (const nft of holdings) {
    const item = grouped.get(nft.tick) ?? { ticker: nft.tick, tokenIds: [], listedTokenIds: [], unlistedTokenIds: [] };
    item.tokenIds!.push(nft.tokenId);
    (nft.status?.state === "listed" ? item.listedTokenIds! : item.unlistedTokenIds!).push(nft.tokenId);
    grouped.set(nft.tick, item);
  }
  const data = [...grouped.values()];
  const summariesByTicker = new Map<string, WalletCollectionSummary & { tokenIds: Set<string> }>();

  for (const item of data) {
    const ticker = item.ticker ? normalizeTicker(item.ticker) : "";
    if (!ticker || (await isCollectionBlacklisted(ticker))) {
      continue;
    }

    const collection = getCollectionInfo(ticker);
    if (!collection) {
      continue;
    }

    const tokenIds = (item.tokenIds || []).map(String);
    const previewTokenId = tokenIds[0] ?? collection.previewTokenId ?? null;
    summariesByTicker.set(collection.ticker, {
      collectionId: collection.collectionId,
      ticker: collection.ticker,
      displayName: collection.displayName,
      count: tokenIds.length,
      tokenIds: new Set(tokenIds),
      previewTokenId,
      imageUrl: previewTokenId ? getKrc721ImageUrl(collection.collectionId, previewTokenId) : null,
      listedCount: item.listedTokenIds?.length ?? 0,
      unlistedCount: item.unlistedTokenIds?.length ?? 0
    });
  }

  return Array.from(summariesByTicker.values())
    .map(({ tokenIds: _tokenIds, ...summary }) => summary)
    .sort((left, right) => right.count - left.count || left.ticker.localeCompare(right.ticker));
}

export async function fetchWalletCollectionTokenPage({
  walletAddress,
  collectionId,
  selectedTraits,
  limit = 48,
  offset = 0
}: {
  walletAddress: string;
  collectionId: string;
  selectedTraits?: CollectionTraitFilters;
  limit?: number;
  offset?: number;
}): Promise<CollectionTokenPage & { catalog: CollectionTraitCatalog; hasMore: boolean }> {
  const collection = getCollectionInfo(collectionId);
  if (!collection || (await isCollectionBlacklisted(collection.ticker))) {
    return { tokens: [], totalCount: 0, limit, offset, catalog: [], hasMore: false };
  }

  const [holdingTokens, legacyListings] = await Promise.all([
    fetchWalletCollectionTokens(walletAddress, collection.ticker),
    fetchLegacyEscrowListingsForWalletAndTicker(walletAddress, collection.ticker)
  ]);
  const [snapshot, ranks] = await Promise.all([privateCollectionSnapshot(collection.ticker), storedCollectionRanks(collection.collectionId)]);
  const catalogById = new Map(snapshot.items.map((item) => [String(item.tokenId), item]));
  const sourceTokens = mergeWalletAndLegacyTokens(holdingTokens, legacyListings).map((token) => {
    const cached = catalogById.get(String(token.tokenId));
    return { ...token, attributes: cached?.attributes, traits: cached?.traits,
      rarityRank: ranks.get(String(token.tokenId)) ?? undefined };
  });
  const filteredTokens = filterWalletTokens(sourceTokens, selectedTraits).sort((left, right) => Number(left.tokenId ?? 0) - Number(right.tokenId ?? 0));
  const pagedTokens = filteredTokens.slice(offset, offset + limit).map((token) => {
    const tokenId = String(token.tokenId);
    return {
      tokenId,
      ticker: collection.ticker,
      rarityRank: token.rarityRank ?? null,
      imageUrl: getKrc721ImageUrl(collection.collectionId, tokenId)
    };
  });

  return {
    tokens: pagedTokens,
    totalCount: filteredTokens.length,
    limit,
    offset,
    catalog: buildWalletTraitCatalog(sourceTokens),
    hasMore: offset + limit < filteredTokens.length
  };
}

async function fetchWalletCollectionTokens(walletAddress: string, ticker: string) {
  const collection = getCollectionInfo(ticker);
  const [holdings, ranks] = await Promise.all([privateWallet(walletAddress, ticker), storedCollectionRanks(collection!.collectionId)]);
  return holdings.map((nft) => ({ ticker: nft.tick, tokenId: nft.tokenId,
    attributes: nft.metadata?.attributes, rarityRank: ranks.get(nft.tokenId) ?? undefined }));
}

async function fetchLegacyEscrowListingsForWallet(walletAddress: string, tickers: string[]) {
  const entries = await Promise.all(
    tickers.map(async (ticker) => [ticker, await fetchLegacyEscrowListingsForWalletAndTicker(walletAddress, ticker)] as const)
  );

  return new Map(entries.filter(([, listings]) => listings.length > 0));
}

async function fetchLegacyEscrowListingsForWalletAndTicker(walletAddress: string, ticker: string) {
  const normalizedWallet = walletAddress.toLowerCase();
  const orders = await fetchLegacyListingsForTicker(ticker);
  return orders.filter((order) => order.sellerWalletAddress?.toLowerCase() === normalizedWallet);
}

async function fetchLegacyListingsForTicker(ticker: string) {
  const cached = legacyListingCache.get(ticker);
  if (cached && Date.now() - cached.checkedAt < LEGACY_LISTING_CACHE_MS) return cached.orders;
  const existing = legacyListingInflight.get(ticker);
  if (existing) return existing;

  const request = loadLegacyListingsForTicker(ticker)
    .then((orders) => {
      legacyListingCache.set(ticker, { checkedAt: Date.now(), orders });
      return orders;
    })
    .catch((error) => {
      if (cached) return cached.orders;
      throw error;
    })
    .finally(() => legacyListingInflight.delete(ticker));
  legacyListingInflight.set(ticker, request);
  return request;
}

async function loadLegacyListingsForTicker(ticker: string) {
  const listings: LegacyListedOrder[] = [];
  const seenPages = new Set<string>();
  let offset = 0;

  for (;;) {
    const response = await fetch(`https://api.kaspa.com/krc721-orders/listed-orders/${encodeURIComponent(ticker)}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        pagination: { limit: LEGACY_LISTING_PAGE_LIMIT, offset },
        sort: { field: "createdAt", direction: "desc" }
      }),
      cache: 'no-store'
    });

    if (!response.ok) {
      break;
    }

    const data = (await response.json()) as LegacyListedOrdersResponse;
    const orders = data.orders ?? [];
    const fingerprint = JSON.stringify(orders.map((order) => [order.orderId ?? order.id, order.tokenId]));
    if (orders.length && seenPages.has(fingerprint)) throw new Error("Marketplace escrow pagination did not advance.");
    seenPages.add(fingerprint);
    listings.push(...orders);

    if (orders.length < LEGACY_LISTING_PAGE_LIMIT || offset + LEGACY_LISTING_PAGE_LIMIT >= (data.totalCount ?? 0)) {
      break;
    }

    offset += LEGACY_LISTING_PAGE_LIMIT;
  }

  return listings;
}

function mergeWalletAndLegacyTokens(tokens: WalletLookupToken[], legacyListings: LegacyListedOrder[]) {
  const merged = new Map<string, WalletLookupToken>();
  for (const token of tokens) {
    if (token.tokenId !== undefined) {
      merged.set(String(token.tokenId), token);
    }
  }

  for (const listing of legacyListings) {
    if (listing.tokenId === undefined) {
      continue;
    }

    const tokenId = String(listing.tokenId);
    if (!merged.has(tokenId)) {
      merged.set(tokenId, {
        ticker: listing.ticker,
        tokenId,
        rarityRank: listing.rarityRank
      });
    }
  }

  return Array.from(merged.values());
}

function filterWalletTokens(tokens: WalletLookupToken[], selectedTraits: CollectionTraitFilters = {}) {
  const activeFilters = Object.entries(selectedTraits).filter(([, values]) => values.length > 0);
  if (activeFilters.length === 0) {
    return tokens;
  }

  return tokens.filter((token) =>
    activeFilters.every(([traitType, values]) => values.includes(String(readTraitValue(token, traitType) ?? "")))
  );
}

function buildWalletTraitCatalog(tokens: WalletLookupToken[]): CollectionTraitCatalog {
  const traitsByType = new Map<string, Map<string, number>>();

  for (const token of tokens) {
    const entries = token.attributes?.length
      ? token.attributes.map((attribute) => [attribute.trait_type, attribute.value] as const)
      : Object.entries(token.traits || {});

    for (const [traitType, rawValue] of entries) {
      if (!traitType || rawValue === null || rawValue === undefined) {
        continue;
      }

      const value = typeof rawValue === "object" && "value" in rawValue ? rawValue.value : rawValue;
      if (value === null || value === undefined || value === "") {
        continue;
      }

      const values = traitsByType.get(traitType) || new Map<string, number>();
      values.set(String(value), (values.get(String(value)) ?? 0) + 1);
      traitsByType.set(traitType, values);
    }
  }

  return Array.from(traitsByType.entries())
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([traitType, values]) => ({
      traitType,
      values: Array.from(values.entries())
        .map(([value, count]) => ({ value, count, rarity: null }))
        .sort((left, right) => right.count - left.count || left.value.localeCompare(right.value))
    }));
}

function readTraitValue(token: WalletLookupToken, traitType: string) {
  const attribute = token.attributes?.find((item) => item.trait_type === traitType);
  if (attribute) {
    return attribute.value;
  }

  const rawValue = token.traits?.[traitType];
  return typeof rawValue === "object" && rawValue !== null && "value" in rawValue ? rawValue.value : rawValue;
}
