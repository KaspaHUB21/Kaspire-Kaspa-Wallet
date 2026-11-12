# Kaspire Android 0.11.104 & Browser Extension 0.5.29

2026-11-12. Cumulative changes since public Android **0.11.102 (247)** and
public Extension **0.5.28**. Android 0.11.103 (248) was a separate test APK;
its locked-balance feature is included in this public release.

## KRC20 locked balances — both platforms

- Wallet holdings and token detail screens show tokens held in PSKT listings
  as a separate line, for example **+2,000 SOULS locked**.
- Tokens remain visible when the entire holding is listed and the available
  balance is zero. Exact raw-unit formatting preserves decimal precision.
- Locked amounts come from the existing Kasplex address balance response, or
  the existing KRC20 mirror when the primary is unavailable. There are no new
  marketplace/order-list API calls and no guessed marketplace attribution.
- Available balances, Max, transfer amounts and balance valuations remain
  separate from locked amounts. Signing and transaction recovery are unchanged.
- Missing or malformed amounts are not fabricated as zero. Wallet-list privacy
  mode masks locked quantities. Existing own-hosted token logos remain unchanged.

## Android refresh correction

- Pull-to-refresh now waits for the actual wallet reads, rather than ending as
  soon as they are started. Account scope, balances, assets, UTXOs, wallet name,
  market information and already-started activity sources are refreshed.
- Newly arrived token holdings appear immediately while unrelated sources are
  still loading. Flutter's retained old FutureBuilder snapshot can no longer
  cover a newer locked-balance update.
- Completed empty source responses clear the old holdings. Pending/failed
  categories retain previously loaded holdings, without treating them as zero.
- Late results from an older refresh cannot replace the active view. A fresh
  API instance also prevents a previous market-price future being reused.

## Browser Extension refresh correction

- A **Refresh wallet** button reloads wallet sources without restarting the
  extension. Browser page reload also requests fresh categories.
- Explicit refresh bypasses the short-lived category and KCC20 holdings caches;
  reads use `no-store`. Older in-flight reads cannot overwrite the newer cache.
- Normal popup reopening can still join an existing discovery scan, preserving
  early positive balances and progress beyond ordinary UI deadlines.
- Failed categories retain known holdings and show their actual load failure.
  Newly confirmed empty categories replace old data.
- The same wallet/locked-balance behavior is used by the popup and optional
  side panel. No new permissions or signing support are introduced.

## Release and verification

- Android **0.11.104 (249)** retains the official signing identity and both ARM
  ABIs. Its native signing cores are byte-identical to public 0.11.102.
- Extension **0.5.29** retains the official extension identity, permissions and
  unchanged released WASM signing core. ZIP publication does not mean Chrome
  Web Store approval; store review/submission is a separate process.
- Android's classic website download and signed-manifest/GitHub in-app update
  both deliver the same checked APK. Release notes stay on GitHub, not inline
  on the website download cards.
- Regression coverage includes the 21 → 90 locked KASBTC transition during a
  slow refresh, confirmed-empty clearing, failed-source retention, exact units,
  duplicate/cursor handling, privacy, Max excludes locked tokens and all themes.
- React iOS PWA delivery is separate and experimental, and is intentionally not
  part of this public Git commit/release. The original Flutter PWA is preserved.

No live user payment was executed during verification. Existing unrelated
uncommitted marketplace/server work is excluded from these release packages.

Verified packages:

- Android SHA-256: `2b8ec414d5ca8e7db420bc943dadf184233ab582deeb0fbd219e147904258f1f`
- Extension ZIP SHA-256: `6d476f54435b87f48de25f657f3cbaf01f775c6bdda004afa1a59cec59ddb8d7`
- 93 focused Flutter tests; 292 extension tests passed (six optional fixtures
  skipped), TypeScript/analyzer and actual packaged Chromium UI checks. Both
  popup and side-panel ZIP checks cover live refresh of synthetic locked
  balances, locked-only holdings, details, early/late discovery and reopening.
- Unchanged released WASM plus prebuilt native fixture executables were reused
  for native/WASM comparisons; no new signing implementation was compiled.
- Read-only Kasplex verification for goatmilk.kas now reports
  `locked=9000000000`, `dec=8`, i.e. **90 locked KASBTC**.
