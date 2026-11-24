# Kaspire Android 0.11.130 & Browser Extension 0.5.34

2026-11-24. Android build **278**, cumulative since public **0.11.122 (270)**.
Includes the Explorer and Glacier work tested in Android 0.11.123–0.11.129.
The combined GitHub Latest release also carries the already-public extension
**0.5.34**, unchanged, with its cumulative notes since extension **0.5.32** below.

## Android: integrated Kaspa Explorer

- Replaces the eighth dashboard action, Settings, with **Explorer**. Settings
  remains available in the bottom navigation. The Explorer adapts to all eleven
  existing themes and has a direct **Back to Kaspire** action.
- Adds **Explore the Kaspa Network** with unified TX-ID, Kaspa address, token
  ticker, covenant ID, KNS and dotK name search. Bare names include dotK matches;
  exact transaction searches do not show unverified block suggestions or run
  unrelated name searches. KCC20 results include their covenant ID to distinguish
  identical tickers, shortened to six leading and six trailing characters on
  narrow screens. Exact known covenant IDs open the corresponding token.
- Adds separate Kaspa price and hashrate charts, market cap, 24h/3d/7d ranges,
  labelled right-hand scales, grid lines, timestamps and interactive crosshairs.
- Provides KCC20, KRC20, KRC721 and KNS/dotK asset metrics and rankings, token
  detail pages and wallet lookups. Mobile views use cards/grids rather than a
  table switch, including KCC20 holders, transfers and recent DEX trades.
- Wallet lookups put the native KAS balance first, group asset holdings into
  expandable sections and show native transaction history with 20 entries per
  page and visibly distinct incoming/outgoing amounts. Back navigation returns
  to Explore, without an incorrect KRC20 heading.
- Transaction details include native inputs/outputs, acceptance and fees, plus
  indexed KCC20 token flows and identities when available. Missing indexed
  covenant details remain explicitly incomplete rather than invented. The
  reported KRON transaction displays its 3,308-token movement.
- Block-to-transaction navigation retains the containing block hash so fresh
  transactions can be read before the ordinary transaction index catches up.
  Validates exact IDs and block hints, ignores stale responses, supports retry
  and distinguishes inclusion from accepted status. Coinbase does not receive
  an invented ordinary network fee.
- Adds readable surfaces for transaction headers, metadata, inputs/outputs,
  NFT notices and pagination across detailed-background themes such as Neptune.

## Android: NFTs, asset metadata and favorites

- Adds an internal KRC721 gallery with locally hosted previews, collection and
  NFT detail views, expandable trait filters, token-ID/rarity sorting, stored
  ranks and PSKT listing status. Removes outbound collection/detail buttons and
  the token-explorer-domain-only Holder Snapshot from the embedded Explorer.
- Labels rarity `-1` as **Legendary**. KASGOTHS rarity sorting begins with token
  IDs **21, 420, 13**, with stable paging and the ordinary ID sort unchanged.
- Marks listing status with an asterisk explaining that only PSKT listings are
  checked; escrow listings are not included.
- Uses existing own-hosted KRC20 logos and resolved KCC20 metadata/image sources,
  including the checked Kascov image fallback. A missing image does not erase a
  known balance. Published/verified units are used; unknown decimals are never
  guessed. The user-excluded pre-finalization HUB21 issuance and covenant
  `69001bc75394f3baf1863aad014c35275371935fad29e1d3a114aa23a4db721a`,
  along with unidentified placeholders, are hidden without deleting holdings
  or stored favorites. Named assets may still show raw units if units are absent.
- Moves starred assets into **Favorites** in the hamburger menu. Removes the
  favorites filter row and date-format gear from asset pages. Favorites survive
  reopening/source failures, and Back to explorer opens Explore.
- Removes L2 from this embedded Explorer, including its menus, rankings,
  favorites, search and wallet reads. Legacy Combined/L2 routes return home;
  stored data is preserved. The native Igra/Kasplex wallets are unchanged.

## Android: live BlockDAG and Glacier responsiveness

- Adds a real **Live BlockDAG** view backed by public block observations from
  Kaspire's own node, not randomly generated blocks. The bounded window contains
  up to 240 real block headers and parent links, with pause/resume, pan/zoom,
  block selection, recent blocks and links to block/transaction details.
- The read-only service has no wallet keys or signing/broadcast functions.
  Hidden/unmounted views stop polling; failed, stale or out-of-order replies
  preserve the known graph and clearly report source state instead of fabricating
  fresh activity. The trait-catalog helper likewise exposes public reads only.
