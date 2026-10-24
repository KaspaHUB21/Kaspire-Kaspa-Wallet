# Kaspire Browser Extension

Manifest V3 counterpart to Kaspire Android. Websites communicate with an injected `window.kaspire` provider through an origin-bound content bridge. It does not use WalletConnect.

## 0.5.23 — Kasseal recovery

Recovery recognizes both the Rust SDK's flat SafeJSON input outpoints and the
nested Rocket RPC form. It does not rewrite saved signed bytes, clear uncertain
payments or create a replacement. Newly verified/signed Kasseal swaps submit
without a redundant history scan; later recovery/rejection uses independently
confirmed exact-outpoint conflicts. Existing encrypted pending swaps survive
the upgrade unchanged.

## 0.5.22 — Kasseal and KCC20

Swap now lists KaspaRocket, Kasseal DEX and KRON, in that order. Kasseal uses the
same pinned SDK 0.1.1 unsigned planner, native Mainnet contract profiles, live
own-node UTXO checks and Rust/WASM script execution as Android. No API key or
remote signing code is bundled. Token discovery is independent; a failed source
does not erase another source's holdings. Search is global rather than limited
to the first loaded catalogue page.

Sell preparations are reviewed as self-owned split/merge operations, confirmed
and indexed before a fresh trade review. They are not recorded as sales. Signed
transactions are persisted inside the encrypted wallet before submission and
resumed only as the same bytes. Confirmed trades appear in My activity.

Rocket tokens open their asset detail screen before Send Asset or Swap. Direct
transfers resolve live reference 10/10 token cells through Kaspire's own-node
gateway, with local native reconstruction and VM validation. Their explorer links
use `/kcc20/<covenantId>`. This package also includes the latest P2SH history,
swap-conflict pagination, verified KCC23 display and dot.k filters.

## 0.5.21 — KaspaRocket Mainnet

Swap lists KaspaRocket before KRON and preserves the DEX Swaps / My Activity flow.
Bonding-curve holdings and correctly scaled token prices load directly from
KaspaRocket, independently of Kasvio. Mainnet credentials stay on the fixed
Kaspire gateway; no provider key is included in the extension.

The same Mainnet Rust/WASM profile checks network, covenant IDs, SIGHASH_ALL,
review binding, fee payouts and every signed contract. Inputs are checked
against the own node. Signed swaps are saved in the encrypted wallet vault
before broadcast; status/recovery never authorizes a replacement transaction.
A confirmed competing spend can archive an obsolete first step and release
Refresh quote. Missing transactions, HTTP 409, timeouts and partly completed
plans do not discard a pending swap. Operations are bound to the unlocked
session, selected wallet derivation path and network.

KaspaRocket moved its former TN10 deployment to Mainnet. The old network is
rejected explicitly instead of showing Mainnet assets inside a TN10 account.

## Security architecture

The extension compiles Kaspire's existing `kaspa_secure_core` to WebAssembly. Seed generation, BIP-39 import and passphrases, HD derivation, KIP-5 signatures, transaction construction, PSKT analysis, KasCoven policy recognition, inscription reveals and KCC20 covenant execution therefore share the reviewed Rust implementation used by Kaspire Android.

Secrets are stored only inside a versioned Argon2id-derived AES-256-GCM vault. While unlocked, the decrypted vault is held in the extension's memory-only offscreen session so normal Manifest V3 worker suspension does not interrupt an active wallet session. Chrome session storage contains the random session-channel token, not the decrypted vault. The unlocked session is discarded on explicit locking, configured inactivity or browser-session termination. Recovery phrases and private keys require the vault password plus a separate high-risk approval window.

Websites receive `window.kaspire`. Requests cross an origin-bound content bridge and a bounded, declared method registry. Connecting, switching networks, signing messages, sending assets and signing reviewed PSKTs or recognized vault policies opens an extension-owned approval window. A website cannot supply the text displayed for a transaction review: Kaspire derives it from the Rust core's reconstructed transaction and binds approval to `reviewHash`.

KAS signing validates unique live UTXOs and node fee data. KRC-20, KRC-721 and KNS use canonical commit/reveal operations, verified holdings and resumable pending reveals. KCC20 requires complete signing cells from the indexer, checks them independently against Kaspire's local-node API and executes the covenant locally before broadcast.

Pinned standard KCC20 payments that require consolidation use a deterministic payment plan: all self-consolidations and the final recipient payment, including every transaction ID and the total network fee, are reviewed together and bound to one approval hash. The native core rebuilds and VM-validates the whole chain before returning any signatures. All signed bytes are persisted before the first broadcast. Recovery checks accepted parents and replays only the identical approved transactions; it never signs a replacement or changes fees. A plan is limited to 65 original token cells / 32 transactions. The original reference actor retains its three-token-input/output limit; the independently pinned 10/10 configuration allows ten before consolidation is needed. Indexer metadata cannot override either template. Older KCC20 and KRON profiles retain their existing flows.

## Implemented capabilities

1. Create, restore and import BIP-39, passphrase, private-key and watch wallets, including English BIP-39 autocomplete and invalid-word feedback.
2. BIP-44 accounts and address-index subwallets with correct selected-path signing.
3. Versioned encrypted backups, wallet naming, removal and Mainnet/TN10 switching.
4. KAS balance, activity details, address book, privacy mode and UTXO compound.
5. KRC-20, KRC-721, KNS and KCC20 balances plus reviewed transfer methods.
6. Origin-bound permissions and independently managed dApp sessions.
7. KIP-5, KAS, typed assets, reviewed PSKT and recognized KasCoven signing.
8. Theme, fiat preference, auto-lock and high-risk export controls.

