# Kaspire Android 0.11.32 · build 104

## dot.k Marketplace

- List, buy and cancel dot.k name offers directly in the Android wallet.
- Native sale covenants lock listed names and enforce the seller proceeds,
  2.1% marketplace fee and return of the separate 1 KAS sale reserve. Minimum
  listing price: 10 KAS. Network fees are shown separately in transaction review.
- The fee recipient is resolved from hub21.kas when creating an offer and is
  fixed in its covenant. No marketplace operator holds the seller's private key.
- Rust prepares and signs typed transactions. Android checks referenced cells
  against the own-node endpoint; native authorization is bound to the review.
- Save the listing recovery code before submission. Publication is automatic;
  if the directory is unavailable, the app explicitly directs you to retry
  Publish under My listings. Published entries have a disabled Published action.
- My listings puts active offers first and completed history last, newest first
  within each group. Confirmed sales/cancellations remove obsolete action buttons.
- Browse supports search and low-to-high/high-to-low price sorting. Refreshes
  happen after actions or via Reload, without periodic ten-second polling.
- The marketplace header no longer contains the test-build notice. Fees remain
  visible in review. Marketplace availability is enabled by default on Layer 1.

## Explorer and distribution

- https://kaspatoken.kaslab.space/dotk shows Kaspire Marketplace volume, trades,
  daily aggregates, top names and recent sales. Completed trades are archived;
  earlier unarchived trades may be missing and coverage is explicitly labelled.
- Android 11+, ARMv7/ARM64, package space.kaspire.wallet; existing signing lineage
  retained. Website latest APK, signed in-app update manifest and WalletConnect
  installation fallback all point to this release.
- Browser extension remains 0.4.8; the marketplace is Android-only in this release.
- APK SHA-256: `b496779d9b52dc4c817ee22c6913bbf23806f4d4349104a8fa6a48d7750b551e`.
- Android signing lineage verified separately for API 30–32 and API 33+.

## Verification

- 123 Flutter tests, 61 Rust-core tests and 6 marketplace analytics tests passed.
- Native list/buy/cancel fixtures run through signature and script validation.
  Invalid payouts, mismatched reviews, wrong ownership and duplicate inputs fail.
- Real listing/purchase tests were performed by the user; cancellation and sale
  evidence was checked against accepted transactions. The agent did not move funds.
- These checks are not an independent audit. Endpoint availability and indexer
  discovery remain dependencies. See [marketplace implementation](dotk_marketplace_prototype.md).
