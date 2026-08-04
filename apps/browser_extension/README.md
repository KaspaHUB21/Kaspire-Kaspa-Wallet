# Kaspire Browser Extension

Manifest V3 counterpart to Kaspire Android. Websites communicate with an injected `window.kaspire` provider through an origin-bound content bridge. It does not use WalletConnect.

## Security architecture

The extension compiles Kaspire's existing `kaspa_secure_core` to WebAssembly. Seed generation, BIP-39 import and passphrases, HD derivation, KIP-5 signatures, transaction construction, PSKT analysis, KasCoven policy recognition, inscription reveals and KCC20 covenant execution therefore share the reviewed Rust implementation used by Kaspire Android.

Secrets are stored only inside a versioned Argon2id-derived AES-256-GCM vault. While unlocked, the decrypted vault is held in Chrome's memory-only session storage so normal Manifest V3 worker suspension does not interrupt an active wallet session. It is discarded on explicit locking, configured inactivity or browser-session termination. Recovery phrases and private keys require the vault password plus a separate high-risk approval window.

Websites receive `window.kaspire`. Requests cross an origin-bound content bridge and a bounded, declared method registry. Connecting, switching networks, signing messages, sending assets and signing reviewed PSKTs or recognized vault policies opens an extension-owned approval window. A website cannot supply the text displayed for a transaction review: Kaspire derives it from the Rust core's reconstructed transaction and binds approval to `reviewHash`.

KAS signing validates unique live UTXOs and node fee data. KRC-20, KRC-721 and KNS use canonical commit/reveal operations, verified holdings and resumable pending reveals. KCC20 requires complete signing cells from the indexer, checks them independently against Kaspire's local-node API and executes the covenant locally before broadcast.

## Implemented capabilities

1. Create, restore and import BIP-39, passphrase, private-key and watch wallets, including English BIP-39 autocomplete and invalid-word feedback.
2. BIP-44 accounts and address-index subwallets with correct selected-path signing.
3. Versioned encrypted backups, wallet naming, removal and Mainnet/TN10 switching.
4. KAS balance, activity details, address book, privacy mode and UTXO compound.
5. KRC-20, KRC-721, KNS and KCC20 balances plus reviewed transfer methods.
6. Origin-bound permissions and independently managed dApp sessions.
7. KIP-5, KAS, typed assets, reviewed PSKT and recognized KasCoven signing.
8. Theme, fiat preference, auto-lock and high-risk export controls.

The packaged build is validated by unit tests, Rust security-core tests and a real headless-Chromium flow covering onboarding, Manifest V3 worker restart, direct dApp connection and KIP-5 approval/signing. This is still not a substitute for an independent extension security audit or browser-store review.

Provider compatibility names follow public KasWare conventions where useful, but no KasWare key storage or signing code is copied.

```bash
npm install
npm run check
npm run build
npm run test:browser
npm run package
```

Load `dist/` at `chrome://extensions` → Developer mode → Load unpacked.
