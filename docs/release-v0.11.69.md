# Kaspire Android 0.11.69 — Sell presets and Kasseal market ranking

Build **212**, package `space.kaspire.wallet`, Android 11+, ARM64 and ARMv7.
Complete Android changes since **0.11.68**. The extension remains **0.5.27**;
Windows and its update channel are unchanged. These new swap controls/ranking
are Android changes, not a new extension release.

## Sell 25%, 50%, 75% or MAX

- Add four theme-matched buttons in one row beneath the Sell amount field for
  **KaspaRocket, Kasseal and KRON**. They do not appear on Buy.
- Fill the amount field directly from the loaded wallet token balance. Repeated
  taps always use that balance, not a percentage of the previous input.
- Use exact integer-unit arithmetic, never floating point. Respect Rocket's
  three decimals, Kasseal's whole tokens and KRON's declared token precision.
  Fractional raw units are rounded down; MAX never exceeds the balance.
- Kasseal bonding curves round down to complete lots of the token's reported
  size (normally 1,000 tokens). Explain that rounding beside the controls.
  After graduation, presets use any whole-token amount. A sub-lot balance cannot
  produce an invalid curve sell; presets that would yield zero are disabled.
- Disable presets while balances are unavailable/zero, a swap is being processed
  or saved-swap recovery blocks a new trade. Do not interpret unavailable as zero.
- Clear an old quote when a preset changes the amount. Choosing a percentage
  does not request a signature, execute a swap or skip a fresh quote/review.
- Keep all four buttons in one row on narrow phones, using the existing
  theme-specific button styling rather than hard-coded colors.

## Kasseal catalogue ordering

- Replace the confusing default ordering with **market cap descending**, then
  **rolling 24h trading volume descending for ties**. Display these metrics and
  the ordering rule in the token list.
- Rank the **complete verified catalogue before pagination**, not just the first
  20 loaded rows. Load more uses a stable ranked snapshot and adds 20 tokens.
- Aggregate 24h KAS trade volume from the paginated public tape, deduplicate by
  token/transaction, and exclude older trades. Compare raw amounts as integers.
- Share/coalesce cached read-only snapshots across users, with bounded requests,
  history, time and cache size. Do not issue one history request per token/wallet.
- Bind cursors to the snapshot and search query. Expired/mismatched cursors ask
  for a refresh instead of silently mixing different rankings. Search still
  covers the whole catalogue; exact covenant-ID lookup remains available.
- If complete volume data is unavailable, retain market-cap ordering, show an
  explicit warning and mark volume unavailable rather than inventing zero.
- Preserve the existing catalogue endpoint behavior for older clients. New
  Android requests opt into `sort=mcap-volume`. No quote, transaction planning,
  contract proof, fee, signing or broadcast policy is changed by the ranking.

## Test the internal update route

On **Android 0.11.68**, check for updates and open the update chooser. Select
**Download & install from GitHub** to download this release internally. Allow
installs from Kaspire if Android requests it, return and tap Continue installation,
then confirm in Android's installer. The classic official-website path remains
available. GitHub's exact versioned APK asset is published before the signed
manifest advertises this version.

## Verification

- **714 Flutter tests passed**, including actual trade-screen amount fields for
  all three DEXes, exact 0/3/8-decimal amounts, curve-lot rounding, all themes and
  narrow single-row layouts. No real financial transaction was broadcast.
- **14 planner/catalogue tests passed**, covering global ordering across pages,
  integer precision, 24h receipt deduplication, cached concurrent requests,
  search/cursor binding and unavailable-volume behavior.
- The live public ranked endpoint was checked across 40 rows/two pages, with
  complete volume coverage. TEK, DELU, KASX, DAGDOG and UNNACHOD headed the
  observed ranking; rankings can change with market activity. Legacy reads work.
- Focused Dart analysis found no errors. Verified the compiled release version,
  both native ABIs, client/Reown configuration, APK alignment and v3 signature.
  The existing release certificate and signing lineage are preserved.
- The Android updater itself is unchanged from 0.11.68. Server/build/download
  checks do not replace the physical-device upgrade test the user is performing.

## Downloads

- [Official APK](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.69.apk)
- [GitHub APK for internal update](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/v0.11.69/Kaspire-Android-mainnet-v0.11.69.apk)
- SHA-256: `79f49dc31688b89af911c21b70e672f48b9077a0ce6828bd1ea8b2a85d99740a`
- Release certificate SHA-256: `0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`
- [Source comparison: 0.11.68 → 0.11.69](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/compare/v0.11.68...v0.11.69)

Install over the existing app rather than uninstalling it. Keep a current
encrypted wallet backup, including P2SH state/pending transactions where used.
