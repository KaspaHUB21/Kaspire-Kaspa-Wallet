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

async function sendTelegram(config, method, body) {
  const response = await fetch(`https://api.telegram.org/bot${config.token}/${method}`, {
    method: 'POST', body, signal: AbortSignal.timeout(30000),
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok || result.ok !== true || !Number.isSafeInteger(result.result?.message_id)) {
    throw Error(`Telegram ${method} failed (${response.status}): ${String(result.description || 'invalid receipt').slice(0, 160)}`);
  }
  return {messageId: result.result.message_id, method};
}

async function sendAlert(config, kind, record) {
  let bytes, mime;
  try {
    const image = await fetch(`${config.imageBase}/${encodeURIComponent(record.ticker)}/${encodeURIComponent(record.tokenId)}`,
      {signal: AbortSignal.timeout(15000), cache: 'no-store', redirect: 'error'});
    if (!image.ok) { await image.body?.cancel(); throw Error('Image unavailable'); }
    mime = image.headers.get('content-type')?.split(';')[0];
    if (!['image/png', 'image/jpeg', 'image/webp', 'image/gif'].includes(mime)) {
      await image.body?.cancel(); throw Error('Unsupported image');
    }
    bytes = await image.arrayBuffer();
    if (!bytes.byteLength || bytes.byteLength > 10 * 1024 * 1024) throw Error('Invalid image size');
  } catch {
    const body = new URLSearchParams({chat_id: config.chatId, message_thread_id: config.threadId,
      parse_mode: 'HTML', text: alertCaption(kind, record) + '\n\n🖼 Image unavailable.'});
    return sendTelegram(config, 'sendMessage', body);
  }
  const form = new FormData();
  form.set('chat_id', config.chatId);
  form.set('message_thread_id', config.threadId);
  form.set('parse_mode', 'HTML');
  form.set('caption', alertCaption(kind, record));
  const extension = {'image/png':'png', 'image/jpeg':'jpg', 'image/webp':'webp', 'image/gif':'gif'}[mime];
  form.set('photo', new Blob([bytes], {type: mime}), `${record.ticker}-${record.tokenId}.${extension}`);
  return sendTelegram(config, 'sendPhoto', form);
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
  const pendingSales = salesPage.sales.filter(sale => !saleIds.has(sale.transactionId))
    .sort((a, b) => Number(a.soldAt) - Number(b.soldAt));
  const sent = {listings: 0, sales: 0, failed: 0};
  for (const [kind, records, ids, field, counter, idKey] of [
    ['listing', pendingListings, listingIds, 'listings', 'listings', 'listingTransactionId'],
    ['sale', pendingSales, saleIds, 'sales', 'sales', 'transactionId'],
  ]) {
    for (const record of records) {
      const offer = byListing.get(record.listingTransactionId) || {};
      let receipt;
      try {
        receipt = await sendAlert(config, kind, kind === 'sale'
          ? {...record, rarityRank: offer.rarityRank ?? record.rarityRank ?? null} : record);
      } catch (error) {
        sent.failed++;
        console.error(JSON.stringify({status:'failed', kind, ticker:record.ticker,
          tokenId:record.tokenId, eventId:record[idKey], error:String(error.message || error).slice(0, 300)}));
        continue;
      }
      // Persist each confirmed delivery before proceeding; state-write failures abort
      // rather than continuing to send without a durable duplicate guard.
      ids.add(record[idKey]);
      state[field] = [...ids];
      state.receipts ||= {};
      state.receipts[`${kind}:${record[idKey]}`] = {...receipt, sentAt:Date.now()};
      await atomicJson(config.alertState, state);
      sent[counter]++;
      console.log(JSON.stringify({status:'delivered', kind, ticker:record.ticker,
        tokenId:record.tokenId, eventId:record[idKey], ...receipt}));
    }
  }
  return sent;
}

async function main() {
  const config = {token: required('TELEGRAM_BOT_TOKEN'), chatId: required('TELEGRAM_CHAT_ID'),
    threadId: required('TELEGRAM_THREAD_ID'), listingsUrl: required('MARKET_LISTINGS_URL'),
    alertState: required('ALERT_STATE_FILE'), salesUrl: required('MARKET_SALES_URL'),
    imageBase: required('NFT_IMAGE_BASE')};
  const interval = Math.max(10000, Number(process.env.ALERT_INTERVAL_MS) || 30000);
  for (;;) {
    try { const sent = await runAlerts(config); if (sent.listings || sent.sales || sent.failed) console.log(JSON.stringify({status:'sent', ...sent})); }
    catch (error) { console.error(`NFT marketplace alert cycle failed: ${String(error.message || error).slice(0, 300)}`); }
    await new Promise(resolve => setTimeout(resolve, interval));
  }
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) await main();
