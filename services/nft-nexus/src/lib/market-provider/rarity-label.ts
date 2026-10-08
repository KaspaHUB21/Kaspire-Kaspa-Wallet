import { normalizeCollectionId } from "./collections";

const KASGOTHS_LEGENDARY_TOKEN_IDS = new Set(["13", "21", "420"]);

export function getRarityLabel(collectionId: string, tokenId: string | number, rarityRank: number | null | undefined) {
  if (rarityRank === -1) {
    return "Legendary";
  }

  if (normalizeCollectionId(collectionId) === "kasgoths" && KASGOTHS_LEGENDARY_TOKEN_IDS.has(String(tokenId))) {
    return "Legendary";
  }

  return rarityRank ?? "unknown";
}
