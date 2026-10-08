import rankingData from "@/data/hash-rankings.json";

export const HASH_COLLECTION_ID = "hash";
export const HASH_TICKER = "HASH";
export const HASH_SUPPLY = 2870;

type HashRankingRecord = {
  tokenId: number;
  newRank: number;
};

const records = (rankingData as { swaps?: HashRankingRecord[] }).swaps ?? [];
const rankByTokenId = new Map(records.map(({ tokenId, newRank }) => [String(tokenId), newRank]));
const tokenIdsByRank = [...records]
  .sort((left, right) => left.newRank - right.newRank)
  .map(({ tokenId }) => String(tokenId));

function validateHashRankings() {
  const tokenIds = new Set(records.map(({ tokenId }) => tokenId));
  const ranks = new Set(records.map(({ newRank }) => newRank));
  const complete = Array.from({ length: HASH_SUPPLY }, (_item, index) => index + 1);

  if (
    records.length !== HASH_SUPPLY ||
    tokenIds.size !== HASH_SUPPLY ||
    ranks.size !== HASH_SUPPLY ||
    complete.some((value) => !tokenIds.has(value) || !ranks.has(value))
  ) {
    throw new Error("HASH rankings must contain every unique token ID and rank from 1 to 2870.");
  }
}

validateHashRankings();

export function isHashCollection(collectionIdOrTicker: string) {
  return [HASH_COLLECTION_ID, HASH_TICKER.toLowerCase()].includes(collectionIdOrTicker.trim().toLowerCase());
}

export function getHashImageUrl(tokenId: string | number) {
  const normalized = String(tokenId);
  return rankByTokenId.has(normalized) ? `/assets/collections/hash/${normalized}.png` : null;
}

export function getHashRarityRank(tokenId: string | number) {
  return rankByTokenId.get(String(tokenId)) ?? null;
}

export function getHashTokenPage(limit: number, offset: number, sortField: "tokenId" | "rarityRank") {
  const orderedTokenIds =
    sortField === "rarityRank"
      ? tokenIdsByRank
      : Array.from({ length: HASH_SUPPLY }, (_item, index) => String(index + 1));
  const tokenIds = orderedTokenIds.slice(offset, offset + limit);

  return {
    tokens: tokenIds.map((tokenId) => ({
      tokenId,
      ticker: HASH_TICKER,
      rarityRank: getHashRarityRank(tokenId),
      imageUrl: getHashImageUrl(tokenId)
    })),
    totalCount: HASH_SUPPLY,
    limit,
    offset
  };
}

export function getHashRarityRanks(tokenIds: string[]) {
  return new Map(tokenIds.map((tokenId) => [tokenId, getHashRarityRank(tokenId)]));
}
