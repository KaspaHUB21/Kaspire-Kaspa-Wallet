import {readFile, writeFile, rename} from 'node:fs/promises';
import {join} from 'node:path';

const HEX = /^[a-f0-9]{64}$/;
const ADDRESS = /^kaspa:[a-z0-9]{40,80}$/;

export function confirmedSale(offer, listing, tx) {
  if (!tx || tx.is_accepted !== true || !HEX.test(tx.transaction_id) ||
      tx.inputs?.[0]?.previous_outpoint_hash !== offer.listingTransactionId ||
      String(tx.inputs[0].previous_outpoint_index) !== '0') return null;
  const output = index => tx.outputs?.find(o => o.index === index);
  const seller = output(0), buyer = output(1), commission = output(2);
  if (!seller || !buyer || !commission || !Number.isSafeInteger(offer.priceSompi)) return null;
  const price = BigInt(offer.priceSompi), fee = (price * 21n + 999n) / 1000n;
  if (seller.script_public_key_address !== offer.seller ||
      String(seller.amount) !== String(price - fee + BigInt(listing.amount)) ||
      commission.script_public_key_address !== offer.feeAddress ||
      String(commission.amount) !== String(fee) ||
      !ADDRESS.test(buyer.script_public_key_address || '') ||
      buyer.script_public_key_address === offer.seller) return null;
  const soldAt = tx.accepting_block_time ?? tx.block_time;
  if (!Number.isSafeInteger(soldAt) || soldAt <= 0 || soldAt > Date.now() + 60000) return null;
  return {transactionId: tx.transaction_id, listingTransactionId: offer.listingTransactionId,
    ticker: offer.ticker, tokenId: offer.tokenId, priceSompi: String(price), soldAt,
    sellerAddress: offer.seller, buyerAddress: buyer.script_public_key_address};
}

export function createSalesFeed({state, get, node, records}) {
  const file = join(state, 'confirmed-nft-sales.json');
  let archive, checkedAt = 0, inFlight, cursor = 0;
  const listings = new Map();
  async function refresh() {
    if (!archive) {
      try { archive = JSON.parse(await readFile(file, 'utf8')); }
      catch (error) { if (error.code !== 'ENOENT') throw error; archive = {}; }
    }
    const pending = records().filter(r => !archive[r.listingTransactionId]);
    const batch = pending.slice(cursor, cursor + 20);
    cursor = cursor + 20 >= pending.length ? 0 : cursor + 20;
    for (let start = 0; start < batch.length; start += 4) {
      const results = await Promise.allSettled(batch.slice(start, start + 4).map(async offer => {
        let listing = listings.get(offer.listingTransactionId);
        if (!listing) {
          const tx = await get(`${node}/transactions/${offer.listingTransactionId}`);
          if (tx.is_accepted !== true || tx.transaction_id !== offer.listingTransactionId) {
            throw Error('Listing proof unavailable');
          }
          listing = tx.outputs?.find(o => o.index === 0);
          if (!listing || !ADDRESS.test(listing.script_public_key_address || '')) throw Error('Invalid listing output');
          listings.set(offer.listingTransactionId, listing);
        }
        const address = encodeURIComponent(listing.script_public_key_address);
        const utxos = await get(`${node}/addresses/${address}/utxos`);
        if (!Array.isArray(utxos)) throw Error('Invalid UTXO response');
        if (utxos.some(u => u.outpoint?.transactionId === offer.listingTransactionId &&
            Number(u.outpoint.index) === 0)) return;
        // Completion notifications are optional; find the actual spending transaction.
        for (let offset = 0; offset < 1000; offset += 100) {
          const history = await get(`${node}/addresses/${address}/full-transactions?limit=100&offset=${offset}&resolve_previous_outpoints=light`);
          if (!Array.isArray(history)) throw Error('Invalid transaction history');
          const spend = history.find(tx => tx.is_accepted === true && tx.inputs?.some(i =>
            i.previous_outpoint_hash === offer.listingTransactionId && String(i.previous_outpoint_index) === '0'));
          if (spend) {
            const sale = confirmedSale(offer, listing, spend);
            archive[offer.listingTransactionId] = {sale};
            return;
          }
          if (history.length < 100) return;
        }
        throw Error('NFT listing history pagination incomplete');
      }));
      const failure = results.find(result => result.status === 'rejected');
      if (failure) throw failure.reason;
    }
    await writeFile(file + '.pending', JSON.stringify(archive), {mode: 0o600});
    await rename(file + '.pending', file);
    checkedAt = Date.now();
  }
  return async function salesPage(offset) {
    if (!Number.isSafeInteger(offset) || offset < 0) throw Error('Invalid sales offset');
    if (!checkedAt || Date.now() - checkedAt >= 30000) {
      if (!inFlight) inFlight = refresh().finally(() => { inFlight = null; });
      await inFlight;
    }
    const sales = Object.values(archive).map(r => r.sale).filter(Boolean)
      .sort((a, b) => a.soldAt - b.soldAt || a.transactionId.localeCompare(b.transactionId));
    return {sales: sales.slice(offset, offset + 100),
      nextOffset: offset + 100 < sales.length ? offset + 100 : null, checkedAt};
  };
}
