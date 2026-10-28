# Braid TN10 Android preview

This document records the original TN10 preview. Android 0.11.76/build 221
supersedes its Mainnet and fee restrictions with the pinned Mainnet router
and a disclosed 1% partner fee, including independently valued atomic
token-to-token routes. See [the current release](release-v0.11.76.md).
Historical evidence and the deliberate exclusion of staged KRON-to-KRON
routes remain documented below. The browser extension is unchanged.

Android 0.11.71/build 216 adds a searchable selector for each side and selected
token covenant IDs with copy buttons. These UI changes do not enable partner
fees: the pinned native profile remains 0%, pending independent Token→Token
valuation for the requested full 1% integration.

Release 0.11.70/build 215 includes this TN10 integration and fixes activity
selection. It is enabled by default on TN10 (build-time opt-out remains possible).
See [release notes](release-v0.11.70.md). Mainnet Braid and extension remain disabled.

Historical preview evidence below refers to private build 214, `0.11.69-braid-preview`.
Enable with `KASPIRE_BRAID_TN10=true`. Mainnet, extension, public manifests,
website and GitHub releases are unchanged. KasForge's preceding read-only
preview remains available with its separate opt-in flag.

## Source and trust boundary

Reviewed the public wallet documentation at
https://app.braidswap.com/docs/wallets and the independently readable TN10
reference frontend/recovery implementation at https://tn10-aggregator.braidswap.com.
Downloaded reference files are data only; they are not bundled or executed.
No provider JavaScript executes in the wallet. Quotes/builds are untrusted.

The first native profile pins r2c router fingerprint
`905df466072298313e1cc9e86132ba61f26e2a359f7a7dbd5028fa1963872646`,
executor, fee key, program length, all 21 state fields, BRT1 v4 payload,
fresh nonce/ref intent, token identities and exact token program fingerprints.
This is a covenant deposit followed by execution/refund, not a claim that the
user's deposit and final execution occur in one atomic wallet transaction.

The native core checks the exact wallet debit, recipient/refund, token
conservation/change, minimum payout, fee/deadline bounds and SIGHASH_ALL.
Signed deposits and reclaims execute every input locally before leaving Rust.
Independent live TN10 UTXOs are fetched through Kaspire's existing full-node
gateway; clocks come from public REST and a separate synced public wRPC node.
No quote-server clock or arbitrarily supplied node URL is trusted.

## Deliberate limits

- TN10 only, ordinary Schnorr wallet. Never used with Mainnet keys/addresses.
- The frozen public TN10 test-token set is supported, not similarly named
  Mainnet deployments. Token amounts are explicitly **base units** until
  deployment-specific unit declarations are independently verified.
- User selected a future 1% partner fee. This first TN10 profile strictly
  permits 0% integrator fee; no TN10 fee address has been designated. Enabling
  a fee requires a separately reviewed native policy and clear review UI.
- Staged KRON-to-KRON routes are rejected: they can refund intermediate KAS,
  which is not equivalent to returning the original input asset.
- No automatic token-note consolidation, arbitrary/custom token programs,
  Braid Mainnet endpoint, extension port or public release in this change.
- Braid mock-token balances appear within Braid. This does not claim universal
  discovery of every Braid mock token by unrelated portfolio indexers.

## Recovery and UI

The encrypted, read-back-verified journal is saved before any signed bytes are
submitted. Unknown, missing, expired or failed API responses never erase a
signed receipt. Reopening resumes the same signatures, never a fresh payment.
Finality requires an independently accepted transaction spending the exact
saved deposit and paying the saved guaranteed asset/amount to this wallet.
Refund verification includes both the original token note and returned KAS.

After the on-chain deadline, recovery is built locally from the saved receipt
and live outpoints and submitted to a network-checked independent public node.
No Braid API is required to construct or sign the reclaim. Maximum reclaim
fee is 0.05 KAS. The public recovery receipt can be exported; it contains no
seed/private key, but may contain public signed transaction bytes.

All four themes inherit the wallet's existing widget styling. Narrow-layout,
percentage buttons, quote invalidation, failed/late balance loading and
navigation/signing state are tested. Other platforms are intentionally unchanged.

## Verification

- Full Rust security-core library suite: 140 tests passed.
- Full Flutter suite: 751 tests passed; opt-in live network tests remain skipped
  in the offline suite. Targeted static analysis reports no issues.
- Synthetic KAS deposits/reclaims and reference/KaspaRocket token sell
  deposits/reclaims sign and execute locally using dummy keys only.
- Real unsigned TN10 KAS-to-ICE build passes independent live UTXO enrichment
  and the native review; locally computed transaction ID matches provider ID.
- Router/terms/outputs/fees/signature mutations are rejected.
- No real wallet secret, real signed trade or broadcast is used in these tests.
- Widget/unit tests are not a funded Android-device end-to-end test. No
  Android device is attached to this server; a funded TN10 on-device swap and
  refund remain a tester handoff step.

Build with `scripts/build_android_release.sh` after rebuilding both Android
Rust ABIs. Preserve normal production signing identity and configured Reown/
KaspaRocket client keys. Never replace public APK aliases or update manifests
with this opt-in preview. The next build intended to upgrade preview testers
must have a versionCode greater than 214.

Signed APK SHA-256:
`1083bf9b012b120af613a9a65826a43de7f1667decdd498f113d4089167034ed`.
The final package has the existing Android release certificate, versionCode 214,
both rebuilt Rust ABIs and verified Reown/KaspaRocket client configuration.
