import { formatRawTokenAmount } from '../shared/tokenAmount';

type Row = Record<string, any>;
type Item = { record: Row; pending?: Row };
type Hooks = { command(name: string, values?: Record<string, unknown>): Promise<any>; shell(content: string, title?: string, back?: boolean): void; address(): string; network(): string };
const esc = (value: unknown) => String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
const kas = (value: unknown) => `${formatRawTokenAmount(String(value ?? 0), 8)} KAS`;
const line = (label: string, value: unknown) => `<div class="vault-line"><small>${esc(label)}</small><span>${esc(value)}</span></div>`;
const button = (id: string, label: string, extra = '') => `<button id="${id}" ${extra}>${label}</button>`;
const panel = (content: string, extra = '') => `<article class="review-card vault-panel ${extra}">${content}</article>`;
const title = (kind: string) => kind === 'timeLock' ? 'Time-Locked Vault' : 'Dead Man’s Switch';
const statusText = (item: Item) => item.pending ? item.pending.submitted ? 'Awaiting confirmation' : 'Transaction incomplete' : item.record.status === 'pending' ? 'Checking vault state' : item.record.status;
const header = () => panel(`<p class="vault-eyebrow">KASPA L1 · NON-CUSTODIAL · COVENANT ENFORCED</p><h1>Your money.<br>Your rules.</h1><p>Programmable self-custody and true sovereignty.<br>Secured by covenant logic and Kaspa consensus.</p><ul>${['Your keys stay in your wallet', 'Rules enforced on Kaspa L1', 'Portable recovery path'].map(s => `<li>${s}</li>`).join('')}</ul>`, 'vault-intro');
function reviewHtml(review: Row) {
  const t = review.terms;
  return line('Vault', t.name) + line('Action', review.action) + line('Amount', kas(review.amountSompi)) + line('Network fee', kas(review.feeSompi)) +
    (review.action === 'create' && t.kind === 'deadManSwitch' ? line('Beneficiary discovery notice', `${kas(review.beneficiaryNoticeSompi)}, paid to the beneficiary (not a fee)`) : '') +
    line(t.kind === 'timeLock' ? 'Unlock DAA' : 'Inactivity duration (DAA)', t.limitDaa) + line('Owner', t.owner) + (t.beneficiary ? line('Beneficiary', t.beneficiary) : '') + line('Recipient', review.recipient) + line('Covenant ID', review.covenantId) +
    (review.action === 'heartbeat' ? '<p>The full vault balance is preserved. The owner pays the network fee from a separate KAS output.</p>' : '') +
    (t.kind === 'timeLock' ? '<p>There is no early cancellation. The on-chain DAA score, not the estimated date, determines when funds can be released.</p>' : '');
}
function dialog<T>(html: string, bind: (host: HTMLDialogElement, finish: (value: T | null) => void) => void): Promise<T | null> {
  return new Promise(resolve => {
    const host = document.createElement('dialog'); host.className = 'vault-dialog';
    host.innerHTML = `<section class="review-card vault-panel" data-preserve-case>${html}</section>`;
    document.body.append(host);
    const observer = new MutationObserver(() => { if (!document.querySelector('#vault-content')) finish(null); });
    const finish = (value: T | null) => { observer.disconnect(); host.close(); host.remove(); resolve(value); };
    observer.observe(document.querySelector('#app')!, { childList: true, subtree: true });
    host.addEventListener('cancel', event => { event.preventDefault(); finish(null); });
    bind(host, finish); host.showModal();
  });
}
async function passwordPrompt(importing: boolean): Promise<number[] | null> {
  return dialog<number[]>(`<h2>${importing ? 'Import vault recovery' : 'Protect recovery file'}</h2><p>${importing ? 'Enter the password used to protect this recovery file.' : 'Use a strong password of at least 12 characters. No seed or private key is included.'}</p><div class="form"><label>Recovery password<div class="vault-password"><input id="vault-password" type="password" autocomplete="${importing ? 'current-password' : 'new-password'}" minlength="12" maxlength="1024"><button id="vault-eye" type="button" class="outline" aria-label="Show password">◉</button></div></label>${importing ? '' : '<label>Confirm password<input id="vault-password-confirm" type="password" autocomplete="new-password" maxlength="1024"></label>'}<p id="vault-password-error" class="error" role="alert"></p><div class="vault-actions">${button('vault-dialog-cancel', 'Cancel', 'class="outline"')}${button('vault-dialog-continue', importing ? 'Import' : 'Encrypt & download')}</div></div>`, (host, finish) => {
    const input = host.querySelector<HTMLInputElement>('#vault-password')!, confirm = host.querySelector<HTMLInputElement>('#vault-password-confirm');
    const end = (value: number[] | null) => { input.value = ''; if (confirm) confirm.value = ''; finish(value); };
    host.addEventListener('cancel', () => { input.value = ''; if (confirm) confirm.value = ''; });
    host.querySelector<HTMLButtonElement>('#vault-eye')!.onclick = () => { input.type = input.type === 'password' ? 'text' : 'password'; if (confirm) confirm.type = input.type; host.querySelector('#vault-eye')!.setAttribute('aria-label', input.type === 'password' ? 'Show password' : 'Hide password'); };
    host.querySelector<HTMLButtonElement>('#vault-dialog-cancel')!.onclick = () => end(null);
    const submit = () => {
      const bytes = new TextEncoder().encode(input.value);
      if (input.value.length < 12 || bytes.length > 1024 || (confirm && input.value !== confirm.value)) {
        bytes.fill(0); host.querySelector('#vault-password-error')!.textContent = confirm && input.value !== confirm.value ? 'Passwords do not match.' : 'Use at least 12 characters, at most 1024 UTF-8 bytes.'; return;
      }
      const value = Array.from(bytes); bytes.fill(0); end(value);
    };
    host.querySelector<HTMLButtonElement>('#vault-dialog-continue')!.onclick = submit;
    host.querySelectorAll('input').forEach(input => input.addEventListener('keydown', e => { if ((e as KeyboardEvent).key === 'Enter') { e.preventDefault(); submit(); } }));
    setTimeout(() => input.focus(), 0);
  });
}
function acknowledgeDownload(name: string, funding: boolean) {
  return dialog<boolean>(`<h2>Recovery file downloaded</h2><p>${esc(name)}</p><p>Protected with Argon2id, XChaCha20-Poly1305, ML-KEM-1024 and ML-DSA-87. Keep this file and a strong password safe. No seed or private key is included.</p>${funding ? '<p>Check that the file was saved before funding this vault.</p><label class="vault-check"><input id="vault-file-saved" type="checkbox"> I have saved the encrypted recovery file and its password.</label>' : ''}<div class="vault-actions">${button('vault-download-cancel', funding ? 'Cancel' : 'Back to vault', 'class="outline"')}${funding ? button('vault-download-continue', 'Continue to signature', 'disabled') : ''}</div>`, (host, finish) => {
    host.querySelector<HTMLButtonElement>('#vault-download-cancel')!.onclick = () => finish(funding ? false : true);
    const next = host.querySelector<HTMLButtonElement>('#vault-download-continue');
    host.querySelector<HTMLInputElement>('#vault-file-saved')?.addEventListener('change', e => { next!.disabled = !(e.target as HTMLInputElement).checked; });
    if (next) next.onclick = () => finish(true);
  });
}
async function chooseFile() {
  return dialog<File>(`<h2>Choose vault recovery file</h2><p>Select an encrypted recovery file exported by Kaspire Android, Windows or this extension.</p><label class="file">Recovery file<input id="vault-file" type="file" accept=".json,application/json"></label><div class="vault-actions">${button('vault-file-cancel', 'Cancel', 'class="outline"')}${button('vault-file-import', 'Continue', 'disabled')}</div>`, (host, finish) => {
    const input = host.querySelector<HTMLInputElement>('#vault-file')!, next = host.querySelector<HTMLButtonElement>('#vault-file-import')!;
    input.onchange = () => { next.disabled = !input.files?.length; };
    next.onclick = () => finish(input.files?.[0] ?? null);
    host.querySelector<HTMLButtonElement>('#vault-file-cancel')!.onclick = () => finish(null);
  });
}

