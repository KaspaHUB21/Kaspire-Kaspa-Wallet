# KasForge TN10 integration

## Android test APK 0.11.88 / build 233 — contracts 3.8

This is a separate Android test download, not a public update-channel release.
Download: https://kaspire.kaslab.space/downloads/Kaspire-Android-v0.11.88-Forge-test.apk
SHA-256: `4604b97225a17fc77b473c5b0fb91df715fc8f7ae462ac2f24227fe425d3deec`.
KasForge remains Testnet-10 only. Public SDK 0.5.1 templates are pinned as data:
buy v5 for contracts 3.7/3.8, buy v4 for 3.4–3.6, and sell v4 for 3.4+.
Old 3.3 and versionless, byte-for-byte matched saved orders retain recovery.
Unknown declared versions and mismatched fresh market/order versions reject.

The confidential 3.8 partner kit is not redistributed. Its order vectors are
labelled 3.7 because 3.7 and 3.8 share these order programs. Private-vector
checks rebuild the programs from the public SDK data, checking bytecode,
script hash and addresses; they do not execute partner SDK JavaScript or
establish an independent contract audit.

New multi-step builds require `stepSubmit: true`. Before a dependent signature,
the already signed prefix is persisted/read back, locally re-reviewed, submitted
with `{buildId, signed: prefix, step: true}`, and independently confirmed. Later
inputs are checked on chain, not merely against embedded parent data. Resuming
does not re-sign an existing prefix. Rejection, expiry and unknown confirmation
preserve the exact bytes and recovery journal. Progress is visible in the
existing themed order screen; a partial plan is not reported as a filled order.

Live unsigned 3.8 buy/sell checking exposed two old assumptions: sell v4's
order-owned token piece reserves 2 KAS instead of 1, and a legitimate token
witness can exceed the former flat 0.1 KAS network-fee cap. The reserve is
version/program-bound and excess reserve is returned during local cancellation.
Fees remain review-bound: the ceiling is the greater of 0.1 KAS and 250
sompi times locally calculated signed mass, bounded by an absolute 0.5 KAS.
This is a safety ceiling, not a minimum fee charged to the user.
Cancellation keeps its separately confirmed 0.1 KAS fee. No provider-advertised
mass or recommended fee rate authorizes a larger payment.

The old fixed TN10 node URLs were no longer available during verification.
The officially resolved `vector-10.kaspa.green` is now pinned for independent
TN10 reads/clock and same-byte recovery broadcast, with a fixed old-node
fallback. The unsigned TN10 UTXO service uses bounded per-read connections,
safe handle retirement and explicit unavailable state. Mainnet services and
their existing node route are unchanged.

Validation includes 157 Rust tests (actual local script execution for buy/sell
and cancellation across supported versions), private partner vectors, prefix
submission/reopening tests, and parent-captured actual 3.8 API buy/sell builds
replayed against the native inspector with independent live UTXOs and two chain
clocks. No funded buy, sell, broadcast, or physical-device settlement was
performed. An attached Android device/emulator is not available on this server.
The full Flutter suite passes 1,013 tests (18 explicit opt-in tests skipped),
35 focused snapshot/service/theme tests pass with the captured public data,
and five bounded-node lifecycle/failure tests pass. Final focused analysis
reports no issues. Both packaged Android ABIs match the verified native build
after the normal Android symbol stripping, contain the new order policy and
use the same release signing certificate/lineage as the public Android APK.

Intentional exclusions: no Forge Mainnet, direct-buy third-party recipient,
launch/claim workflow, extension or iOS port is enabled by this test build.
The new, separately named KForge preview below does not share this signer.

## KForge preview in the same test APK

KForge is **not KasForge**. Public documentation at
https://testnet.kforge.xyz/#/docs identifies the separate TN10 API
https://api-test.kforge.xyz. The APK adds a distinct KForge catalogue with
search, paging, images, curve/pool identity, copyable token covenant IDs, prices
and indexer-reported whole-token wallet balances. Balances participate in the
existing progressive TN10 discovery; failed/unknown results never mean zero.
Narrow layouts are tested in all ten themes.

