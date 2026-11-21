# Kaspire Android 0.11.116

2026-11-22. Android build **264**, cumulative since public **0.11.113 (261)**,
including the changes tested in 0.11.114 and 0.11.115.

## Trestly in the dApp browser

- Adds **Trestly** at **https://trestly.io/**, in second position directly below
  Kasvio, with its official bundled SVG logo. Other entries retain their order.
- Uses the existing Kaspire Mobile / WalletConnect pairing route, browser-origin
  binding, user connection approval and native signing reviews. No provider,
  transaction method or signing-policy expansion is introduced.
- Only the exact HTTPS origin `trestly.io` is approved. HTTP, credentials,
  nonstandard ports, lookalike domains and unrelated top-level navigation remain
  blocked. Existing WebView restrictions and recovery-download permissions stay.
- This is an entry for Trestly's existing website, not a new native bridge or
  swap implementation, and is not an audit of Trestly or its bridge backing.

## Cosmic theme and adaptive layout

- Adds **Cosmic** under Settings → Wallet display → Kaspire design, persisted by
  theme name without changing existing preferences or the default theme.
- Includes dark space artwork, violet/cyan neon surfaces, a real Kaspire wordmark,
  enhanced nebula/starfield action buttons and a planetary-horizon navigation bar.
  Icons, labels, balances, controls and approvals remain live Flutter widgets.
- The balance card now renders its unbranded planet separately in a bounded
  square with proportional `BoxFit.contain` scaling. It cannot stretch with a
  wider card; the old combined/stretched planet background is no longer packaged.
  The Kaspire logo inside the planet was removed as requested.
- Improves compact and large-text header/action layout, with checks covering
  narrow phones, foldable/tablet widths and landscape. The regular wallet-manager
  icon, privacy toggle, theme-independent lockscreen and QR contrast are retained.

## Aligned KAS payment details in every theme

- KAS payment reviews and success receipts now use a shared two-column layout.
  Values start at one common **left edge**, rather than floating with text length.
  Labels and values wrap independently on narrow displays or with large text;
  amounts, fees, debit, change, network, input/output counts, mass and time remain
  complete. This is presentation-only; payment calculations and signing do not
  change.

## Validation and public delivery

- **184 Flutter tests** passed, covering Trestly order/logo/origin policy, existing
  pairing/session/recovery and token reviews, Cosmic layouts and unbranded
  proportional planet rendering, all-theme payment columns, QR and lockscreen.
  Focused static analysis is clean. A read-only mobile Chromium check loaded the
  actual Trestly site successfully without connecting a wallet or starting a
  pairing/payment. Actual built APK package checks are required before publication.
- The public ARM64/ARMv7 APK preserves the release signing identity/lineage,
  public-client configuration and permissions. Native libraries are byte-identical
  to the checked prior release; new artwork and Trestly's logo are verified inside
  the built package. No physical-device or live-payment test is claimed.
- Publishes the GitHub release, website version/checksum/download and signed
  Android update manifest. Both Android update routes deliver identical APK bytes
  using installed clients' existing update trust.
- Browser Extension **0.5.32**, iOS PWA and Windows channels are unchanged.
  Unrelated in-progress marketplace recovery changes and private experiment
  directories are excluded from this APK and commit. Release notes remain on
  GitHub, not embedded in the website download section.

Android APK: `Kaspire-Android-mainnet-v0.11.116.apk`

SHA-256: `a0b458cca3fac15ae2d27ba10db2b93b78284e0b094f6995940cac39c41c27b4`
