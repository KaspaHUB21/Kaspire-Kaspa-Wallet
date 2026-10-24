# Kaspire Android 0.11.66 — Activity fixes and persistent token logos

Android build **209**, package `space.kaspire.wallet`, ARM64 and ARMv7,
Android 11+. Includes the recent WalletConnect hotfixes. The browser extension
remains **0.5.23**; this release does not change Windows.

- Fix KRC20 Activity failing on large token amounts: internal decimal amounts
  remain canonical, while thousands separators are applied only for display.
- Resolve standard KCC20 Activity from covenant references in the wallet's
  native transactions and discovered token outputs. Do not scan every token's
  global trading history to build the wallet timeline. Retain a separate source
  for legacy covenant history and existing NFT/name receipts.
- Give targeted Activity reads priority over background KCC20 balance discovery
  while preserving shared request pacing and HTTP 429 backoff. Cache complete
  transaction details and coalesce duplicate requests across service instances.
- Initially display the latest **50 merged Activity entries**. Load more adds
  another 50, with bounded pagination for native and KRC20 history. The REST
  gateway can now paginate past its former 100-transaction merge window;
  requests beyond its bounded window report an explicit error, not an empty page.
- Keep sources independent and progressive. Failed lookups retain previously
  loaded entries and remain explicitly retryable rather than implying no history.
- Keep long token names and Covenant Wyrm operation labels inside narrow cards,
  including larger accessibility text and all app themes.
- Load KRC20 logos directly through Kaspire's own persistent server-side cache,
  without waiting for the full asset/market snapshot. Previously saved logos
  survive upstream failures and service restarts. Missing images still require
  a working original source on their first fetch.

## Verification

- All **674 Flutter tests** pass, including narrow-layout regressions across all
  themes, canonical large token amounts, 50-entry pagination, targeted incoming
  and outgoing KCC20 history, request caching and priority scheduling.
- All **24 gateway/cache tests** pass. Changed Dart files and their selected
  regression tests pass static analysis without issues.
- Read-only checks against `goatmilk.kas`: KRC20 returned 51 entries in about
  0.27 seconds; native history returned 51 in about 0.49 seconds. Targeted
  standard KCC20 history returned 38 entries without warnings in about 20
  seconds, publishing progressively rather than waiting for the holdings scan.
  These are server measurements, not guaranteed device timings.
- The public gateway returned a further 51 native transactions at offset 100.
  KASBTC, SOULS, NACHO and PLUTO logos were fetched and persisted on the server.
- No transaction-signing, broadcast, seed or wallet migration changes. Android
  release signing identity, lineage and signed update trust remain unchanged.
- No physical Android device is attached to this build server; device testing
  remains to be confirmed after installation.

APK SHA-256:
`abb8a43f74242d46cffd86851b766ef9680f232321c650f14f5ab728f45c9176`

Signing certificate SHA-256:
`0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`
