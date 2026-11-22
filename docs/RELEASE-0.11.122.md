# Kaspire Android 0.11.122

2026-11-22. Android build **270**, cumulative since public **0.11.116 (264)**.
Includes the changes tested in Android 0.11.117 through 0.11.121.

## Native KAS / kUSDT swaps

- Adds **KAS / kUSDT** as the first entry in Swap, above the other KCC20 DEXes.
  Buy and sell through Trestly KasPool directly inside Kaspire on Kaspa Mainnet,
  without opening a dApp, connecting a separate session or bridging to an L2.
  kUSDT is the bridge-backed USDT asset issued through Trestly.
- Uses pinned local builders, token/pool identities and compiled locking scripts.
  Live inputs and state are independently verified; review binds the exact
  direction, debit, receive amount, fee limit and pool state. Native authorization
  and on-device script execution remain mandatory. No arbitrary dApp signing
  profile is enabled by this integration.
- Corrects pool base-value validation: the pool's base reserve is independent
  from the **1.5 KAS** recoverable storage attached to a user kUSDT cell.
  Native build tooling also invalidates the wallet crate's cached ABI outputs
  so restored source/build timestamps cannot silently reuse a stale native core.
- Displays available kUSDT and **MAX** for selling back to KAS, with exact
  six-decimal units. Incomplete or failed discovery is not displayed as zero.
  With fragmented holdings, the total and maximum per swap are shown separately:
  this native profile spends **one token UTXO per sell**, so MAX is the largest
  verified spendable cell. Automatic consolidation is not added.
- Uses Kaspire's dedicated exact-wRPC relay instead of the old SDK/GothDAG
  route. It forwards original signed bytes to the fixed own node, without keys,
  wallet SDK conversion, changed witnesses, output edits or automatic send retries.
- Preserves signed swaps before submission. Recovery checks the exact accepted
  transaction and mempool before resending; unknown/rejected results retain the
  same signed journal and show the bounded node error. It never silently creates
  a replacement swap or treats a submission acknowledgement as confirmation.
- Removes the requested audit-status sentence from this swap screen's footer;
  the bridge-backed asset and Kaspa-L1-only explanations remain.

## Igra and Kasplex ERC-20 tokens

- Removes the allowlist-only hiding and unsupported/unverified-identity labels
  from ordinary ERC-20 balances. Valid discovered contracts are shown directly.
- ERC-20 sending no longer depends on a discovery allowlist. Missing decimals
  are resolved through the contract's on-chain `decimals()` call when possible.
  If units cannot be established, the balance remains visible in raw units and
  sending stays disabled; the app never guesses 18 decimals.
- Rechecks the selected network after asynchronous discovery so late results
  cannot be applied to a different network. Existing native EVM signing and
  transaction-format validation remain unchanged.

## Braid and KForge recovery fixes

- Braid now independently finds the accepted transaction spending the exact
  saved deposit or verified intermediate coin when the provider's status is stale,
  unavailable or has forgotten the reference. It reconstructs pinned owned token
  outputs and verifies guaranteed payouts/refunds before completing a receipt.
  Missing history, unrelated spends and unaccepted transactions stay unresolved.
- Distinguishes waiting for **Braid execution** from waiting for a network
  confirmation, exposes provider reasons and indicates recovery after the
  independently read on-chain deadline. Status checks never sign or broadcast.
  Existing signed deposits, staged-route ancestry and recovery remain preserved.
- Braid still advertises the same pinned r2c router. The reported recent deposits
  were accepted but not executed by Braid and were refunded after their deadline.
  The wallet fix reconciles that outcome; it does not claim to repair the
  provider's executor or turn a refunded deposit into a successful swap.
- KForge's signature extractor now accepts canonical small-number data pushes
  in token witnesses. The exact normal-path witness layout and Schnorr
  SIGHASH_ALL requirements remain enforced, fixing affected sell submissions.

## Verification and public delivery

- Offline Rust signing/script-engine regression suite, Flutter DEX/token/update
  tests and built APK checks are required for this release. Coverage includes
  full-balance native sells, failed/partial balance discovery, exact MAX,
  stale/failed Braid status, positive refund proof, unrelated-spend rejection,
  narrow/all-theme layouts and the existing signed Android updater.
- The release preserves the Android certificate/rotation lineage, public-client
  configuration, permissions and the verified ARM64/ARMv7 native libraries from
  the tested APK. No real payment or physical-device end-to-end test is claimed.
- Publishes GitHub Release, website version/checksum/download and the signed
  Android update manifest. The native in-app installer and browser/manual path
  deliver identical APK bytes using existing installed-client update trust.
- Browser Extension **0.5.32**, iOS PWA **0.2.32** and Windows channels remain
  unchanged by this Android release. iOS journal/storage changes and all private
  or unrelated KaspaCom experiments are excluded from the Android APK and commit.

Android APK: `Kaspire-Android-mainnet-v0.11.122.apk`

SHA-256: `17417d0a9387d63cc6710fe5f3e22e8236ad77c029005d3349297e8cb398e5d6`