## Marketplace and DEX provider profile

`window.kaspire` exposes the native primitives KaspaCom requested without
embedding marketplace-specific business methods. The KCOM adapter is a private
KaspaCom integration layer built inside KCC20/Kaspiano after provider review;
it is not an SDK or adapter maintained in this repository. Normalized PSKT
requests support explicit input indexes, all six Kaspa sighashes, P2SH redeem
scripts and the
`wrap-signature`, `signature-first-args`, and `ordered-args` argument templates.
The Rust core preserves app metadata and covenant outputs and rejects stale
account or network state after the approval window opens.

Authentication returns the selected x-only public key together with the KIP-5
signature. Balance results include `{ current, pending, outgoing }` in KAS.
Account, network, connection and monitored balance changes are exposed as
provider events. Mainnet and TN10 generic Kaspa operations are available;
unsupported networks and Mainnet-only asset helpers fail with explicit errors.

See [the complete Kaspire provider API hand-off](../../docs/KASPACOM_PROVIDER.md)
for request schemas, response compatibility, native evidence and
backend-broadcast guidance.

The packaged build is validated by unit tests, Rust security-core tests and a
real headless-Chromium flow covering onboarding, Manifest V3 worker restart,
direct dApp connection, KIP-5 auth/public-key consistency, normalized
script-aware PSKT signing, SafeJSON preservation, TN10 switching/events and
stale-request rejection. This is still not a substitute for an independent
extension security audit, browser-store review or KaspaCom's target-app
acceptance run.

Provider compatibility names follow public KasWare conventions where useful, but no KasWare key storage or signing code is copied.

```bash
npm install
npm run check
npm run build
npm run test:browser
npm run package
```

Load `dist/` at `chrome://extensions` → Developer mode → Load unpacked.

## Neptune and NFT Market

Neptune reuses Android's local ocean, water-glass and moon-orb artwork, including
the corrected logo placement. Select it in Settings → Wallet display.

K-Agora now offers dot.k Market and NFT Market separately. NFT Market uses the
same KRC721 commit/reveal listing and seller PSKT profile as Android, with Browse,
My NFTs and My listings, 10-item pagination, collection/trait filters and price
sorting. Send and List remain separate NFT actions. Public recovery records are
saved before broadcast; incomplete listings and ambiguous broadcasts can resume.
Completed listings publish automatically, with bounded retry on indexer lag.

NFT inventories, images and rarity metadata prefer the read-only Kaspire gateway.
Only source unavailability invokes the official inventory fallback; healthy empty
results remain authoritative. Ownership/listing/spendability checks for transactions
use the official KaspaCom indexer and accepted node data, never display metadata.

The native PSKT profile checks the 2.1% fee and the hub21.kas address pinned per
listing. A seller's SINGLE|ANYONECANPAY signature binds the seller payout but
cannot make the fee unavoidable for an external PSKT consumer. The approval
screen discloses this limitation. No operator escrow or server-held keys are used.

The 0.5.7.1 revision restores collection thumbnails from held NFT IDs,
places Send and List below each gallery image, and hides recovery/publication
controls on sold or cancelled listings. Remote app listings without a local
extension recovery stage are not considered incomplete. Genuine pending local
transactions retain their recovery flow. Neptune uses an intrinsic 420px root
width to avoid viewport-dependent browser-action autosizing feedback.

Additional checks: `npm test`, `node tests/neptune-nft-browser.mjs` and
`node tests/neptune-popup-browser.mjs` after build. The popup check opens the
actual Chromium browser action repeatedly, including persisted Neptune settings.
Browser fixtures and synthetic WASM settlement tests do not broadcast transactions;
real-wallet acceptance testing is still required before a public release.

## 0.5.8.2 KRON DEX and Nexus Offers

Swap opens the DEX selection on Mainnet, with Kron DEX for bonding-curve and
DEX trades. It uses Android's unsigned planner, pinned own-node input/origin
verification and the locally reviewed `kron-swap-v1` Rust PSKT profile. Token
amounts use the token's decimals in balances, quotes, reviews, receipts and
Activity. Partner attribution is `kaspirewallet` and does not add a fee.
Lock, wallet and network changes invalidate prepared signing approvals.
Signed swaps are saved before submission and can resume the same bytes.

Nexus Offers recognizes Kaspire and KaspaCom PSKT listings using the shared
cached resolver, including venue-labelled prices and listing notifications.
KaspaCom links open the specific NFT on the official KaspaCom site; its full
marketplace is not embedded in this extension. Private offers and negotiation
remain inside Kaspire, with no funds locked. KaspaCom credentials are never
included in the package. Package and display names do not use a testing suffix.

The swap approval stays visible inside Kaspire. Closing or rejecting the review
ends the pending authorization instead of leaving a permanent in-progress lock.
Broadcast timeouts retain the signed transaction; Resume submits those same bytes.

KAS Activity derives swap direction and amount from the inputs and change of all
controlled account addresses, not the pool's total transaction outputs. Purchases
show the wallet debit and sales the wallet credit, including fees and reserve
changes in that balance change. Full pool/covenant movements remain expandable
technical details. Ordinary KAS transfers retain their separate transfer amount
and network fee. Existing transactions use the corrected calculation on reload.

Validation for 0.5.8.2: 105 automated tests, TypeScript checks, themed browser
fixtures and the real Chromium extension smoke test. The smoke test covers
onboarding, dApp approvals, signing, backups and pending reveal recovery; it does
not broadcast a real mainnet swap.