- Improves Glacier rendering by caching three small pre-rendered, content-free
  veil textures instead of repeatedly running Gaussian filters for scrolling
  cards. Text, controls, borders and facets remain live and sharp. Theme loading
  preloads the cache; rapid theme changes keep the latest selection.
- The previous controlled software-raster comparison measured about 29% less
  raster time for thirteen cold panels. This is not a physical-phone FPS claim.
  Existing artwork, default theme and saved preferences are preserved.

## Browser Extension 0.5.34 (already public, unchanged)

- Native **KAS / kUSDT** is the first Swap entry, using Trestly KasPool directly
  on Kaspa Mainnet without a separate dApp session or L2 bridge. Uses pinned
  identities/scripts and the shared Android local builder, independently checked
  live inputs/state, exact reviews, explicit popup/Side Panel approval and local
  script execution. Generic dApp signing permissions are not broadened.
- Shows exact six-decimal kUSDT balances and MAX. Incomplete discovery is not
  zero; fragmented totals and the largest verified single-cell sell are separate.
  No automatic consolidation is added.
- Saves signed swaps before submission, uses the dedicated exact-wRPC route and
  checks the exact transaction/mempool before resending the same bytes. Unknown
  outcomes retain recovery data; submission is not mistaken for confirmation.
  Encrypted extension backups include native recovery data. Cross-platform
  pending-journal import is not claimed.
- Adds **Cosmic**, with Android space artwork, neon surfaces, detailed action
  buttons, a round unbranded planet and planetary-horizon navigation adapted to
  the extension's existing desktop actions and approval surfaces.
- Fixes all eleven currency options through canonical values protected from
  automatic text casing, visible save/error feedback and preference storage
  independent of stale wallet snapshots. Conversion and selection survive screen
  reentry, closure, lock/unlock and a browser restart; failed FX reads do not reset
  the setting to USD. Late saves cannot replace a later send/approval view.
- Keeps the pinned pool core separate from the wallet WASM, checks the packaged
  core checksum and invalidates cached native ABI outputs during builds.
  Relative to 0.5.32, the narrow `https://api.trestly.io/*` host permission is added.
- The extension ZIP is byte-identical to its already-public 0.5.34 package.
  Android's new Explorer and Glacier rendering changes are **not** claimed as
  extension changes. Chrome Web Store submission/approval remains separate.

## Verification and public delivery

- Release checks include Flutter tests for Explorer routing/read boundaries,
  all-theme dashboard layouts, Glacier cache/raster behavior, swaps/recovery,
  token support and both Android update surfaces. Explorer TypeScript/build,
  JavaScript/read-service tests and packaged Chromium checks cover search,
  charts, wallets, NFTs, KCC20 cards, favorites, fresh block transactions and
  real BlockDAG fixtures, including slow/failing/reopened reads.
- **165 Flutter tests** passed with two existing skips, alongside **21
  JavaScript/read-service tests**, TypeScript checks and packaged browser tests.
  Analyzer checks have no errors or warnings; five existing style infos remain.
- Checks the Explorer files extracted from the actual signed APK, package ID,
  build/version, unchanged permissions, original assets and production-client
  configuration. ARM64/ARMv7 native wallet libraries and other non-app native
  libraries match public Android 0.11.122 byte-for-byte; no signing boundary or
  contract support is silently broadened.
- Preserves the existing Android release certificate, rotation lineage and
  updater trust. No live payment or physical-device end-to-end test is claimed.
- **Both Android update routes** provide the same signed APK: website/manual
  download and native in-app installer through the signed update manifest.
  GitHub assets/checksums, website version/download/checksum and signed manifest
  are published together. The combined GitHub Latest title and notes cover both
  Android 0.11.130 and Extension 0.5.34.
- iOS PWA, Windows, the existing extension channel and unfinished/private
  KaspaCom experiments are unchanged. Wallet data is preserved.

Android APK: `Kaspire-Android-mainnet-v0.11.130.apk`

Android SHA-256: `ae12db3385a4769079379756642a6d2f33ebfdc5e9c38abb075f1eca218ac7af`

Extension ZIP: `kaspire-extension-0.5.34.zip`

Extension SHA-256: `e083a5c7c0d0ebb022f3df1a4b011bd8bed42a6609a7adfbe5320c4f74060413`
