import { prisma } from "@/lib/db/prisma";
import {
  fetchCollectionTokenPage,
  fetchTokenRarityRanks,
  type CollectionTokenPage,
  type CollectionTokenSort
} from "@/lib/market-provider/kaspacom-tokens";

const DETAIL_RARITY_LOOKUP_TIMEOUT_MS = 2500;
const BULK_RARITY_PAGE_SIZE = 500;

export async function getCachedRarityRank(collectionId: string, tokenId: string) {
  const cached = await prisma.nftRarityCache.findUnique({
    where: { collectionId_tokenId: { collectionId, tokenId } }
  });

  return cached?.rarityRank ?? null;
}

export async function hydrateCollectionTokenPageFromCache(
  collectionId: string,
  page: CollectionTokenPage,
  sort: CollectionTokenSort
): Promise<CollectionTokenPage> {
  return page;
}

export async function getOrFetchRarityRank(collectionId: string, tokenId: string) {
  try {
    const ranks = await fetchTokenRarityRanks(collectionId, [tokenId], DETAIL_RARITY_LOOKUP_TIMEOUT_MS);
    return ranks.get(tokenId) ?? null;
  } catch {
    return null;
  }
}

export async function warmCollectionRarityRanks(collectionId: string) {
  let offset = 0;
  let totalCount = 0;
  let savedCount = 0;

  for (;;) {
    const page = await fetchCollectionTokenPage(collectionId, BULK_RARITY_PAGE_SIZE, offset, "tokenId");
    totalCount = page.totalCount;

    await Promise.all(
      page.tokens.map((token) =>
        prisma.nftRarityCache.upsert({
          where: { collectionId_tokenId: { collectionId, tokenId: token.tokenId } },
          update: {},
          create: { collectionId, tokenId: token.tokenId, rarityRank: token.rarityRank }
        })
      )
    );

    savedCount += page.tokens.length;
    offset += page.tokens.length;

    if (page.tokens.length === 0 || offset >= totalCount) {
      break;
    }
  }

  return { collectionId, totalCount, savedCount };
}
