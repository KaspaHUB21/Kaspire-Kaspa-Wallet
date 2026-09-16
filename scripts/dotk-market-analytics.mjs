// Public market analytics only. No signing or user-supplied broadcast endpoint.
export const REGISTRY = 'ee2128c03dfac7f6d74734bb3c879bd999434c47a55945b8a6daae2a1e4a21de';
const HEX = /^[a-f0-9]{64}$/;
const BOND = 100000000n;
export function completion(offer, tx, sellerDeed) {
  if (!tx || tx.is_accepted !== true || !HEX.test(tx.transaction_id) ||
      !Array.isArray(tx.inputs) || !Array.isArray(tx.outputs)) return null;
  for (const index of [0, 1]) {
    if (tx.inputs.filter(i => i.previous_outpoint_hash === offer.listingTxId &&
        String(i.previous_outpoint_index) === String(index)).length !== 1) return null;
  }
  const out = index => {
    const rows = tx.outputs.filter(o => o.index === index);
    return rows.length === 1 ? rows[0] : null;
  };
  const deed = out(0), seller = out(1), fee = out(2);
  if (!deed || !seller || deed.covenant_id !== REGISTRY || String(deed.amount) !== String(BOND) ||
      seller.covenant_id != null || seller.script_public_key_address !== offer.terms.seller) return null;
  const price = BigInt(offer.terms.priceSompi), commission = price * 21n / 1000n;
  const timestamp = tx.accepting_block_time ?? tx.block_time;
  if (!Number.isSafeInteger(timestamp) || timestamp <= 0 || timestamp > Date.now() + 60000) return null;
  const result = { transactionId: tx.transaction_id, timestamp,
    buyer_deed_address: deed.script_public_key_address ?? null };
  if (String(seller.amount) === String(price - commission + BOND) && fee &&
      fee.covenant_id == null && fee.script_public_key_address === offer.terms.feeAddress &&
      String(fee.amount) === String(commission)) return { ...result, status: 'sold' };
  if (String(seller.amount) === String(BOND) && deed.script_public_key === sellerDeed)
    return { ...result, status: 'cancelled', buyer_deed_address: null };
  return null;
}

export async function discoverCompletion(offer, { json, derive, node }) {
  const key = await json(`https://api.dotk.name/v1/names/${encodeURIComponent(offer.terms.name)}/key`);
  if (key.registryCovenantId !== REGISTRY || !HEX.test(key.key)) throw Error('Invalid name history');
  const d = await derive(offer.terms, null);
  for (let offset = 0; offset < 2000; offset += 100) {
    const history = await json(`https://api.dotk.name/v1/keys/${key.key}/history?limit=100&offset=${offset}`);
    if (history.registryCovenantId !== REGISTRY || !Array.isArray(history.entries)) throw Error('Invalid history');
    for (const event of history.entries) {
      if (event.txid === offer.listingTxId) return null;
      if (!HEX.test(event.txid)) continue;
      const tx = await json(`${node}/transactions/${event.txid}`);
      const result = completion(offer, tx, d.deed.scriptPublicKey);
      if (result) return result;
    }
    // "complete" describes index completeness, not the last pagination page.
    if (history.entries.length < 100 ||
        (Number.isSafeInteger(history.total) && offset + history.entries.length >= history.total)) return null;
  }
  throw Error('Name history pagination incomplete');
}

export function marketAnalytics(archive, query = '') {
  const q = query.trim().toLowerCase().replace(/\.k$/, '');
  const sales = Object.values(archive.records).filter(r => r.completion?.status === 'sold');
  const seen = new Set();
  const unique = sales.filter(r => {
    if (seen.has(r.completion.transactionId)) return false;
    seen.add(r.completion.transactionId); return true;
  });
  let volume = 0n;
  const names = new Map(), days = new Map();
  for (const record of unique) {
    const price = BigInt(record.offer.terms.priceSompi);
    volume += price;
    const name = record.offer.terms.name + '.k';
    const top = names.get(name) || { domain: name, sompi: 0n, total_trades: 0 };
    top.sompi += price; top.total_trades++; names.set(name, top);
    const day = Math.floor(record.completion.timestamp / 86400000) * 86400;
    const point = days.get(day) || { sompi: 0n, trades: 0 };
    point.sompi += price; point.trades++; days.set(day, point);
  }
  // Match KNS: chronological reported daily aggregates, not a calendar padded
  // with synthetic zero days. The UI takes the latest reported daily point.
  const graph = [...days.entries()].sort(([a], [b]) => a - b)
    .map(([time, point]) => ({ time, total_volume_kas: Number(point.sompi) / 1e8,
      total_trades: point.trades }));
  return {
    source: 'Kaspire Marketplace', indexedAt: archive.updatedAt,
    coverage: { since: archive.startedAt, historicalComplete: false,
      note: 'Confirmed sales recorded by Kaspire Marketplace. Earlier unarchived trades may be missing. Volume excludes network fees and returned covenant reserves.' },
    totals: { volume_sompi: volume.toString(), volume_kas: Number(volume) / 1e8, trades: unique.length },
    graph,
    top_domains: [...names.values()].filter(r => r.domain.includes(q))
      .sort((a, b) => a.sompi === b.sompi ? a.domain.localeCompare(b.domain) : a.sompi > b.sompi ? -1 : 1)
      .slice(0, 8).map(r => ({ domain: r.domain, total_trades: r.total_trades, total_volume_kas: Number(r.sompi) / 1e8 })),
    recent_sales: unique.filter(r => r.offer.terms.name.includes(q))
      .sort((a, b) => b.completion.timestamp - a.completion.timestamp).slice(0, 50)
      .map(r => ({ domain: r.offer.terms.name + '.k', price_kas: r.offer.terms.priceSompi / 1e8,
        price_sompi: String(r.offer.terms.priceSompi), seller: r.offer.terms.seller,
        buyer_deed_address: r.completion.buyer_deed_address, timestamp: r.completion.timestamp,
        transaction_id: r.completion.transactionId, listing_transaction_id: r.offer.listingTxId })),
    pending_verification: Object.values(archive.records).filter(r => !r.completion).length,
  };
}
