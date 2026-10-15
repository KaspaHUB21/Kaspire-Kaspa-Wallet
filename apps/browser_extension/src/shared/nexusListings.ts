// Prices and listing state come from the shared, cached Nexus resolver.
// Do not request KaspaCom separately for every card or notification.
export function nexusListing(data: any) {
  const listing = data?.marketplaceListing ?? data?.kaspacomListing ?? data?.kaspireListing;
  if (!listing || !['kaspire', 'kaspacom'].includes(listing.source)) return null;
  const ticker = String(listing.ticker ?? data.collectionId ?? '').toUpperCase();
  const tokenId = String(listing.tokenId ?? data.tokenId ?? '');
  if (!/^[A-Z0-9_-]{1,32}$/.test(ticker) || !/^\d{1,20}$/.test(tokenId) || ticker !== String(data.collectionId ?? data.ticker).toUpperCase() || tokenId !== String(data.tokenId)) return null;
  if (listing.source === 'kaspacom' && !/^[A-Za-z0-9_-]{1,128}$/.test(String(listing.orderId))) return null;
  const priceSompi = listing.priceSompi ?? data.listingPriceSompi;
  if (!/^\d{1,20}$/.test(String(priceSompi))) return null;
  return { ...listing, ticker, tokenId, priceSompi: String(priceSompi), venue: listing.source === 'kaspacom' ? 'KaspaCom' : 'Kaspire' };
}
export function kaspaComNftUrl(data: any) {
  const listing = nexusListing(data);
  if (!listing || listing.source !== 'kaspacom') throw Error('No verified KaspaCom listing for this NFT.');
  return `https://kaspa.com/nft/collections/${encodeURIComponent(listing.ticker)}/${listing.tokenId}`;
}
