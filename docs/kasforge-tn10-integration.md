# KasForge TN10 integration

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
