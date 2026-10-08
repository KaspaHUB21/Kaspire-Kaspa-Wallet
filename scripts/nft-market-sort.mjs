export function compareNftListings(a, b, sort = 'recent') {
  const tie = Number(b.createdAt ?? 0) - Number(a.createdAt ?? 0)
    || String(a.listingTransactionId ?? '').localeCompare(String(b.listingTransactionId ?? ''));
  if (sort === 'low' || sort === 'high') {
    return (sort === 'high' ? -1 : 1) * (Number(a.priceSompi) - Number(b.priceSompi)) || tie;
  }
  if (sort === 'rank-low' || sort === 'rank-high') {
    const valid = r => Number.isSafeInteger(r) && (r > 0 || r === -1);
    const left = valid(a.rarityRank), right = valid(b.rarityRank);
    if (left !== right) return left ? -1 : 1;
    if (left) return (sort === 'rank-high' ? -1 : 1) * (a.rarityRank - b.rarityRank) || tie;
  }
  return tie;
}
