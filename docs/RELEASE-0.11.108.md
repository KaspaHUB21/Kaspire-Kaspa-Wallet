# Kaspire Android 0.11.108 — Unified biometric lockscreen

2026-11-14. Android build **256**, cumulative changes since the last public
Android release **0.11.107 (255)**.

## New lockscreen

- Brings the latest iOS PWA lockscreen artwork and layout to Android: centered
  Kaspire wordmark, illuminated logo above the mountain, dark teal controls and
  the lower mountain landscape. Artwork is bundled locally; opening the locked
  wallet does not fetch it from a server.
- The locked view is the same in every theme. The selected wallet theme appears
  after unlocking. There is no duplicate biometric badge over the mountain.
- Android uses a **fingerprint icon** and **Use Biometrics** instead of Face ID.
  Only devices with enrolled biometrics display that action.
- **Enter wallet PIN** and **Unlock** open Kaspire's existing protected native
  PIN dialog directly, without the extra authentication-method chooser. This
  intentionally differs from the PWA's editable password field: no PIN input or
  keystrokes are moved into Flutter. Devices without a Kaspire PIN retain the
  existing Android device-lock authentication fallback.
- A verified **Update available** action is accessible while the wallet remains
  locked and opens the existing website/GitHub update-choice dialog.
- The screen scrolls on small or landscape displays and supports enlarged text.
  Errors remain readable; cancelling or failing authentication permits retry.

## Security and compatibility

- Authentication remains native. The new biometric shortcut requires a successful
  biometric-only platform result; the PIN shortcut requires native PIN validation.
  No wallet session is activated on failure, cancellation or a late response
  after the lockscreen has been disposed. Repeated taps do not open parallel
  authentication attempts.
- Wallet storage, PIN retry controls, transaction approvals, signing policy,
  permissions, package identity, release certificate and signing lineage are
  unchanged. Both ARM architectures retain the exact native libraries from
  public 0.11.107, including its Toccata PSKT diagnostics and 64-KiB script limit.
- No DEX, indexer, KaspaCom or payment-protocol changes are included. Windows,
  extension **0.5.31** and the iOS PWA are unchanged.

## Validation and delivery

- 77 automated tests cover Android and Windows unlocking, all ten themes,
  failed/cancelled authentication, native-channel routing, repeated taps,
  session activation/disposal, small/landscape layouts, update choices, update
  manifest checks, PSKT reviews and existing KCC20 authorization checks.
- The Android view was rendered locally with the real bundled artwork and fonts.
  The built APK is checked for its package/version, release signature, alignment,
  both ARM ABIs, unchanged native libraries and permissions, and bundled assets.
  No physical-device biometric test or live payment was performed.
- **Both update routes** deliver the same signed APK: the official website and
  the matching GitHub Release used by the signed in-app updater. The website
  version/checksum and signed Android update manifest are updated together.
  Existing wallets upgrade without reinstalling or reimporting.

APK: `Kaspire-Android-mainnet-v0.11.108.apk`.

SHA-256: `163a82df8d416f82d63d35ea83212219c36f79be75eeefc1c4a7302e3bfde86e`
