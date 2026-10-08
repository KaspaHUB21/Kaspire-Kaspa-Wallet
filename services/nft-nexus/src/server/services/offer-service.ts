import type { OfferRevisionType, OfferStatus, Prisma } from "@prisma/client";
import { prisma } from "@/lib/db/prisma";
import { getNftNexusUrl } from "@/lib/nft-links";
import { kasToSompi } from "@/lib/offers/money";
import { assertCanTransition } from "@/lib/offers/status-machine";
import { refreshNftSnapshot } from "./nft-service";

async function audit(tx: Prisma.TransactionClient, input: {
  actorWalletAddress?: string;
  entityType: string;
  entityId: string;
  action: string;
  metadataJson?: Prisma.InputJsonValue;
}) {
  await tx.auditEvent.create({ data: input });
}

async function transitionOffer(tx: Prisma.TransactionClient, input: {
  offerId: string;
  actorWalletAddress: string;
  nextStatus: OfferStatus;
  revisionType: OfferRevisionType;
  amountSompi?: bigint;
}) {
  const offer = await tx.offerThread.findUniqueOrThrow({ where: { id: input.offerId } });
  assertCanTransition(offer.status, input.nextStatus);

  const updated = await tx.offerThread.update({
    where: { id: offer.id },
    data: {
      status: input.nextStatus,
      currentAmountSompi: input.amountSompi ?? offer.currentAmountSompi,
      agreedAt: input.nextStatus === "AGREED_WAITING_RELIST" ? new Date() : offer.agreedAt
    }
  });

  await tx.offerRevision.create({
    data: {
      offerThreadId: offer.id,
      actorWalletAddress: input.actorWalletAddress,
      type: input.revisionType,
      amountSompi: input.amountSompi
    }
  });

  await audit(tx, {
    actorWalletAddress: input.actorWalletAddress,
    entityType: "OfferThread",
    entityId: offer.id,
    action: input.revisionType
  });

  return updated;
}

export async function createOffer(input: {
  buyerWalletAddress: string;
  collectionId: string;
  tokenId: string;
  amountKas: string;
  durationDays: number;
}) {
  const snapshot = await refreshNftSnapshot({ collectionId: input.collectionId, tokenId: input.tokenId });
  const amountSompi = kasToSompi(input.amountKas);
  const expiresAt = new Date(Date.now() + input.durationDays * 24 * 60 * 60 * 1000);

  if (snapshot.currentOwnerWallet === input.buyerWalletAddress) {
    throw new Error("You already own this NFT.");
  }

  return prisma.$transaction(async (tx) => {
    const buyer = await tx.walletAccount.upsert({
      where: { walletAddress: input.buyerWalletAddress },
      update: {},
      create: { walletAddress: input.buyerWalletAddress, verifiedAt: new Date() }
    });
    const seller = snapshot.currentOwnerWallet
      ? await tx.walletAccount.upsert({
          where: { walletAddress: snapshot.currentOwnerWallet },
          update: {},
          create: { walletAddress: snapshot.currentOwnerWallet }
        })
      : null;

    const offer = await tx.offerThread.create({
      data: {
        nftCacheId: snapshot.id,
        buyerWalletAccountId: buyer.id,
        sellerWalletAtCreation: snapshot.currentOwnerWallet,
        currentSellerWallet: snapshot.currentOwnerWallet,
        currentAmountSompi: amountSompi,
        expiresAt,
        marketUrlAtCreation: snapshot.marketUrl,
        revisions: {
          create: {
            actorWalletAddress: input.buyerWalletAddress,
            type: "CREATED",
            amountSompi
          }
        }
      },
      include: { nftCache: true, revisions: true }
    });

    await audit(tx, {
      actorWalletAddress: input.buyerWalletAddress,
      entityType: "OfferThread",
      entityId: offer.id,
      action: "CREATED",
      metadataJson: { collectionId: input.collectionId, tokenId: input.tokenId }
    });

    if (seller && seller.walletAddress !== buyer.walletAddress) {
      await tx.notification.upsert({
        where: { dedupeKey: `offer-created:${offer.id}:seller` },
        update: {},
        create: {
          walletAccountId: seller.id,
          type: "OFFER_CREATED",
          channel: "IN_APP",
          dedupeKey: `offer-created:${offer.id}:seller`,
          payloadJson: {
            title: "New private offer",
            message: `${offer.nftCache.name} received an offer for ${input.amountKas} KAS.`,
            url: getNftNexusUrl(input.collectionId, input.tokenId),
            offerId: offer.id,
            collectionId: input.collectionId,
            tokenId: input.tokenId
          }
        }
      });
    }

    return offer;
  });
}