Native KForge swaps and generic transfers remain disabled. The public registry
publishes curve/pool source fingerprints, compiler commit and parameters, but
the documented downloadable artifact covers only KCC20. The user confirms no
curve/pool source/artifact kit is available. Required for the native verifier:
`saleshard_prod5.sil` and `amm_pool6.sil` (or compiled, reconstructible templates),
constructor/state/entrypoint layouts and representative curve/pool buy/sell
vectors. No general PSKT policy is loosened to substitute for that handoff.

## Android 0.11.76 / build 221

The Forge submission adapter now sends the SDK's single owner-signature
envelope while retaining the complete locally verified signed witness in its
encrypted receipt. Expired and partially prepared plans gain dependency-aware
recovery of their exact wallet-owned KAS funding; token inputs are not signed
by that funding-return path. Missing index entries never unblock a signed order.

Foreground status checks use backoff and wait for independently verified
settlement/refund instead of presenting ordinary confirmation delay as a
rejection. Verified completed orders leave the attention list and appear in
merged activity with token quantities, KAS values and copyable transaction IDs.
Forge remains TN10-only. See the cumulative
[0.11.76 release notes](release-v0.11.76.md).

## Android 0.11.73 / build 218 — required JSON identity and reachable recovery

The reported Forge parser rejection identifies the missing top-level `id`:
the native signer returns it separately, and the adapter must restore that
required SafeJSON metadata before `/submit`. The adapter now re-prepares the
original plan in Rust, matches its saved review and computed ID, and verifies
all signed fields against the original except the selected witnesses. It adds
only the verified ID, retaining the exact witness bytes and reviewed terms.
Old signed receipts use the same repair without another signature.

Saved local orders now have explicit loading/error states and prominent access
in both the catalogue and token trade screen, independently of Forge's empty
server list. Review reopens the exact pending receipt instead of requesting a
second build. No journal entries are cleared simply because a server has none.

An explicitly confirmed unsubmitted single-step KAS buy can invalidate its
saved deposit by returning its exact independently verified P2PK funding inputs
to the same wallet, with a disclosed 0.1 KAS fee. This uses the existing ordinary
P2PK signer, not a new contract policy. Token/split plans are excluded. Deposited
orders keep the existing contract cancellation. The journal stays blocking
until the exact cancellation/invalidation and return are independently accepted.

69 targeted tests and the opt-in live unsigned curve buy/sell and pool buy
adapter test pass. That test reproduces the missing-ID exception with actual
Rusty-Kaspa 2.1.0 deserialization, verifies the repaired ID and unchanged dummy
witnesses, and natively reviews the self-return plan. Its submit handler is
intercepted: no funded transaction or actual Forge submission is performed.
See [0.11.73](release-v0.11.73.md) for release evidence and limitations.

## Android 0.11.72 / build 217 — submission correction

Order deposits must go through Forge `/submit`: a direct node broadcast does
not register an order with its sequencer. The 0.11.71 error fallback has been
removed. Rejections and timeouts preserve the original error and signed bytes
without broadcasting. Existing affected orders can be identified from accepted
deposits and their exact unspent order outputs; a missing index entry alone
never means failure, refund or completion. This does not establish the original
reason why Forge failed to confirm submission; that error was previously hidden.

45 focused service/widget tests pass, including rejection, timeout, malformed
responses, same-byte API retry, independent unspent/mismatching/spent/unknown
states and narrow layouts in all four themes. No funded submission or
cancellation was performed during this investigation. Full release evidence
and limitations are recorded in [0.11.72](release-v0.11.72.md).

## Android 0.11.71 / build 216

TN10 order trading now uses a dedicated native `kasforge-tn10-order-v1` profile.
Public SDK 0.4.0 template data is pinned locally; no provider JavaScript or
provider verification verdict is executed or trusted by the wallet. Mainnet,
browser-extension and iOS packages remain unchanged.

