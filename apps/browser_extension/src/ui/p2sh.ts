import QRCode from 'qrcode';
import { formatRawTokenAmount } from '../shared/tokenAmount';
import { p2shIntro, p2shSeparate, p2shRecovery, p2shExposure, p2shAccept } from '../shared/p2sh';

type Row = Record<string, any>;
type Hooks = {
  command(name: string, values?: Record<string, unknown>, signal?: AbortSignal): Promise<any>;
  shell(content: string, title?: string, back?: boolean): void;
  regular(): void; address(): string; copy(text: string, message: string): void;
};
const esc = (value: unknown) => String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
const kas = (raw: unknown) => formatRawTokenAmount(String(raw ?? 0), 8) + ' KAS';
const line = (label: string, value: unknown) => `<div class="vault-line"><small>${esc(label)}</small><span>${esc(value)}</span></div>`;
const panel = (content: string) => `<article class="review-card vault-panel">${content}</article>`;
export const receiveModeTabs = (p2sh: boolean) => `<div class="p2sh-tabs" role="group" aria-label="Receive account"><button id="receive-regular" class="${p2sh ? 'outline' : ''}" aria-pressed="${!p2sh}">Receive KAS</button><button id="receive-p2sh" class="${p2sh ? '' : 'outline'}" aria-pressed="${p2sh}">P2SH account</button></div>`;
function backupPassword(): Promise<string | null> {
  return new Promise(resolve => {
    const dialog = document.createElement('dialog'); dialog.className = 'vault-dialog';
    dialog.innerHTML = '<h2>Save encrypted recovery backup</h2><p>This backup includes your wallet secret, issued/retired P2SH addresses and any saved payment. Keep it and its password safe.</p><label>Backup password<input id="p2sh-backup-password" type="password" autocomplete="new-password"></label><label>Confirm password<input id="p2sh-backup-confirm" type="password" autocomplete="new-password"></label><p id="p2sh-password-error" class="error"></p><div class="vault-actions"><button id="p2sh-backup-cancel" class="outline">Cancel</button><button id="p2sh-backup-save">Save backup</button></div>';
    document.body.append(dialog); dialog.showModal();
    const finish = (value: string | null) => { dialog.querySelectorAll('input').forEach(input => { input.value = ''; }); dialog.close(); dialog.remove(); resolve(value); };
    dialog.oncancel = e => { e.preventDefault(); finish(null); };
    dialog.querySelector<HTMLButtonElement>('#p2sh-backup-cancel')!.onclick = () => finish(null);
    dialog.querySelector<HTMLButtonElement>('#p2sh-backup-save')!.onclick = () => {
      const password = dialog.querySelector<HTMLInputElement>('#p2sh-backup-password')!.value;
      if (password.length < 12 || password !== dialog.querySelector<HTMLInputElement>('#p2sh-backup-confirm')!.value) { dialog.querySelector('#p2sh-password-error')!.textContent = 'Use at least 12 characters and matching passwords.'; return; }
      finish(password);
    };
  });
}
export async function openP2sh(hooks: Hooks) {
  hooks.shell(`<section class="p2sh-screen">${receiveModeTabs(true)}<div id="p2sh-content"></div></section>`, 'Receive KAS', true);
  const host = document.querySelector<HTMLElement>('#p2sh-content')!, controller = new AbortController(), owner = hooks.address();
  const active = () => host.isConnected && owner === hooks.address();
  const observer = new MutationObserver(() => { if (!active()) { controller.abort(); observer.disconnect(); } });
  observer.observe(document.querySelector('#app')!, { childList: true, subtree: true });
  const command = (name: string, data: Record<string, unknown> = {}) => hooks.command(name, data, controller.signal);
  let accepted = false, busy = false, error = '', progress = '', hdMessage = '', supportKnown = false;
  let snapshot: Row | null = null, state: Row | null = null, receive: Row | null = null, prepared: Row | null = null, receipt: Row | null = null;
  let recipient = '', amount = '', sendAll = false, transactions: Row[] = [], copied = '';
  document.querySelector<HTMLButtonElement>('#receive-regular')!.onclick = () => hooks.regular();
  const listener = (event: Event) => { if (active()) { progress = (event as CustomEvent).detail; const label = host.querySelector('#p2sh-progress'); if (label) label.textContent = progress; } };
  document.addEventListener('kaspire-operation-progress', listener);
  const cleanup = new MutationObserver(() => { if (!active()) { document.removeEventListener('kaspire-operation-progress', listener); cleanup.disconnect(); } });
  cleanup.observe(document.querySelector('#app')!, { childList: true, subtree: true });
  async function run(action: () => Promise<void>) {
    if (busy || !active()) return; busy = true; error = ''; copied = ''; paint();
    try { await action(); }
    catch (e) {
      error = (e as Error).message;
      if (!receipt?.confirmed) receipt = null;
      try { state = await command('p2shState'); } catch { /* Keep existing state, never treat lookup failure as zero. */ }
      prepared = null; receive = null;
    } finally { busy = false; progress = ''; if (active()) paint(); }
  }
  async function refresh() {
    const result = await command('p2shRefresh');
    state = result.state; prepared = null;
    if (result.payment) { receipt = result.payment; receive = null; snapshot = null; transactions = []; return; }
    receipt = null; snapshot = result; receive = result.receive; transactions = result.transactions; error = result.activityError ?? '';
  }
  async function backup() {
    const password = await backupPassword(); if (password == null || !active()) return;
    const raw = await command('exportBackup', { password }); if (!active()) return;
    const url = URL.createObjectURL(new Blob([raw], { type: 'application/json' }));
    const link = document.createElement('a'); link.href = url; link.download = 'Kaspire-P2SH-Recovery.json'; document.body.append(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url), 30000);
    copied = 'Encrypted recovery backup downloaded. Keep the file and its password safe.';
  }
  function paint() {
    if (!active()) return;
    const pending = state?.pending, review = prepared?.review;
    let html = panel(`<h1>P2SH account</h1><p>${p2shIntro}</p><p>${p2shSeparate}</p><details><summary>Recovery and key exposure</summary><p>KIP-22 · PR #48<br>Descriptor: kip22-p2sh-v1<br>Derivation: m/22'/111111'/0'/branch/index<br>Receive branch 0 · change branch 1 · discovery gap 20.<br>Redeem script: &lt;x-only public key&gt; OP_CHECKSIG.</p><p>${p2shRecovery}</p><p>${esc(p2shExposure)}</p></details>${hdMessage ? `<h2>Seed-based HD wallet required</h2><p>${esc(hdMessage)}</p>` : supportKnown && !accepted ? `<label class="p2sh-accept"><input id="p2sh-accept" type="checkbox">${p2shAccept}</label>` : ''}`);
    if (busy) html += '<p class="loading" id="p2sh-progress" role="status">' + esc(progress || 'Checking account…') + '</p>';
    if (error) html += panel(`<p class="error" role="alert">${esc(error)}</p><p>Saved addresses and signed payments remain preserved. Refresh before trying again.</p>`);
    if (copied) html += panel(`<p role="status">${esc(copied)}</p>`);
    if (receipt?.confirmed) html += panel(`<div class="receipt-check">✓</div><h2>Payment confirmed by the Kaspire node.</h2>${line('Transaction ID', receipt.transactionId)}<button id="p2sh-return">Return to account</button>`);
    if (pending) html += panel(`<h2>Payment awaiting confirmation</h2><p>The signed payment is safely saved. Kaspire checks it automatically before submitting the same bytes. Do not create another payment. Input keys are already retired.</p>${receipt?.submissionIssue ? line('Submission status', receipt.submissionIssue) : ''}${line('Transaction ID', pending.transactionId)}<button id="p2sh-resume">Check payment status</button>`);
    if (snapshot && !receipt?.confirmed) html += panel(`<h2>Separate KAS account balance</h2><h1>${esc(kas(snapshot.balanceSompi))}</h1><p>This balance is not part of your ordinary wallet balance.</p><button id="p2sh-backup">Save encrypted recovery backup</button>`);
    if (receive && !pending && !receipt && !busy) html += panel(`<h2>Receive KAS</h2><p>P2SH address · public key not published by this account</p><div class="receive-qr"><img id="p2sh-qr" alt="QR code for the P2SH receive address"></div><code class="p2sh-address">${esc(receive.address)}</code><div class="p2sh-actions"><button id="p2sh-copy">Copy address</button><button id="p2sh-new" class="outline">New receive address</button></div>`);
    if (snapshot && !pending && !receipt) html += panel(`<h2>Send KAS</h2><label>Kaspa Mainnet recipient address<input id="p2sh-recipient" value="${esc(recipient)}" spellcheck="false"></label><div class="p2sh-amount"><label>Amount${sendAll ? ' (Max)' : ' in KAS'}<input id="p2sh-amount" value="${esc(amount)}" inputmode="decimal" ${sendAll ? 'readonly' : ''}></label><button id="p2sh-max" class="outline">${sendAll ? 'Cancel' : 'Max'}</button></div>${sendAll ? '<p>The network fee is deducted automatically. Review shows the exact amount; no change output is created.</p>' : ''}<button id="p2sh-review">Review payment</button>`);
    if (review) html += panel(`<h2>Review payment</h2>${line('Recipient', review.recipient)}${line(review.sendAll ? 'Amount (Max)' : 'Amount', kas(review.amountSompi))}${line('Network fee', kas(review.feeSompi))}${BigInt(review.changeSompi) > 0n ? line('Fresh P2SH change', kas(review.changeSompi)) + line('Change address', review.changeAddress) : '<p>No change output · entire spendable balance minus the network fee.</p>'}${line('Inputs', review.inputCount)}<button id="p2sh-submit">Sign and send</button>`);
    if (transactions.length && !receipt) html += panel(`<h2>Account activity</h2>${transactions.map(tx => `<div class="p2sh-activity"><span>${tx.incoming ? '↙' : '↗'}</span><div><b>${esc(kas(tx.amountSompi))}</b><code>${esc(tx.transactionId)}</code></div><button class="outline mini" data-p2sh-tx="${esc(tx.transactionId)}" title="Copy transaction ID" aria-label="Copy transaction ID">Copy</button></div>`).join('')}`);
    if (accepted && !receipt?.confirmed) html += '<button id="p2sh-refresh" class="outline">Refresh account</button>';
    host.innerHTML = html;
    host.querySelectorAll<HTMLButtonElement | HTMLInputElement>('button,input').forEach(control => { if (busy) control.disabled = true; });
    document.querySelector<HTMLButtonElement>('#receive-regular')!.disabled = busy;
    const click = (id: string, fn: () => void) => host.querySelector<HTMLButtonElement>('#' + id)?.addEventListener('click', fn);
    host.querySelector<HTMLInputElement>('#p2sh-accept')?.addEventListener('change', () => { accepted = true; void run(refresh); });
    click('p2sh-refresh', () => void run(refresh)); click('p2sh-return', () => void run(refresh));
    click('p2sh-backup', () => void run(backup));
    click('p2sh-resume', () => void run(async () => { receipt = await command('p2shResume'); state = await command('p2shState'); }));
    click('p2sh-copy', () => hooks.copy(String(receive!.address), 'Address copied'));
    click('p2sh-new', () => void run(async () => { const result = await command('p2shReceive', { fresh: true }); receive = result.address; state = result.state; }));
    click('p2sh-max', () => { sendAll = !sendAll; prepared = null; amount = ''; paint(); });
    host.querySelector<HTMLInputElement>('#p2sh-recipient')?.addEventListener('input', e => { recipient = (e.target as HTMLInputElement).value; prepared = null; host.querySelector('#p2sh-submit')?.closest('article')?.remove(); });
    host.querySelector<HTMLInputElement>('#p2sh-amount')?.addEventListener('input', e => { amount = (e.target as HTMLInputElement).value; prepared = null; host.querySelector('#p2sh-submit')?.closest('article')?.remove(); });
    click('p2sh-review', () => void run(async () => { prepared = await command('p2shPrepare', { recipient, amount, sendAll }); if (sendAll) amount = formatRawTokenAmount(String(prepared!.review.amountSompi), 8); }));
    click('p2sh-submit', () => void run(async () => { const result = await command('p2shSubmit', { id: prepared!.id }); prepared = null; receive = null; snapshot = null; receipt = result; state = await command('p2shState'); }));
    host.querySelectorAll<HTMLButtonElement>('[data-p2sh-tx]').forEach(button => button.onclick = () => hooks.copy(button.dataset.p2shTx!, 'Transaction ID copied'));
    const image = host.querySelector<HTMLImageElement>('#p2sh-qr');
    if (image && receive) void QRCode.toDataURL(String(receive.address), { width: 240, margin: 2, color: { dark: '#000000', light: '#ffffff' } }).then(url => { if (image.isConnected) image.src = url; });
  }
  paint();
  await run(async () => { const support = await command('p2shSupport'); supportKnown = true; if (!support.supported) hdMessage = support.message; });
}