export async function cancelOffer(offerId: string, actorWalletAddress: string) {
  return prisma.$transaction(async (tx) => {
    const offer = await tx.offerThread.findUniqueOrThrow({
      where: { id: offerId },
      include: { buyerWalletAccount: true, nftCache: true }
    });
    if (offer.buyerWalletAccount.walletAddress !== actorWalletAddress) {
      throw new Error("Only the buyer can cancel this offer.");
    }
    const updated = await transitionOffer(tx, {
      offerId,
      actorWalletAddress,
      nextStatus: "CANCELLED_BY_BUYER",
      revisionType: "CANCELLED"
    });

    if (offer.currentSellerWallet) {
      const seller = await tx.walletAccount.upsert({
        where: { walletAddress: offer.currentSellerWallet },
        update: {},
        create: { walletAddress: offer.currentSellerWallet }
      });
      const dedupeKey = `offer-cancelled:${offer.id}:${Date.now()}`;
      await tx.notification.upsert({
        where: { dedupeKey },
        update: {},
        create: {
          walletAccountId: seller.id,
          type: "CANCELLED",
          channel: "IN_APP",
          dedupeKey,
          payloadJson: {
            title: "Offer cancelled",
            message: `${offer.nftCache.name} offer was cancelled by the buyer.`,
            url: getNftNexusUrl(offer.nftCache.collectionId, offer.nftCache.tokenId),
            offerId: offer.id,
            collectionId: offer.nftCache.collectionId,
            tokenId: offer.nftCache.tokenId
          }
        }
      });
    }

    return updated;
  });
}

export async function acceptCounterOffer(offerId: string, actorWalletAddress: string) {
  const offer = await prisma.offerThread.findUniqueOrThrow({
    where: { id: offerId },
    include: { buyerWalletAccount: true, nftCache: true }
  });

  if (offer.buyerWalletAccount.walletAddress !== actorWalletAddress) {
    throw new Error("Only the buyer can accept this counter offer.");
  }

  if (offer.status !== "COUNTERED") {
    throw new Error("Only countered offers can be accepted.");
  }

  const snapshot = await refreshNftSnapshot({
    collectionId: offer.nftCache.collectionId,
    tokenId: offer.nftCache.tokenId
  });

  if (!snapshot.currentOwnerWallet) {
    throw new Error("Owner status is unknown. Counter offer cannot continue safely.");
  }

  const seller = await prisma.walletAccount.upsert({
    where: { walletAddress: snapshot.currentOwnerWallet },
    update: {},
    create: { walletAddress: snapshot.currentOwnerWallet }
  });

  return prisma.$transaction(async (tx) => {
    const updated = await transitionOffer(tx, {
      offerId,
      actorWalletAddress,
      nextStatus: "AGREED_WAITING_RELIST",
      revisionType: "AGREED_TO_RELIST"
    });
    const nftUrl = getNftNexusUrl(offer.nftCache.collectionId, offer.nftCache.tokenId);
    const dedupeKey = `counter-accepted:${offer.id}:${Date.now()}`;

    await tx.offerThread.update({
      where: { id: offer.id },
      data: { currentSellerWallet: snapshot.currentOwnerWallet }
    });

    await tx.notification.upsert({
      where: { dedupeKey },
      update: {},
      create: {
        walletAccountId: seller.id,
        type: "COUNTER_ACCEPTED",
        channel: "IN_APP",
        dedupeKey,
        payloadJson: {
          title: "Counter accepted",
          message: `${offer.nftCache.name} counter offer was accepted. Relist it for the agreed amount to continue.`,
          url: nftUrl,
          offerId: offer.id,
          collectionId: offer.nftCache.collectionId,
          tokenId: offer.nftCache.tokenId
        }
      }
    });

    return updated;
  });
}

