import { storedCollectionRanks } from "./stored-rarity";
import { privateCollectionSnapshot, privateFetch } from "./private-indexer";
import { getCollectionInfo, getKrc721ImageUrl } from "./collections";
import { getHashRarityRank, getHashRarityRanks, isHashCollection } from "./hash-collection";
import { getRarityLabel } from "./rarity-label";

export type KaspaComToken = {
  tokenId: string;
  ticker: string;
  rarityRank: number | null;
  imageUrl: string | null;
};

export type CollectionTokenSort = "tokenId" | "rarityRank";
export type CollectionTraitFilters = Record<string, string[]>;

export class CollectionLookupUnavailableError extends Error {
  constructor() {
    super("Collection providers are temporarily unavailable.");
    this.name = "CollectionLookupUnavailableError";
  }
}

type KaspaComTokenTrait = {
  value?: string | number | boolean | null;
  rarity?: number;
};

type KaspaComTokenItem = {
  ticker?: string;
  tokenId?: string | number;
  traits?: Record<string, KaspaComTokenTrait | string | number | boolean | null>;
  rarityRank?: number;
};

type KaspaComTokenResponse = {
  items?: KaspaComTokenItem[];
  totalCount?: number;
  metadataReady?: number;
  metadataTotal?: number;
};

type KaspaComSellOrdersResponse = {
  orders?: Array<{
    id?: string;
    orderId?: string;
    ticker?: string;
    tokenId?: string | number;
    createdAt?: string;
    status?: string;
  }>;
  totalCount?: number;
};

type Krc721IndexerCollectionResponse = {
  message?: string;
  result?: {
    tick?: string;
    max?: string | number;
    minted?: string | number;
  } | null;
};

type CollectionTokenResponseResult = {
  collection: NonNullable<ReturnType<typeof getCollectionInfo>>;
  data: KaspaComTokenResponse;
};

export type CollectionTokenPage = {
  tokens: KaspaComToken[];
  totalCount: number;
  limit: number;
  offset: number;
  metadataReady?: number;
  metadataTotal?: number;
};

function tokenDisplayPriority(collectionId: string, token: KaspaComToken) {
  if (collectionId === "kasgoths" && token.tokenId === "21") {
    return 0;
  }

  return getRarityLabel(collectionId, token.tokenId, token.rarityRank) === "Legendary" ? 1 : 2;
}

export function prioritizeCollectionTokens(collectionId: string, tokens: KaspaComToken[]) {
  return tokens
    .map((token, index) => ({ token, index }))
    .sort(
      (left, right) =>
        tokenDisplayPriority(collectionId, left.token) - tokenDisplayPriority(collectionId, right.token) ||
        left.index - right.index
    )
    .map(({ token }) => token);
}

export type CollectionTraitCatalog = Array<{
  traitType: string;
  values: Array<{
    value: string;
    count: number;
    rarity: number | null;
  }>;
}>;

function normalizeTraitFilters(traits: CollectionTraitFilters = {}): CollectionTraitFilters {
  return Object.fromEntries(
    Object.entries(traits)
      .map(([traitType, values]) => [
        traitType,
        Array.from(new Set(values.map((value) => value.trim()).filter(Boolean)))
      ])
      .filter(([, values]) => values.length > 0)
  );
}

function getTraitValue(trait: KaspaComTokenTrait | string | number | boolean | null | undefined) {
  if (trait === null || trait === undefined) {
    return null;
  }

  if (typeof trait === "object") {
    return trait.value === null || trait.value === undefined ? null : String(trait.value);
  }

  return String(trait);
}

function getTraitRarity(trait: KaspaComTokenTrait | string | number | boolean | null | undefined) {
  return typeof trait === "object" && trait !== null && typeof trait.rarity === "number" ? trait.rarity : null;
}

function compareTokenIds(left: KaspaComTokenItem, right: KaspaComTokenItem) {
  return String(left.tokenId ?? "").localeCompare(String(right.tokenId ?? ""), undefined, {
    numeric: true,
    sensitivity: "base"
  });
}

function compareRarityRanks(left: KaspaComTokenItem, right: KaspaComTokenItem) {
  const leftRank = typeof left.rarityRank === "number" ? left.rarityRank : Number.POSITIVE_INFINITY;
  const rightRank = typeof right.rarityRank === "number" ? right.rarityRank : Number.POSITIVE_INFINITY;
  return leftRank - rightRank || compareTokenIds(left, right);
}

