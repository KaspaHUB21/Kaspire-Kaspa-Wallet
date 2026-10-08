import { prisma } from "@/lib/db/prisma";
import { getNftNexusUrl } from "@/lib/nft-links";

let running = false;

export async function processExpiredOffers() {
  if (running) return { expired: 0 };
  running = true;

  try {
    const expired = await prisma.offerThread.findMany({
      where: {
        status: { in: ["OPEN", "COUNTERED"] },
        expiresAt: { lte: new Date() }
      },
      select: { id: true, status: true }
    });

    for (const offer of expired) {
      await prisma.$transaction(async (tx) => {
        const current = await tx.offerThread.findUniqueOrThrow({
          where: { id: offer.id },
          include: { nftCache: true, buyerWalletAccount: true }
        });
        if (!["OPEN", "COUNTERED"].includes(current.status)) {
          return;
        }
        await tx.offerThread.update({ where: { id: offer.id }, data: { status: "EXPIRED" } });
        await tx.offerRevision.create({
          data: { offerThreadId: offer.id, actorWalletAddress: "system", type: "EXPIRED" }
        });
        await tx.auditEvent.create({
          data: { entityType: "OfferThread", entityId: offer.id, action: "EXPIRED" }
        });
        await tx.notification.upsert({
          where: { dedupeKey: `offer-expired:${offer.id}:buyer` },
          update: {},
          create: {
            walletAccountId: current.buyerWalletAccountId,
            type: "EXPIRED",
            channel: "IN_APP",
            dedupeKey: `offer-expired:${offer.id}:buyer`,
            payloadJson: {
              title: "Offer expired",
              message: `${current.nftCache.name} offer expired.`,
              url: getNftNexusUrl(current.nftCache.collectionId, current.nftCache.tokenId),
              offerId: current.id,
              collectionId: current.nftCache.collectionId,
              tokenId: current.nftCache.tokenId
            }
          }
        });
      });
    }

    return { expired: expired.length };
  } finally {
    running = false;
  }
}

export function startExpiryWorker() {
  void processExpiredOffers().catch((error) => console.error("Expiry worker failed", error));
  return setInterval(() => {
    void processExpiredOffers().catch((error) => console.error("Expiry worker failed", error));
  }, 60_000);
}
