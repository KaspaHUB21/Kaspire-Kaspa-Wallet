import { parseVaultJson } from './covenantVaults';
import { formatRawTokenAmount } from '../shared/tokenAmount';

type Row = Record<string, any>;
export type P2shState = { descriptor: string; receiveCount: number; changeCount: number; exposed: string[]; pending?: Row };
export type P2shContext = {
  walletId: string; binding: string; signal?: AbortSignal;
  clock?(): number; delay?(ms: number): Promise<void>;
  guard(): Promise<void>; load(): P2shState; save(state: P2shState): Promise<void>;
  derive(branch: number, start: number, count: number): Promise<Row[]>;
  validate(address: Row, rows: Row[]): Promise<string>;
  prepare(request: Row): Promise<Row>; sign(request: Row, hash: string): Promise<Row>;
  verify(saved: Row): Promise<void>;
  approve(details: string[], request: Row): Promise<boolean>;
  progress(message: string): void;
};
export const P2SH_DESCRIPTOR = 'kip22-p2sh-v1';
const node = 'https://kaspire.kaslab.space/api/local-node';
const history = 'https://kaspire.kaslab.space/api';
// /local-node is a read-only gateway namespace. POST must use the same
// transaction route as Android; the gateway does not strip that prefix on POST.
const submitEndpoint = `${history}/transactions`;
const reviews = new Map<string, { binding: string; request: Row; review: Row; expires: number }>();
const operations = new Set<string>();
type ReadLane = { next: number; cooldown: number; queue: Promise<unknown> };
const nodeReads: ReadLane = { next: 0, cooldown: 0, queue: Promise.resolve() };
const historyReads: ReadLane = { next: 0, cooldown: 0, queue: Promise.resolve() };
export function clearP2shReviews() { reviews.clear(); activityPages.clear(); }
const activityPages = new Map<string, {addresses:Row[]; offsets:Map<string,number|null>; transactions:Map<string,Row>}>();
export const emptyP2shState = (): P2shState => ({ descriptor: P2SH_DESCRIPTOR, receiveCount: 0, changeCount: 0, exposed: [] });
export const p2shKas = (raw: unknown) => formatRawTokenAmount(String(raw), 8) + ' KAS';
export function parseP2shKas(text: string) {
  if (!/^\d+(\.\d{1,8})?$/.test(text) || text.length > 40) throw Error('Enter a KAS amount with at most 8 decimal places.');
  const [whole, fraction = ''] = text.split('.'), amount = BigInt(whole! + fraction.padEnd(8, '0'));
  if (amount < 10000n || amount > 2870000000000000000n) throw Error('Amount is outside the allowed range.');
  return amount.toString();
}
export function validateP2shState(value: unknown): P2shState {
  const s = value as P2shState;
  if (s?.descriptor === 'kaspire-hidden-kas-v1' && s.receiveCount === 0 && s.changeCount === 0 && Array.isArray(s.exposed) && !s.exposed.length && !s.pending) return emptyP2shState();
  if (s?.descriptor !== P2SH_DESCRIPTOR || ![s.receiveCount, s.changeCount].every(n => Number.isInteger(n) && n >= 0 && n <= 10000) || !Array.isArray(s.exposed) || s.exposed.length > 20000) throw Error('Invalid P2SH recovery journal. Existing data was preserved.');
  const unique = new Set<string>();
  for (const key of s.exposed) {
    if (typeof key !== 'string' || !/^[01]:(0|[1-9]\d{0,3})$/.test(key)) throw Error('Invalid P2SH key-exposure record.');
    const [branch, index] = key.split(':').map(Number);
    if (index! >= (branch === 0 ? s.receiveCount : s.changeCount) || unique.has(key)) throw Error('P2SH exposure outside the issued range.');
    unique.add(key);
  }
  if (s.pending) {
    if (!/^[0-9a-f]{64}$/.test(s.pending.transactionId) || typeof s.pending.submitJson !== 'string' || s.pending.submitJson.length > 1024 * 1024 || !s.pending.request) throw Error('Invalid saved P2SH payment.');
    const entries = [...(s.pending.request.signers ?? []), s.pending.request.change];
    for (const a of entries) if (!a || !unique.has(`${a.branch}:${a.index}`)) throw Error('Saved payment has unretired input or change keys.');
  }
  return structuredClone(s);
}
const key = (a: Row) => `${a.branch}:${a.index}`;
const now = (context: P2shContext) => context.clock?.() ?? Date.now();
async function sleep(ms: number, context: P2shContext) {
  context.signal?.throwIfAborted();
  if (context.delay) { await context.delay(ms); await context.guard(); return; }
  await new Promise<void>((resolve, reject) => {
    const done = () => { clearTimeout(timer); context.signal?.removeEventListener('abort', abort); resolve(); };
    const abort = () => { clearTimeout(timer); context.signal?.removeEventListener('abort', abort); reject(Error('The account view was closed. Saved payments remain preserved.')); };
    const timer = setTimeout(done, ms);
    context.signal?.addEventListener('abort', abort, { once: true });
  });
  await context.guard();
}
async function read(context: P2shContext, url: string, missing = false): Promise<any> {
  // A public indexer cooldown must never stall own-node confirmation/UTXOs.
  const lane = url.startsWith(node + '/') ? nodeReads : historyReads;
  for (let attempt = 0; attempt < 3; attempt++) {
    const slot = lane.queue.then(async () => {
      await context.guard();
      while (true) {
        const wait = Math.max(lane.next, lane.cooldown) - now(context);
        if (wait > 30000) throw Error('Account data is temporarily rate-limited. Please wait and refresh.');
        if (wait <= 0) break;
        await sleep(wait, context);
      }
      lane.next = now(context) + 100;
    });
    lane.queue = slot.catch(() => {}); await slot;
    const response = await fetch(url, { cache: 'no-store', redirect: 'error', signal: AbortSignal.any([AbortSignal.timeout(15000), ...(context.signal ? [context.signal] : [])]) });
    await context.guard();
    if (response.status === 429) {
      const retry = response.headers.get('retry-after'), seconds = retry == null ? NaN : Number(retry);
      const delay = Number.isFinite(seconds) && seconds >= 0 ? seconds * 1000 : retry && Number.isFinite(Date.parse(retry)) ? Math.max(0, Date.parse(retry) - now(context)) : 1000 * 2 ** attempt;
      lane.cooldown = Math.max(lane.cooldown, now(context) + delay);
      if (attempt === 2 || delay > 30000) throw Error('Account data is temporarily rate-limited. Please wait and refresh. Saved payments remain preserved.');
      continue;
    }
    if (missing && response.status === 404) return null;
    if (!response.ok) throw Error(`Account lookup unavailable (${response.status}). Saved addresses and signed payments remain preserved.`);
    const raw = await response.text();
    if (raw.length > 8 * 1024 * 1024) throw Error('Account response is too large.');
    return parseVaultJson(raw);
  }
  throw Error('Account lookup unavailable.');
}
async function observe(context: P2shContext, used: Row[]) {
  const state = validateP2shState(context.load()), known = new Set(state.exposed);
  for (const a of used) {
    if (![0, 1].includes(a.branch) || !Number.isInteger(a.index) || a.index < 0 || a.index >= 10000) throw Error('Invalid P2SH derivation coordinates.');
    const name = a.branch === 0 ? 'receiveCount' : 'changeCount';
    state[name] = Math.max(state[name], a.index + 1); known.add(key(a));
  }
  state.exposed = [...known];
  await context.guard();
  if (JSON.stringify(state) !== JSON.stringify(context.load())) await context.save(state);
  return state;
}
async function issue(context: P2shContext, branch: number) {
  const state = validateP2shState(context.load());
  if (state.pending) throw Error('Finish the saved payment before generating another address.');
  const name = branch === 0 ? 'receiveCount' : 'changeCount', index = state[name];
  if (branch === 1 && index > 0 && !state.exposed.includes(`1:${index - 1}`)) return (await context.derive(1, index - 1, 1))[0]!;
  const highest = Math.max(-1, ...state.exposed.filter(k => k.startsWith(`${branch}:`)).map(k => Number(k.split(':')[1])));
  if (index >= 10000 || index - highest > 20) throw Error('Discovery gap limit reached. Use an issued address before generating more, and keep the encrypted backup.');
  const address = (await context.derive(branch, index, 1))[0]!;
  state[name]++; await context.save(state); // Durable BEFORE exposing the address to the UI.
  return address;
}
async function scan(context: P2shContext) {
  const state = validateP2shState(context.load()), retired = new Set(state.exposed);
  const addresses: Row[] = [], utxos: Row[] = [], used: Row[] = [], points = new Set<string>();
  let checked = 0, total = 0n;
  for (let branch = 0; branch < 2; branch++) {
    const issued = branch === 0 ? state.receiveCount : state.changeCount;
    let start = 0, lastUsed = -1;
    while (start < Math.max(issued, lastUsed + 21)) {
      const target = Math.max(issued, lastUsed + 21);
      if (target > 10000) throw Error('Discovery reached the scan limit. Keep the encrypted backup; no address will be reused.');
      const batch = await context.derive(branch, start, Math.min(20, target - start));
      if (!batch.length) throw Error('P2SH derivation returned no addresses.');
      for (let offset = 0; offset < batch.length; offset += 5) {
        const group = batch.slice(offset, offset + 5);
        const responses = await Promise.all(group.map(async a => {
          const encoded = encodeURIComponent(a.address);
          const [rows, activity] = await Promise.all([
            read(context, `${node}/addresses/${encoded}/utxos`),
            retired.has(key(a)) ? Promise.resolve([true]) : read(context, `${node}/addresses/${encoded}/full-transactions?limit=1&offset=0&resolve_previous_outpoints=light`),
          ]);
          if (!Array.isArray(rows) || !Array.isArray(activity)) throw Error('Incomplete account discovery response. Receiving and signing remain disabled.');
          const amount = await context.validate(a, rows);
          return { rows, activity, amount };
        }));
        for (let i = 0; i < group.length; i++) {
          const a = group[i]!, response = responses[i]!;
          for (const row of response.rows) {
            const point = `${row.outpoint?.transactionId}:${row.outpoint?.index}`;
            if (points.has(point)) throw Error('Duplicate P2SH output from the node.');
            points.add(point); row.address = a.address;
          }
          if (response.rows.length || response.activity.length) { used.push(a); lastUsed = a.index; }
          addresses.push(a); utxos.push(...response.rows); total += BigInt(response.amount);
        }
        checked += group.length; context.progress(`Checking account · ${checked} addresses`);
      }
      start += batch.length;
    }
  }
  return { state: await observe(context, used), addresses, utxos, balanceSompi: total.toString() };
}
async function activity(context: P2shContext, addresses: Row[], more = false) {
  const owned = new Set(addresses.map(a => a.address));
  // Only addresses with confirmed history/outputs need an activity request.
  const retired = new Set(context.load().exposed);
  if(!more||!activityPages.has(context.binding)) {
    activityPages.set(context.binding,{addresses,offsets:new Map(addresses.filter(a=>retired.has(key(a))).map(a=>[a.address,0])),transactions:new Map()});
  }
  const pager=activityPages.get(context.binding)!,{transactions}=pager;
  for (const [address,offset] of pager.offsets) {
    if(offset===null)continue;
    const rows = await read(context, `${node}/addresses/${encodeURIComponent(address)}/full-transactions?limit=50&offset=${offset}&resolve_previous_outpoints=light`);
    if (!Array.isArray(rows)) throw Error('Account activity lookup unavailable.');
    for (const row of rows) if (/^[0-9a-f]{64}$/.test(row.transaction_id) && row.is_accepted === true) transactions.set(row.transaction_id, row);
    pager.offsets.set(address,rows.length<50?null:offset+50);
  }
  const items=[...transactions.values()].map(tx => {
    let incoming = 0n, outgoing = 0n;
    for (const input of tx.inputs ?? []) if (owned.has(input.previous_outpoint_address)) outgoing += BigInt(String(input.previous_outpoint_amount));
    for (const output of tx.outputs ?? []) if (owned.has(output.script_public_key_address)) incoming += BigInt(String(output.amount));
    const net = incoming - outgoing;
    return { transactionId: tx.transaction_id, amountSompi: (net < 0n ? -net : net).toString(), incoming: net >= 0n, timestamp: tx.block_time ?? 0 };
  }).sort((a, b) => Number(b.timestamp) - Number(a.timestamp));
  return {transactions:items,historyHasMore:[...pager.offsets.values()].some(offset=>offset!==null)};
}
async function confirmed(context: P2shContext, pending: Row) {
  await context.verify(pending);
  const tx = await read(context, `${node}/transactions/${pending.transactionId}`, true);
  if (tx == null) return false;
  if (tx.transaction_id !== pending.transactionId || tx.is_accepted !== true) return false;
  await context.guard();
  const state = validateP2shState(context.load());
  if (state.pending?.transactionId !== pending.transactionId) throw Error('The saved P2SH payment changed.');
  delete state.pending; await context.save(state); return true;
}
function submissionDetail(data: any): string {
  const detail = data?.detail ?? data?.error?.message ?? data?.message;
  const text = typeof detail === 'string' ? detail : Array.isArray(detail)
    ? detail.slice(0, 3).map(item => typeof item?.msg === 'string' ? item.msg : '').filter(Boolean).join('; ') : '';
  return text.replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, 400);
}
async function resume(context: P2shContext) {
  const pending = validateP2shState(context.load()).pending;
  if (!pending) return { confirmed: false, pending: false };
  context.progress('Checking saved payment…');
  if (await confirmed(context, pending)) return { confirmed: true, transactionId: pending.transactionId };
  // A previous encrypted-storage write may have failed after setting volatile
  // state. Re-commit the exact journal before EVERY possible POST, including
  // resume, rather than trusting that an in-memory pending entry is durable.
  const durable = validateP2shState(context.load());
  if (durable.pending?.transactionId !== pending.transactionId) throw Error('The saved P2SH payment changed.');
  await context.save(durable);
  await context.guard(); context.progress('Submitting saved payment…');
  let response: Response | undefined, receipt: any, submissionIssue = '';
  try {
    response = await fetch(submitEndpoint, { method: 'POST', redirect: 'error', headers: { 'content-type': 'application/json', accept: 'application/json' }, body: pending.submitJson, signal: AbortSignal.any([AbortSignal.timeout(15000), ...(context.signal ? [context.signal] : [])]) });
    const raw = await response.text();
    if (raw.length <= 65536) {
      try { receipt = JSON.parse(raw); } catch { /* A malformed receipt is not confirmation. */ }
    }
  } catch {
    // The node may have accepted the bytes before the response was interrupted.
    // Keep this separate from definitive HTTP rejection and ID mismatch below.
    submissionIssue = 'The submission connection was interrupted or timed out.';
  }
  await context.guard();
  if (response) {
    if (response.ok) {
      const id = receipt?.transactionId ?? receipt?.transaction_id;
      if (id != null && id !== pending.transactionId) throw Error('The node returned a different transaction ID. The original signed payment remains saved; do not create a second payment.');
      if (!receipt) submissionIssue ||= 'The endpoint returned an unreadable submission receipt.';
    } else {
      const detail = submissionDetail(receipt);
      submissionIssue = `Submission rejected (HTTP ${response.status})${detail ? `: ${detail}` : ''}`;
      const alreadyKnown = /already (?:known|in (?:the )?mempool|accepted|exists)|already been accepted|duplicate transaction/i.test(detail);
      if (!alreadyKnown && response.status >= 400 && response.status < 500 && ![408, 425, 429].includes(response.status)) {
        // Reconcile a possible acceptance race once, but never disguise an
        // explicit rejection as another thirty-second confirmation wait.
        if (await confirmed(context, pending)) return { confirmed: true, transactionId: pending.transactionId };
        throw Error(`${submissionIssue}. The exact signed payment remains saved. Fix or retry this saved payment; do not create a second payment.`);
      }
    }
  }
  await context.guard(); context.progress('Waiting for own-node confirmation…');
  const deadline = now(context) + 30000;
  while (true) {
    if (await confirmed(context, pending)) return { confirmed: true, transactionId: pending.transactionId };
    if (now(context) >= deadline) break;
    await sleep(2000, context);
  }
  return { confirmed: false, pending: true, transactionId: pending.transactionId, ...(submissionIssue ? { submissionIssue } : {}) };
}
async function execute(context: P2shContext, message: Row): Promise<any> {
  await context.guard();
  if (message.command === 'p2shState') return validateP2shState(context.load());
  if (message.command === 'p2shHistoryMore') {
    const pager=activityPages.get(context.binding);
    if(!pager)throw Error('Refresh the P2SH account before loading older history.');
    return activity(context,pager.addresses,true);
  }
  if (message.command === 'p2shRefresh') {
    if (context.load().pending) return { payment: await resume(context), state: context.load() };
    const snapshot = await scan(context);
    const available = snapshot.addresses.filter(a => a.branch === 0 && a.index < snapshot.state.receiveCount && !snapshot.state.exposed.includes(key(a)));
    const receiving = available.at(-1) ?? await issue(context, 0);
    let result = {transactions:[] as Row[],historyHasMore:false}, activityError = '';
    try { result = await activity(context, snapshot.addresses); } catch (e) { activityError = (e as Error).message; }
    return { ...snapshot, state: context.load(), receive: receiving, ...result, activityError };
  }
  if (message.command === 'p2shReceive') {
    const snapshot = await scan(context), s = snapshot.state;
    if (s.pending) throw Error('Finish the saved payment before receiving again.');
    const available = snapshot.addresses.filter(a => a.branch === 0 && a.index < s.receiveCount && !s.exposed.includes(key(a)));
    return { address: message.fresh || !available.length ? await issue(context, 0) : available.at(-1), state: context.load() };
  }
  if (message.command === 'p2shPrepare') {
    const recipient = String(message.recipient ?? '').trim();
    if (!recipient) throw Error('Enter a Kaspa Mainnet recipient address before reviewing the payment.');
    const sendAll = message.sendAll === true, amount = sendAll ? '0' : parseP2shKas(String(message.amount ?? '').trim());
    const snapshot = await scan(context);
    if (snapshot.state.pending) throw Error('Finish the saved payment first.');
    if (!snapshot.utxos.length) throw Error('No spendable KAS is available in this P2SH account.');
    const signers = snapshot.addresses.filter(a => snapshot.utxos.some(row => row.address === a.address));
    const change = await issue(context, 1);
    const data = await read(context, `${node}/info/fee-estimate`);
    const feeRate = Math.max(100, Number(data.priorityBucket?.feerate ?? data.normalBuckets?.[0]?.feerate ?? 100));
    if (!Number.isFinite(feeRate) || feeRate > 1000) throw Error('Network fee exceeds the safety limit. Try again later.');
    const request = { descriptor: P2SH_DESCRIPTOR, recipient, amountSompi: amount, ...(sendAll ? { sendAll: true } : {}), feeRate, signers, change, utxosJson: JSON.stringify(snapshot.utxos) };
    await verifyRequest(context, request);
    const review = await context.prepare(request);
    for (const [id, item] of reviews) if (item.expires <= now(context)) reviews.delete(id);
    if (reviews.size >= 32) throw Error('Too many pending P2SH reviews. Close another view first.');
    const id = crypto.randomUUID(); reviews.set(id, { binding: context.binding, request, review, expires: now(context) + 600000 });
    return { id, review };
  }
  if (message.command === 'p2shSubmit') {
    const prepared = reviews.get(String(message.id));
    if (!prepared || prepared.binding !== context.binding || prepared.expires <= now(context)) throw Error('P2SH review expired. Review the payment again.');
    const { request, review } = prepared;
    if (!await context.approve([`Recipient: ${review.recipient}`, `Amount${review.sendAll ? ' (Max)' : ''}: ${p2shKas(review.amountSompi)}`, `Network fee: ${p2shKas(review.feeSompi)}`, `Fresh P2SH change: ${p2shKas(review.changeSompi)}`, `Inputs: ${review.inputCount}`, 'Signing reveals the spending keys; do not reuse these addresses.'], request)) throw Error('Payment rejected. Nothing was signed.');
    await context.guard(); await verifyRequest(context, request);
    const live: Row[] = [];
    for (const a of request.signers) {
      const rows = await read(context, `${node}/addresses/${encodeURIComponent(a.address)}/utxos`);
      if (!Array.isArray(rows)) throw Error('Cannot verify live P2SH outputs.');
      await context.validate(a, rows); rows.forEach((r: Row) => { r.address = a.address; live.push(r); });
    }
    const identities = (rows: Row[]) => rows.map(r => `${r.address}:${r.outpoint.transactionId}:${r.outpoint.index}:${r.utxoEntry.amount}:${r.utxoEntry.blockDaaScore}:${r.utxoEntry.isCoinbase}:${r.utxoEntry.scriptPublicKey.version ?? 0}:${r.utxoEntry.scriptPublicKey.scriptPublicKey}`).sort().join('\n');
    if (identities(live) !== identities(parseVaultJson(request.utxosJson))) throw Error('Spendable outputs changed during review. Review again; nothing was signed.');
    const rebuilt = await context.prepare(request);
    if (rebuilt.reviewHash !== review.reviewHash) throw Error('P2SH payment terms changed. Review again.');
    await observe(context, [...request.signers, request.change]); // Durable retirement BEFORE signing.
    reviews.delete(String(message.id)); await context.guard();
    const signed = await context.sign(request, review.reviewHash);
    const state = validateP2shState(context.load());
    if (state.pending) throw Error('A saved payment already exists. No signed bytes may leave the background.');
    state.pending = { ...signed, request }; await context.save(state); // Durable BEFORE any broadcast.
    return resume(context);
  }
  if (message.command === 'p2shResume') return resume(context);
  throw Error('Unknown P2SH command.');
}
async function verifyRequest(context: P2shContext, request: Row) {
  const s = validateP2shState(context.load());
  if (s.pending) throw Error('Finish the saved payment first.');
  if (request.descriptor !== P2SH_DESCRIPTOR || request.change.branch !== 1 || request.change.index !== s.changeCount - 1 || s.exposed.includes(key(request.change))) throw Error('Change address is not the latest unexposed reservation.');
  const retired: Row[] = [];
  for (const coordinate of s.exposed) { const [branch, index] = coordinate.split(':').map(Number); retired.push(...await context.derive(branch!, index!, 1)); }
  for (const a of [...request.signers, request.change, ...retired]) {
    if (a.address === request.recipient) throw Error('Recipient is a retired or spending address of this P2SH account. Choose a fresh receiving address.');
    if (![0, 1].includes(a.branch) || a.index < 0 || a.index >= (a.branch === 0 ? s.receiveCount : s.changeCount)) throw Error('Unissued P2SH address.');
  }
}
export async function p2shCommand(context: P2shContext, message: Row) {
  if (operations.has(context.walletId)) throw Error('A P2SH operation is already in progress. Wait for it to finish.');
  operations.add(context.walletId);
  try { return await execute(context, message); }
  finally { operations.delete(context.walletId); }
}