function itemMatchesTraits(item: KaspaComTokenItem, traits: CollectionTraitFilters) {
  return Object.entries(traits).every(([traitType, acceptedValues]) => {
    const value = getTraitValue(item.traits?.[traitType]);
    return value !== null && acceptedValues.includes(value);
  });
}

async function fetchCollectionTokenResponse(
  collectionId: string,
  limit: number,
  offset: number,
  sortField: CollectionTokenSort,
  traits: CollectionTraitFilters = {}
): Promise<CollectionTokenResponseResult | null> {
  const collection = getCollectionInfo(collectionId);
  if (!collection) {
    return null;
  }
  const normalizedTraits = normalizeTraitFilters(traits);
  const [snapshot, ranks] = await Promise.all([privateCollectionSnapshot(collection.ticker), storedCollectionRanks(collection.collectionId)]);
  const items: KaspaComTokenItem[] = snapshot.items.map((item) => ({
    ...item,
    rarityRank: isHashCollection(collectionId) ? getHashRarityRank(String(item.tokenId)) ?? undefined : ranks.get(String(item.tokenId)) ?? undefined,
    traits: {
      ...item.traits,
      ...Object.fromEntries((item.attributes ?? []).map((attr) => [attr.trait_type, { value: attr.value }]))
    }
  }));
  const matching = items.filter((item) => itemMatchesTraits(item, normalizedTraits))
    .sort(sortField === "rarityRank" ? compareRarityRanks : compareTokenIds);
  return { collection, data: { items: matching.slice(offset, offset + limit), totalCount: matching.length, metadataReady: snapshot.metadataReady, metadataTotal: snapshot.totalCount } };
}

async function fetchCollectionSnapshot(collectionId: string): Promise<CollectionTokenResponseResult | null> {
  if (!getCollectionInfo(collectionId)) return null;
  return fetchCollectionTokenResponse(collectionId, Number.MAX_SAFE_INTEGER, 0, "tokenId");
}

export async function fetchCollectionTokenPage(
  collectionId: string,
  limit = 24,
  offset = 0,
  sortField: CollectionTokenSort = "tokenId",
  traits: CollectionTraitFilters = {}
): Promise<CollectionTokenPage> {
  const result = await fetchCollectionTokenResponse(collectionId, limit, offset, sortField, traits);
  if (!result) {
    return { tokens: [], totalCount: 0, limit, offset };
  }

  const { collection, data } = result;
  const tokens = (data.items || [])
    .filter((item) => item.tokenId !== undefined)
    .map((item) => {
      const tokenId = String(item.tokenId);
      return {
        tokenId,
        ticker: item.ticker || collection.ticker,
        rarityRank: isHashCollection(collection.collectionId) ? getHashRarityRank(tokenId) : item.rarityRank ?? null,
        imageUrl: getKrc721ImageUrl(collection.collectionId, tokenId)
      };
    });

  return {
    tokens: prioritizeCollectionTokens(collection.collectionId, tokens),
    totalCount: data.totalCount ?? tokens.length,
    metadataReady: data.metadataReady,
    metadataTotal: data.metadataTotal,
    limit,
    offset
  };
}

export async function fetchCollectionTraitCatalog(collectionId: string): Promise<CollectionTraitCatalog> {
  const snapshot = await fetchCollectionSnapshot(collectionId);
  if (!snapshot) {
    return [];
  }
  const traitsByType = new Map<string, Map<string, { count: number; rarityTotal: number; rarityCount: number }>>();

  for (const item of snapshot.data.items || []) {
    for (const [traitType, trait] of Object.entries(item.traits || {})) {
      const value = getTraitValue(trait);
      if (!value) {
        continue;
      }

      const values = traitsByType.get(traitType) || new Map<string, { count: number; rarityTotal: number; rarityCount: number }>();
      const current = values.get(value) || { count: 0, rarityTotal: 0, rarityCount: 0 };
      const rarity = getTraitRarity(trait);
      values.set(value, {
        count: current.count + 1,
        rarityTotal: current.rarityTotal + (rarity ?? 0),
        rarityCount: current.rarityCount + (rarity === null ? 0 : 1)
      });
      traitsByType.set(traitType, values);
    }
  }

  return Array.from(traitsByType.entries())
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([traitType, values]) => ({
      traitType,
      values: Array.from(values.entries())
        .map(([value, stats]) => ({
          value,
          count: stats.count,
          rarity: stats.rarityCount > 0 ? stats.rarityTotal / stats.rarityCount : null
        }))
        .sort((a, b) => b.count - a.count || a.value.localeCompare(b.value))
    }));
}