export async function openCovenantVaults(hooks: Hooks) {
  if (hooks.network() !== 'mainnet') {
    hooks.shell(`<section class="vault-screen">${panel('<h1>Kaspire Covenant Vaults</h1><p>Covenant vaults require Kaspa Mainnet. Switch back before continuing.</p>')}</section>`, 'Vaults', true); return;
  }
  const address = hooks.address();
  hooks.shell(`<section class="vault-screen" data-preserve-case><div class="vault-toolbar"><h2>Kaspire Covenant Vaults</h2><button id="vault-home" class="icon" aria-label="Vault overview" title="Vault overview">⌂</button><button id="vault-reload" class="icon" aria-label="Refresh vaults" title="Refresh vaults">↻</button></div><div id="vault-content"></div></section>`, 'Vaults', true);
  const host = document.querySelector<HTMLElement>('#vault-content')!;
  let items: Item[] = [], selected = '', kind = '', prepared: Row | null = null;
  let form = { name: '', amount: '1', beneficiary: '', deadline: '', duration: 864000 };
  let daa = 0, daaAt = Date.now(), busy = false, error = '', receipt: Row | null = null;
  const active = () => host.isConnected && hooks.address() === address && hooks.network() === 'mainnet';
  const currentDaa = () => daa ? daa + Math.floor((Date.now() - daaAt) / 100) : 0;
  const item = () => items.find(i => i.record.covenantId === selected);
  const click = (id: string, action: () => void) => host.querySelector<HTMLButtonElement>('#' + id)?.addEventListener('click', action);
  async function run(action: () => Promise<void>) {
    if (!active() || busy) return; busy = true; error = ''; paint();
    try { await action(); } catch (e) {
      if (active()) { error = (e as Error).message; try { items = await hooks.command('covenantVaultSaved'); } catch { /* Preserve existing records. */ } }
    } finally { busy = false; if (active()) paint(); }
  }
  async function load(refresh = false, pendingOnly = false) {
    items = await hooks.command('covenantVaultSaved'); if (!active()) return; paint();
    if (refresh || items.some(i => i.pending || i.record.status === 'pending')) {
      const result = await hooks.command('covenantVaultRefresh', { pendingOnly });
      items = result.items; if (result.error) error = result.error;
    }
    daa = await hooks.command('covenantVaultDaa'); daaAt = Date.now();
  }
  function home() { if (busy) return; kind = selected = ''; prepared = receipt = null; error = ''; paint(); }
  const reset = () => { prepared = null; receipt = null; };
  function start(value: string) { kind = value; selected = ''; reset(); error = ''; form = { ...form, name: title(kind), deadline: String(currentDaa() + form.duration) }; paint(); }
  function notice(i: Item) {
    return panel(`<h2>${i.pending!.submitted ? 'Awaiting node confirmation' : 'Action required · Transaction incomplete'}</h2><p>${i.pending!.submitted ? 'The transaction was submitted, but is not confirmed yet. Kaspire checks automatically. Do not create a replacement vault.' : 'A signed transaction is saved. Vault creation or the requested action is NOT complete. Retry this exact transaction; do not create a second vault.'}</p><code>${esc(i.pending!.transactionId)}</code><button data-vault-resume="${esc(i.record.covenantId)}">Resume saved transaction</button>`, 'vault-pending');
  }
  function countdown(i: Item) {
    const r = i.record, t = r.terms;
    const deadline = t.kind === 'timeLock' ? Number(t.limitDaa) : r.lastConfirmedCell ? Number(r.lastConfirmedCell.blockDaaScore) + Number(t.limitDaa) : 0;
    const seconds = deadline && daa ? Math.max(0, Math.floor((deadline - currentDaa()) / 10)) : null;
    return { deadline, canOpen: Boolean(daa && deadline && currentDaa() > deadline && r.status === 'locked' && !i.pending), text: seconds == null ? 'Refresh to confirm the vault output' : seconds === 0 ? 'Unlock DAA reached — refresh before opening' : `${Math.floor(seconds / 86400)}d ${Math.floor(seconds / 3600) % 24}h ${Math.floor(seconds / 60) % 60}m ${seconds % 60}s` };
  }
  async function exportRecovery(id?: string) {
    const password = await passwordPrompt(false); if (!password || !active()) { password?.fill(0); return false; }
    let result;
    try { result = await hooks.command('covenantVaultExport', { ...(id ? { id } : { covenantId: selected }), password }); }
    finally { password.fill(0); }
    if (!active()) return false;
    const name = `Kaspire-Vault-${result.covenantId}.json`;
    const url = URL.createObjectURL(new Blob([result.envelope], { type: 'application/json' }));
    const link = document.createElement('a'); link.href = url; link.download = name; document.body.append(link); link.click(); link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 30000);
    return Boolean(await acknowledgeDownload(name, Boolean(id)));
  }
  async function finish(result: Row) {
    items = await hooks.command('covenantVaultSaved');
    for (let attempt = 0; attempt < 8 && active() && item()?.pending; attempt++) {
      const checked = await hooks.command('covenantVaultRefresh', { pendingOnly: true }); items = checked.items;
      if (checked.error) { error = checked.error; break; }
      if (!item()?.pending) break;
      paint();
      if (attempt < 7) await new Promise(resolve => setTimeout(resolve, 2000));
    }
    if (!active()) return;
    receipt = { transactionId: result.transactionId, confirmed: Boolean(item() && !item()!.pending) };
    kind = ''; prepared = null;
  }
  async function prepare(action: string) {
    prepared = await hooks.command('covenantVaultPrepare', action === 'create' ? { action, kind, ...form } : { action, covenantId: selected });
  }
  async function submit() {
    const p = prepared!;
    if (p.review.action === 'create' && !await exportRecovery(p.id)) return;
    if (!active()) return;
    selected = p.review.covenantId; kind = '';
    await finish(await hooks.command('covenantVaultSubmit', { id: p.id, recoverySaved: p.review.action === 'create' }));
  }
  function paint() {
    if (!active()) return;
    const current = item();
    let content = '';
    if (receipt) {
      content = panel(`<div class="receipt-check">${receipt.confirmed ? '✓' : '…'}</div><h1>${receipt.confirmed ? 'Vault transaction confirmed' : 'Transaction not yet confirmed'}</h1><p>${receipt.confirmed ? 'The Kaspire node confirmed the transaction.' : 'The signed transaction is safely saved, but vault creation or the requested action is NOT complete yet. Kaspire will keep checking automatically. Do not create a replacement vault. If needed, retry only this saved transaction.'}</p>${line('Transaction ID', receipt.transactionId)}${button('vault-return', receipt.confirmed ? 'Return to vaults' : 'View pending vault')}`);
    } else if (kind) {
      content = header() + panel(`<h2>${title(kind)}</h2><div class="form"><label>Vault name<input id="vault-name" maxlength="80" value="${esc(form.name)}"></label><label>Amount in KAS<input id="vault-amount" inputmode="decimal" value="${esc(form.amount)}"></label>${kind === 'deadManSwitch' ? `<label>Beneficiary Kaspa address<input id="vault-beneficiary" value="${esc(form.beneficiary)}" spellcheck="false"></label>` : ''}${line('Current DAA score (last node check)', daa || 'Loading…')}<label>Duration estimate<select id="vault-duration">${[[1200, '2 minutes'], [36000, '1 hour'], [864000, '1 day'], [6048000, '7 days'], [25920000, '30 days'], [315360000, '1 year']].map(([value, text]) => `<option value="${value}" ${form.duration === value ? 'selected' : ''}>${text}</option>`).join('')}</select></label><label>Initial unlock DAA score<input id="vault-deadline" inputmode="numeric" value="${esc(form.deadline)}"></label><p>${kind === 'timeLock' ? 'Funds stay locked until this DAA score. The owner is the fixed payout recipient.' : 'The owner can pulse at any time. Each confirmed pulse restarts the inactivity duration; the beneficiary can claim only after that duration has elapsed.'}</p>${button('vault-prepare', 'Prepare vault')}</div>`);
      if (prepared) content += panel(`${reviewHtml(prepared.review)}<p>First save the encrypted recovery file, then approve the wallet signature. Start with a small amount.</p>${button('vault-submit', 'Save recovery · Sign & broadcast')}`);
      content += button('vault-back', 'Back to vault selection', 'class="outline"');
    } else if (current) {
      const r = current.record, t = r.terms, counter = countdown(current);
      content = (current.pending ? notice(current) : '') + header() + panel(`<h2>${esc(t.name)}</h2>${line('Vault type', title(t.kind))}${line('Locked amount', kas(r.amountSompi))}${line('Status', statusText(current))}${r.status !== 'opened' ? `<div class="vault-line"><small>Estimated countdown</small><span id="vault-countdown">${counter.text}</span></div><p>Time estimates assume 10 DAA/s. Consensus and a fresh node check determine spendability.</p>` : ''}<details><summary>Technical details</summary>${line('Vault address', r.vaultAddress)}${line('Covenant ID', r.covenantId)}${line('Owner', t.owner)}${t.beneficiary ? line('Beneficiary', t.beneficiary) : ''}${line('Genesis transaction', r.genesisTransactionId ?? r.transactionId)}${line('Current output transaction', r.transactionId)}${line('Compiler', r.compiler)}${line(t.kind === 'timeLock' ? 'Unlock DAA' : 'Inactivity DAA', t.limitDaa)}</details>${!current.pending && t.kind === 'deadManSwitch' && t.owner === address && r.status === 'locked' ? button('vault-pulse', 'Owner Pulse') : ''}${!current.pending && ((t.kind === 'timeLock' && t.owner === address) || (t.kind === 'deadManSwitch' && t.beneficiary === address)) ? button('vault-open', 'Open Vault', counter.canOpen ? '' : 'disabled') : ''}${button('vault-export', 'Export recovery', 'class="outline"')}${button('vault-detail-refresh', 'Refresh vaults', 'class="outline"')}${button('vault-another', 'Create another vault', 'class="outline"')}`);
      if (prepared) content += panel(`${reviewHtml(prepared.review)}${button('vault-submit', 'Sign & broadcast')}${button('vault-review-cancel', 'Cancel', 'class="outline"')}`);
    } else {
      const overview = items.filter(i => i.record.status !== 'opened' || i.pending);
      content = items.filter(i => i.pending).map(notice).join('') + header() + panel(`<h2>My Vaults</h2>${overview.length ? overview.map(i => `<button class="vault-row outline" data-vault-id="${esc(i.record.covenantId)}"><span class="vault-row-icon">${i.record.terms.kind === 'timeLock' ? '◷' : '♡'}</span><span><b>${esc(i.record.terms.name)}</b><small>${esc(kas(i.record.amountSompi))} · ${esc(statusText(i))}</small></span><span>›</span></button>`).join('') : `<p>${items.length ? 'No active vaults. Opened vaults are hidden from this overview.' : 'No saved vaults yet. Create a vault, import a recovery file, or scan the DAG.'}</p>`}`) +
        panel(`<h2>Recovery</h2><details><summary>Post-quantum recovery protection</summary><p>Vault recovery files use Argon2id, XChaCha20-Poly1305, ML-KEM-1024 and ML-DSA-87. A strong password remains essential.</p></details>${button('vault-import', 'Import recovery file', 'class="outline"')}${button('vault-scan', 'Scan owner / beneficiary vaults', 'class="outline"')}`) +
        ['timeLock', 'deadManSwitch'].map(k => panel(`<img class="vault-type-image" src="vaults/${k === 'timeLock' ? 'timelockedvault' : 'deadmansswitch'}.png" alt=""><h2>${title(k)}</h2><p>${k === 'timeLock' ? 'Lock KAS until a chosen DAA score. Release to the fixed owner address after maturity.' : 'Keep control with Owner Pulses. The beneficiary can claim only after the configured inactivity period.'}</p><button data-vault-start="${k}">Start</button>`)).join('');
    }
    host.innerHTML = `${busy ? '<div class="loading" role="status">Checking vaults…</div>' : ''}${error ? panel(`<p class="error" role="alert">${esc(error)}</p><p>Saved vaults and recovery records are preserved.</p>`) : ''}${content}`;
    host.querySelectorAll<HTMLButtonElement | HTMLInputElement | HTMLSelectElement>('button,input,select').forEach(control => { if (busy) control.disabled = true; });
    document.querySelector<HTMLButtonElement>('#vault-home')!.disabled = busy;
    document.querySelector<HTMLButtonElement>('#vault-reload')!.disabled = busy;
    host.querySelectorAll<HTMLButtonElement>('[data-vault-start]').forEach(b => b.onclick = () => start(b.dataset.vaultStart!));
    host.querySelectorAll<HTMLButtonElement>('[data-vault-id]').forEach(b => b.onclick = () => { selected = b.dataset.vaultId!; prepared = null; paint(); });
    host.querySelectorAll<HTMLButtonElement>('[data-vault-resume]').forEach(b => b.onclick = () => void run(async () => { selected = b.dataset.vaultResume!; await finish(await hooks.command('covenantVaultResume', { covenantId: selected })); }));
    for (const key of ['name', 'amount', 'beneficiary', 'deadline'] as const) {
      host.querySelector<HTMLInputElement>('#vault-' + key)?.addEventListener('input', e => { form[key] = (e.target as HTMLInputElement).value; reset(); host.querySelector('#vault-submit')?.closest('.vault-panel')?.remove(); });
    }
    host.querySelector<HTMLSelectElement>('#vault-duration')?.addEventListener('change', e => { form.duration = Number((e.target as HTMLSelectElement).value); form.deadline = String(currentDaa() + form.duration); reset(); paint(); });
    click('vault-prepare', () => void run(() => prepare('create')));
    click('vault-submit', () => void run(submit));
    click('vault-pulse', () => void run(() => prepare('heartbeat')));
    click('vault-open', () => void run(() => prepare(current!.record.terms.kind === 'timeLock' ? 'release' : 'claim')));
    click('vault-export', () => void run(async () => { await exportRecovery(); }));
    click('vault-review-cancel', () => { prepared = null; paint(); });
    click('vault-detail-refresh', () => void run(() => load(true)));
    click('vault-back', home); click('vault-another', home);
    click('vault-return', () => { if (receipt?.confirmed) home(); else { receipt = null; paint(); } });
    click('vault-import', () => void run(async () => {
      const file = await chooseFile(); if (!file || !active()) return;
      if (file.size > 512 * 1024) throw Error('Recovery file is too large.');
      const envelope = await file.text(), password = await passwordPrompt(true);
      if (!password || !active()) { password?.fill(0); return; }
      try { const r = await hooks.command('covenantVaultImport', { envelope, password }); selected = r.covenantId; items = await hooks.command('covenantVaultSaved'); }
      finally { password.fill(0); }
      await dialog(`<h2>Vault recovery imported</h2><p>Vault data restored. Refresh to check its current on-chain state. Only the owner or beneficiary wallet can authorize the corresponding actions.</p>${button('vault-ok', 'Back to vault')}`, (host, finish) => { host.querySelector<HTMLButtonElement>('#vault-ok')!.onclick = () => finish(true); });
    }));
    click('vault-scan', () => void run(async () => {
      const count = await hooks.command('covenantVaultDiscover'); items = await hooks.command('covenantVaultSaved');
      await dialog(`<h2>DAG scan completed</h2><p>${esc(count)} new vault records restored. Existing records were preserved.</p>${button('vault-ok', 'Return to vaults')}`, (host, finish) => { host.querySelector<HTMLButtonElement>('#vault-ok')!.onclick = () => finish(true); });
    }));
  }
  document.querySelector<HTMLButtonElement>('#vault-home')!.onclick = home;
  document.querySelector<HTMLButtonElement>('#vault-reload')!.onclick = () => void run(() => load(true));
  const clock = setInterval(() => {
    if (!active()) { clearInterval(clock); clearInterval(confirmations); return; }
    const current = item(); if (!current) return;
    const state = countdown(current), counter = host.querySelector('#vault-countdown');
    if (counter) counter.textContent = state.text;
    const open = host.querySelector<HTMLButtonElement>('#vault-open'); if (open) open.disabled = busy || !state.canOpen;
  }, 1000);
  const confirmations = setInterval(() => {
    if (!active()) { clearInterval(clock); clearInterval(confirmations); return; }
    if (!busy && items.some(i => i.pending || i.record.status === 'pending')) void run(async () => {
      const result = await hooks.command('covenantVaultRefresh', { pendingOnly: true }); items = result.items;
      if (result.error) error = result.error;
      if (receipt && item() && !item()!.pending) receipt.confirmed = true;
    });
  }, 5000);
  await run(() => load(false, true));
}
