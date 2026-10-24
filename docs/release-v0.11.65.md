# Kaspire Android 0.11.65 — Progressive activity and reliable KAS history

Android build **208**, package `space.kaspire.wallet`, ARM64 and ARMv7,
Android 11+. Includes the WalletConnect fixes from 0.11.64. The browser
extension remains **0.5.23**; this release does not change Windows.

- Display KAS, fresh KRC20/KRON history and locally saved receipts as each
  source becomes available. They no longer wait for the complete asset and
  market-data snapshot before appearing in Activity.
- Publish validated asset history from intermediate wallet snapshots. Late
  asset enrichment updates the feed without restarting KAS history queries.
- Report failed or incomplete KAS history explicitly instead of silently
  converting lookup errors into an empty list. Offer a source-specific Retry
  activity button without clearing already loaded entries.
- Preserve previously loaded entries during refresh, source errors and timeouts.
  A slow or failed source cannot suppress transactions from healthy sources.
- For HD accounts, publish successful address histories immediately, deduplicate
  transaction IDs across addresses and limit simultaneous history lookups to
  four. A failed rotated address no longer discards every other address's KAS
  history; incomplete coverage is shown explicitly.
- Reject malformed native-history responses and try the independent read-only
  fallback, including malformed JSON. An invalid response is not an empty
  wallet history.
- Saved receipt updates refresh only local activity instead of restarting all
  remote history lookups. Ignore stale refresh results and late callbacks.
- Keep fresh, confirmed KAS history ahead of stale snapshot receipts when
  merging. KAS and asset movements belonging to the same transaction remain
  separate entries.

## Verification

- All **656 Flutter tests** pass, including 13 new Activity/API regressions covering
  stalled asset discovery, partial HD failures, all-source KAS failures,
  fallback validation, refresh ordering, deadlines and bounded concurrency.
- Changed Dart files pass static analysis without issues.
- The public KAS history route was checked read-only against an already public
  account and returned HTTP 200 in approximately 0.32 seconds. This does not
  prove every affected user's lookup succeeded; no incident-specific device
  logs were available.
- No transaction signing, broadcast or wallet migration changes. Existing APK
  release signing identity, lineage and signed update trust are preserved.
- No physical Android device is attached to this build server; device testing
  remains to be confirmed after installation.

APK SHA-256:
`f89bdc0a76d1b1822862dd55c5920327ed6c881792f0e7fe2d0abd16f5d09b37`

Signing certificate SHA-256:
`0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`
