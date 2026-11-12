# Kaspire Browser Extension 0.5.29

Cumulative changes since public ZIP 0.5.28, 12 November 2026.

- KRC20 balances now show a separate PSKT-locked amount in the wallet list,
  token details and send screen. Fully listed tokens remain visible with zero
  available balance. Locked quantities are not added to Max or spendable funds.
- Uses the existing Kasplex balance response and KRC20 mirror; no additional
  KaspaCom listing/order queries and no unsupported marketplace attribution.
- Added Refresh wallet. Explicit refresh and browser page reload bypass the
  short-lived category/holdings caches. Normal popup reopening can still join
  existing discovery, preserving early positive and post-timeout balances.
- Older in-flight reads cannot replace a newer refreshed cache or view.
  Successful empty results clear old holdings; failed categories retain known
  data with their actual source warning. Reads use no-store.
- Exact grouped token formatting and hidden-amount handling cover the new
  display. Popup and optional side panel share the same behavior.

No new permissions, extension identity, signing algorithm or recovery rules.
The released WASM signing core is unchanged. Verification includes 292 passing
tests (six optional fixtures skipped), real Chromium wallet/dApp checks, and
the actual ZIP in popup and side-panel UI fixtures, including refresh without
restart and Max excluding locked tokens. No live user payment was made.

Official ZIP publication is separate from Chrome Web Store review/approval.
The combined Android 0.11.104 / Extension 0.5.29 release has the complete
cross-platform notes and both package assets.
