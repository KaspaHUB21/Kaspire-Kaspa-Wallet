# Kaspire Android 0.11.113

2026-11-18. Android build **261**, cumulative since public **0.11.112 (260)**.

## KaspaCom KRC20 sorting, matching the iOS PWA controls

- Shows the missing **Sort offers** selector for KRC20 token listings with
  **Most recent listings**, **Price: Low to High** and **Price: High to Low**.
- **Price: Low to High** is the default when opening KaspaCom and when switching
  asset families, as requested. Price sorts compare the KAS price **per token**,
  not the total KAS for differently sized orders. The token catalogue keeps its
  existing discovery ranking; the selector orders the selected token's offers.
- Sorting is applied upstream to the full set of active decentralized listings
  before pagination, not just to the currently loaded page. Switching sort
  restarts at the first page; subsequent pages and refresh retain the selection.
- Records the relay's already-live KRC20 sort correction in the release source:
  newest sorts by descending creation time, price sorts by unit price in the
  selected direction. Existing KRC721 rarity and KNS/NFT total-price sorts remain.
- The Android controls are available in all themes and narrow layouts. Delayed
  results from a previous selection cannot replace the active selection's rows.

## Validation and delivery

- **84 Flutter tests** passed. Marketplace and signed-updater regressions cover the sort controls
  in every Android theme at 320px, paging, refresh, late responses, existing NFT
  filters and transaction review/recovery. Focused static analysis is clean.
- **12 relay tests** passed, covering all three KRC20 sorts, pagination and unchanged NFT/KNS
  ordering. Read-only live KASBTC checks verify all three sorts across two pages
  each (60 orders). No live payment, listing or cancellation was made.
- The built ARM64/ARMv7 APK is checked for version, public client configuration,
  release certificate/signing lineage, alignment, packaged labels, unchanged
  permissions and byte-identical native libraries/branding against 0.11.112.
  No physical-device or emulator runtime test is claimed.
- Signing, fees, marketplace transactions and the existing kUSDT/Igra/Kasplex
  behavior are unchanged. Unrelated in-progress purchase-recovery experiments
  are excluded from this APK and commit.
- Public delivery updates the website version/checksum, GitHub release and
  signed Android update manifest. The website and GitHub update routes serve
  identical APK bytes without changing installed clients' update trust.
- Browser Extension **0.5.32**, iOS PWA and Windows channels are unchanged.
  Release notes stay on GitHub, not in the website download section.

Android APK: `Kaspire-Android-mainnet-v0.11.113.apk`

SHA-256: `fc3d092b9231995bb3e44cd0ba079ed7016cb01dbf6f320dfb5623bb23e8234f`
