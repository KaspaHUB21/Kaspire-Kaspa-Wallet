export type NftReference = {
  collectionId: string;
  tokenId: string;
};

export type NftSnapshot = {
  collectionId: string;
  collectionName: string;
  tokenId: string;
  name: string;
  imageUrl: string | null;
  ownerWallet: string | null;
  marketUrl: string;
  listingStatus: "LISTED" | "UNLISTED" | "UNKNOWN";
  listingPriceSompi: bigint | null;
  listingId: string | null;
  rarityRank: number | null;
  checkedAt: Date;
};

export interface MarketProvider {
  parseMarketUrl(url: string): Promise<NftReference | null>;
  getNftSnapshot(ref: NftReference): Promise<NftSnapshot | null>;
  getCanonicalMarketUrl(ref: NftReference): string;
  isSupportedCollection(collectionId: string): Promise<boolean>;
}
