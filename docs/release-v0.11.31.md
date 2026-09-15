# Kaspire Android 0.11.31 (100) and extension 0.4.8

## dot.k covenant names on Kaspa Layer 1

- Separate collapsible, alphabetically ordered dot.k asset category in both wallets.
- Name details show fresh ownership verification, payment address, deed address,
  registry covenant ID and live deed outpoint.
- Enter `name.k` in KAS/asset recipient fields, address-book contacts and watch
  wallet entry. Existing transaction review and recipient allowlists remain active.
- Same native Rust derivation on Android/JNI and locally packaged browser/WASM.
  Registry identity and deed template are embedded, not accepted from the API.
  Node checks reject stale/spent deeds, foreign covenant IDs, wrong script/bond
  and address mismatches. No transaction or secret is sent to the dot.k directory.
- Names are displayed as directory listings until verified; failed verification
  blocks name-based payment. Registration, name transfers and custom records are
  not included. Covenant owners without a payment address cannot be recipients.

## Distribution

- Android: `space.kaspire.wallet`, version **0.11.31**, build **100**, Android 11+,
  ARMv7 and ARM64. Existing Android signing lineage retained for normal upgrades.
- APK SHA-256: `10b0e419a9b26341be14ecc767c249ffa0c6105f9b15e96da579038019b6c72e`.
- Extension ZIP: **0.4.8**, SHA-256:
  `e40e0ac07305b9d9d7b365e13806855421f052937ecd9e5f0d11fcc44b0becc0`.
- New extension host permission: `https://api.dotk.name/*` for public holdings
  and name resolution. Chrome Web Store submission/approval is separate from
  this GitHub ZIP release; this release does not assert the Store is updated.
- Website latest-only APK, signed Android update manifest and WalletConnect
  install fallback are updated together. Historical URLs redirect to latest.

## Checks

Android dot.k test build confirmed working by the user. 113 Flutter tests and
49 Rust tests passed during implementation, including a real read-only
`21millioncoven.k` directory/node probe. Extension TypeScript check and all 36
unit/WASM tests pass; the complete Chromium smoke test passes. HUB21 UI checks
cover the new category and ownership view in addition to existing asset flows.
No real funds were moved by these checks.

See [dot.k integration](dotk_integration.md) for endpoint, pruning/availability
dependencies and the distinction between node trust and on-device SPV proof.
