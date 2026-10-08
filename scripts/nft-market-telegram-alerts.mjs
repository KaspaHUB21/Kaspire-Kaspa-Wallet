import {readFile, writeFile, rename} from 'node:fs/promises';

const required = name => {
  const value = String(process.env[name] || '').trim();
  if (!value) throw Error(`${name} is required`);
  return value;
};

export function formatKas(sompiValue) {
  const sompi = BigInt(String(sompiValue));
  const whole = sompi / 100000000n;
  const fraction = String(sompi % 100000000n).padStart(8, '0').replace(/0+$/, '');
  return fraction ? `${whole}.${fraction}` : String(whole);
}

const escapeHtml = value => String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

export function alertCaption(kind, record) {
  const ticker = escapeHtml(record.ticker), tokenId = escapeHtml(record.tokenId);
  const rank = Number.isSafeInteger(record.rarityRank) && record.rarityRank > 0
    ? `#${record.rarityRank}` : 'Not ranked';
  return kind === 'sale'
    ? `🎉 <b>NFT sold</b>\n\n<b>${ticker} #${tokenId}</b>\n💎 Rarity: <b>${rank}</b>\n💰 Price: <b>${formatKas(record.priceSompi)} KAS</b>`
    : `🟢 <b>New NFT listing</b>\n\n<b>${ticker} #${tokenId}</b>\n💎 Rarity: <b>${rank}</b>\n💰 Price: <b>${formatKas(record.priceSompi)} KAS</b>`;
}

export function initialListingPlan(offers, count = 4) {
  const ordered = [...offers].sort((a, b) => Number(a.createdAt) - Number(b.createdAt));
  return {alreadySeen: ordered.slice(0, Math.max(0, ordered.length - count)),
    backfill: ordered.slice(Math.max(0, ordered.length - count))};
}

async function jsonFile(path, fallback) {
  try { return JSON.parse(await readFile(path, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return fallback; throw error; }
}

async function atomicJson(path, value) {
  await writeFile(`${path}.pending`, JSON.stringify(value), {mode: 0o600});
  await rename(`${path}.pending`, path);
}

async function fetchJson(url) {
  const response = await fetch(url, {signal: AbortSignal.timeout(15000), cache: 'no-store'});
  if (!response.ok) throw Error(`Local marketplace returned HTTP ${response.status}`);
  return response.json();
}

async function sendPhoto({token, chatId, threadId, imageBase}, kind, record) {
  const image = await fetch(`${imageBase}/${encodeURIComponent(record.ticker)}/${encodeURIComponent(record.tokenId)}`,
    {signal: AbortSignal.timeout(15000), cache: 'no-store'});
  if (!image.ok) throw Error(`Local NFT image returned HTTP ${image.status}`);
  const bytes = await image.arrayBuffer();
  if (!bytes.byteLength || bytes.byteLength > 10 * 1024 * 1024) throw Error('NFT image size is invalid for Telegram');
  const form = new FormData();
  form.set('chat_id', chatId);
  form.set('message_thread_id', threadId);
  form.set('parse_mode', 'HTML');
  form.set('caption', alertCaption(kind, record));
  form.set('photo', new Blob([bytes], {type: image.headers.get('content-type') || 'image/png'}), `${record.ticker}-${record.tokenId}.png`);
  const response = await fetch(`https://api.telegram.org/bot${token}/sendPhoto`, {
    method: 'POST', body: form, signal: AbortSignal.timeout(30000),
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok || result.ok !== true) throw Error(`Telegram sendPhoto failed (${response.status}): ${String(result.description || 'unknown error').slice(0, 160)}`);
  return result.result?.message_id;
}

export async function runAlerts(config) {
  const listingPage = await fetchJson(config.listingsUrl);
  const offers = listingPage.offers;
  if (!Array.isArray(offers)) throw Error('Invalid marketplace offers state');
  const salesPage = await fetchJson(config.salesUrl);
  if (!Array.isArray(salesPage.sales)) throw Error('Invalid marketplace sales feed');
  let state = await jsonFile(config.alertState, null);
  if (!state) {
    const plan = initialListingPlan(offers, 4);
    state = {version: 1, listings: plan.alreadySeen.map(r => r.listingTransactionId),
      sales: salesPage.sales.map(r => r.transactionId)};
    await atomicJson(config.alertState, state);
  }
  const listingIds = new Set(state.listings || []), saleIds = new Set(state.sales || []);
  const byListing = new Map(offers.map(offer => [offer.listingTransactionId, offer]));
  const pendingListings = offers.filter(offer => !listingIds.has(offer.listingTransactionId))
    .sort((a, b) => Number(a.createdAt) - Number(b.createdAt));
  for (const offer of pendingListings) {
    await sendPhoto(config, 'listing', offer);
    listingIds.add(offer.listingTransactionId);
    state.listings = [...listingIds]; await atomicJson(config.alertState, state);
  }
  const pendingSales = salesPage.sales.filter(sale => !saleIds.has(sale.transactionId))
    .sort((a, b) => Number(a.soldAt) - Number(b.soldAt));
  for (const sale of pendingSales) {
    const offer = byListing.get(sale.listingTransactionId) || {};
    await sendPhoto(config, 'sale', {...sale, rarityRank: offer.rarityRank ?? null});
    saleIds.add(sale.transactionId);
    state.sales = [...saleIds]; await atomicJson(config.alertState, state);
  }
  return {listings: pendingListings.length, sales: pendingSales.length};
}

async function main() {
  const config = {token: required('TELEGRAM_BOT_TOKEN'), chatId: required('TELEGRAM_CHAT_ID'),
    threadId: required('TELEGRAM_THREAD_ID'), listingsUrl: required('MARKET_LISTINGS_URL'),
    alertState: required('ALERT_STATE_FILE'), salesUrl: required('MARKET_SALES_URL'),
    imageBase: required('NFT_IMAGE_BASE')};
  const interval = Math.max(10000, Number(process.env.ALERT_INTERVAL_MS) || 30000);
  for (;;) {
    try { const sent = await runAlerts(config); if (sent.listings || sent.sales) console.log(JSON.stringify({status:'sent', ...sent})); }
    catch (error) { console.error(`NFT marketplace alert cycle failed: ${String(error.message || error).slice(0, 300)}`); }
    await new Promise(resolve => setTimeout(resolve, interval));
  }
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) await main();
