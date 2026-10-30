# Kaspire Android 0.11.77 browser and DEX token overviews

Build **222**, Android 11+, ARM64 and ARMv7. Complete Android changes since
public **0.11.76/build 221**. Extension **0.5.27**, Windows and iOS are unchanged.

## Braid in Kaspire Browser

- Add **Braid** at `https://app.braidswap.com/` with its official icon.
- Browser order: **Kasvio, Kasseal, GothDAG, Braid, dot.k, Kaspa News,
  Kaspa Dev Tools, KasCoven Vaults**.
- Approve only Braid's exact HTTPS origin, keeping the existing in-app
  WalletConnect approval flow and navigation restrictions.

## KaspaRocket and Kasseal token lists

- Show **market cap in USD**, **price per token in KAS** and **24h volume in KAS**
  in both Android Swap catalogues. Retain search, pagination, native ranking,
  verified token identity and the existing trading flow.
- Convert Kasseal's current market cap using its fresh public KAS/USD quote,
  falling back to Kaspire Token Explorer. KaspaRocket uses the explorer's
  KAS/USD reference with its native market cap and token price.
- Calculate Kasseal's per-token spot price from market cap and whole-token
  supply, not the price of an entire 1,000-token curve lot. Keep all trading
  calculations and signing amounts unchanged.
- Share and cache display-price lookups instead of fetching a price per row.
  Load USD independently so a slow or unavailable price source does not delay
  the token list or hide its KAS metrics. Missing/stale data is **Unavailable**,
  never a fabricated zero. Use English thousands separators and wrapped lines
  with ellipsized covenant IDs for narrow screens and all themes.

## Braid progress compatibility

- Display route names for Kasseal and KaspaRocket launchpad legs when returned
  by supported routes, and display attempt count, competing spends, network bid
  and wait reason when Braid returns live progress.
- Keep independent settlement verification and saved-receipt recovery.
  Braid's live Mainnet r2c fingerprint still matches the existing pin; the
  deposit flow and disclosed 1% partner-fee checks are unchanged.
- This update does **not** enable optional priority bids or wait-for-price
  launch controls, or automatically approve additional token contracts.
  The existing independently pinned token and route restrictions remain.

## Updates and compatibility

Install over the current app; do not uninstall or clear wallet data. Both the
official-site download and GitHub in-app update deliver the same signed APK
through the signed Android update manifest. Android still asks for installation
approval. Website download metadata is updated; release notes remain on GitHub,
not inline in the website's download section.

No wallet derivation, signing-core binaries, fees, recovery keys, extension
package or other platform's update channel changes in this release.

## Verification

- Full Flutter regression: **867 tests passed**, with four opt-in or
  fixture-dependent checks skipped.
- Tests cover rate freshness and fallback, coalesced requests, failed refresh,
  exact lot versus per-token units, slow display results, both real catalogue
  screens, narrow layouts in all themes, browser ordering and origin checks,
  plus Braid progress labels. Live read-only checks also exercised both public
  price sources through the production display-price service.
- Package checks confirm **0.11.77/build 222**, the Braid icon and new display
  paths, configured WalletConnect/Rocket clients, both ARM ABIs, 16 KB alignment
  and unchanged native signing-core hashes. Signing certificate SHA-256 remains
  `0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`.
- These checks do not substitute for installation and trading on a physical
  Android device; no funded trades were executed for this display update.

## Downloads

- [Official APK](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.77.apk)
- [GitHub APK](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/v0.11.77/Kaspire-Android-mainnet-v0.11.77.apk)
- APK SHA-256: `8a486c34f2e4ec31f045085d38afe6a811c1bd2fdaffe8e2378deb91fbff720a`.
