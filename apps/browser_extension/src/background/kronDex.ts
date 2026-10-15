import { kronBalances } from './kronHoldings';
import { formatRawTokenAmount } from '../shared/tokenAmount';

const base = 'https://kaspire.kaslab.space/dex-test-v1/kron';
const node = 'https://kaspire.kaslab.space/api/local-node';
type Side = 'buy' | 'sell';
export type KronToken = { covenantId: string; ticker: string; name: string; decimals: number; image: string; phase: string; priceKas?: string };
export type KronContext = {
  address: string; binding: string; guard(): Promise<void>;
  signal?: AbortSignal;
  balance(): Promise<string>;
  prepare(request: any): Promise<any>;
  sign(request: any, hash: string): Promise<any>;
  approve(title: string, details: string[], raw: any): Promise<boolean>;
  broadcast(bytes: string, id: string): Promise<string>;
  record(address: string, transaction: any): Promise<void>;
};
const quotes = new Map<string, { address: string; token: KronToken; side: Side; raw: string; quote: any }>();
const prepared = new Map<string, { address: string; binding: string; request: any; review: any; token: KronToken; summary: any; expires: number }>();
const inFlight = new Set<string>();
export function clearKronDexReviews() { quotes.clear(); prepared.clear(); }
export function kronDisplay(raw: any, decimals: number) {
  const value = BigInt(raw ?? 0);
  return (value < 0n ? '-' : '') + formatRawTokenAmount((value < 0n ? -value : value).toString(), decimals);
}

export async function kronJson(url: string, body?: any, signal?: AbortSignal): Promise<any> {
  const response = await fetch(url, { method: body === undefined ? 'GET' : 'POST', redirect: 'error',
    headers: { accept: 'application/json', ...(body === undefined ? {} : { 'content-type': 'application/json' }) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(45000)]) : AbortSignal.timeout(45000) });
  const text = await response.text();
  if (text.length > 4 * 1024 * 1024) throw Error('KRON response is too large.');
  let data: any; try { data = JSON.parse(text); } catch { throw Error('KRON returned an invalid response.'); }
  if (!response.ok) throw Error(String(data?.error ?? `KRON temporarily unavailable (${response.status}).`));
  return data;
}
export function parseKronAmount(value: string, decimals: number) {
  if (!Number.isInteger(decimals) || decimals < 0 || decimals > 18 || !/^\d+(\.\d+)?$/.test(value.trim()) || value.length > 80)
    throw Error('Enter a positive amount using a decimal point.');
  const [whole, fraction = ''] = value.trim().split('.');
  if (fraction.length > decimals) throw Error(`This amount supports at most ${decimals} decimal places.`);
  const raw = BigInt(whole! + fraction.padEnd(decimals, '0'));
  if (raw <= 0n || raw > 9999999999999999999n) throw Error('Enter a positive amount within the supported range.');
  return raw;
}
export async function kronTokens(): Promise<KronToken[]> {
  const rows = await kronJson(base + '/tokens');
  if (!Array.isArray(rows) || rows.length > 10000) throw Error('Invalid KRON token catalogue.');
  const seen = new Set<string>();
  for (const row of rows) {
    if (!/^[a-f0-9]{64}$/.test(row?.covenantId) || seen.has(row.covenantId) || !Number.isInteger(row.decimals) || row.decimals < 0 || row.decimals > 18 || typeof row.ticker !== 'string')
      throw Error('Invalid or duplicate KRON token.');
    seen.add(row.covenantId);
  }
  return rows;
}
export async function kronTokenContext(address: string, id: string, balance: () => Promise<string>) {
  if (!/^[a-f0-9]{64}$/.test(id)) throw Error('Invalid KRON token covenant.');
  const [tokens, rows, kas] = await Promise.all([kronTokens(), kronBalances(kronJson, address), balance()]);
  const token = tokens.find(t => t.covenantId === id);
  if (!token) throw Error('This token is no longer available on KRON.');
  const holding = rows.find((r: any) => r.covenantId === id);
  if (holding && Number(holding.dec) !== token.decimals) throw Error('KRON balance decimals differ from the verified token metadata.');
  const raw = String(holding?.balance ?? '0');
  return { token, balanceSompi: kas, holdingRaw: raw, holdingDisplay: kronDisplay(raw, token.decimals), pending: await pendingKronSwap(address) };
}
export async function getKronQuote(address: string, id: string, side: Side, amount: string, balance: () => Promise<string>) {
  if (side !== 'buy' && side !== 'sell') throw Error('Invalid swap direction.');
  const context = await kronTokenContext(address, id, balance);
  const raw = parseKronAmount(amount, side === 'buy' ? 8 : context.token.decimals);
  if (context.pending) throw Error('Resume the saved swap before starting another trade.');
  if (side === 'sell' && raw > BigInt(context.holdingRaw)) throw Error(`Insufficient ${context.token.ticker} balance. Available: ${context.holdingDisplay} ${context.token.ticker}.`);
  if (side === 'buy' && raw >= BigInt(context.balanceSompi)) throw Error('Insufficient KAS. Leave room for protocol fees, token deposits and the network fee.');
  const quote = await kronJson(base + '/quote', { tokenId: id, side, rawAmount: raw.toString() });
  if (quote.tokenId !== id || quote.side !== side || quote.decimals !== context.token.decimals || quote.ref !== 'kaspirewallet' || !/^\d+$/.test(String(quote.tokenAmount)) || !/^\d+$/.test(String(quote.netKasSompi)) || !Number.isFinite(quote.quoteExpiresAt) || quote.quoteExpiresAt <= Date.now())
    throw Error('Invalid or expired KRON quote.');
  if (side === 'buy' && BigInt(quote.netKasSompi) + 50000000n > BigInt(context.balanceSompi)) throw Error('Insufficient KAS for the trade, protocol fees and token deposit.');
  const quoteId = crypto.randomUUID();
  for (const [key, saved] of quotes) if (saved.quote.quoteExpiresAt <= Date.now()) quotes.delete(key);
  if (quotes.size >= 100) quotes.delete(quotes.keys().next().value!);
  quotes.set(quoteId, { address, token: context.token, side, raw: raw.toString(), quote });
  return { ...quote, quoteId, rawAmount: raw.toString(), token: context.token };
}

