# Kaspire Android 0.11.71 — Forge TN10 swaps and Rocket transfer handling

Build **216**, Android 11+, ARM64 and ARMv7. Complete Android changes since
public **0.11.70/build 215**. Extension **0.5.27**, Windows and iOS packages and
their update channels are unchanged. The shared Rocket cell gateway correction
also benefits existing extension clients using that endpoint.

## KasForge — Testnet 10 only

- Enable buy/sell covenant orders for the pinned Forge 3.3 deployment profile,
  using the curve before graduation and the pool afterwards. Recheck the route
  and the quote identity/age before building; preserve launch-protection errors
  from the API rather than claiming that an order was placed.
- Rebuild order scripts from public SDK **0.4.0** template data inside Kaspire's
  Rust core. Independently verify owner, token/market, amount, minimum payout,
  expiry, fee limits, order/token outpoints, token conservation and wallet change.
- Verify live inputs against an independent TN10 node, check actual witness
  mass/network fee, bind signing to the reviewed terms and execute all signed
  inputs locally. No generic signing policy is relaxed and no provider JS signer
  receives wallet secrets.
- Support token preparation/merge transactions, encrypted read-back-verified
  order journals, same-byte resume and a public-node fallback after API/build-ID
  expiry. Order deposits and completed swaps are distinct states.
- Add saved-order review/recovery, copyable IDs and public recovery-receipt
  export. Build owner cancellation locally from the saved contract and live
  UTXOs without depending on Forge's server; cancellation network fee 0.1 KAS.
- Verify final KAS/token payouts through an independent accepted transaction
  spending the exact saved order. Unknown, failed or missing status never
  discards a signed order or authorizes a replacement trade.
- Mainnet Forge remains disabled. The confidential kit is not published; only
  the newly public MIT-licensed SDK template data is included.

## KaspaRocket / KCC20 sending

- Normalize harmless source hints before constructing a signing plan: ignore
  zero-token cells and count identical repeated outpoints once. Do not mutate
  the source list or double-count its balance.
- Reject conflicting duplicate amounts, malformed quantities, unsafe numeric
  values, incomplete balances and changed/mismatched live cells. Own-node
  ownership/program/covenant checks and the 10-input/consolidation policy remain.
- Resolve both original receive cells and the increase-only Borrowed Receive
  cells Kaspire already creates, requiring an exact live script hash. Keep the
  actual policy in the returned signing cell; do not relabel or rewrite it.
- The reported KB wallet was not supplied, so its exact upstream response could
  not be replayed; the addressed zero/duplicate rejection cases are regression
  tested rather than claimed as an address-specific confirmed reproduction.

## Braid interface

- Search by ticker or covenant ID at the top of both From/To token selectors.
- Display selected token covenant IDs with copy buttons and responsive wrapping.
- Preserve all four themes, quote invalidation, sell presets and late/failed
  balance behavior. The pending 1% partner-fee work is **not** enabled: the
  independent Token→Token valuation remains a separate prerequisite.

## Website and both Android update routes

- Update the public Android version, checksum and APK download. Keep the website
  download cards free of changelog paragraphs; release notes stay on GitHub.
- Preserve the themed choice between the official-site APK download and the
  matching GitHub-release download inside the app. Preserve the existing APK
  signing identity/lineage and signed-manifest trust. Publish the GitHub asset
  before advertising the update; installation still requires Android approval.

## Verification and limitations

- Full Rust library regression: **145 passed**; full Flutter regression:
  **765 passed**, with opt-in live suites skipped in the offline run.
- Gateway regression: **16 passed**. Final Forge/Braid targeted UI/service
  checks: **40 passed**; static analysis reports no issues.
- Actual APK checked for version 0.11.71/build 216, both rebuilt native ABIs,
  new UI strings, Reown/Rocket configuration, 16 KB alignment and v3 signature.
- Signing certificate SHA-256:
  `0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`.

Automated verification covers native contract execution, altered reviews/terms,
server-independent cancellation, journals surviving failures, false completion
claims, theme/narrow layouts, source normalization and regression suites. Real
unsigned Forge curve buy/sell and pool buy builds pass native review. The public
pool fixture has no funded holder; live pool sell and funded Android-device
settlement/refund remain tester checks. No real user key or funded transaction
was signed/broadcast during this work. These contracts are not claimed audited.

## Downloads

- [Official APK](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.71.apk)
- [GitHub APK](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/v0.11.71/Kaspire-Android-mainnet-v0.11.71.apk)
- APK SHA-256: `7e04a4c90c91985776052c424b96f313891676caaefdfd6bf4614391eb111a7e`.

Install over the existing app; do not uninstall. Keep an encrypted backup.
