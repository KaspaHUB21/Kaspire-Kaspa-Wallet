import { kronDisplay, kronSwapDetails, type KronToken } from '../background/kronDex';
import {openKasseal} from './kasseal';
type Hooks = { command(name: string, values?: Record<string, unknown>): Promise<any>; shell(content: string, title?: string, back?: boolean): void; address(): string };
const esc = (v: any) => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
const kas = (raw: any) => kronDisplay(raw, 8) + ' KAS';
const safeImage = (v: any) => typeof v === 'string' && /^https:\/\//i.test(v) ? esc(v) : '';
const logo = (token: KronToken) => safeImage(token.image) ? `<img src="${safeImage(token.image)}" alt="">` : '◈';
const details = (summary: any, token: KronToken) => kronSwapDetails(summary, token).map(line => { const colon = line.indexOf(':'); return `<div class="kron-detail-row"><span>${esc(line.slice(0, colon))}</span><b>${esc(line.slice(colon + 1).trim())}</b></div>`; }).join('');

export function openDexSelection(hooks: Hooks, network: string, rocket: () => void) {
  if (network === 'testnet-10') { rocket(); return; }
  if (network !== 'mainnet') { hooks.shell('<article class="review-card"><h1>KCC20 DEX Swaps</h1><p>Switch to Kaspa Mainnet to use Kron DEX.</p></article>', 'Swap', true); return; }
  hooks.shell(`<section class="marketplace-screen"><h1>KCC20 DEX Swaps</h1><button id="rocket-open" class="rocket-token market-offer"><span class="rocket-logo"><img src="https://kasparocket.fun/icon.jpeg" alt="KaspaRocket"></span><span><b>KaspaRocket</b><small>Kaspa Mainnet · DEX & Launchpad</small></span><i>›</i></button><button id="kron-open" class="rocket-token market-offer"><span class="rocket-logo"><img src="https://kron.technology/icon-512.png" alt="Kron"></span><span><b>Kron DEX</b><small>Kaspa Mainnet · DEX & Launchpad</small></span><i>›</i></button><p class="kron-coming">More KCC20 DEXes are coming soon.</p></section>`, 'Swap', true);
  const kasseal=document.createElement('button');kasseal.id='kasseal-open';kasseal.className='rocket-token market-offer';
  kasseal.innerHTML='<span class="rocket-logo"><img src="kasseal.png" alt="Kasseal"></span><span><b>Kasseal DEX</b><small>Kaspa Mainnet · DEX & Launchpad</small></span><i>›</i>';
  document.querySelector('#kron-open')!.before(kasseal);kasseal.onclick=()=>void openKasseal(hooks);
  document.querySelector<HTMLButtonElement>('#rocket-open')!.onclick = () => rocket();
  document.querySelector<HTMLButtonElement>('#kron-open')!.onclick = () => void openKronDex(hooks);
}
export async function openKronDex(hooks: Hooks) {
  const address = hooks.address();
  hooks.shell('<section class="marketplace-screen kron-screen"><div class="market-title"><h1>Kron DEX</h1><button id="kron-reload" class="icon" aria-label="Reload Kron DEX">↻</button></div><div id="kron-content"></div></section>', 'Kron DEX', true);
  const host = document.querySelector<HTMLElement>('#kron-content')!;
  host.dataset.preserveCase = '';
  let tokens: KronToken[] = [], selected: KronToken | null = null, context: any = null, quote: any = null, receipt: any = null;
  let amount = '', side: 'buy' | 'sell' = 'buy', query = '', loading = false, error = '', epoch = 0;
  const active = () => host.isConnected && address === hooks.address();
  async function run(action: () => Promise<void>) {
    if (loading) return; loading = true; error = ''; paint();
    try { await action(); } catch (e) { if (active()) error = (e as Error).message; }
    finally { if (active()) { loading = false; paint(); } }
  }
  async function load() { tokens = await hooks.command('kronDexTokens'); }
  async function balances(token: KronToken) { const stamp = ++epoch; const result = await hooks.command('kronDexContext', { tokenId: token.covenantId }); if (active() && selected?.covenantId === token.covenantId && stamp === epoch) context = result; }
  function paint() {
    if (!active()) return;
    let html = '';
    if (receipt) html = `<section class="receipt-screen"><div class="receipt-check">✓</div><h1>${receipt.summary.side === 'buy' ? 'Bought' : 'Sold'} ${esc(receipt.token.ticker)}</h1><article class="review-card">${details(receipt.summary, receipt.token)}</article><section class="copy-detail"><label>Transaction ID</label><code>${esc(receipt.transactionId)}</code></section><button id="kron-return">Return to Kron DEX</button></section>`;
    else if (!selected) {
      const rows = tokens.filter(t => `${t.ticker} ${t.name} ${t.covenantId}`.toLowerCase().includes(query.toLowerCase()));
      html = `<label>Search ticker, name or covenant ID<input id="kron-search" value="${esc(query)}"></label>${rows.map(t => `<button class="rocket-token market-offer" data-kron-token="${esc(t.covenantId)}"><span class="rocket-logo">${logo(t)}</span><span><b data-preserve-case>${esc(t.ticker.toUpperCase())}</b><small>${esc(t.name)}</small><code>${esc(t.covenantId)}</code><em>${t.phase === 'pool' ? 'DEX' : 'Launchpad'} · Price ${esc(t.priceKas ?? '—')} KAS</em></span><i>›</i></button>`).join('') || (loading ? '' : '<p>No tokens found.</p>')}`;
    } else {
      const t = selected;
      html = `<button id="kron-back" class="outline">← Back to swaps</button><section class="token-detail rocket-detail"><div class="token-logo">${logo(t)}</div><h1 data-preserve-case>${esc(t.ticker.toUpperCase())}</h1><p>${esc(t.name)} · ${t.phase === 'pool' ? 'DEX' : 'Launchpad'}</p><section class="copy-detail"><label>Token covenant</label><code>${esc(t.covenantId)}</code></section><p>Price ${esc(t.priceKas ?? '—')} KAS</p>${context?.pending ? `<article class="review-card kron-recovery"><h2>Swap incomplete — action required</h2><p>Signed swap saved. Resume submits the exact same bytes; do not start a second trade.</p><code>${esc(context.pending.transactionId)}</code><button id="kron-resume">Resume saved swap</button></article>` : ''}<div class="segmented rocket-side"><button data-kron-side="buy" class="${side === 'buy' ? 'active' : ''}">Buy</button><button data-kron-side="sell" class="${side === 'sell' ? 'active' : ''}">Sell</button></div><div class="form"><label>${side === 'buy' ? 'KAS trade amount (protocol fees added)' : 'Token amount'}<small class="available">Available: ${context ? side === 'buy' ? esc(kas(context.balanceSompi)) : `${esc(context.holdingDisplay)} ${esc(t.ticker)}` : 'Loading…'}</small><div class="amount"><input id="kron-amount" inputmode="decimal" value="${esc(amount)}"><span>${side === 'buy' ? 'KAS' : esc(t.ticker)}</span></div></label><button id="kron-quote" class="outline" ${!context || loading || context.pending ? 'disabled' : ''}>Get live quote</button>${quote ? `<article class="review-card">${details(quote, t)}</article>` : ''}<button id="kron-review" ${!quote || loading || context?.pending ? 'disabled' : ''}>Review swap</button></div></section>`;
    }
    host.innerHTML = `${error ? `<p class="error">${esc(error)}</p>` : ''}${loading ? '<div class="loading">Loading KRON…</div>' : ''}${html}`;
    host.querySelectorAll<HTMLButtonElement>('[data-kron-token], #kron-back, #kron-resume').forEach(button => button.disabled = loading);
    const amountInput = host.querySelector<HTMLInputElement>('#kron-amount');
    if (amountInput) amountInput.disabled = loading;
    host.querySelectorAll<HTMLImageElement>('img').forEach(img => img.onerror = () => { img.replaceWith(document.createTextNode('◈')); });
    host.querySelector<HTMLButtonElement>('#kron-return')?.addEventListener('click', () => { receipt = null; selected = null; context = null; quote = null; amount = ''; void run(load); });
    host.querySelector<HTMLInputElement>('#kron-search')?.addEventListener('input', e => { const input = e.target as HTMLInputElement, pos = input.selectionStart; query = input.value; paint(); const next = host.querySelector<HTMLInputElement>('#kron-search'); next?.focus(); next?.setSelectionRange(pos, pos); });
    host.querySelectorAll<HTMLButtonElement>('[data-kron-token]').forEach(b => b.onclick = () => { selected = tokens.find(t => t.covenantId === b.dataset.kronToken)!; context = null; quote = null; amount = ''; side = 'buy'; void run(() => balances(selected!)); });
    host.querySelector<HTMLButtonElement>('#kron-back')?.addEventListener('click', () => { selected = null; ++epoch; context = null; quote = null; error = ''; paint(); });
    host.querySelectorAll<HTMLButtonElement>('[data-kron-side]').forEach(b => b.onclick = () => { if (loading) return; side = b.dataset.kronSide as 'buy' | 'sell'; quote = null; amount = ''; error = ''; paint(); });
    host.querySelector<HTMLInputElement>('#kron-amount')?.addEventListener('input', e => { amount = (e.target as HTMLInputElement).value; quote = null; host.querySelector('.form .review-card')?.remove(); host.querySelector<HTMLButtonElement>('#kron-review')!.disabled = true; });
    host.querySelector<HTMLButtonElement>('#kron-quote')?.addEventListener('click', () => void run(async () => { quote = await hooks.command('kronDexQuote', { tokenId: selected!.covenantId, side, amount }); }));
    host.querySelector<HTMLButtonElement>('#kron-review')?.addEventListener('click', () => void run(async () => { const result = await hooks.command('kronDexPrepare', { quoteId: quote.quoteId }); if (active()) review(result); }));
    host.querySelector<HTMLButtonElement>('#kron-resume')?.addEventListener('click', () => void run(async () => { receipt = await hooks.command('kronDexResume'); context = null; }));
  }
  function review(prepared: any) {
    const overlay = document.createElement('div'); overlay.className = 'kaspire-modal';
    overlay.dataset.preserveCase = '';
    overlay.innerHTML = `<section class="approval-sheet"><h1>${prepared.summary.side === 'buy' ? 'Buy' : 'Sell'} ${esc(prepared.token.ticker)}</h1><article class="review-card">${details(prepared.summary, prepared.token)}</article><p>Slippage limit: 1%. Partner attribution does not add a fee.</p><section class="copy-detail"><label>Token covenant</label><code>${esc(prepared.token.covenantId)}</code><label>Market covenant</label><code>${esc(prepared.summary.marketId)}</code></section><details class="raw-json"><summary>Unsigned transaction</summary><pre>${esc(JSON.stringify(prepared.rawPlan, null, 2))}</pre></details><p id="kron-submit-error" class="error"></p><div class="approval-actions"><button id="kron-cancel" class="outline">Cancel</button><button id="kron-submit">Authorize & swap</button></div></section>`;
    document.body.append(overlay);
    overlay.querySelector<HTMLButtonElement>('#kron-cancel')!.onclick = () => overlay.remove();
    overlay.querySelector<HTMLButtonElement>('#kron-submit')!.onclick = async () => {
      const submit = overlay.querySelector<HTMLButtonElement>('#kron-submit')!; submit.disabled = true;
      overlay.querySelector<HTMLButtonElement>('#kron-cancel')!.disabled = true;
      submit.textContent = 'Waiting for secure approval…';
      try { const result = await hooks.command('kronDexSubmit', { id: prepared.id }); overlay.remove(); if (active()) { receipt = result; context = null; quote = null; paint(); } }
      catch (e) { overlay.remove(); if (active()) { error = (e as Error).message; quote = null; try { await balances(prepared.token); } catch { /* Keep the original submit error. */ } paint(); } }
    };
  }
  document.querySelector<HTMLButtonElement>('#kron-reload')!.onclick = () => void run(async () => { quote = null; await load(); if (selected) await balances(selected); });
  paint(); await run(load);
}
