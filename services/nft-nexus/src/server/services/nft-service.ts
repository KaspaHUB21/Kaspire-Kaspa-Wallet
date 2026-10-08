import { prisma } from "@/lib/db/prisma";
import { getMarketProvider } from "@/lib/market-provider";
import type { NftReference, NftSnapshot } from "@/lib/market-provider/types";
import { BLACKLIST_MESSAGE, isCollectionBlacklisted } from "@/server/services/blacklist-service";

export async function getDisplayNftSnapshot(ref: NftReference) {
  if (await isCollectionBlacklisted(ref.collectionId)) {
    throw new Error(BLACKLIST_MESSAGE);
  }

  const provider = getMarketProvider();
  const supported = await provider.isSupportedCollection(ref.collectionId);
  if (!supported) {
    throw new Error("Unsupported collection.");
  }

  const snapshot = await provider.getNftSnapshot(ref);
  if (!snapshot) {
    throw new Error("NFT not found.");
  }

  return {
    id: `${snapshot.collectionId}:${snapshot.tokenId}`,
    collectionId: snapshot.collectionId,
    tokenId: snapshot.tokenId,
    name: snapshot.name,
    imageUrl: snapshot.imageUrl,
    marketUrl: snapshot.marketUrl,
    currentOwnerWallet: snapshot.ownerWallet,
    listingStatus: snapshot.listingStatus,
    listingPriceSompi: snapshot.listingPriceSompi,
    listingId: snapshot.listingId,
    rarityRank: snapshot.rarityRank,
    lastCheckedAt: snapshot.checkedAt
  };
}

export async function refreshNftSnapshot(ref: NftReference) {
  if (await isCollectionBlacklisted(ref.collectionId)) {
    throw new Error(BLACKLIST_MESSAGE);
  }

  const provider = getMarketProvider();
  const supported = await provider.isSupportedCollection(ref.collectionId);
  if (!supported) {
    throw new Error("Unsupported collection.");
  }

  const snapshot = await provider.getNftSnapshot(ref);
  if (!snapshot) {
    throw new Error("NFT not found.");
  }

  return upsertSnapshot(snapshot);
}

export async function upsertSnapshot(snapshot: NftSnapshot) {
  const listingVerified = snapshot.listingStatus !== "UNKNOWN";
  const nftCache = await prisma.nftCache.upsert({
    where: {
      collectionId_tokenId: {
        collectionId: snapshot.collectionId,
        tokenId: snapshot.tokenId
      }
    },
    update: {
      name: snapshot.name,
      imageUrl: snapshot.imageUrl,
      marketUrl: snapshot.marketUrl,
      currentOwnerWallet: snapshot.ownerWallet,
      listingStatus: listingVerified ? snapshot.listingStatus : undefined,
      listingPriceSompi: listingVerified ? snapshot.listingPriceSompi : undefined,
      listingId: listingVerified ? snapshot.listingId : undefined,
      lastCheckedAt: snapshot.checkedAt
    },
    create: {
      collectionId: snapshot.collectionId,
      tokenId: snapshot.tokenId,
      name: snapshot.name,
      imageUrl: snapshot.imageUrl,
      marketUrl: snapshot.marketUrl,
      currentOwnerWallet: snapshot.ownerWallet,
      listingStatus: snapshot.listingStatus,
      listingPriceSompi: snapshot.listingPriceSompi,
      listingId: snapshot.listingId,
      lastCheckedAt: snapshot.checkedAt
    }
  });

  await prisma.nftRarityCache.upsert({
    where: {
      collectionId_tokenId: {
        collectionId: snapshot.collectionId,
        tokenId: snapshot.tokenId
      }
    },
    // The background importer owns rank updates. A stale display snapshot
    // must not overwrite a newly imported marketplace rank.
    update: {},
    create: {
      collectionId: snapshot.collectionId,
      tokenId: snapshot.tokenId,
      rarityRank: snapshot.rarityRank
    }
  });

  return nftCache;
}
