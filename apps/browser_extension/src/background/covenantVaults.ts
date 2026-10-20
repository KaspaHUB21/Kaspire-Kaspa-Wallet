import { core } from './core';
import { broadcastKcc20 } from './api';
import { formatRawTokenAmount } from '../shared/tokenAmount';

export const VAULT_PROTOCOL = 'kaspire-covenant-vault-v1';
const node = 'https://kaspire.kaslab.space/api/local-node';
const storageKey = 'covenantVaultsV1';
type Row = Record<string, any>;
export type VaultItem = { record: Row; pending?: Row };
export type VaultContext = {
  address: string; binding: string; signal?: AbortSignal;
  guard(): Promise<void>;
  sign(request: Row, hash: string): Promise<Row>;
  approve(title: string, details: string[], request: Row): Promise<boolean>;
};
type Prepared = { request: Row; review: Row; previous?: Row; binding: string; expires: number; recoverySaved: boolean };
const prepared = new Map<string, Prepared>();
const inFlight = new Set<string>();
let writes: Promise<unknown> = Promise.resolve();
export function clearCovenantVaultReviews() { prepared.clear(); }
const clone = <T>(value: T): T => structuredClone(value);
const hash = (value: unknown): value is string => typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
const number = (value: unknown) => {
  if (typeof value === 'number' && !Number.isSafeInteger(value)) throw Error('The node returned an imprecise vault amount. Nothing was signed.');
  if (!/^\d+$/.test(String(value))) throw Error('Invalid vault amount or DAA score.');
  return BigInt(String(value));
};
export const vaultKas = (value: unknown) => `${formatRawTokenAmount(number(value).toString(), 8)} KAS`;
export function parseVaultKas(text: string) {
  if (!/^\d+(\.\d{1,8})?$/.test(text) || text.length > 40) throw Error('Enter a KAS amount with at most 8 decimal places.');
  const [whole, fraction = ''] = text.split('.');
  const raw = BigInt(whole! + fraction.padEnd(8, '0'));
  if (raw < 100000000n || raw > 2870000000000000000n) throw Error('Vault amount must be at least 1 KAS and within the Kaspa supply.');
  return raw.toString();
}
export function parseVaultJson(text: string) {
  // Preserve u64 values before JSON.parse can round them. Quoted strings are
  // skipped as complete tokens, including escaped quotes and number-like names.
  return JSON.parse(text.replace(/"(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/g, token => {
    if (token.startsWith('"') || /[.eE]/.test(token)) return token;
    const n = BigInt(token);
    return n > BigInt(Number.MAX_SAFE_INTEGER) || n < BigInt(Number.MIN_SAFE_INTEGER) ? JSON.stringify(token) : token;
  }));
}
export async function vaultGet(path: string, missing = false, signal?: AbortSignal): Promise<any> {
  const response = await fetch(node + path, { signal: AbortSignal.any([AbortSignal.timeout(20000), ...(signal ? [signal] : [])]), cache: 'no-store' });
  if (missing && response.status === 404) return null;
  if (!response.ok) throw Error(`The Kaspire node is unavailable (${response.status}). Saved vaults remain safe.`);
  const text = await response.text();
  if (text.length > 8 * 1024 * 1024) throw Error('Node response too large.');
  return parseVaultJson(text);
}
export async function vaultDaa(signal?: AbortSignal) {
  const data = await vaultGet('/info/blockdag', false, signal);
  if (data.networkName !== 'kaspa-mainnet' || number(data.virtualDaaScore) <= 0n || number(data.virtualDaaScore) >= 500000000000n) throw Error('The local node did not report a valid Mainnet DAA score.');
  return Number(data.virtualDaaScore);
}
async function validate(record: Row): Promise<Row> {
  return JSON.parse((await core()).validateVaultRecord(JSON.stringify(record)));
}
async function all(): Promise<VaultItem[]> {
  await writes;
  const rows = (await chrome.storage.local.get(storageKey))[storageKey] ?? [];
  if (!Array.isArray(rows) || rows.length > 10000) throw Error('Vault catalogue is damaged. Import a recovery file; existing data was preserved.');
  return rows;
}
export async function vaultSaved(address: string): Promise<VaultItem[]> {
  const items = (await all()).filter(item => item.record?.terms?.owner === address || item.record?.terms?.beneficiary === address);
  for (const item of items) await validate(item.record);
  return items;
}
async function put(item: VaultItem, onlyIfAbsent = false, expected?: VaultItem) {
  const validated = { ...clone(item), record: await validate(item.record) };
  const operation = writes.then(async () => {
    const rows = (await chrome.storage.local.get(storageKey))[storageKey] ?? [];
    if (!Array.isArray(rows)) throw Error('Vault catalogue is damaged. Existing data was preserved.');
    const index = rows.findIndex((e: VaultItem) => e.record.covenantId === validated.record.covenantId);
    if (expected && (index < 0 || JSON.stringify(rows[index]) !== JSON.stringify(expected))) throw Error('The saved vault state changed in another window. Refresh before continuing.');
    if (index < 0) rows.push(validated);
    else if (!onlyIfAbsent) rows[index] = validated;
    await chrome.storage.local.set({ [storageKey]: rows });
  });
  writes = operation.catch(() => {});
  await operation;
}
async function itemFor(address: string, cid: unknown) {
  if (!hash(cid)) throw Error('Invalid vault covenant ID.');
  const item = (await vaultSaved(address)).find(item => item.record.covenantId === cid);
  if (!item) throw Error('The saved vault record was not found for this wallet.');
  return item;
}
export async function vaultCell(record: Row, signal?: AbortSignal): Promise<Row | null> {
  await validate(record);
  const rows = await vaultGet(`/addresses/${encodeURIComponent(record.vaultAddress)}/utxos`, false, signal);
  if (!Array.isArray(rows)) throw Error('Invalid vault output response from the node.');
  const matches: Row[] = [];
  for (const row of rows) {
    const point = row.outpoint, entry = row.utxoEntry, spk = entry?.scriptPublicKey;
    if (spk?.scriptPublicKey !== record.scriptPublicKey || (spk.version ?? 0) !== 0 || entry.isCoinbase !== false || number(entry.amount) !== number(record.amountSompi) || number(entry.blockDaaScore) <= 0n) continue;
    if (!hash(point?.transactionId) || point.index !== 0) continue;
    const tx = await vaultGet(`/transactions/${point.transactionId}`, false, signal);
    if (tx.is_accepted !== true || tx.transaction_id !== point.transactionId || !tx.outputs?.some((o: Row) => o.index === point.index && o.covenant_id === record.covenantId && o.script_public_key === record.scriptPublicKey && number(o.amount) === number(record.amountSompi))) continue;
    matches.push({ covenantId: record.covenantId, transactionId: point.transactionId, index: point.index, valueSompi: String(entry.amount), blockDaaScore: Number(entry.blockDaaScore), scriptPublicKey: record.scriptPublicKey });
  }
  if (matches.length > 1) throw Error('Ambiguous vault outputs. No transaction will be signed.');
  return matches[0] ?? null;
}
async function confirmedOpening(record: Row, signal?: AbortSignal) {
  const recipient = record.terms.kind === 'timeLock' ? record.terms.owner : record.terms.beneficiary;
  for (let offset = 0; offset < 1000; offset += 100) {
    const rows = await vaultGet(`/addresses/${encodeURIComponent(record.vaultAddress)}/full-transactions?limit=100&offset=${offset}&resolve_previous_outpoints=light`, false, signal);
    if (!Array.isArray(rows)) throw Error('Invalid vault history response.');
    for (const tx of rows) {
      if (tx.is_accepted !== true || tx.inputs?.length !== 1 || tx.outputs?.length !== 1) continue;
      const input = tx.inputs[0], output = tx.outputs[0];
      if (output.script_public_key_address !== recipient || output.covenant_id != null || number(output.amount) <= 0n || number(output.amount) > number(record.amountSompi) || !hash(input.previous_outpoint_hash) || input.previous_outpoint_index !== 0) continue;
      const parent = await vaultGet(`/transactions/${input.previous_outpoint_hash}`, false, signal);
      if (parent.is_accepted === true && parent.transaction_id === input.previous_outpoint_hash && parent.outputs?.some((o: Row) => o.index === 0 && o.covenant_id === record.covenantId && o.script_public_key === record.scriptPublicKey && number(o.amount) === number(record.amountSompi))) return true;
    }
    if (rows.length < 100) return false;
  }
  return false;
}
export async function refreshVault(item: VaultItem, signal?: AbortSignal): Promise<VaultItem> {
  const record = clone(item.record), pending = item.pending;
  const live = await vaultCell(record, signal);
  if (live && (!pending || live.transactionId === pending.transactionId)) {
    record.transactionId = live.transactionId; record.lastConfirmedCell = live; record.status = 'locked';
  } else if (pending) {
    if (!hash(pending.transactionId)) throw Error('Damaged saved vault transaction. Existing data was preserved.');
    const tx = await vaultGet(`/transactions/${pending.transactionId}`, true, signal);
    if (tx?.transaction_id === pending.transactionId && tx.is_accepted === true) {
      if (['create', 'heartbeat'].includes(pending.action) && tx.outputs?.some((o: Row) => o.index === record.index && o.covenant_id === record.covenantId && o.script_public_key === record.scriptPublicKey && number(o.amount) === number(record.amountSompi))) record.status = live ? 'locked' : 'pending';
      else if (['release', 'claim'].includes(pending.action)) record.status = 'opened';
      else return item;
    } else return item;
  } else if (!live && record.status !== 'opened' && await confirmedOpening(record, signal)) record.status = 'opened';
  else return item;
  const updated = { record }; await put(updated, false, item); return updated;
}
export async function verifyVaultInputs(request: Row, signal?: AbortSignal) {
  const daa = await vaultDaa(signal);
  if (request.action === 'create' && request.terms.kind === 'timeLock' && number(request.terms.limitDaa) <= BigInt(daa)) throw Error('The prepared unlock DAA has already passed. Choose a future DAA and prepare again. Nothing was broadcast.');
  const funding = parseVaultJson(request.fundingUtxosJson);
  if (funding.length) {
    const current = await vaultGet(`/addresses/${encodeURIComponent(request.sender)}/utxos`, false, signal);
    const identity = (r: Row) => `${r.outpoint.transactionId}:${r.outpoint.index}:${number(r.utxoEntry.amount)}:${number(r.utxoEntry.blockDaaScore)}:${r.utxoEntry.isCoinbase}:${r.utxoEntry.scriptPublicKey.version ?? 0}:${r.utxoEntry.scriptPublicKey.scriptPublicKey}`;
    if (!Array.isArray(current) || !funding.every((r: Row) => current.some(e => identity(e) === identity(r)))) throw Error('Wallet outputs changed during review. Refresh and prepare again. Nothing was broadcast.');
  }
  if (request.cell) {
    const descriptor = JSON.parse((await core()).prepareCovenantVault(JSON.stringify(request))).record;
    const current = await vaultCell(descriptor, signal);
    if (!current || Object.keys(request.cell).some(key => String(current[key]) !== String(request.cell[key]))) throw Error('The vault output changed during review. Refresh and review again.');
  }
}
function preparedFor(context: VaultContext, id: unknown) {
  const saved = prepared.get(String(id));
  if (!saved || saved.binding !== context.binding || saved.request.sender !== context.address || saved.expires <= Date.now()) throw Error('Secure vault review expired. Prepare and review again.');
  return saved;
}
export async function prepareVault(context: VaultContext, message: Row) {
  await context.guard();
  const currentDaa = await vaultDaa(context.signal);
  let previous: Row | undefined, terms: Row, amount: string, cell: Row | null = null;
  if (message.action === 'create') {
    // Prevent a second deposit when a previous submission is not yet reconciled.
    if ((await vaultSaved(context.address)).some(item => item.pending)) throw Error('Resume or refresh the saved vault transaction before creating another vault.');
    const deadline = number(message.deadline);
    if (deadline <= BigInt(currentDaa) || deadline >= 500000000000n) throw Error('Choose an unlock DAA score in the future.');
    terms = { kind: message.kind, owner: context.address, beneficiary: message.kind === 'deadManSwitch' ? String(message.beneficiary).trim() : '', name: String(message.name).trim(), limitDaa: Number(message.kind === 'timeLock' ? deadline : deadline - BigInt(currentDaa)), instance: Array.from(crypto.getRandomValues(new Uint8Array(32)), b => b.toString(16).padStart(2, '0')).join('') };
    amount = parseVaultKas(String(message.amount).trim());
  } else {
    const item = await itemFor(context.address, message.covenantId);
    if (item.pending) throw Error('A signed vault transaction is already saved. Resume or refresh it first.');
    previous = item.record; terms = previous.terms; amount = String(previous.amountSompi);
    cell = await vaultCell(previous, context.signal);
    if (!cell) throw Error('No confirmed spendable vault output was found. It may still be pending. Refresh before trying again.');
  }
  const funding = ['create', 'heartbeat'].includes(message.action) ? await vaultGet(`/addresses/${encodeURIComponent(context.address)}/utxos`, false, context.signal) : [];
  const request = { action: message.action, sender: context.address, terms, amountSompi: amount, currentDaa, feeRate: 100, fundingUtxosJson: JSON.stringify(funding), cell };
  const review = JSON.parse((await core()).prepareCovenantVault(JSON.stringify(request)));
  await context.guard();
  for (const [id, item] of prepared) if (item.expires <= Date.now()) prepared.delete(id);
  if (prepared.size >= 32) throw Error('Too many pending vault reviews. Close the other view first.');
  const id = crypto.randomUUID();
  prepared.set(id, { request, review, previous, binding: context.binding, expires: Date.now() + 600000, recoverySaved: false });
  return { id, review };
}
export function vaultReviewDetails(review: Row) {
  const terms = review.terms;
  return [`Vault: ${terms.name}`, `Action: ${review.action}`, `Amount: ${vaultKas(review.amountSompi)}`, `Network fee: ${vaultKas(review.feeSompi)}`,
    ...(review.action === 'create' && terms.kind === 'deadManSwitch' ? [`Beneficiary discovery notice: ${vaultKas(review.beneficiaryNoticeSompi)} (paid to the beneficiary, not a fee)`] : []),
    `${terms.kind === 'timeLock' ? 'Unlock DAA' : 'Inactivity duration (DAA)'}: ${terms.limitDaa}`, `Owner: ${terms.owner}`, ...(terms.beneficiary ? [`Beneficiary: ${terms.beneficiary}`] : []), `Recipient: ${review.recipient}`, `Covenant ID: ${review.covenantId}`,
    terms.kind === 'timeLock' ? 'There is no early cancellation. The on-chain DAA score determines when funds can be released.' : 'An Owner Pulse preserves the full vault balance. The owner pays its network fee from a separate KAS output.'];
}
async function exclusive<T>(address: string, action: () => Promise<T>) {
  if (inFlight.has(address)) throw Error('A vault transaction is already in progress.');
  inFlight.add(address); try { return await action(); } finally { inFlight.delete(address); }
}
async function resume(context: VaultContext, cid: unknown) {
  await context.guard();
  let item = await itemFor(context.address, cid);
  if (!item.pending) return { transactionId: item.record.transactionId, confirmed: true };
  const expected = item.pending.transactionId;
  item = await refreshVault(item, context.signal);
  if (!item.pending) return { transactionId: expected, confirmed: true };
  const pending = item.pending;
  if (!hash(expected) || typeof pending.wrpcJson !== 'string' || pending.wrpcJson.length > 2 * 1024 * 1024 || parseVaultJson(pending.wrpcJson).id !== expected) throw Error('Saved transaction data is damaged. Import recovery; no replacement transaction was created.');
  await context.guard();
  // The journal is already durable. A timeout never authorizes a replacement.
  const signed = pending.wrpcJson;
  const timeout = AbortSignal.any([AbortSignal.timeout(45000), ...(context.signal ? [context.signal] : [])]);
  let abort: () => void = () => {};
  try {
    await Promise.race([broadcastKcc20(signed, expected), new Promise<never>((_, reject) => { abort = () => reject(Error('Submission interrupted. The exact signed vault transaction is saved. Resume it; do not create a replacement.')); timeout.addEventListener('abort', abort, { once: true }); if (timeout.aborted) abort(); })]);
  } finally { timeout.removeEventListener('abort', abort); }
  const before = clone(item);
  item.record.status = ['release', 'claim'].includes(pending.action) ? 'opening' : 'pending';
  pending.submitted = true; await put(item, false, before);
  try { item = await refreshVault(item, context.signal); } catch { /* Retain exact signed bytes until our node confirms. */ }
  return { transactionId: expected, confirmed: !item.pending };
}
export async function submitVault(context: VaultContext, id: unknown, recoverySaved: unknown) {
  return exclusive(context.address, async () => {
    await context.guard();
    const saved = preparedFor(context, id);
    if (saved.request.action === 'create' && (!saved.recoverySaved || recoverySaved !== true)) throw Error('Save the encrypted recovery file and confirm it before funding the vault.');
    if ((await vaultSaved(context.address)).some(item => item.pending)) throw Error('Resume or refresh the saved vault transaction first.');
    if (!await context.approve(saved.request.action === 'create' ? 'Create covenant vault' : saved.request.action === 'heartbeat' ? 'Owner Pulse' : 'Open Vault', vaultReviewDetails(saved.review), saved.request)) throw Error('Vault transaction rejected. Nothing was signed.');
    await context.guard();
    await verifyVaultInputs(saved.request, context.signal);
    await context.guard();
    const signed = await context.sign(saved.request, saved.review.reviewHash);
    if (signed.transactionId !== saved.review.transactionId) throw Error('Signed vault transaction differs from the reviewed transaction.');
    const record = clone(signed.record);
    record.genesisTransactionId = saved.previous?.genesisTransactionId ?? saved.previous?.transactionId ?? signed.transactionId;
    if (saved.request.cell) record.lastConfirmedCell = saved.request.cell;
    if (['release', 'claim'].includes(saved.request.action)) record.transactionId = saved.previous!.transactionId;
    await put({ record, pending: { transactionId: signed.transactionId, wrpcJson: signed.wrpcJson, submitJson: signed.submitJson, action: saved.request.action } }, false, saved.previous ? { record: saved.previous } : undefined);
    prepared.delete(String(id));
    return resume(context, record.covenantId);
  });
}
async function discover(context: VaultContext) {
  const known = new Set((await vaultSaved(context.address)).map(item => item.record.covenantId));
  let count = 0;
  for (let offset = 0; offset < 10000; offset += 100) {
    await context.guard();
    const rows = await vaultGet(`/addresses/${encodeURIComponent(context.address)}/full-transactions?limit=100&offset=${offset}&resolve_previous_outpoints=light`, false, context.signal);
    if (!Array.isArray(rows)) throw Error('Invalid vault discovery response.');
    for (const row of rows) {
      if (row.is_accepted !== true) continue;
      let record: Row;
      try {
        const hex = row.payload;
        if (typeof hex !== 'string' || hex.length > 32768 || !/^(?:[0-9a-f]{2})+$/.test(hex)) continue;
        const payload = parseVaultJson(new TextDecoder('utf-8', { fatal: true }).decode(Uint8Array.from(hex.match(/../g)!, b => parseInt(b, 16))));
        if (payload.p !== VAULT_PROTOCOL || payload.action !== 'create' || (payload.terms?.owner !== context.address && payload.terms?.beneficiary !== context.address)) continue;
        const output = row.outputs?.find((o: Row) => o.index === 0);
        if (!output || known.has(output.covenant_id)) continue;
        const descriptor = JSON.parse((await core()).describeCovenantVault(JSON.stringify(payload.terms)));
        if (descriptor.scriptPublicKey !== output.script_public_key || descriptor.vaultAddress !== payload.vaultAddress || number(output.amount) !== number(payload.amountSompi)) continue;
        record = await validate({ ...descriptor, covenantId: output.covenant_id, transactionId: row.transaction_id, genesisTransactionId: row.transaction_id, index: 0, amountSompi: String(output.amount), status: 'pending' });
      } catch { continue; /* Unrelated or non-canonical genesis payload. */ }
      await context.guard();
      await put({ record }, true); known.add(record.covenantId); count++;
    }
    if (rows.length < 100) return count;
  }
  throw Error('Scanned the first 10,000 transactions. Import a recovery file for older vaults. Existing records were preserved.');
}
export async function covenantVaultCommand(context: VaultContext, message: Row): Promise<any> {
  await context.guard();
  switch (message.command) {
    case 'covenantVaultSaved': return vaultSaved(context.address);
    case 'covenantVaultDaa': return vaultDaa(context.signal);
    case 'covenantVaultPrepare': return prepareVault(context, message);
    case 'covenantVaultSubmit': return submitVault(context, message.id, message.recoverySaved);
    case 'covenantVaultResume': return exclusive(context.address, () => resume(context, message.covenantId));
    case 'covenantVaultRefresh': return exclusive(context.address, async () => {
      const items = await vaultSaved(context.address); const failures: string[] = [];
      for (let i = 0; i < items.length; i++) {
        await context.guard();
        if (message.pendingOnly && !items[i]!.pending && items[i]!.record.status !== 'pending') continue;
        try { items[i] = await refreshVault(items[i]!, context.signal); } catch (e) { failures.push((e as Error).message); }
      }
      return { items, error: failures[0] ?? '' };
    });
    case 'covenantVaultDiscover': return exclusive(context.address, () => discover(context));
    case 'covenantVaultExport': {
      const saved = message.id ? preparedFor(context, message.id) : null;
      const record = saved ? saved.review.record : (await itemFor(context.address, message.covenantId)).record;
      const password = passwordBytes(message.password);
      try {
        const wasm = await core(); await context.guard();
        const envelope = wasm.sealVaultRecovery(password, JSON.stringify(record));
        if (saved) saved.recoverySaved = true;
        return { envelope, covenantId: record.covenantId };
      } finally { password.fill(0); if (Array.isArray(message.password)) message.password.fill(0); }
    }
    case 'covenantVaultImport': {
      const password = passwordBytes(message.password);
      try {
        if (typeof message.envelope !== 'string' || message.envelope.length > 512 * 1024) throw Error('Recovery file is too large or invalid.');
        const wasm = await core(); await context.guard();
        const record = JSON.parse(wasm.openVaultRecovery(password, message.envelope));
        if (record.terms.owner !== context.address && record.terms.beneficiary !== context.address) throw Error('Select the owner or beneficiary wallet before importing this vault.');
        await put({ record }, true); return record;
      } finally { password.fill(0); if (Array.isArray(message.password)) message.password.fill(0); }
    }
    default: throw Error('Unknown covenant vault command.');
  }
}
function passwordBytes(value: unknown) {
  if (!Array.isArray(value) || value.length < 12 || value.length > 1024 || value.some(v => !Number.isInteger(v) || v < 0 || v > 255)) throw Error('Use a strong recovery password of at least 12 characters (at most 1024 UTF-8 bytes).');
  return new Uint8Array(value);
}
