import { prisma } from "@/lib/db/prisma";

const cached = new Map<string, { until: number; ranks: Map<string, number | null> }>();
const pending = new Map<string, Promise<Map<string, number | null>>>();

export async function storedCollectionRanks(collectionId: string) {
  const hit = cached.get(collectionId);
  if (hit && hit.until > Date.now()) return hit.ranks;
  const inflight = pending.get(collectionId);
  if (inflight) return inflight;
  const request = prisma.nftRarityCache.findMany({ where: { collectionId }, select: { tokenId: true, rarityRank: true } })
    .then((rows) => {
      const ranks = new Map(rows.map((row) => [row.tokenId, row.rarityRank]));
      cached.set(collectionId, { until: Date.now() + 30_000, ranks });
      return ranks;
    }).finally(() => pending.delete(collectionId));
  pending.set(collectionId, request);
  return request;
}
