import { core } from "./core";
import { dotkBareName, dotkNamesOf, DOTK_REGISTRY } from "./dotk";

export const MARKET_DIRECTORY = "https://kaspire.kaslab.space/market-test-v1";
export const MARKET_NODE = "https://kaspire.kaslab.space/api/local-node";
const STORAGE_KEY = "dotkMarketRecoveryV1";
const TRANSIENT = new Set([429, 502, 503, 504]);

export type MarketOffer = {
  terms: { name: string; seller: string; feeAddress: string; priceSompi: number };
  listingTxId: string;
  saleId: string;
};
export type MarketState = "active" | "pending" | "sold" | "cancelled" | "unavailable";
export type MarketStatus = { state: MarketState; transactionId?: string };

class ReadScheduler {
  private lanes: Promise<void>[] = [Promise.resolve(), Promise.resolve()];
  private gate = Promise.resolve();
  private next = 0;
  run<T>(action: () => Promise<T>): Promise<T> {
    const lane = this.next++ % this.lanes.length;
    const job = this.lanes[lane]!.then(async () => {
      const start = this.gate.then(() => new Promise<void>((resolve) => setTimeout(resolve, 125)));
      this.gate = start;
      await start;
      return action();
    });
    this.lanes[lane] = job.then(() => undefined, () => undefined);
    return job;
  }
}
const scheduler = new ReadScheduler();
const pending = new Map<string, Promise<any>>();

async function read(url: string): Promise<any> {
  const existing = pending.get(url);
  if (existing) return existing;
  const task = (async () => {
    for (let attempt = 0; attempt < 4; attempt++) {
      try {
        const response = await scheduler.run(() => fetch(url, { signal: AbortSignal.timeout(12_000), headers: { accept: "application/json" } }));
        if (!TRANSIENT.has(response.status)) {
          if (!response.ok) throw new Error(`Marketplace data unavailable (${response.status}).`);
          const text = await response.text();
          if (text.length > 4 * 1024 * 1024) throw new Error("Marketplace response is too large.");
          return JSON.parse(text);
        }
      } catch (error) {
        if (attempt === 3 || (!(error instanceof TypeError) && (error as Error).name !== "TimeoutError")) throw error;
      }
      if (attempt === 3) throw new Error("Marketplace verification temporarily unavailable. Please retry.");
      await new Promise((resolve) => setTimeout(resolve, 700 * 2 ** attempt));
    }
  })();
  pending.set(url, task);
  try { return await task; } finally { pending.delete(url); }
}

export function marketOffer(raw: any): MarketOffer {
  const terms = raw?.terms;
  dotkBareName(`${String(terms?.name ?? "")}.k`);
  if (!/^[0-9a-f]{64}$/.test(String(raw?.listingTxId ?? "")) ||
      !/^[0-9a-f]{64}$/.test(String(raw?.saleId ?? "")) ||
      !Number.isSafeInteger(terms?.priceSompi) ||
      typeof terms?.seller !== "string" || typeof terms?.feeAddress !== "string")
    throw new Error("Invalid marketplace offer.");
  return { terms: { name: terms.name, seller: terms.seller, feeAddress: terms.feeAddress,
    priceSompi: terms.priceSompi }, listingTxId: raw.listingTxId, saleId: raw.saleId };
}

export async function marketOffers(query = "") {
  const rows: MarketOffer[] = [];
  let offset: number | null = 0;
  while (offset !== null && rows.length < 1000) {
    const page = await read(`${MARKET_DIRECTORY}/offers?q=${encodeURIComponent(query.trim().toLowerCase())}&offset=${offset}`);
    if (!Array.isArray(page?.offers)) throw new Error("Invalid marketplace directory response.");
    rows.push(...page.offers.map(marketOffer));
    const next = page.nextOffset;
    if (next !== null && (!Number.isSafeInteger(next) || next <= offset)) throw new Error("Invalid marketplace pagination.");
    offset = next;
  }
  return rows;
}

export async function savedOffers(seller?: string) {
  const stored = await chrome.storage.local.get(STORAGE_KEY);
  const rows = Array.isArray(stored[STORAGE_KEY]) ? stored[STORAGE_KEY].map(marketOffer) : [];
  return seller ? rows.filter((offer: MarketOffer) => offer.terms.seller === seller) : rows;
}
export async function saveOffer(offer: MarketOffer) {
  const clean = marketOffer(offer), rows = await savedOffers();
  const next = rows.filter((row) => row.listingTxId !== clean.listingTxId);
  next.push(clean);
  await chrome.storage.local.set({ [STORAGE_KEY]: next });
  return clean;
}
export async function publishOffer(offer: MarketOffer) {
  const response = await fetch(`${MARKET_DIRECTORY}/offers`, { method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" }, body: JSON.stringify(marketOffer(offer)),
    signal: AbortSignal.timeout(25_000) });
  if (response.status !== 200 && response.status !== 201)
    throw new Error("Offer is saved in this extension, but directory publication is pending. Retry Publish after confirmation.");
  return true;
}

