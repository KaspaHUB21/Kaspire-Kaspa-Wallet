# Kaspire Android 0.11.85 — Kasseal transfers and accurate KCC20 discovery status

Build **230**, Android 11+, ARM64 and ARMv7. Complete Android changes since
public **0.11.84/build 229**. The browser extension remains **0.5.27**;
Windows and iOS deployments and update channels are unchanged.

## Send Kasseal tokens

- Kasseal holdings now open the familiar token detail screen, with the image,
  ticker, balance, price per token and balance value, plus separate **Send Asset**
  and **Swap** buttons. Opening an asset no longer redirects immediately to Swap.
- Resolve display prices by the exact covenant ID, never by a shared ticker.
  Missing optional market data does not remove the token's identity or balance.
- Prepare fresh signing cells when sending instead of treating a display-only
  indexed holding as permanently unsendable. Reconstruct the pinned token
  program locally and check the accepted origin and live output on Kaspire's
  own node before native review and signing.
- Use a separate owner-signed Kasseal transfer mode: whole-token units,
  the pinned three-input/three-output reference program, disabled borrowing,
  no extension commitment, and a **5 KAS reserve per new token cell**. The
  review includes any required reserve top-up, released reserve and network fee.
- Preserve Kasseal-compatible policy and reserve for both recipient and change
  cells, including intermediate consolidation transactions. Consolidation above
  the contract's input limit uses the existing reviewed fixed-plan flow.
- **Kasseal Borrowed Receive remains disabled and its swap signing rules are
  unchanged.** Unknown programs, unsupported policies and foreign-owner cells
  remain blocked; this is not blanket acceptance of indexer-provided scripts.

## KCC20 discovery warnings

- Track missing signing data per covenant and clear a source-specific mapping
  warning when a dedicated or fallback source resolves that same holding.
- Do not report obsolete pre-final legacy contracts with the exact known
  legacy program identifier as failed current-standard signing discovery.
  Existing holdings are not deleted and their signing eligibility is not
  broadened by this display correction.
- Recognized KaspaRocket 10/10 token-family rows are handled by the dedicated
  Rocket discovery/signing path instead of producing a duplicate failure in
  the reference-actor loader. A failed Rocket source still reports an error.
- Kasvio's unrecognized global contracts, when explicitly not attributable to
  this wallet, no longer appear as a failed wallet holding. Keep incomplete
  coverage as a separate state: an incomplete empty lookup is **not** shown as
  a confirmed zero-assets wallet. Real current-token verification failures,
  partial pages and unavailable sources remain visible.

## Verification and delivery

- **155 Rust tests and 990 Flutter tests passed.** Sixteen optional Flutter
  checks were skipped in the offline suite. Static analysis reports no errors.
- Local tests use dummy keys and pinned SDK-generated fixtures, including
  signed VM execution of partial/full Kasseal sends and consolidation, and
  rejection of altered programs, foreign owners, borrowing and fractional units.
- App regressions cover the native-mode selection, own-node cell checks,
  recipient policy, exact quantities, legacy/current warning separation,
  incomplete empty discovery, and detail-screen actions across all themes.
- No physical Android device is attached to this build server. Local VM and
  app tests do not constitute an end-to-end Mainnet phone transfer or a full
  independent security audit.
- Both update choices deliver the same release-signed APK: the official
  website download and the matching GitHub release inside Kaspire. Existing
  signing identity, WalletConnect project identity and signed-update trust are
  retained. Android still requires installation approval.
- Install over the existing app. **Do not uninstall or clear app data.**
- Website changes are download metadata only; release notes remain GitHub-only.
- The built APK's package, version/build, CRCs, both updated native libraries,
  public client configuration, WalletConnect identity, 16 KB ZIP alignment and
  release signature were verified.
- Release certificate SHA-256:
  `0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`.

## Downloads

- [Official APK](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.85.apk)
- [GitHub APK](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/v0.11.85/Kaspire-Android-mainnet-v0.11.85.apk)
- [APK SHA-256](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.85.apk.sha256)
- APK SHA-256: `801d68cd042415dc1e8028e8f63d25e0fae5603ba5e0baf6b9be97abf0c8a1dc`.
- [All changes since 0.11.84](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/compare/v0.11.84...v0.11.85)