// Same own-node checks as Android. Addresses are lookup hints, not evidence.
export async function verifyKronInputs(request: any, get: typeof kronJson = kronJson, signal?: AbortSignal) {
  signal?.throwIfAborted();
  const tx = JSON.parse(request.txJsonString), inputs = tx.inputs, addresses = request.tradeSummary?.inputAddresses;
  if (!Array.isArray(inputs) || !inputs.length || inputs.length > 100 || !Array.isArray(addresses) || inputs.length !== addresses.length || addresses.some(a => typeof a !== 'string' || !/^kaspa:[a-z0-9]{61,63}$/.test(a)))
    throw Error('Incomplete KRON input verification data.');
  const live = new Map<string, any[]>(), origins = new Map<string, any>();
  for (const address of new Set<string>(addresses)) {
    const rows = await get(`${node}/addresses/${encodeURIComponent(address)}/utxos`, undefined, signal);
    if (!Array.isArray(rows)) throw Error('Invalid node UTXO response.');
    live.set(address, rows);
  }
  for (let i = 0; i < inputs.length; i++) {
    signal?.throwIfAborted();
    const input = inputs[i], embedded = input.utxo;
    if (!/^[a-f0-9]{64}$/.test(input.transactionId) || !Number.isInteger(input.index) || !embedded) throw Error('Invalid swap outpoint.');
    const matches = live.get(addresses[i])!.filter(row => row.outpoint?.transactionId === input.transactionId && row.outpoint?.index === input.index);
    if (matches.length !== 1) throw Error('The market or wallet output was already spent. Get a fresh quote.');
    const entry = matches[0].utxoEntry, spk = entry?.scriptPublicKey;
    const version = spk?.version ?? 0;
    if (!Number.isInteger(version) || version < 0 || version > 65535) throw Error('Invalid node script version.');
    const script = version.toString(16).padStart(4, '0') + String(spk?.script ?? spk?.scriptPublicKey);
    if (!origins.has(input.transactionId)) origins.set(input.transactionId, await get(`${node}/transactions/${input.transactionId}`, undefined, signal));
    const origin = origins.get(input.transactionId), outputs = (origin?.outputs ?? []).filter((o: any) => o.index === input.index);
    if (origin?.is_accepted !== true || origin.transaction_id !== input.transactionId || outputs.length !== 1 || (outputs[0].covenant_id ?? null) !== (embedded.covenantId ?? null))
      throw Error('Swap covenant differs from the confirmed node transaction.');
    if (String(entry.amount) !== String(embedded.amount) || script !== embedded.scriptPublicKey || String(entry.blockDaaScore) !== String(embedded.blockDaaScore) || entry.isCoinbase !== embedded.isCoinbase)
      throw Error('Swap UTXO data differs from the own-node result.');
  }
}
export function validateKronPlan(request: any, address: string, tokenId: string, side: Side, raw: string, minimum: string) {
  const terms = request?.tradeSummary;
  if (request?.sender !== address || request.profile !== 'kron-swap-v1' || request.tokenId !== tokenId || request.side !== side || terms?.rawAmount !== raw || terms?.minimumReceive !== minimum || terms?.ref !== 'kaspirewallet')
    throw Error('KRON plan does not match your selected trade.');
}
export async function prepareKronSwap(context: KronContext, quoteId: string) {
  await context.guard();
  if (await pendingKronSwap(context.address)) throw Error('Resume the saved swap before starting another trade.');
  const saved = quotes.get(quoteId);
  if (!saved || saved.address !== context.address || saved.quote.quoteExpiresAt <= Date.now()) throw Error('Quote expired. Get a fresh quote.');
  quotes.delete(quoteId);
  const minimum = (BigInt(saved.side === 'buy' ? saved.quote.tokenAmount : saved.quote.netKasSompi) * 99n / 100n).toString();
  const plan = await kronJson(base + '/plan', { address: context.address, tokenId: saved.token.covenantId, side: saved.side, rawAmount: saved.raw, minimumReceive: minimum }, context.signal);
  const request = plan.request;
  validateKronPlan(request, context.address, saved.token.covenantId, saved.side, saved.raw, minimum);
  await verifyKronInputs(request, kronJson, context.signal); await context.guard();
  const review = await context.prepare(request); await context.guard();
  const sum = (rows: any[]) => rows.reduce((s, r) => s + BigInt(r.amountSompi), 0n);
  const summary = { ...request.tradeSummary, networkFeeSompi: review.feeSompi,
    walletKasChangeSompi: (sum(review.outputs.filter((r: any) => r.returnsToWallet)) - sum(review.inputs.filter((r: any) => r.selected))).toString() };
  const id = crypto.randomUUID();
  if (prepared.size >= 100) prepared.delete(prepared.keys().next().value!);
  prepared.set(id, { address: context.address, binding: context.binding, request, review, token: saved.token, summary, expires: Date.now() + 10 * 60000 });
  return { id, token: saved.token, summary, review, rawPlan: request };
}
const pendingKey = (address: string) => `kronSwapRecoveryV1:${address}`;
export async function pendingKronSwap(address: string) { return (await chrome.storage.local.get(pendingKey(address)))[pendingKey(address)] ?? null; }
export function kronSwapDetails(summary: any, token: KronToken) {
  const kas = (v: any) => kronDisplay(v, 8) + ' KAS';
  return [
    `Token amount: ${kronDisplay(summary.tokenAmount, token.decimals)} ${token.ticker}`,
    `${summary.side === 'buy' ? 'KAS into swap' : 'Gross KAS returned'}: ${kas(summary.grossKasSompi)}`,
    `${summary.side === 'buy' ? 'Trade + protocol fees' : 'Net KAS returned'}: ${kas(summary.netKasSompi)}`,
    `Creator fee: ${kas(summary.creatorFeeSompi)}`, `Protocol fee: ${kas(summary.platformFeeSompi)}`,
    ...(BigInt(summary.devFundFeeSompi ?? 0) ? [`Dev fund fee: ${kas(summary.devFundFeeSompi)}`] : []),
    ...(BigInt(summary.lpFeeSompi ?? 0) ? [`LP fee (included): ${kas(summary.lpFeeSompi)}`] : []),
    ...(summary.networkFeeSompi == null ? [] : [`Network fee: ${kas(summary.networkFeeSompi)}`]),
    ...(summary.walletKasChangeSompi == null ? [] : [`Wallet KAS change: ${kas(summary.walletKasChangeSompi)}`]),
  ];
}
async function exclusive<T>(address: string, run: () => Promise<T>) {
  if (inFlight.has(address)) throw Error('A swap is already in progress.');
  inFlight.add(address); try { return await run(); } finally { inFlight.delete(address); }
}
async function broadcastSavedSwap(context: KronContext, receipt: any) {
  // A node may accept the transaction but fail to acknowledge it. Release the
  // volatile operation after interruption/timeout, NEVER the durable receipt.
  // Only a resume of these same signed bytes is then allowed.
  const signal = AbortSignal.any([AbortSignal.timeout(45000), ...(context.signal ? [context.signal] : [])]);
  signal.throwIfAborted();
  let abort: () => void = () => {};
  const interrupted = new Promise<never>((_, reject) => {
    abort = () => reject(Error('Swap submission interrupted. The signed swap is saved; resume it before starting another trade.'));
    signal.addEventListener('abort', abort, { once: true });
  });
  try {
    return await Promise.race([context.broadcast(receipt.signedTxJson, receipt.transactionId), interrupted]);
  } finally { signal.removeEventListener('abort', abort); }
}
async function submitReceipt(context: KronContext, receipt: any) {
  await context.guard();
  if (receipt.address !== context.address || !/^[a-f0-9]{64}$/.test(receipt.transactionId) || typeof receipt.signedTxJson !== 'string') throw Error('Invalid saved swap.');
  const id = await broadcastSavedSwap(context, receipt);
  if (id !== receipt.transactionId) throw Error('Node returned a mismatching swap transaction ID.');
  await context.record(context.address, { transactionId: id, blockTime: receipt.timestamp, incoming: receipt.summary.side === 'buy', assetKind: 'KCC20',
    assetSymbol: receipt.token.ticker, displayAmount: kronDisplay(receipt.summary.tokenAmount, receipt.token.decimals), covenantId: receipt.token.covenantId,
    type: 'kron-swap', standard: 'kron-native', operationLabel: receipt.summary.side === 'buy' ? 'KRON Buy' : 'KRON Sell', rawJson: receipt });
  await chrome.storage.local.remove(pendingKey(context.address));
  for (const [key, value] of quotes) if (value.address === context.address) quotes.delete(key);
  for (const [key, value] of prepared) if (value.address === context.address) prepared.delete(key);
  return receipt;
}
export async function submitKronSwap(context: KronContext, id: string) {
  return exclusive(context.address, async () => {
    await context.guard();
    if (await pendingKronSwap(context.address)) throw Error('Resume the saved swap before starting another trade.');
    const saved = prepared.get(id);
    if (!saved || saved.address !== context.address || saved.binding !== context.binding || saved.expires <= Date.now()) throw Error('Secure swap review expired. Review the swap again.');
    prepared.delete(id);
    if (!await context.approve(`${saved.summary.side === 'buy' ? 'Buy' : 'Sell'} ${saved.token.ticker}`, [...kronSwapDetails(saved.summary, saved.token), `Token covenant: ${saved.token.covenantId}`, `Market covenant: ${saved.summary.marketId}`, 'Slippage limit: 1%. Partner attribution does not add a fee.'], saved.request)) throw Error('Swap rejected.');
    await context.guard(); await verifyKronInputs(saved.request, kronJson, context.signal); await context.guard();
    const signed = await context.sign(saved.request, saved.review.reviewHash);
    const receipt = { address: context.address, timestamp: Date.now(), token: saved.token, summary: saved.summary, transactionId: signed.transactionId, signedTxJson: signed.wrpcJson };
    if (!receipt.signedTxJson || receipt.transactionId !== saved.review.transactionId) throw Error('Signed swap differs from the reviewed transaction.');
    await chrome.storage.local.set({ [pendingKey(context.address)]: receipt });
    return submitReceipt(context, receipt);
  });
}
export async function resumeKronSwap(context: KronContext) {
  return exclusive(context.address, async () => {
    const saved = await pendingKronSwap(context.address);
    if (!saved) throw Error('No saved swap for this wallet.');
    // A successful earlier submit may have timed out. Check the own node first.
    let confirmed = false;
    try { const tx = await kronJson(`${node}/transactions/${saved.transactionId}`, undefined, context.signal); confirmed = tx.is_accepted === true && tx.transaction_id === saved.transactionId; }
    catch { /* Otherwise rebroadcast exactly the durable signed bytes. */ }
    return submitReceipt(confirmed ? { ...context, broadcast: async () => saved.transactionId } : context, saved);
  });
}