The wallet rebuilds buy and sell contracts, checks the exact token/market,
owner, minimum, fees, expiry (two independent clocks), order/token outpoints,
token conservation and wallet change. Input state is checked against an
independent TN10 node. Actual witness mass and network fees are checked, and
every fully signed transaction executes locally before returning from Rust.

Orders and multi-step plans are encrypted and read-back-verified before
submission. This release included a direct-node submission fallback on API
errors; that fallback is withdrawn by the 0.11.72 correction above because
it can deposit funds without registering the swap. Owner cancellation is constructed from saved data
and independent live UTXOs without the Forge API. Its displayed network fee is
0.1 KAS (separate from the contract's automatic-refund fee). Completed status
requires an accepted independent transaction spending the exact saved order
and satisfying its guaranteed KAS/token payout. Missing data never means final.

Synthetic buy/sell and both cancellation branches execute locally. Live unsigned
curve buy/sell and pool buy builds pass native review. The public pool fixture
has no funded holder, so no live pool sell was manufactured by signing a real
trade. No physical-device or funded end-to-end settlement is claimed.

## Before 0.11.71 (historical read-only integration)

Android 0.11.70/build 215 includes the read-only TN10 integration first tried in
private build 213. It is enabled by default only on Testnet 10; builds may opt out
with KASPIRE_KASFORGE_TN10=false. Mainnet and extension are not enabled.

## Implemented and verified boundaries

- Public token-list metadata, names, logos and zero-decimal balances, keyed by
  covenant ID rather than ticker. Indexed balances are not verified signing cells.
- Market-cap/volume catalogue, search, 20 visible entries and Load more.
- Wallet token detail, balances, buy/sell quote previews, sell percentages and
  public portfolio/activity. Theme/narrow layouts and long labels are tested.
- Curve covenant before graduation, pool covenant afterwards. Recheck live
  market identity before quotes; never sign a stale route.
- Independent progressive TN10 sources: a slow/failing DEX does not suppress a
  different source's positive holdings. Unknown does not become zero.
- Network guard discards late responses after a network change.
- No order creation, signing, submission or cancellation is enabled. The wallet
  service only performs GETs; an estimated quote is never a completed swap.

Public documentation: https://kaspa.pumpforge.tech/docs
Token list: https://kaspa.pumpforge.tech/api/kaspa-tn/forge/tokenlist
Reads: /api/v1/markets, /market/:id, /portfolio/:pub, /quote/:liveMarket.

## Confidential kit and remaining handoff

The partner supplied the contracts 3.3 kit privately. Do not commit or redistribute
its archive, contract sources, ABI artifacts or original vectors. The public
read-only tool `kasforge_vectors` reads a local kit and prints only verdicts.
It checks the four compiled artifacts against bytecode, BLAKE2b-256 script hashes,
P2SH addresses on both networks and SilverScript template fingerprints.

All four supplied examples pass. This is internal consistency verification,
not recompilation from source, an independent audit, or end-to-end settlement.

A real unsigned /api/v1/build response was inspected without signing/submitting.
It supplied txs with txJsonString/signInputs and summary/buildId, but no output
order redeem programs. A summary is not authority for the destination, minimum
payout, expiry or recovery guarantees. Needed before native order signing:

1. Build-bound output redeem scripts and constructor/state data for each newly
   created buy/sell order and token cell, or an equivalent independently
   reconstructible public handoff.
2. Independent live-input validation, exact token ownership/conservation and
   minimum/fee/deadline enforcement against those pinned programs.
3. Buy/sell, split/merge and cancel/refund fixtures on curve and pool, including
   persistence/recovery after API expiry and interrupted submission.
4. Distinguish accepted deposits from actual settlement; never lose unknown
   signed state or enable Mainnet merely because a provider changes its host.

No generic signing profile is loosened to bypass these requirements.

## Validation

Release evidence is recorded in [0.11.70](release-v0.11.70.md). Original private
build 213 passed 735 Flutter tests and a separate read-only live test; its Rust
signer was unchanged. Build 215 includes the later Braid and Kasseal native work.
No real wallet keys or signed/broadcast Forge trade were used. No physical
Android device is attached to this server.
