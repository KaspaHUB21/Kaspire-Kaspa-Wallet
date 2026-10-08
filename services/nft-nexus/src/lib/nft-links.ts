export function getNftNexusPath(collectionId: string, tokenId: string) {
  return `/nft/${encodeURIComponent(collectionId)}/${encodeURIComponent(tokenId)}`;
}

export function getNftNexusUrl(collectionId: string, tokenId: string) {
  const base = process.env.APP_URL || "http://localhost:3010";
  return `${base.replace(/\/$/, "")}${getNftNexusPath(collectionId, tokenId)}`;
}
