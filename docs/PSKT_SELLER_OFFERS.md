# Partially funded seller PSKTs

Available in Android 0.11.29 (build 95) and extension 0.4.7.

`signPskt` (extension) and `kaspa_signPskt` (WalletConnect) accept sign-only
seller drafts whose output total exceeds the embedded UTXO total, provided
**every selected input uses SINGLE|ANYONECANPAY (132)** and has a same-index
output. Script-aware selection supports the same rule. The buyer supplies
funding later. Other underfunded sighash combinations remain rejected.

P2SH script matching, duplicate-outpoint checks, review binding, safe JSON
preservation and stale-session rejection remain enforced. No changes to
ordinary KAS, KRON or legacy KCC20 funding checks are implied.

The Rust review exposes:

- `fundingDeficitSompi`: additional input value needed before network fees.
- `feeSompi`: null when unfunded; otherwise the current draft input/output
  difference. With mutable sighashes this is not a final fee quote.
- `finalFeeKnown`: false for mutable sighashes.
- `outputs[].signatureBound`: whether a selected signature binds that output.

The confirmation shows missing buyer funding, unknown final fee, bound
payouts and draft-only totals. An unfunded draft returns signed SafeJSON but
no broadcastable `submitJson`. Keep `submitTransaction: false`. The backend
must complete and validate the transaction before broadcasting.

The supplied KaspaCom example (1.05 KAS input, 3.05 KAS paired payout) is
stored in `apps/browser_extension/tests/fixtures/kaspacom-seller-offer.json`.
Rust tests prepare that exact TN10 draft. A generated P2SH seller-signature
test uses official Rusty-Kaspa sighash calculation and Schnorr verification:
buyer funding and change preserve the signature; changing the paired payout
invalidates it. WASM and Chromium tests exercise underfunded sign-only flows.

These are local capability/regression tests, not completed KaspaCom
provider-plus-adapter tests or a live testnet broadcast. KaspaCom owns its
internal adapter and must retest its final seller/buyer flow with these builds.
