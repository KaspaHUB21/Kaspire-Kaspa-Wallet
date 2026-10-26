# Kaspire Android 0.11.70 — Kasseal 0.3.0 and TN10 integrations

Build **215**, Android 11+, ARM64 and ARMv7. Complete cumulative Android changes
since public **0.11.69** (build 212), including private preview builds 213–214.
The browser extension remains **0.5.27**; Windows and its update channel are unchanged.

## Kasseal SDK 0.3.0

- Upgrade the unsigned Mainnet/TN10 planner to the pinned official SDK 0.3.0.
- Independently recognize both old and new contract programs in the native
  Rust signing core. Existing tokens, pools, sells and token preparation remain
  supported; the allowlist is extended, never replaced by a remote assertion.
- New curve contracts protect the creator's first buy for 200 DAA (about 20
  seconds). A first non-creator buy uses exactly the required relative sequence;
  the creator, later buys, sells and older programs do not acquire that delay.
- Verify creator copies, program fingerprints, wallet ownership, exact amounts,
  reviewed limits, fees and local execution before returning signed bytes.
- No Kasseal borrowed-receive policy expansion. The earlier exclusion remains.
- Extension 0.5.27 does not acquire new-contract signing support from this
  Android release. Existing-token planner compatibility is retained.

## Braid Aggregator — Testnet 10 only

- Add Braid to TN10 Swap, with KAS/token and supported single-stage token/token
  quotes, local native deposit verification, review and wallet authorization.
- Pin router r2c and the TN10 token deployment/program set. Independently check
  live UTXOs and two chain clocks, destination/refund, minimum received, input
  amounts, fees, nonce/intent, deadline and all transaction outputs.
- Save/read back encrypted receipts before submission. Reopening/resuming sends
  the same signatures, not a second payment. Export public recovery receipts.
- Verify completion against an independent accepted transaction spending the
  exact deposit. A missing/expired/failed API response never clears signed data.
- Build and verify deadline reclaims locally; no Braid API is needed to construct
  the reclaim. Both original tokens and returned KAS must be accounted for.
- My activity entries are now tappable: open the selected swap detail view,
  showing the paid amount, guaranteed minimum, route, status and transaction ID.
- Use theme-matched controls, narrow-screen layouts and exact sell percentages.
  Unknown/late balances do not become zero, and editing amounts clears quotes.
- Limits: no Mainnet Braid swaps, no staged KRON-to-KRON routes, no arbitrary
  token programs. TN10 mock-token amounts are explicitly base units. Integrator
  fee remains **0%** here; the requested future 1% is not silently enabled.

## KasForge — read-only TN10 preview

- Add independently network-gated token discovery, names/logos, balances,
  catalogue, token detail, buy/sell quote preview, portfolio and activity.
- Keep curve/pool routing distinct before/after graduation and reject stale
  market identity. Publish slow-source results independently; unavailable is not
  zero. Handle long labels, pagination, theme layouts and exact token units.
- The confidential contracts 3.3 kit was checked locally: all four supplied
  artifacts match their bytecode, script-hash, P2SH-address and template vectors.
  A read-only verifier is included; the kit, sources and artifacts are **not**.
- **Trading remains disabled.** The observed public build response supplies
  transactions/summary but not the new order-output redeem programs and complete
  recovery data needed for this wallet's independent deposit verification.
  The vector check is not an independent audit or proof of the full trading flow.

## Both Android update routes

Keep the existing themed chooser: download the APK from the official website,
or download the exact matching GitHub release inside Kaspire. The internal route
checks the signed manifest, checksum, package, version and signing identity before
opening Android's installer. Android still requires user installation approval.
Publish the GitHub APK first, then advertise this version in the signed manifest.

## Verification and limitations

- Full Rust library suite: **142 passed**, including new SDK-generated synthetic
  creator-window buys on both networks and rejection of altered sequences.
- Full Flutter suite with TN10 integrations enabled: **753 passed**; live network
  suites are opt-in. Braid activity navigation and all-theme narrow layouts pass.
- Unsigned planner/catalogue suite: **14 passed**, including old-token behavior.
- Synthetic transactions use public dummy keys and fake outpoints; no real
  funds were signed or broadcast. Real unsigned Braid build/node/native checks
  passed separately during preview development.
- Verified the actual release APK's version/build, both native ABIs, client
  configuration, alignment and existing v3 release signature.
- No physical Android device is attached to the build server. Automated tests
  and package checks do not replace a funded device swap/refund or the user's
  internal-update installation test. These contracts are not claimed audited.

## Downloads

- [Official APK](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.70.apk)
- [GitHub APK](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/v0.11.70/Kaspire-Android-mainnet-v0.11.70.apk)
- SHA-256: `37e58ec7371a0c2d9ab76d747a3c96f247a0489544cb406734e4d989d3cfdec1`.

Install over the existing app; do not uninstall. Keep a current encrypted backup.
