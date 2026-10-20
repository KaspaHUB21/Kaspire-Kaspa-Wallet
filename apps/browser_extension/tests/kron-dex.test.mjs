import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { parseKronAmount, kronDisplay, kronSwapDetails, validateKronPlan, verifyKronInputs, getKronQuote, prepareKronSwap, submitKronSwap, resumeKronSwap, pendingKronSwap, clearKronDexReviews } from './generated/kronDex.mjs';
const address = 'kaspa:q' + 'a'.repeat(61), tokenId = 'a'.repeat(64), txid = 'b'.repeat(64);
const token = { covenantId: tokenId, ticker: 'ROCKET', name: 'Rocket', decimals: 3, image: '', phase: 'pool' };
const input = { transactionId: txid, index: 0, utxo: { amount: '1000000000', scriptPublicKey: '000020abac', blockDaaScore: '123', isCoinbase: false, covenantId: null } };
function request(raw = '100000000', minimum = '99000') { return { sender: address, tokenId, profile: 'kron-swap-v1', side: 'buy', txJsonString: JSON.stringify({ inputs: [input] }), tradeSummary: { tokenId, ticker: token.ticker, decimals: 3, side: 'buy', rawAmount: raw, minimumReceive: minimum, ref: 'kaspirewallet', inputAddresses: [address], tokenAmount: '100000', grossKasSompi: raw, netKasSompi: '101000000', creatorFeeSompi: '250000', platformFeeSompi: '750000', devFundFeeSompi: '0', lpFeeSompi: '0', marketId: 'c'.repeat(64) } }; }
const nodeData = url => url.includes('/utxos') ? [{ outpoint: { transactionId: txid, index: 0 }, utxoEntry: { amount: '1000000000', scriptPublicKey: { scriptPublicKey: '20abac' }, blockDaaScore: '123', isCoinbase: false } }] : { transaction_id: txid, is_accepted: true, outputs: [{ index: 0, covenant_id: null }] };
function environment(t) {
  const oldChrome = globalThis.chrome, oldFetch = globalThis.fetch, store = {}, calls = [];
  globalThis.chrome = { storage: { local: { get: async key => ({ [key]: store[key] }), set: async data => Object.assign(store, data), remove: async key => { delete store[key]; } } } };
  globalThis.fetch = async (url, options) => {
    url = String(url); calls.push({ url, options }); let data;
    if (url.endsWith('/kron/tokens')) data = [token];
    else if (url.endsWith('/info')) data = { result: { network: 'mainnet', networkOk: true, synced: true, divergent: false } };
    else if (url.endsWith('/tokenlist')) data = { result: [{ covenantId: tokenId, balance: '420290', dec: '3' }] };
    else if (url.endsWith('/quote')) data = { ...request().tradeSummary, quoteExpiresAt: Date.now() + 120000 };
    else if (url.endsWith('/plan')) { const body = JSON.parse(options.body); data = { request: request(body.rawAmount, body.minimumReceive) }; }
    else data = nodeData(url);
    return new Response(JSON.stringify(data), { status: 200 });
  };
  clearKronDexReviews(); t.after(() => { globalThis.chrome = oldChrome; globalThis.fetch = oldFetch; clearKronDexReviews(); });
  const events = [], context = { address, binding: '1:1:wallet', guard: async () => {}, balance: async () => '10000000000',
    prepare: async () => ({ transactionId: txid, reviewHash: 'hash', feeSompi: '10000', inputs: [{ selected: true, amountSompi: '1000000000' }], outputs: [{ returnsToWallet: true, amountSompi: '800000000' }] }),
    sign: async () => { events.push('sign'); return { transactionId: txid, wrpcJson: '{"signed":"same-bytes"}' }; },
    approve: async () => true,
    broadcast: async (bytes, id) => { assert.equal(store['kronSwapRecoveryV1:' + address]?.signedTxJson, bytes); events.push('broadcast'); return id; },
    record: async (wallet, tx) => { events.push('record'); assert.equal(wallet, address); assert.equal(tx.assetSymbol, 'ROCKET'); assert.equal(tx.displayAmount, '100'); assert.equal(tx.operationLabel, 'KRON Buy'); },
  };
  return { context, store, calls, events };
}
test('KRON decimals are consistent in input, balances, reviews and signed KAS changes', () => {
  assert.equal(parseKronAmount('420.29', 3), 420290n);
  assert.equal(kronDisplay('420290', 3), '420.29');
  assert.equal(kronDisplay('-101000000', 8), '-1.01');
  assert(kronSwapDetails({ ...request().tradeSummary, tokenAmount: '420290' }, token).includes('Token amount: 420.29 ROCKET'));
  for (const value of ['0', '-1', '1,25', '1.0001', '1e3', '100000000000000000000']) assert.throws(() => parseKronAmount(value, 3));
});
test('KRON planner remains bound to selected address, covenant, amount, minimum and partner', () => {
  validateKronPlan(request(), address, tokenId, 'buy', '100000000', '99000');
  for (const mutation of [{ sender: 'other' }, { tokenId: 'd'.repeat(64) }, { profile: 'generic' }, { side: 'sell' }, { tradeSummary: { ...request().tradeSummary, ref: 'other' } }, { tradeSummary: { ...request().tradeSummary, minimumReceive: '0' } }]) assert.throws(() => validateKronPlan({ ...request(), ...mutation }, address, tokenId, 'buy', '100000000', '99000'));
});
test('own-node UTXOs accept omitted version zero and reject stale or altered inputs', async () => {
  await verifyKronInputs(request(), async url => nodeData(url));
  await assert.rejects(verifyKronInputs(request(), async url => url.includes('/utxos') ? [] : nodeData(url)), /already spent/);
  for (const field of ['amount', 'blockDaaScore', 'scriptPublicKey', 'covenantId']) {
    const r = request(), tx = JSON.parse(r.txJsonString); tx.inputs[0].utxo[field] = 'altered'; r.txJsonString = JSON.stringify(tx);
    await assert.rejects(verifyKronInputs(r, async url => nodeData(url)), /differs/);
  }
});
test('overselling and unaffordable purchases fail before requesting quotes', async t => {
  const { calls } = environment(t);
  await assert.rejects(getKronQuote(address, tokenId, 'sell', '421', async () => '10000000000'), /Insufficient ROCKET.*420.29/);
  await assert.rejects(getKronQuote(address, tokenId, 'buy', '1', async () => '100000000'), /Insufficient KAS/);
  assert.equal(calls.filter(c => c.url.endsWith('/quote')).length, 0);
});
test('signed swaps persist before broadcast, produce token activity and clear completed recovery', async t => {
  const { context, events } = environment(t);
  const q = await getKronQuote(address, tokenId, 'buy', '1', context.balance);
  const review = await prepareKronSwap(context, q.quoteId);
  const receipt = await submitKronSwap(context, review.id);
  assert.equal(receipt.transactionId, txid); assert.deepEqual(events, ['sign', 'broadcast', 'record']);
  assert.equal(await pendingKronSwap(address), null);
});
test('failed swaps retain exactly the signed bytes and prohibit a second trade until resumed', async t => {
  const { context } = environment(t); const normal = context.broadcast;
  context.broadcast = async () => { throw Error('offline'); };
  const q = await getKronQuote(address, tokenId, 'buy', '1', context.balance), review = await prepareKronSwap(context, q.quoteId);
  await assert.rejects(submitKronSwap(context, review.id), /offline/);
  const saved = await pendingKronSwap(address); assert.equal(saved.signedTxJson, '{"signed":"same-bytes"}');
  await assert.rejects(getKronQuote(address, tokenId, 'buy', '1', context.balance), /Resume the saved swap/);
  context.broadcast = normal; await resumeKronSwap(context); assert.equal(await pendingKronSwap(address), null);
});
test('lock during approval and switching accounts invalidate prepared signing', async t => {
  const { context, events } = environment(t);
  const q = await getKronQuote(address, tokenId, 'buy', '1', context.balance), review = await prepareKronSwap(context, q.quoteId);
  await assert.rejects(submitKronSwap({ ...context, binding: '1:3:wallet' }, review.id), /review expired/);
  let locked = false;
  context.approve = async () => { locked = true; clearKronDexReviews(); return true; };
  context.guard = async () => { if (locked) throw Error('Wallet locked'); };
  await assert.rejects(submitKronSwap(context, review.id), /Wallet locked/);
  assert.deepEqual(events, []); assert.equal(await pendingKronSwap(address), null);
});
test('rejected or interrupted approval releases the swap lock without signing', async t => {
  const { context, events } = environment(t);
  const prepare = async () => { const q = await getKronQuote(address, tokenId, 'buy', '1', context.balance); return prepareKronSwap(context, q.quoteId); };
  let releaseApproval, entered;
  const waiting = new Promise(resolve => { entered = resolve; });
  context.approve = () => { entered(); return new Promise(resolve => { releaseApproval = resolve; }); };
  const review = await prepare();
  const first = submitKronSwap(context, review.id);
  await waiting;
  await assert.rejects(submitKronSwap(context, review.id), /already in progress/);
  assert.deepEqual(events, []);
  releaseApproval(false);
  await assert.rejects(first, /Swap rejected/);
  assert.equal(await pendingKronSwap(address), null);
  context.approve = async () => { throw Error('Approval window closed'); };
  await assert.rejects(submitKronSwap(context, (await prepare()).id), /window closed/);
  context.approve = async () => true;
  await submitKronSwap(context, (await prepare()).id);
  assert.deepEqual(events, ['sign', 'broadcast', 'record']);
});
test('closing during node verification aborts the request and permits a fresh review', async t => {
  const { context, events } = environment(t);
  const prepare = async () => { const q = await getKronQuote(address, tokenId, 'buy', '1', context.balance); return prepareKronSwap(context, q.quoteId); };
  const review = await prepare(), controller = new AbortController(), fetchNormally = globalThis.fetch;
  const originalGuard = context.guard;
  context.signal = controller.signal;
  context.guard = async () => controller.signal.throwIfAborted();
  let entered;
  const waiting = new Promise(resolve => { entered = resolve; });
  globalThis.fetch = (url, options) => {
    if (!String(url).includes('/utxos')) return fetchNormally(url, options);
    return new Promise((resolve, reject) => {
      entered();
      options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true });
    });
  };
  const first = submitKronSwap(context, review.id);
  await waiting;
  controller.abort();
  await assert.rejects(first, { name: 'AbortError' });
  assert.deepEqual(events, []);
  assert.equal(await pendingKronSwap(address), null);
  globalThis.fetch = fetchNormally; context.signal = undefined; context.guard = originalGuard;
  await submitKronSwap(context, (await prepare()).id);
  assert.deepEqual(events, ['sign', 'broadcast', 'record']);
});
test('closing after signing preserves the durable transaction and never signs a replacement', async t => {
  const { context, events } = environment(t), controller = new AbortController();
  const q = await getKronQuote(address, tokenId, 'buy', '1', context.balance), review = await prepareKronSwap(context, q.quoteId);
  const persistNormally = chrome.storage.local.set, originalGuard = context.guard;
  context.signal = controller.signal;
  context.guard = async () => controller.signal.throwIfAborted();
  chrome.storage.local.set = async data => { await persistNormally(data); controller.abort(); };
  await assert.rejects(submitKronSwap(context, review.id), { name: 'AbortError' });
  assert.deepEqual(events, ['sign']);
  assert.equal((await pendingKronSwap(address)).signedTxJson, '{"signed":"same-bytes"}');
  context.signal = undefined; context.guard = originalGuard;
  await assert.rejects(getKronQuote(address, tokenId, 'buy', '1', context.balance), /Resume the saved swap/);
  await resumeKronSwap(context);
  assert.deepEqual(events, ['sign', 'record']);
  assert.equal(await pendingKronSwap(address), null);
});
test('KRON commands use the visible in-app approval pump and cancellable operation port', () => {
  const ui = readFileSync(new URL('../src/ui/wallet.ts', import.meta.url), 'utf8');
  const guarded = ui.slice(ui.indexOf('const guarded = ['), ui.indexOf('async function withInAppApprovals'));
  for (const name of ['kronDexPrepare', 'kronDexSubmit', 'kronDexResume']) assert(guarded.includes('"' + name + '"'));
  const background = readFileSync(new URL('../src/background/index.ts', import.meta.url), 'utf8');
  assert.match(background, /port\.onDisconnect\.addListener\(\(\) => disconnected\.abort\(\)\)/);
  assert.match(background, /rawJson \}, operationSignal\)/);
});
test('an interrupted unacknowledged broadcast releases only the volatile lock, not signed recovery', async t => {
  const { context, events } = environment(t), controller = new AbortController();
  const q = await getKronQuote(address, tokenId, 'buy', '1', context.balance), review = await prepareKronSwap(context, q.quoteId);
  let entered, completeLate;
  const waiting = new Promise(resolve => { entered = resolve; });
  context.signal = controller.signal;
  context.broadcast = async () => { events.push('broadcast-start'); entered(); return new Promise(resolve => { completeLate = resolve; }); };
  const first = submitKronSwap(context, review.id);
  await waiting;
  controller.abort();
  await assert.rejects(first, /signed swap is saved/);
  assert.equal((await pendingKronSwap(address)).signedTxJson, '{"signed":"same-bytes"}');
  await assert.rejects(getKronQuote(address, tokenId, 'buy', '1', context.balance), /Resume the saved swap/);
  // The own node confirms the original ID: no second signing/broadcast.
  context.signal = undefined;
  await resumeKronSwap(context);
  completeLate(txid);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(events, ['sign', 'broadcast-start', 'record']);
  assert.equal(await pendingKronSwap(address), null);
});
test('extension packages and displayed version do not use a testing suffix', () => {
  const manifest = JSON.parse(readFileSync(new URL('../manifest.json', import.meta.url)));
  assert.equal(manifest.version, JSON.parse(readFileSync(new URL('../package.json', import.meta.url))).version); assert.doesNotMatch(manifest.version_name, /test/i);
});