export async function fetchCollectionTokens(
  collectionId: string,
  limit = 24,
  offset = 0,
  sortField: CollectionTokenSort = "tokenId"
): Promise<KaspaComToken[]> {
  const page = await fetchCollectionTokenPage(collectionId, limit, offset, sortField);
  return page.tokens;
}

export async function fetchCollectionListedTokenPage(collectionId: string, limit = 24, offset = 0): Promise<CollectionTokenPage> {
  const collection = getCollectionInfo(collectionId);
  if (!collection) {
    return { tokens: [], totalCount: 0, limit, offset };
  }

  const [psktPage, legacyPage] = await Promise.all([
    fetchCollectionListedOrdersPage(collection.ticker, limit, offset, "pskt"),
    fetchCollectionListedOrdersPage(collection.ticker, limit, offset, "legacy")
  ]);
  const seenTokenIds = new Set<string>();
  const combinedOrders = [...psktPage.orders, ...legacyPage.orders]
    .filter((order) => order.tokenId !== undefined)
    .sort((left, right) => Date.parse(String(right.createdAt ?? "")) - Date.parse(String(left.createdAt ?? "")))
    .filter((order) => {
      const tokenId = String(order.tokenId);
      if (seenTokenIds.has(tokenId)) {
        return false;
      }
      seenTokenIds.add(tokenId);
      return true;
    });
  const tokens = combinedOrders.map((order) => {
    const tokenId = String(order.tokenId);
    return {
      tokenId,
      ticker: collection.ticker,
      rarityRank: isHashCollection(collectionId) ? getHashRarityRank(tokenId) : null,
      imageUrl: getKrc721ImageUrl(collection.collectionId, tokenId)
    };
  });

  return {
    tokens,
    totalCount: psktPage.totalCount + legacyPage.totalCount,
    limit,
    offset
  };
}

async function fetchCollectionListedOrdersPage(ticker: string, limit: number, offset: number, source: "pskt" | "legacy") {
  const endpoint =
    source === "pskt"
      ? `https://api.kaspa.com/krc721-orders-v2/sell-orders?${new URLSearchParams({ ticker })}`
      : `https://api.kaspa.com/krc721-orders/listed-orders/${encodeURIComponent(ticker)}`;
  try {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        pagination: { limit, offset },
        sort: { field: "createdAt", direction: "desc" }
      }),
      cache: "no-store"
    });

    if (!response.ok) {
      return { orders: [], totalCount: 0, available: false };
    }

    const data = (await response.json()) as KaspaComSellOrdersResponse;
    return { orders: data.orders ?? [], totalCount: data.totalCount ?? data.orders?.length ?? 0, available: true };
  } catch {
    return { orders: [], totalCount: 0, available: false };
  }
}

export async function fetchIndexerCollectionTokenPage(collectionId: string, limit = 24, offset = 0): Promise<CollectionTokenPage> {
  return fetchCollectionTokenPage(collectionId, limit, offset);
}

export async function fetchTokenRarityRanks(collectionId: string, tokenIds: string[], timeoutMs?: number) {
  const collection = getCollectionInfo(collectionId);
  const uniqueTokenIds = new Set(tokenIds.filter(Boolean));
  if (!collection || !uniqueTokenIds.size) return new Map<string, number | null>();
  if (isHashCollection(collectionId)) return getHashRarityRanks([...uniqueTokenIds]);
  const ranks = await storedCollectionRanks(collection.collectionId);
  return new Map([...uniqueTokenIds].map((tokenId) => [tokenId, ranks.get(tokenId) ?? null]));
}

export async function resolveExistingCollection(collectionIdOrTicker: string) {
  const collection = getCollectionInfo(collectionIdOrTicker);
  if (!collection) return null;
  try {
    const response = await privateFetch(`/api/v1/krc721/mainnet/nfts/${encodeURIComponent(collection.ticker)}`);
    if (response.status === 404) return null;
    if (!response.ok) throw new CollectionLookupUnavailableError();
    const data = await response.json() as Krc721IndexerCollectionResponse;
    if (data.message !== "success") throw new CollectionLookupUnavailableError();
    return data.result ? collection : null;
  } catch {
    throw new CollectionLookupUnavailableError();
  }
}