export async function sellerTransition(input: {
  offerId: string;
  actorWalletAddress: string;
  nextStatus: OfferStatus;
  revisionType: OfferRevisionType;
  amountKas?: string;
}) {
  const offer = await prisma.offerThread.findUniqueOrThrow({
    where: { id: input.offerId },
    include: { nftCache: true }
  });
  const snapshot = await refreshNftSnapshot({
    collectionId: offer.nftCache.collectionId,
    tokenId: offer.nftCache.tokenId
  });

  if (!snapshot.currentOwnerWallet) {
    throw new Error("Owner status is unknown. Seller action cannot continue safely.");
  }

  if (snapshot.currentOwnerWallet !== input.actorWalletAddress) {
    await prisma.offerThread.update({
      where: { id: offer.id },
      data: { status: "INVALIDATED_OWNER_CHANGED", currentSellerWallet: snapshot.currentOwnerWallet }
    });
    await prisma.notification.upsert({
      where: { dedupeKey: `owner-changed:${offer.id}` },
      update: {},
      create: {
        walletAccountId: offer.buyerWalletAccountId,
        type: "INVALIDATED_OWNER_CHANGED",
        channel: "IN_APP",
        dedupeKey: `owner-changed:${offer.id}`,
        payloadJson: {
          title: "Offer invalidated",
          message: `${offer.nftCache.name} owner changed before the seller action could continue.`,
          url: getNftNexusUrl(offer.nftCache.collectionId, offer.nftCache.tokenId),
          offerId: offer.id,
          collectionId: offer.nftCache.collectionId,
          tokenId: offer.nftCache.tokenId
        }
      }
    });
    throw new Error("Wallet no longer owns this NFT.");
  }

  const amountSompi = input.amountKas ? kasToSompi(input.amountKas) : undefined;
  return prisma.$transaction(async (tx) => {
    const updated = await transitionOffer(tx, {
      offerId: input.offerId,
      actorWalletAddress: input.actorWalletAddress,
      nextStatus: input.nextStatus,
      revisionType: input.revisionType,
      amountSompi
    });

    const title =
      input.revisionType === "COUNTERED"
        ? "Counter offer received"
        : input.revisionType === "DECLINED"
          ? "Offer declined"
          : "Seller agreed";
    const message =
      input.revisionType === "COUNTERED" && input.amountKas
        ? `${offer.nftCache.name} was countered at ${input.amountKas} KAS.`
        : input.revisionType === "DECLINED"
          ? `${offer.nftCache.name} offer was declined.`
          : `${offer.nftCache.name} seller agreed. Watch for the relisted NFT.`;
    const dedupeKey = `offer-${input.revisionType.toLowerCase()}:${offer.id}:${Date.now()}`;

    await tx.notification.upsert({
      where: { dedupeKey },
      update: {},
      create: {
        walletAccountId: offer.buyerWalletAccountId,
        type: input.revisionType,
        channel: "IN_APP",
        dedupeKey,
        payloadJson: {
          title,
          message,
          url: getNftNexusUrl(offer.nftCache.collectionId, offer.nftCache.tokenId),
          offerId: offer.id,
          collectionId: offer.nftCache.collectionId,
          tokenId: offer.nftCache.tokenId
        }
      }
    });

    return updated;
  });
}