async function cell(address: string, script: string, covenant: string, amount: number,
  expected?: { txid: string; index: number }, proof?: () => Promise<any>) {
  const rows = await read(`${MARKET_NODE}/addresses/${encodeURIComponent(address)}/utxos`);
  if (!Array.isArray(rows)) throw new Error("Invalid marketplace UTXO response.");
  for (const raw of rows) {
    const point = raw?.outpoint, entry = raw?.utxoEntry, spk = entry?.scriptPublicKey;
    if (String(entry?.amount) !== String(amount) || entry?.isCoinbase !== false ||
        spk?.scriptPublicKey !== script || (expected && (point?.transactionId !== expected.txid || point?.index !== expected.index))) continue;
    const id = String(point?.transactionId ?? "");
    if (!/^[0-9a-f]{64}$/.test(id)) continue;
    const tx = proof ? await proof() : await read(`${MARKET_NODE}/transactions/${id}`);
    if (tx?.transaction_id !== id || tx?.is_accepted !== true || !Array.isArray(tx?.outputs)) continue;
    if (!tx.outputs.some((out: any) => out?.index === point.index && out?.covenant_id === covenant &&
      out?.script_public_key === script && String(out?.amount) === String(amount))) continue;
    return { transactionId: id, index: point.index, valueSompi: amount,
      blockDaaScore: Number(entry.blockDaaScore), scriptPublicKey: script, covenantId: covenant };
  }
  throw new Error("This name or listing is not currently spendable. It may be pending, sold or cancelled.");
}

export async function verifiedMarketCells(offer: MarketOffer) {
  const clean = marketOffer(offer), wasm = await core();
  const descriptor = JSON.parse(wasm.describeDotkMarket(JSON.stringify({ terms: clean.terms, saleId: clean.saleId })));
  let proof: Promise<any> | undefined;
  const loadProof = () => proof ??= read(`${MARKET_NODE}/transactions/${clean.listingTxId}`);
  return Promise.all([
    cell(descriptor.deed.deedAddress, descriptor.deed.scriptPublicKey, DOTK_REGISTRY, 100_000_000,
      { txid: clean.listingTxId, index: 0 }, loadProof),
    cell(descriptor.saleAddress, descriptor.saleScriptPublicKey, clean.saleId, 100_000_000,
      { txid: clean.listingTxId, index: 1 }, loadProof),
  ]);
}

function completion(offer: MarketOffer, tx: any, sellerDeed: string): MarketStatus | null {
  if (tx?.is_accepted !== true || !/^[0-9a-f]{64}$/.test(String(tx?.transaction_id ?? "")) ||
      !Array.isArray(tx?.inputs) || !Array.isArray(tx?.outputs)) return null;
  for (const index of [0, 1]) if (tx.inputs.filter((input: any) =>
    input?.previous_outpoint_hash === offer.listingTxId && String(input?.previous_outpoint_index) === String(index)).length !== 1) return null;
  const out = (index: number) => { const rows = tx.outputs.filter((item: any) => item?.index === index); return rows.length === 1 ? rows[0] : null; };
  const deed = out(0), seller = out(1), fee = out(2);
  if (!deed || !seller || deed.covenant_id !== DOTK_REGISTRY || String(deed.amount) !== "100000000" ||
      seller.script_public_key_address !== offer.terms.seller || seller.covenant_id != null) return null;
  const price = BigInt(offer.terms.priceSompi), commission = price * 21n / 1000n;
  if (String(seller.amount) === String(price - commission + 100_000_000n) && fee &&
      String(fee.amount) === String(commission) && fee.script_public_key_address === offer.terms.feeAddress && fee.covenant_id == null)
    return { state: "sold", transactionId: tx.transaction_id };
  if (String(seller.amount) === "100000000" && deed.script_public_key === sellerDeed)
    return { state: "cancelled", transactionId: tx.transaction_id };
  return null;
}

export async function marketStatus(input: MarketOffer): Promise<MarketStatus> {
  const offer = marketOffer(input);
  try { await verifiedMarketCells(offer); return { state: "active" }; }
  catch (error) { if (/temporarily unavailable|timed out/i.test((error as Error).message)) return { state: "unavailable" }; }
  try {
    const key = await read(`https://api.dotk.name/v1/names/${offer.terms.name}/key`);
    if (key?.registryCovenantId !== DOTK_REGISTRY || !/^[0-9a-f]{64}$/.test(String(key?.key ?? ""))) return { state: "unavailable" };
    const wasm = await core();
    const descriptor = JSON.parse(wasm.describeDotkMarket(JSON.stringify({ terms: offer.terms, saleId: null })));
    const sellerDeed = descriptor.deed.scriptPublicKey;
    for (let offset = 0; offset < 2000; offset += 100) {
      const history = await read(`https://api.dotk.name/v1/keys/${key.key}/history?limit=100&offset=${offset}`);
      if (history?.registryCovenantId !== DOTK_REGISTRY || !Array.isArray(history?.entries)) break;
      for (const event of history.entries) {
        const id = String(event?.txid ?? "");
        if (!/^[0-9a-f]{64}$/.test(id)) continue;
        if (id === offer.listingTxId) break;
        const result = completion(offer, await read(`${MARKET_NODE}/transactions/${id}`), sellerDeed);
        if (result) return result;
      }
      if (history.entries.length < 100 || (Number.isSafeInteger(history.total) && offset + history.entries.length >= history.total) ||
          history.entries.some((event: any) => event?.txid === offer.listingTxId)) break;
    }
    const listing = await read(`${MARKET_NODE}/transactions/${offer.listingTxId}`);
    if (listing?.transaction_id === offer.listingTxId && listing?.is_accepted === false) return { state: "pending" };
  } catch {}
  return { state: "unavailable" };
}

