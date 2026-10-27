# KasForge TN10 integration

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
