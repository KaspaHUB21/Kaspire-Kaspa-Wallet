# KForge v6 Testnet 10 integration

KForge is a separate protocol from **KasForge**. This build enables direct,
atomic KForge curve and pool buys/sells on TN10 only. It does not enable KForge
mainnet or alter Android's public update channel, iOS or the extension.

## Independent contract boundary

The original partner archive and SilverScript sources stay private. The pinned
program data in `kforge_templates.json` was generated from the provided sources,
not downloaded executable SDK logic. Curve/pool compilation uses official
SilverScript commit `9aa70b0d0215e7395e2a95b78472eba0a5b103a5`;
the newer token syntax uses `3ed973335b59269293564805cc2c58a14595ec03`.
The compiled token equals the public token artifact byte for byte. The locally
compiled curve/pool programs match all four captured unsigned API plans' actual
input script commitments. No real wallet secret was used in these comparisons.

Source BLAKE2b-256 fingerprints:

- Curve: `be6d573c719c7965137e70c719aeefc4bd4622ce3ca3e29666e13a2504370c4c`
- Pool: `b5ef5133cf6f74d7b4b830a7e21871ff4ac8779e2f07578ac0a351df1f6d6d53`
- Token: `354841165fb93eea8c7114a70534ad5f7bc7f4143ba3c08fe4a7cc11c2c28d26`

The registry's advertised token BLAKE2b template hash `10c4da…` is not the
six-field token-view hash used by the deployed curve/pool. The independently
computed prefix34/suffix7068 hash is
`0836984efba7bd153858cf421c55a0bf725ccfbfb1b46f928e9b1b02651d9cce`.
Substituting the advertised hash fails the live program comparison; using this
computed hash matches. Token's internal BLAKE3 context is unchanged:
`3c1a50add31375a61341f0e041c5eb35ba122684894d37fea8270441088c8564`.
Registry assertions cannot override the native pins.

`kforge-tn10-swap-v1` rebuilds programs, state transitions and **all** contract
witnesses locally. It checks selected amount/side, both covenant IDs, ownership,
token conservation, receive policies, covenant output authorities, exact venue
math, wallet-only payouts/change, token-cell reserves, SIGHASH_ALL and the API's
expected sighash. Fees are bounded by independently sized, signed transaction
mass and an absolute 1-KAS cap (sale allowance at most 0.4 KAS). Consensus mass
limits are read from the pinned Rust core rather than a legacy standardness
constant. The signed transaction receives its calculated storage commitment;
all inputs execute in the local Rust script VM before any signature is returned.
No generic PSKT or KCC20 signing rules are broadened.

Dart separately verifies each exact outpoint's amount, script, covenant ID,
coinbase flag and DAA against Kaspire's TN10 node before review and again before
signing. Metadata or indexed balances alone never authorize a signature.

## Amounts and recovery

KForge tokens have **zero decimals**. Curves trade lots of 1,000,000 tokens;
pools allow any whole token amount. Curve buys include the contract's burn rule;
zero-amount burn outputs still need a KAS reserve. No UI calls this reserve
universally refundable. Curve sell proceeds follow the contract's two fee
deductions, not a guessed single-fee formula. Pool liquidity and wallet funding
inputs are never displayed as trade proceeds.

Unsigned quotes expire without creating a blocking saved payment. Signed bytes
are saved to encrypted storage with readback before submission. A single-wallet
busy guard covers review, signing, persistence and submission and always releases
on failure. Completion is independently checked automatically; timeout/404 never
means success, failure or zero. Recovery resubmits only the same transaction.
Because these are atomic direct swaps, an expired API signing cache can fall
back to the same VM-verified bytes on fixed TN10 nodes. Only an accepted competing
spender of an exact input can obsolete a saved swap. Completed/obsolete records
move out of pending attention into detailed activity, with token quantity, wallet
KAS total, timestamp and a copyable transaction ID.

## Deliberate initial limits

This test integration supports the API's single-wallet-signature atomic plans,
including eligible Borrowed Receive into an existing note. Token policies are
matched against supported fixed-width states, not inferred from the ticker.
Multi-note consolidation, arbitrary receive policies, generic KForge asset
transfers, claim, graduation and buyback signing are not enabled. Such a plan is
rejected before signing; a balance is not relabelled zero. This is not a claim
that every KForge API entrypoint is supported.

Verification includes all four captured unsigned public plans, synthetic locally
signed curve/pool transactions executed in the actual Rust VM, hostile mutations,
encrypted journal and timeout/reopening cases, and narrow layouts across themes.
It is not an independent contract audit or a funded end-to-end device trade.
The private kits and test wallet keys must never be placed in the APK or public
repository. Public test captures contain public chain data only.

## Test build 0.11.90 (235): UI and asset handoff

- Uses the official four-rectangle KForge mark from the public TN10 site's
  `sm()` SVG component, with its original geometry and jade/amber colors on a
  transparent background. Token previews share the same image widget in the
  catalogue, trade view and result. Uploaded files, HTTPS images and IPFS URIs
  are supported; failed images use the bundled official mark.
- The DEX now uses the established `DEX swaps` / `My activity` tab layout.
  Completed history is paged in groups of 50 and opens the same detailed result.
- A positive independent confirmation replaces the trade route with a persistent
  success page: token quantity, all-in debit/net proceeds, market amount, protocol
  and network fees, cell reserve, date, network, token/market covenant IDs and a
  copyable transaction ID. `Return to KForge DEX` skips the stale trade form.
  Pending and obsolete receipts never render as successful trades. Reopening a
  pending trade still only checks status; it does not automatically resubmit it.
- Wallet discovery converts stored `kaspa:` address formatting to the selected
  TN10 prefix before querying DEX holdings. Known KForge quantities publish under
  KCC20 before a slow global catalogue, using exact zero-decimal raw amounts and
  covenant identity. A valid TN10/v6/unit registry is still required. Failed or
  missing unrelated catalogue metadata cannot erase a positive indexed balance;
  unknown prices remain unavailable rather than zero. Signing-cell completeness
  remains false and generic transfer signing is not enabled by this UI change.
- Durably confirmed receipt transitions notify the wallet to refresh assets and
  KAS. Returning from Swap also refreshes the wallet. Repeated checks of an already
  confirmed receipt do not trigger duplicate notifications.

The Rust signer, its source/compiler pins, native binaries, supported entrypoints
and initial exclusions above are unchanged. This remains a separately signed
TN10 test APK; the public release/update manifests and other platforms are not
changed. Tests cover both trade directions through the actual UI approval/result
navigation (with fake signatures), all ten themes at 320 px, clipboard IDs,
pending-state refusal, progressive/failed metadata, registry mismatch and the
real `KaspaApi.loadWallet` discovery path. No funded device transaction is claimed.
