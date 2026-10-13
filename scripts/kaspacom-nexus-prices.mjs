// Display enrichment only. Shared quotes, bounded globally across all users.
export function createNexusPriceReader(api, {now = Date.now, ttl = 90000,
  requestLimit = 40, concurrency = 2} = {}) {
  const cache = new Map(), pending = new Map();
  let windowAt = now(), requests = 0, running = 0;
  const unavailable = () => Error('KaspaCom price is temporarily unavailable; please retry shortly.');
  async function limited(path, body) {
    if (now() - windowAt >= 60000) { windowAt = now(); requests = 0; }
    if (requests >= requestLimit) throw unavailable();
    requests++;
    return api(path, body);
  }
  return async (ticker, tokenId) => {
    if (!/^[A-Z0-9]{1,10}$/.test(ticker) || !/^\d{1,20}$/.test(tokenId))
      throw Error('Invalid NFT reference');
    const key = ticker + ':' + tokenId, hit = cache.get(key);
    if (hit && hit.until > now()) {
      if (hit.error) throw unavailable();
      return hit.value;
    }
    if (pending.has(key)) return pending.get(key);
    if (running >= concurrency) throw unavailable();
    running++;
    const work = (async () => {
      try {
        const data = await limited('/krc721-orders-v2/sell-orders?ticker=' + ticker,
          {tokenId, completedOrders:false, onlyDecentralize:true,
            pagination:{limit:2, offset:0}, sort:{field:'createdAt', direction:'desc'}});
        if (!Array.isArray(data.orders)) throw unavailable();
        const row = data.orders?.find(o => o.ticker === ticker &&
          String(o.tokenId) === tokenId && o.isDecentralized === true &&
          o.status === 'LISTED_FOR_SALE');
        let value = null;
        if (row) {
          if (!/^[a-f0-9]{24}$/.test(row.orderId ?? '')) throw unavailable();
          const detail = await limited('/krc721-orders-v2/' + row.orderId);
          // Cancel/relist by the same owner must not reuse the previous price.
          const tx = JSON.parse(detail.psktSeller);
          const listingTransactionId = tx.inputs?.[0]?.transactionId;
          if (detail.ticker !== ticker || String(detail.tokenId) !== tokenId ||
              detail.sellerWalletAddress !== row.sellerWalletAddress ||
              detail.status !== 'LISTED_FOR_SALE' ||
              !/^[a-f0-9]{64}$/.test(listingTransactionId ?? '') ||
              !/^\d+(\.\d{1,8})?$/.test(String(detail.totalPrice))) throw unavailable();
          value = {orderId:row.orderId, ticker, tokenId,
            sellerWalletAddress:detail.sellerWalletAddress,
            totalPrice:detail.totalPrice, listingTransactionId};
        }
        if (cache.size >= 2048) cache.delete(cache.keys().next().value);
        cache.set(key, {until:now()+ttl, value});
        return value;
      } catch (error) {
        if (cache.size >= 2048) cache.delete(cache.keys().next().value);
        cache.set(key, {until:now()+15000, error:true});
        throw error;
      } finally {running--; pending.delete(key);}
    })();
    pending.set(key, work);
    return work;
  };
}

export function matchingNexusOrder(order, {ticker, tokenId, owner, listingId, listingStatus}) {
  return listingStatus === 'LISTED' && order && order.ticker === ticker.toUpperCase() &&
    String(order.tokenId) === String(tokenId) && order.sellerWalletAddress === owner &&
    order.listingTransactionId === listingId && /^[a-f0-9]{64}$/.test(listingId ?? '')
    ? order : null;
}