export async function marketNames(address: string) { return dotkNamesOf(address); }

export async function prepareMarketRequest(action: "list" | "buy" | "cancel", sender: string,
  input: { name?: string; priceSompi?: number; feeAddress?: string; offer?: MarketOffer }, feeRate: number, fundingUtxosJson: string) {
  const wasm = await core();
  let terms: MarketOffer["terms"], deed: any, sale: any = null;
  if (action === "list") {
    if (!input.name || !Number.isSafeInteger(input.priceSompi) || !input.feeAddress) throw new Error("Invalid listing request.");
    terms = { name: dotkBareName(input.name), seller: sender, priceSompi: input.priceSompi!, feeAddress: input.feeAddress };
    const descriptor = JSON.parse(wasm.describeDotkMarket(JSON.stringify({ terms, saleId: null })));
    deed = await cell(descriptor.deed.deedAddress, descriptor.deed.scriptPublicKey, DOTK_REGISTRY, 100_000_000);
  } else {
    const offer = marketOffer(input.offer);
    const cells = await verifiedMarketCells(offer);
    terms = offer.terms; deed = cells[0]; sale = cells[1];
  }
  const request = { action, sender, terms, deed, sale, fundingUtxosJson, feeRate };
  const review = JSON.parse(wasm.prepareDotkMarket(JSON.stringify(request)));
  const offer = action === "list" ? marketOffer({ terms, listingTxId: "0".repeat(64), saleId: review.covenantId }) : input.offer;
  return { request, review, offer };
}

export async function verifyPreparedMarket(review: any) {
  const tx = JSON.parse(String(review?.transactionJson ?? ""));
  if (!Array.isArray(tx?.inputs) || tx.inputs.length < 1 || tx.inputs.length > 80) throw new Error("Invalid marketplace transaction inputs.");
  const seen = new Set<string>(), previous = new Map<string, Promise<any>>(), live = new Map<string, Promise<any>>();
  for (const input of tx.inputs) {
    const txid = String(input?.transactionId ?? ""), index = Number(input?.index), expected = input?.utxo;
    const key = `${txid}:${index}`;
    if (!/^[0-9a-f]{64}$/.test(txid) || !Number.isSafeInteger(index) || index < 0 || seen.has(key)) throw new Error("Invalid or duplicate marketplace input.");
    seen.add(key);
    let old = previous.get(txid); if (!old) { old = read(`${MARKET_NODE}/transactions/${txid}`); previous.set(txid, old); }
    const origin = await old;
    if (origin?.transaction_id !== txid || origin?.is_accepted !== true || !Array.isArray(origin?.outputs)) throw new Error("Marketplace input transaction is not accepted.");
    const matches = origin.outputs.filter((output: any) => output?.index === index);
    if (matches.length !== 1) throw new Error("Marketplace input output is missing.");
    const output = matches[0], script = String(expected?.scriptPublicKey ?? "");
    if (!script.startsWith("0000") || String(output.amount) !== String(expected?.amount) || output.script_public_key !== script.slice(4) ||
        (output.covenant_id ?? null) !== (expected?.covenantId ?? null)) throw new Error("Marketplace input conflicts with the accepted on-chain output.");
    const address = String(output.script_public_key_address ?? "");
    if (!address.startsWith("kaspa:")) throw new Error("Invalid marketplace input address.");
    let rows = live.get(address); if (!rows) { rows = read(`${MARKET_NODE}/addresses/${encodeURIComponent(address)}/utxos`); live.set(address, rows); }
    const current = await rows;
    const utxos = Array.isArray(current) ? current.filter((row: any) => row?.outpoint?.transactionId === txid && row?.outpoint?.index === index) : [];
    if (utxos.length !== 1) throw new Error("Marketplace input has already been spent; refresh the offer.");
    const entry = utxos[0].utxoEntry, spk = entry?.scriptPublicKey;
    if (entry?.isCoinbase !== false || String(entry?.amount) !== String(expected?.amount) || spk?.scriptPublicKey !== script.slice(4) ||
        Number(spk?.version ?? 0) !== 0 || String(entry?.blockDaaScore) !== String(expected?.blockDaaScore))
      throw new Error("Marketplace live UTXO does not match the approved input.");
  }
}
