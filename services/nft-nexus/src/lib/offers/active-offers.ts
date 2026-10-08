import { OfferStatus, type Prisma } from "@prisma/client";
import { getCollectionInfo, getKrc721ImageUrl } from "@/lib/market-provider/collections";
import { fetchTokenRarityRanks } from "@/lib/market-provider/kaspacom-tokens";
import { prisma } from "@/lib/db/prisma";
import { sompiToKas } from "@/lib/offers/money";

export const ACTIVE_OFFERS_BATCH_SIZE = 8;
const RARITY_LOOKUP_TIMEOUT_MS = 5000;

const ACTIVE_OFFER_STATUSES = [
  OfferStatus.OPEN,
  OfferStatus.COUNTERED,
  OfferStatus.AGREED_WAITING_RELIST,
  OfferStatus.RELIST_DETECTED
] as const;

export type ActiveOfferCard = {
  id: string;
  collectionId: string;
  tokenId: string;
  ticker: string;
  displayName: string;
  imageUrl: string | null;
  rarityRank: number | null;
  status: OfferStatus;
  statusLabel: string;
  amountKas: string | null;
  isRelistDetected: boolean;
  detailHref: string;
};

export type ActiveOffersBatch = {
  offers: ActiveOfferCard[];
  totalCount: number;
  offset: number;
  limit: number;
  nextOffset: number | null;
};

export function offerStatusLabel(status: OfferStatus) {
  switch (status) {
    case OfferStatus.OPEN:
      return "Open offer";
    case OfferStatus.COUNTERED:
      return "Counter offer";
    case OfferStatus.AGREED_WAITING_RELIST:
      return "Agreed";
    case OfferStatus.RELIST_DETECTED:
      return "Relist detected";
    default:
      return status.replaceAll("_", " ");
  }
}

function getActiveOfferWhere(now = new Date()): Prisma.OfferThreadWhereInput {
  return {
    status: { in: [...ACTIVE_OFFER_STATUSES] },
    OR: [
      { status: { in: [OfferStatus.OPEN, OfferStatus.COUNTERED] }, expiresAt: { gt: now } },
      { status: { in: [OfferStatus.AGREED_WAITING_RELIST, OfferStatus.RELIST_DETECTED] } }
    ]
  };
}

async function getRarityRanksByCollection(
  offers: Array<{ nftCache: { collectionId: string; tokenId: string } }>
) {
  const tokenIdsByCollection = new Map<string, string[]>();
  for (const offer of offers) {
    const tokenIds = tokenIdsByCollection.get(offer.nftCache.collectionId) || [];
    tokenIds.push(offer.nftCache.tokenId);
    tokenIdsByCollection.set(offer.nftCache.collectionId, tokenIds);
  }

  const rankMaps = await Promise.all([...tokenIdsByCollection].map(async ([collectionId, tokenIds]) => {
    try {
      return [collectionId, await fetchTokenRarityRanks(collectionId, tokenIds, RARITY_LOOKUP_TIMEOUT_MS)] as const;
    } catch {
      return [collectionId, new Map<string, number | null>()] as const;
    }
  }));
  const ranksByCollection = new Map(rankMaps);

  return ranksByCollection;
}

export async function getActiveOffersBatch(offset = 0, limit = ACTIVE_OFFERS_BATCH_SIZE): Promise<ActiveOffersBatch> {
  const boundedOffset = Math.max(Math.floor(offset), 0);
  const boundedLimit = Math.min(Math.max(Math.floor(limit), 1), 24);
  const activeOfferWhere = getActiveOfferWhere();

  const [offers, totalCount] = await Promise.all([
    prisma.offerThread.findMany({
      where: activeOfferWhere,
      include: { nftCache: true },
      orderBy: [{ updatedAt: "desc" }, { createdAt: "desc" }],
      skip: boundedOffset,
      take: boundedLimit
    }),
    prisma.offerThread.count({ where: activeOfferWhere })
  ]);

  const rarityRanks = await getRarityRanksByCollection(offers);
  const cards = offers.map((offer) => {
    const collection = getCollectionInfo(offer.nftCache.collectionId);
    const ticker = collection?.ticker || offer.nftCache.collectionId.toUpperCase();
    const displayName = collection?.displayName || ticker;
    const tokenId = offer.nftCache.tokenId;
    const imageUrl = getKrc721ImageUrl(offer.nftCache.collectionId, tokenId);

    return {
      id: offer.id,
      collectionId: offer.nftCache.collectionId,
      tokenId,
      ticker,
      displayName,
      imageUrl,
      rarityRank: rarityRanks.get(offer.nftCache.collectionId)?.get(tokenId) ?? null,
      status: offer.status,
      statusLabel: offerStatusLabel(offer.status),
      amountKas: sompiToKas(offer.currentAmountSompi),
      isRelistDetected: offer.status === OfferStatus.RELIST_DETECTED,
      detailHref: `/nft/${offer.nftCache.collectionId}/${tokenId}`
    };
  });

  const shownCount = boundedOffset + cards.length;

  return {
    offers: cards,
    totalCount,
    offset: boundedOffset,
    limit: boundedLimit,
    nextOffset: shownCount < totalCount ? shownCount : null
  };
}
