# KasForge TN10 integration

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
