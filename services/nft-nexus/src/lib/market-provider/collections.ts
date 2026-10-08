export type SupportedCollectionInfo = {
  collectionId: string;
  ticker: string;
  displayName: string;
  previewTokenId: string;
};

export const SUPPORTED_COLLECTIONS: SupportedCollectionInfo[] = [
  {
    collectionId: "hash",
    ticker: "HASH",
    displayName: "HASH",
    previewTokenId: "1"
  },
  {
    collectionId: "kasgoths",
    ticker: "KASGOTHS",
    displayName: "KasGoths",
    previewTokenId: "21"
  },
  {
    collectionId: "yonatoshi",
    ticker: "YONATOSHI",
    displayName: "Yonatoshi",
    previewTokenId: "1"
  },
  {
    collectionId: "pixelkrex",
    ticker: "PIXELKREX",
    displayName: "PixelKrex",
    previewTokenId: "1"
  },
  {
    collectionId: "jeetslife",
    ticker: "JEETSLIFE",
    displayName: "JeetsLife",
    previewTokenId: "1"
  },
  {
    collectionId: "bitcoin",
    ticker: "BITCOIN",
    displayName: "Bitcoin",
    previewTokenId: "1"
  },
  {
    collectionId: "kaspunks",
    ticker: "KASPUNKS",
    displayName: "KasPunks",
    previewTokenId: "1"
  },
  {
    collectionId: "kaszombies",
    ticker: "KASZOMBIES",
    displayName: "KasZombies",
    previewTokenId: "1"
  },
  {
    collectionId: "kdc",
    ticker: "KDC",
    displayName: "KDC",
    previewTokenId: "1"
  }
];

export const BLACKLISTED_COLLECTION_TICKERS: string[] = [];

export function getSupportedCollection(collectionIdOrTicker: string) {
  const normalized = collectionIdOrTicker.toLowerCase();
  return SUPPORTED_COLLECTIONS.find(
    (collection) => collection.collectionId === normalized || collection.ticker.toLowerCase() === normalized
  );
}

export function normalizeCollectionId(collectionIdOrTicker: string) {
  return collectionIdOrTicker.trim().replace(/[^\p{L}\p{N}]/gu, "").toLowerCase();
}

export function normalizeTicker(collectionIdOrTicker: string) {
  return normalizeCollectionId(collectionIdOrTicker).toUpperCase();
}

export function isBlacklistedCollection(collectionIdOrTicker: string) {
  return BLACKLISTED_COLLECTION_TICKERS.includes(normalizeTicker(collectionIdOrTicker));
}

export function getCollectionInfo(collectionIdOrTicker: string) {
  const configured = getSupportedCollection(collectionIdOrTicker);
  if (configured) {
    return configured;
  }

  const collectionId = normalizeCollectionId(collectionIdOrTicker);
  const ticker = normalizeTicker(collectionIdOrTicker);
  if (!collectionId || isBlacklistedCollection(ticker)) {
    return null;
  }

  return {
    collectionId,
    ticker,
    displayName: ticker,
    previewTokenId: "1"
  };
}

export function getKrc721ImageUrl(collectionIdOrTicker: string, tokenId: string | number) {
  const collection = getCollectionInfo(collectionIdOrTicker);
  if (!collection) {
    return null;
  }

  return `https://kaspire.kaslab.space/krc721-read-v1/images/${encodeURIComponent(collection.ticker)}/${encodeURIComponent(String(tokenId))}`;
}
